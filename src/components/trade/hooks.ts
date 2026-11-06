// Data hooks for the Trade page: balances, allowance, quotes, pool price, recent swaps.
// All on-chain values come from Arc Testnet; nothing here is estimated or filled in.
import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { usePublicClient, useReadContract } from 'wagmi'
import { arcTestnet } from 'viem/chains'
import { BaseError, ContractFunctionRevertedError, encodeAbiParameters, erc20Abi, keccak256, parseAbiParameters, type PublicClient } from 'viem'
import { ADDR, DEPLOY_BLOCK, USDC_EURC_POOL, v4QuoterAbi, venueAbi } from '@/lib/contracts'
import type { ListedAsset } from '@/lib/assets'

export type Side = 'buy' | 'sell'
export const USDC_DECIMALS = 6
const lc = (a: string) => a.toLowerCase()
export const isUsdc = (a: string) => lc(a) === lc(ADDR.usdc)
/** EURC trades on the real Uniswap v4 pool; its venue.quote() always reverts, so we quote via the v4 Quoter. */
export const isV4 = (a: ListedAsset) => lc(a.venue) === lc(ADDR.uniVenue) && lc(a.token) === lc(ADDR.eurc)
export const isMirrorVenue = (a: ListedAsset) => lc(a.venue) === lc(ADDR.mirrorVenue)

export function useDebounced<T>(value: T, ms = 400): T {
  const [v, setV] = useState(value)
  useEffect(() => {
    const id = setTimeout(() => setV(value), ms)
    return () => clearTimeout(id)
  }, [value, ms])
  return v
}

function useArc() {
  return usePublicClient({ chainId: arcTestnet.id })
}

/** ERC-20 balances (USDC via its 6-decimal ERC-20 interface, never the native 18-decimal balance). Keys are lowercase. */
export function useTokenBalances(account: `0x${string}` | undefined, tokens: `0x${string}`[]) {
  const client = useArc()
  const all = Array.from(new Set([ADDR.usdc, ...tokens].map(lc))) as `0x${string}`[]
  return useQuery({
    queryKey: ['trade', 'balances', account, all.join(',')],
    enabled: Boolean(client && account),
    refetchInterval: 15_000,
    queryFn: async () => {
      // one eth_call via Multicall3 (the public RPC rate-limits bursts)
      const res = await client!.multicall({ allowFailure: true, contracts: all.map((t) => ({ address: t, abi: erc20Abi, functionName: 'balanceOf' as const, args: [account!] as const })) })
      const out: Record<string, bigint> = {}
      res.forEach((r, i) => {
        if (r.status === 'success') out[all[i]] = r.result as bigint
      })
      return out
    },
  })
}

export function useAllowance(account: `0x${string}` | undefined, token: `0x${string}`, spender: `0x${string}`) {
  const client = useArc()
  return useQuery({
    queryKey: ['trade', 'allowance', account, lc(token), lc(spender)],
    enabled: Boolean(client && account),
    queryFn: () => client!.readContract({ address: token, abi: erc20Abi, functionName: 'allowance', args: [account!, spender] }),
  })
}

export function useVenueName(asset: ListedAsset | undefined) {
  const v4 = asset ? isV4(asset) : false
  const r = useReadContract({ address: asset?.venue, abi: venueAbi, functionName: 'name', chainId: arcTestnet.id, query: { enabled: Boolean(asset && !v4), staleTime: Infinity } })
  if (!asset) return null
  return v4 ? 'Uniswap v4 · Arc testnet' : (r.data ?? null)
}

const REASONS: Record<string, string> = {
  TradeTooLarge: 'Above the venue limit of 5,000 USDC per trade.',
  RiskBlocked: 'Buys are paused for this asset by its risk level.',
  InsufficientReserve: 'The venue does not hold enough USDC to fill this sell.',
  Unsupported: 'This venue cannot route this pair or size.',
  MinOut: 'Price moved past your slippage limit.',
}

/** Readable reason from a viem contract error. */
export function revertReason(e: unknown): string {
  if (e instanceof BaseError) {
    const r = e.walk((x) => x instanceof ContractFunctionRevertedError)
    const name = r instanceof ContractFunctionRevertedError ? r.data?.errorName : undefined
    if (name && REASONS[name]) return REASONS[name]
    if (name) return `Reverted: ${name}`
    return e.shortMessage
  }
  return (e as Error)?.message ?? 'Quote failed'
}

