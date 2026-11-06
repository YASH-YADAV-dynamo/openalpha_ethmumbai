// Mainnet market data (DISPLAY ONLY) from the GeckoTerminal public API for Arc mainnet.
// On-chain values (holdings, quotes, drift) always come from the contracts, never from here.
// Cached 60s per URL, requests spaced to stay well under the public rate limit. Errors -> null (UI shows "delayed").
import { useQuery } from '@tanstack/react-query'

const BASE = 'https://api.geckoterminal.com/api/v2/networks/arc'
const cache = new Map<string, { at: number; data: unknown }>()
let chain: Promise<unknown> = Promise.resolve()

async function get<T>(path: string): Promise<T | null> {
  const hit = cache.get(path)
  if (hit && Date.now() - hit.at < 60_000) return hit.data as T
  // serialize requests ~400ms apart (about 25/min max under bursts with caching)
  const run = chain.then(async () => {
    // the public API rate-limits per IP (HTTP 429, sent without CORS headers so it surfaces as a network error):
    // back off inside the queue and retry twice before giving up
    for (let attempt = 0; ; attempt++) {
      await new Promise((r) => setTimeout(r, attempt ? 2000 * attempt : 400))
      const res = await fetch(`${BASE}${path}`, { headers: { accept: 'application/json' } }).catch(() => null)
      if ((!res || res.status === 429) && attempt < 2) continue
      if (!res || !res.ok) throw new Error(`gecko ${res?.status ?? 'network'}`)
      return res.json()
    }
  })
  chain = run.catch(() => undefined)
  try {
    const data = await run
    cache.set(path, { at: Date.now(), data })
    return data as T
  } catch {
    return hit ? (hit.data as T) : null
  }
}

export type MarketStat = { priceUsd: number | null; change24h: number | null; volume24h: number | null; liquidityUsd: number | null; topPool: string | null }

type TokenPools = { data?: { attributes: { address: string; reserve_in_usd: string; volume_usd?: { h24?: string }; price_change_percentage?: { h24?: string } } }[] }
type TokenInfo = { data?: { attributes: { price_usd: string | null } } }

/** Price + 24h change + liquidity for a mainnet token (via its deepest pool). */
export async function fetchMarket(mainnetRef: string): Promise<MarketStat> {
  const empty: MarketStat = { priceUsd: null, change24h: null, volume24h: null, liquidityUsd: null, topPool: null }
  if (!mainnetRef) return empty
  const [info, pools] = await Promise.all([get<TokenInfo>(`/tokens/${mainnetRef}`), get<TokenPools>(`/tokens/${mainnetRef}/pools?page=1`)])
  const top = pools?.data?.slice().sort((a, b) => Number(b.attributes.reserve_in_usd) - Number(a.attributes.reserve_in_usd))[0]
  const num = (s?: string | null) => (s === undefined || s === null || s === '' || !Number.isFinite(Number(s)) ? null : Number(s))
  return {
    priceUsd: num(info?.data?.attributes.price_usd),
    change24h: num(top?.attributes.price_change_percentage?.h24),
    volume24h: num(top?.attributes.volume_usd?.h24),
    liquidityUsd: num(top?.attributes.reserve_in_usd),
    topPool: top?.attributes.address ?? null,
  }
}

export function useMarket(mainnetRef: string | undefined) {
  return useQuery({ queryKey: ['market', mainnetRef], queryFn: () => fetchMarket(mainnetRef ?? ''), enabled: Boolean(mainnetRef), staleTime: 60_000, refetchInterval: 60_000 })
}

export type Candle = { t: number; o: number; h: number; l: number; c: number; v: number }
type Ohlcv = { data?: { attributes?: { ohlcv_list?: [number, number, number, number, number, number][] } } }

/** Hourly candles (oldest first) for a mainnet pool. */
export async function fetchCandles(pool: string, limit = 168): Promise<Candle[] | null> {
  const r = await get<Ohlcv>(`/pools/${pool}/ohlcv/hour?limit=${limit}`)
  const list = r?.data?.attributes?.ohlcv_list
  if (!list) return null
  return list.map(([t, o, h, l, c, v]) => ({ t, o, h, l, c, v })).sort((a, b) => a.t - b.t)
}

export function useCandles(pool: string | null | undefined) {
  return useQuery({ queryKey: ['candles', pool], queryFn: () => fetchCandles(pool ?? ''), enabled: Boolean(pool), staleTime: 120_000 })
}

// ---- timeframe-aware OHLCV for the trade chart (same cached, serialized `get`) ----
export type Timeframe = '15m' | '1H' | '4H' | '1D'
export const TIMEFRAMES: Record<Timeframe, { res: 'minute' | 'hour' | 'day'; agg: number; limit: number; sec: number }> = {
  '15m': { res: 'minute', agg: 15, limit: 96, sec: 900 },
  '1H': { res: 'hour', agg: 1, limit: 120, sec: 3600 },
  '4H': { res: 'hour', agg: 4, limit: 120, sec: 14_400 },
  '1D': { res: 'day', agg: 1, limit: 90, sec: 86_400 },
}

/** Candles (oldest first) for an Arc mainnet pool at a timeframe. `token` = mainnet token address so prices are
 *  that token in USD whichever side of the pool it sits on. Throws when the API is unavailable. */
export async function fetchOhlcv(pool: string, tf: Timeframe, token?: string | null): Promise<Candle[]> {
  const t = TIMEFRAMES[tf]
  const q = `aggregate=${t.agg}&limit=${t.limit}&currency=usd${token ? `&token=${token}` : ''}`
  const r = await get<Ohlcv>(`/pools/${pool}/ohlcv/${t.res}?${q}`)
  const list = r?.data?.attributes?.ohlcv_list
  if (!list) throw new Error('candles unavailable') // let react-query retry with backoff
  return list
    .map(([ts, o, h, l, c, v]) => ({ t: ts, o, h, l, c, v }))
    .filter((k) => [k.o, k.h, k.l, k.c].every((x) => Number.isFinite(x) && x > 0))
    .sort((a, b) => a.t - b.t)
}

export function useOhlcv(pool: string | null | undefined, tf: Timeframe, token?: string | null) {
  return useQuery({
    queryKey: ['ohlcv', pool, tf, token ?? null],
    queryFn: () => fetchOhlcv(pool ?? '', tf, token),
    enabled: Boolean(pool),
    staleTime: 60_000,
    refetchInterval: 60_000,
    retry: 3,
    retryDelay: (n: number) => Math.min(20_000, 3_000 * 2 ** n),
    placeholderData: (prev: Candle[] | undefined) => prev, // keep the previous series while a new timeframe loads (no layout jump)
  })
}
