// Listed assets from the on-chain AssetRegistry, with on-chain price/risk. One hook for the whole app.
import { useQuery } from '@tanstack/react-query'
import { usePublicClient } from 'wagmi'
import { arcTestnet } from 'viem/chains'
import { ADDR, registryAbi } from './contracts'

export const CATEGORIES = ['Cash', 'FX', 'Crypto', 'Yield', 'RWA'] as const
export type Category = (typeof CATEGORIES)[number]

export type ListedAsset = {
  token: `0x${string}`
  symbol: string          // on-chain symbol, e.g. "cirBTC.m"
  display: string         // without the ".m" suffix, e.g. "cirBTC"
  category: Category
  decimals: number
  venue: `0x${string}`
  mirror: boolean         // true = testnet mirror priced from Arc mainnet
  mainnetRef: string      // mainnet token address ('' for real testnet assets)
  priceE8: bigint | null  // null = stale or never set (trading disabled)
  observedAt: number | null
  risk: number            // 0 ok, 1 watch, 2 no buys, 3 exit
}

/** Plain-language names for the assets (UI only). */
export const ASSET_NAME: Record<string, string> = {
  USDC: 'USD Coin', EURC: 'Euro Coin', cirBTC: 'Bitcoin (Circle)', WETH: 'Ether', GBPA: 'British Pound',
  syrupUSDC: 'Yield-bearing USDC', XAUM: 'Gold (Matrixdock)', ASTOCK: 'ArcStocks index',
}

export function useAssets() {
  const client = usePublicClient({ chainId: arcTestnet.id })
  return useQuery({
    queryKey: ['assets'],
    enabled: Boolean(client),
    refetchInterval: 30_000,
    queryFn: async (): Promise<ListedAsset[]> => {
      const c = client!
      const tokens = await c.readContract({ address: ADDR.registry, abi: registryAbi, functionName: 'assets' })
      return Promise.all(
        tokens.map(async (t) => {
          const a = await c.readContract({ address: ADDR.registry, abi: registryAbi, functionName: 'assetOf', args: [t] })
          const risk = await c.readContract({ address: ADDR.registry, abi: registryAbi, functionName: 'riskOf', args: [t] })
          let priceE8: bigint | null = null
          let observedAt: number | null = null
          try {
            const [p, at] = await c.readContract({ address: ADDR.registry, abi: registryAbi, functionName: 'priceE8', args: [t] })
            priceE8 = p
            observedAt = Number(at)
          } catch {
            /* stale or unset -> trading disabled */
          }
          return {
            token: t,
            symbol: a.symbol,
            display: a.symbol.replace(/\.m$/, ''),
            category: CATEGORIES[Number(a.category)] ?? 'Cash',
            decimals: Number(a.decimals),
            venue: a.venue,
            mirror: a.mirror,
            mainnetRef: a.mainnetRef,
            priceE8,
            observedAt,
            risk: Number(risk),
          }
        }),
      )
    },
  })
}

export const findAsset = (list: ListedAsset[] | undefined, key: string | undefined) =>
  list?.find((a) => a.display.toLowerCase() === key?.toLowerCase() || a.token.toLowerCase() === key?.toLowerCase())