async function fetchQuote(client: PublicClient, asset: ListedAsset, side: Side, amountIn: bigint): Promise<bigint> {
  const tokenIn = side === 'buy' ? ADDR.usdc : asset.token
  const tokenOut = side === 'buy' ? asset.token : ADDR.usdc
  if (isV4(asset)) {
    // eth_call (not staticcall) so the Quoter's revert-and-decode trick works
    const { result } = await client.simulateContract({
      address: ADDR.v4Quoter,
      abi: v4QuoterAbi,
      functionName: 'quoteExactInputSingle',
      args: [{ poolKey: USDC_EURC_POOL, zeroForOne: isUsdc(tokenIn), exactAmount: amountIn, hookData: '0x' }],
    })
    return result[0]
  }
  return client.readContract({ address: asset.venue, abi: venueAbi, functionName: 'quote', args: [tokenIn, tokenOut, amountIn] })
}

export function useQuote(asset: ListedAsset | undefined, side: Side, amountIn: bigint | null) {
  const client = useArc()
  return useQuery({
    queryKey: ['trade', 'quote', asset?.token, side, amountIn?.toString()],
    enabled: Boolean(client && asset && amountIn && amountIn > 0n),
    refetchInterval: 15_000,
    retry: false,
    queryFn: () => fetchQuote(client as PublicClient, asset!, side, amountIn!),
  })
}

const stateViewAbi = [
  {
    type: 'function', name: 'getSlot0', stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [{ name: 'sqrtPriceX96', type: 'uint160' }, { name: 'tick', type: 'int24' }, { name: 'protocolFee', type: 'uint24' }, { name: 'lpFee', type: 'uint24' }],
  },
] as const

const POOL_ID = keccak256(
  encodeAbiParameters(parseAbiParameters('address, address, uint24, int24, address'), [
    USDC_EURC_POOL.currency0, USDC_EURC_POOL.currency1, USDC_EURC_POOL.fee, USDC_EURC_POOL.tickSpacing, USDC_EURC_POOL.hooks,
  ]),
)

/** Mid price of the testnet USDC/EURC v4 pool, in USDC per EURC (both 6 decimals; USDC is currency0). */
export function usePoolPrice(enabled: boolean) {
  const client = useArc()
  return useQuery({
    queryKey: ['trade', 'poolPrice', POOL_ID],
    enabled: Boolean(client && enabled),
    refetchInterval: 15_000,
    queryFn: async () => {
      const [sqrtP] = await client!.readContract({ address: ADDR.v4StateView, abi: stateViewAbi, functionName: 'getSlot0', args: [POOL_ID] })
      if (sqrtP === 0n) return null
      const s = Number(sqrtP) / 2 ** 96
      const eurcPerUsdc = s * s
      return eurcPerUsdc > 0 ? 1 / eurcPerUsdc : null
    },
  })
}

export type SwapRow = { hash: `0x${string}`; block: bigint; at: number | null; caller: `0x${string}`; side: Side; tokenAmt: bigint; usdcAmt: bigint }
export type SwapScan = { rows: SwapRow[]; scannedFrom: bigint; complete: boolean }
type RawSwap = { hash: `0x${string}`; block: bigint; idx: number; caller: `0x${string}`; tokenIn: string; tokenOut: string; amountIn: bigint; amountOut: bigint }

const swappedEvent = venueAbi.filter((x) => x.type === 'event' && x.name === 'Swapped')
// The Arc testnet RPC rejects eth_getLogs ranges above 10k blocks ("requested range too large") and rate-limits
// bursts, so chunks are 10k and fetched one at a time. Scanned history is cached for the session and shared by
// all assets: later refetches only read new blocks, and go further back only while an asset has < MAX_ROWS rows.
const CHUNK = 10_000n
const MAX_ROWS = 25
const MAX_BACK_PER_FETCH = 12
const scan = { from: null as bigint | null, to: null as bigint | null, logs: [] as RawSwap[], times: new Map<bigint, number>() }
let lock: Promise<unknown> = Promise.resolve()

