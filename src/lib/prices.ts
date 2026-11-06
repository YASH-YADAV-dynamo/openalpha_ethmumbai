import { useSyncExternalStore } from 'react'
// ONE price book for the whole exchange, so the ticker, tables, pair header, chart and ticket always agree.
//
//   last      = on-chain oracle price (AssetRegistry.priceE8, written by the Chainlink CRE workflow).
//               This is the price trades and bucket rebalances settle against. null = stale → trading disabled.
//   ref       = Arc MAINNET market data (GeckoTerminal): 24h change, volume, liquidity, deepest pool for candles.
//               Display only. For real testnet assets without a mainnet ref (EURC), the mainnet token is found
//               by symbol search on Arc mainnet pools.
//   deviation = (last - ref.priceUsd) / ref.priceUsd, shown so users see oracle vs market drift.
import { useQueries, useQuery } from '@tanstack/react-query'
import { useAssets, type ListedAsset } from './assets'
import { fetchMarket, type MarketStat } from './market'

export type PriceRow = {
  asset: ListedAsset
  last: number | null
  oracleAgeSec: number | null
  stale: boolean
  ref: MarketStat | null
  refToken: string | null // Arc mainnet token address used for ref/candles
  change24h: number | null // percent, e.g. -1.2
  deviation: number | null // fraction
}

const SEARCH = 'https://api.geckoterminal.com/api/v2/search/pools'
type SearchPools = {
  data?: { attributes: { name: string; reserve_in_usd: string }; relationships?: { base_token?: { data?: { id?: string } } } }[]
  included?: { id: string; type: string; attributes?: { coingecko_coin_id?: string | null } }[]
}

/** Arc mainnet token address for a symbol. Only tokens GeckoTerminal links to a CoinGecko listing count (copycat tokens
 *  with the same symbol and inflated pool reserves exist on Arc mainnet); among those, the one with the most total
 *  liquidity across its pools wins. Throws on HTTP/network errors (e.g. a 429) so the query retries instead of
 *  caching "not found". Cached for the session. */
export async function findMainnetToken(symbol: string): Promise<string | null> {
  const r = await fetch(`${SEARCH}?query=${encodeURIComponent(symbol)}&network=arc&include=base_token`, { headers: { accept: 'application/json' } })
  if (!r.ok) throw new Error(`gecko search ${r.status}`)
  const j = (await r.json()) as SearchPools
  const listed = new Set((j.included ?? []).filter((t) => t.type === 'token' && t.attributes?.coingecko_coin_id).map((t) => t.id))
  const depth = new Map<string, number>()
  for (const p of j.data ?? []) {
    const id = p.relationships?.base_token?.data?.id // "arc_0xabc…"
    if (!id || !listed.has(id) || !p.attributes.name.toUpperCase().startsWith(`${symbol.toUpperCase()} /`)) continue
    depth.set(id, (depth.get(id) ?? 0) + (Number(p.attributes.reserve_in_usd) || 0))
  }
  const best = [...depth.entries()].sort((x, y) => y[1] - x[1])[0]?.[0]
  return best?.includes('_') ? best.split('_')[1] : null
}

function useRefTokens(assets: ListedAsset[] | undefined) {
  const needSearch = (assets ?? []).filter((a) => !a.mainnetRef && a.display !== 'USDC').map((a) => a.display)
  return useQuery({
    queryKey: ['refTokens', needSearch.join(',')],
    enabled: needSearch.length > 0,
    staleTime: Infinity,
    retry: 5,
    retryDelay: (n: number) => Math.min(30_000, 2_000 * 2 ** n),
    queryFn: async () => {
      const out: Record<string, string | null> = {}
      for (const s of needSearch) out[s] = await findMainnetToken(s)
      return out
    },
  })
}

// Oracle age needs "now" without calling Date.now() during render: a 5s clock via useSyncExternalStore.
const clockSec = () => Math.floor(Date.now() / 5000) * 5
const subscribeClock = (cb: () => void) => {
  const id = setInterval(cb, 5000)
  return () => clearInterval(id)
}

export function usePriceBook() {
  const assets = useAssets()
  const found = useRefTokens(assets.data)
  const list = assets.data ?? []
  const refOf = (a: ListedAsset) => a.mainnetRef || found.data?.[a.display] || null
  const markets = useQueries({
    queries: list.map((a) => ({
      queryKey: ['market', refOf(a) ?? `none:${a.display}`],
      queryFn: () => fetchMarket(refOf(a) ?? ''),
      enabled: Boolean(refOf(a)),
      staleTime: 60_000,
      refetchInterval: 60_000,
    })),
  })
  const now = useSyncExternalStore(subscribeClock, clockSec)
  const rows: PriceRow[] = list.map((a, i) => {
    const ref = markets[i]?.data ?? null
    const last = a.priceE8 != null ? Number(a.priceE8) / 1e8 : null
    const refPx = ref?.priceUsd ?? null
    return {
      asset: a,
      last,
      oracleAgeSec: a.observedAt ? Math.max(0, now - a.observedAt) : null,
      stale: last === null,
      ref,
      refToken: refOf(a),
      change24h: ref?.change24h ?? null,
      deviation: last !== null && refPx ? (last - refPx) / refPx : null,
    }
  })
  const bySymbol = new Map(rows.map((r) => [r.asset.display.toLowerCase(), r]))
  return { rows, bySymbol, isLoading: assets.isLoading, error: assets.error }
}