async function readSwaps(c: PublicClient, fromBlock: bigint, toBlock: bigint): Promise<RawSwap[]> {
  const logs = await c.getContractEvents({ address: [ADDR.mirrorVenue, ADDR.uniVenue], abi: swappedEvent, eventName: 'Swapped', fromBlock, toBlock })
  const out: RawSwap[] = []
  for (const l of logs) {
    const a = l.args as { caller?: `0x${string}`; tokenIn?: `0x${string}`; tokenOut?: `0x${string}`; amountIn?: bigint; amountOut?: bigint }
    if (!a.tokenIn || !a.tokenOut || a.amountIn === undefined || a.amountOut === undefined || !l.transactionHash || l.blockNumber === null) continue
    out.push({ hash: l.transactionHash, block: l.blockNumber, idx: l.logIndex ?? 0, caller: a.caller ?? '0x', tokenIn: lc(a.tokenIn), tokenOut: lc(a.tokenOut), amountIn: a.amountIn, amountOut: a.amountOut })
  }
  return out
}

function rowsFor(token: string): SwapRow[] {
  const rows: SwapRow[] = []
  for (const s of scan.logs) {
    const buy = s.tokenOut === token && isUsdc(s.tokenIn)
    const sell = s.tokenIn === token && isUsdc(s.tokenOut)
    if (!buy && !sell) continue
    rows.push({ hash: s.hash, block: s.block, at: scan.times.get(s.block) ?? null, caller: s.caller, side: buy ? 'buy' : 'sell', tokenAmt: buy ? s.amountOut : s.amountIn, usdcAmt: buy ? s.amountIn : s.amountOut })
  }
  return rows
}

/** Swapped events for one asset from both venues (newest first), scanned from DEPLOY_BLOCK in 10k-block chunks. */
export function useRecentSwaps(asset: ListedAsset | undefined) {
  const client = useArc()
  return useQuery({
    queryKey: ['trade', 'swaps', asset?.token],
    enabled: Boolean(client && asset),
    refetchInterval: 30_000,
    queryFn: async (): Promise<SwapScan> => {
      const c = client as PublicClient
      const token = lc(asset!.token)
      const run = lock.then(async () => {
        const latest = await c.getBlockNumber()
        let to: bigint = scan.to ?? latest
        let from: bigint = scan.from ?? latest + 1n
        scan.to = to
        scan.from = from
        // new blocks since the last fetch
        while (to < latest) {
          const f: bigint = to + 1n
          const t: bigint = f + CHUNK - 1n < latest ? f + CHUNK - 1n : latest
          scan.logs.push(...(await readSwaps(c, f, t)))
          scan.to = to = t
        }
        // older history, only while this asset still needs rows
        for (let n = 0; from > DEPLOY_BLOCK && rowsFor(token).length < MAX_ROWS && n < MAX_BACK_PER_FETCH; n++) {
          const t: bigint = from - 1n
          const f: bigint = t - CHUNK + 1n > DEPLOY_BLOCK ? t - CHUNK + 1n : DEPLOY_BLOCK
          scan.logs.push(...(await readSwaps(c, f, t)))
          scan.from = from = f
        }
      })
      lock = run.catch(() => undefined)
      await run

      scan.logs.sort((x, y) => (y.block === x.block ? y.idx - x.idx : y.block > x.block ? 1 : -1))
      const top = rowsFor(token).slice(0, MAX_ROWS)
      const missing = Array.from(new Set(top.filter((r) => r.at === null).map((r) => r.block)))
      for (const b of missing) {
        try {
          scan.times.set(b, Number((await c.getBlock({ blockNumber: b })).timestamp))
        } catch {
          /* leave the time empty */
        }
      }
      return { rows: top.map((r) => ({ ...r, at: scan.times.get(r.block) ?? null })), scannedFrom: scan.from ?? DEPLOY_BLOCK, complete: (scan.from ?? DEPLOY_BLOCK) <= DEPLOY_BLOCK }
    },
  })
}

export function ago(sec: number | null): string {
  if (sec === null) return '—'
  const d = Math.max(0, Math.floor(Date.now() / 1000 - sec))
  if (d < 60) return `${d}s ago`
  if (d < 3600) return `${Math.floor(d / 60)} min ago`
  if (d < 86400) return `${Math.floor(d / 3600)} h ago`
  return `${Math.floor(d / 86400)} d ago`
}

export const RISK_LABEL = ['OK', 'Watch', 'No buys', 'Exit'] as const
export const RISK_TONE = ['text-up', 'text-warn', 'text-down', 'text-down'] as const
export const priceOf = (a: ListedAsset | undefined) => (a?.priceE8 != null ? Number(a.priceE8) / 1e8 : null)
