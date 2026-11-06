// Read-side hooks for buckets, templates and wallet balances. All numbers come from the chain.
import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { usePublicClient } from 'wagmi'
import { arcTestnet } from 'viem/chains'
import { erc20Abi, type PublicClient } from 'viem'
import { ADDR, DEPLOY_BLOCK, bucketAbi, factoryAbi, templatesAbi } from '@/lib/contracts'
import type { ListedAsset } from '@/lib/assets'

export type Hex = `0x${string}`

export const NO_TEMPLATE = 2n ** 256n - 1n
/** Arc's public RPC rejects eth_getLogs ranges above 10,000 blocks, so scan in 10k chunks. */
export const LOG_CHUNK = 10_000n

/** Contract-enforced bounds (BucketAccount._validateParams / setSip / _replaceTargets). */
export const BOUNDS = {
  band: [100, 2000],
  slippage: [10, 300],
  maxTrade: [500, 5000],
  cooldownMin: 600,
  sipIntervalMin: 3600,
  runs: [1, 520],
  maxAssets: 12,
} as const

export type Params = { bandBps: number; maxSlippageBps: number; maxTradeBps: number; cooldown: number }
export const DEFAULT_PARAMS: Params = { bandBps: 500, maxSlippageBps: 100, maxTradeBps: 2500, cooldown: 3600 }

export function useArcClient() {
  return usePublicClient({ chainId: arcTestnet.id })
}

/** Unix seconds, ticking. */
export function useNow(everyMs = 5_000) {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), everyMs)
    return () => clearInterval(id)
  }, [everyMs])
  return now
}

/** Block ranges [from, to] covering DEPLOY_BLOCK..latest, newest first. */
export async function blockChunks(client: PublicClient, from = DEPLOY_BLOCK) {
  const latest = await client.getBlockNumber()
  const out: [bigint, bigint][] = []
  for (let f = from; f <= latest; f += LOG_CHUNK) out.push([f, f + LOG_CHUNK - 1n > latest ? latest : f + LOG_CHUNK - 1n])
  return out.reverse()
}

/** Run async jobs with bounded concurrency, preserving order. */
export async function pool<T, R>(items: T[], n: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = []
  let i = 0
  await Promise.all(
    Array.from({ length: Math.min(n, items.length) }, async () => {
      while (i < items.length) {
        const k = i++
        out[k] = await fn(items[k])
      }
    }),
  )
  return out
}

// ---------- templates ----------

export type Template = {
  id: bigint
  name: string
  description: string
  tokens: readonly Hex[]
  weightsBps: readonly number[]
  bandBps: number
  version: number
  rationaleHash: Hex
}

export function useTemplates() {
  const client = useArcClient()
  return useQuery({
    queryKey: ['bucket', 'templates'],
    enabled: Boolean(client),
    staleTime: 60_000,
    queryFn: async (): Promise<Template[]> => {
      const c = client!
      const n = await c.readContract({ address: ADDR.templates, abi: templatesAbi, functionName: 'templateCount' })
      const ids = Array.from({ length: Number(n) }, (_, i) => BigInt(i))
      const res = await c.multicall({
        allowFailure: false,
        contracts: ids.map((id) => ({ address: ADDR.templates, abi: templatesAbi, functionName: 'templateOf', args: [id] }) as const),
      })
      return res.map((t, i) => ({ id: ids[i], ...t, weightsBps: t.weightsBps.map(Number), bandBps: Number(t.bandBps), version: Number(t.version) }))
    },
  })
}

// ---------- names (from factory BucketCreated events) ----------

export type Creation = { bucket: Hex; owner: Hex; templateId: bigint; name: string; block: bigint }

async function scanCreations(client: PublicClient, args: { owner?: Hex; bucket?: Hex }): Promise<Creation[]> {
  const chunks = await blockChunks(client)
  const parts = await pool(chunks, 4, ([fromBlock, toBlock]) =>
    client.getContractEvents({ address: ADDR.factory, abi: factoryAbi, eventName: 'BucketCreated', args, fromBlock, toBlock }),
  )
  return parts.flat().map((l) => ({
    bucket: l.args.bucket as Hex,
    owner: l.args.owner as Hex,
    templateId: l.args.templateId ?? NO_TEMPLATE,
    name: l.args.name ?? '',
    block: l.blockNumber,
  }))
}

/** bucket address (lowercase) -> creation info, for an owner's buckets. */
export function useCreationsByOwner(owner: Hex | undefined) {
  const client = useArcClient()
  return useQuery({
    queryKey: ['bucket', 'creations', owner],
    enabled: Boolean(client && owner),
    staleTime: 60_000,
    queryFn: async () => {
      const list = await scanCreations(client!, { owner })
      return new Map(list.map((c) => [c.bucket.toLowerCase(), c]))
    },
  })
}

export function useCreation(bucket: Hex) {
  const client = useArcClient()
  return useQuery({
    queryKey: ['bucket', 'creation', bucket.toLowerCase()],
    enabled: Boolean(client),
    staleTime: 300_000,
    queryFn: async () => (await scanCreations(client!, { bucket }))[0] ?? null,
  })
}

// ---------- bucket state ----------

export type BucketState = {
  address: Hex
  owner: Hex
  tokens: readonly Hex[]
  amounts: readonly bigint[]
  valuesE18: readonly bigint[]
  totalE18: bigint
  targets: { tokens: readonly Hex[]; weights: readonly number[] }
  /** null when driftBps() reverts (usually a stale price on a held asset). */
  drift: { max: number; perAsset: readonly number[] } | null
  params: Params
  sip: { amount: bigint; interval: number; runsLeft: number; nextAt: number; active: boolean }
  paused: boolean
  lastRebalance: number
  follow: { templateId: bigint; following: boolean; version: number }
}

export const bucketStateKey = (a: Hex) => ['bucket', 'state', a.toLowerCase()]

export async function readBucket(c: PublicClient, address: Hex): Promise<BucketState> {
  const b = { address, abi: bucketAbi } as const
  const r = await c.multicall({
    allowFailure: true,
    contracts: [
      { ...b, functionName: 'owner' },
      { ...b, functionName: 'holdings' },
      { ...b, functionName: 'targets' },
      { ...b, functionName: 'driftBps' },
      { ...b, functionName: 'params' },
      { ...b, functionName: 'sip' },
      { ...b, functionName: 'sipActive' },
      { ...b, functionName: 'paused' },
      { ...b, functionName: 'lastRebalance' },
      { ...b, functionName: 'follow' },
    ],
  })
  const [owner, holdings, targets, drift, params, sip, sipActive, paused, lastRebalance, follow] = r
  if (owner.status !== 'success' || holdings.status !== 'success' || targets.status !== 'success' || params.status !== 'success') {
    throw new Error('Not a bucket on Arc Testnet')
  }
  const [tokens, amounts, valuesE18, totalE18] = holdings.result
  const p = params.result
  const s = sip.status === 'success' ? sip.result : ([0n, 0, 0, 0n] as const)
  const f = follow.status === 'success' ? follow.result : ([NO_TEMPLATE, false, 0] as const)
  return {
    address,
    owner: owner.result,
    tokens,
    amounts,
    valuesE18,
    totalE18,
    targets: { tokens: targets.result[0], weights: targets.result[1].map(Number) },
    drift: drift.status === 'success' ? { max: Number(drift.result[0]), perAsset: drift.result[1].map(Number) } : null,
    params: { bandBps: Number(p.bandBps), maxSlippageBps: Number(p.maxSlippageBps), maxTradeBps: Number(p.maxTradeBps), cooldown: Number(p.cooldown) },
    sip: {
      amount: s[0],
      interval: Number(s[1]),
      runsLeft: Number(s[2]),
      nextAt: Number(s[3]),
      active: sipActive.status === 'success' ? sipActive.result : false,
    },
    paused: paused.status === 'success' ? paused.result : false,
    lastRebalance: lastRebalance.status === 'success' ? Number(lastRebalance.result) : 0,
    follow: { templateId: f[0], following: f[1], version: Number(f[2]) },
  }
}

export function useBucket(address: Hex | undefined) {
  const client = useArcClient()
  return useQuery({
    queryKey: bucketStateKey(address ?? '0x'),
    enabled: Boolean(client && address),
    refetchInterval: 15_000,
    retry: 1,
    queryFn: () => readBucket(client!, address!),
  })
}

export function useBucketsOf(owner: Hex | undefined) {
  const client = useArcClient()
  return useQuery({
    queryKey: ['bucket', 'list', owner],
    enabled: Boolean(client && owner),
    refetchInterval: 30_000,
    queryFn: () => client!.readContract({ address: ADDR.factory, abi: factoryAbi, functionName: 'bucketsOf', args: [owner!] }),
  })
}

// ---------- derived ----------

export type RebalanceGate = { ok: boolean; reason: string; readyAt: number }

/** Mirrors BucketAccount.rebalance() preconditions as far as the UI can see them. */
export function rebalanceGate(s: BucketState, now: number): RebalanceGate {
  const readyAt = s.lastRebalance + s.params.cooldown
  if (s.paused) return { ok: false, reason: 'Paused by owner', readyAt }
  if (!s.drift) return { ok: false, reason: 'Drift unavailable: a held asset has a stale price', readyAt }
  if (s.totalE18 === 0n) return { ok: false, reason: 'Empty: deposit first', readyAt }
  if (s.drift.max <= s.params.bandBps) return { ok: false, reason: 'Within band', readyAt }
  if (now < readyAt) return { ok: false, reason: `Cooldown, ready ${until(readyAt, now)}`, readyAt }
  return { ok: true, reason: 'Drift is past the band', readyAt }
}

export function sipDue(s: BucketState, now: number) {
  return !s.paused && s.sip.active && s.sip.runsLeft > 0 && now >= s.sip.nextAt
}

/** "in 12m" / "now" / "3h ago" */
export function until(ts: number, now: number) {
  const d = ts - now
  const a = Math.abs(d)
  const txt = a < 60 ? `${a}s` : a < 3600 ? `${Math.round(a / 60)}m` : a < 86400 ? `${Math.round(a / 3600)}h` : `${Math.round(a / 86400)}d`
  if (a < 5) return 'now'
  return d > 0 ? `in ${txt}` : `${txt} ago`
}

export function duration(sec: number) {
  if (sec % 86400 === 0) return `${sec / 86400}d`
  if (sec % 3600 === 0) return `${sec / 3600}h`
  if (sec % 60 === 0) return `${sec / 60}m`
  return `${sec}s`
}

export const dateTime = (ts: number) =>
  ts ? new Date(ts * 1000).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—'

/** USD value of a raw token amount using the registry price; null when price is stale/unset. */
export function valueOf(asset: ListedAsset | undefined, amount: bigint): number | null {
  if (!asset || asset.priceE8 === null) return null
  return (Number(amount) / 10 ** asset.decimals) * (Number(asset.priceE8) / 1e8)
}

// ---------- wallet ----------

/** ERC-20 balances of every listed asset for `owner`. */
export function useWalletBalances(owner: Hex | undefined, assets: ListedAsset[] | undefined) {
  const client = useArcClient()
  return useQuery({
    queryKey: ['bucket', 'wallet', owner, assets?.map((a) => a.token).join()],
    enabled: Boolean(client && owner && assets?.length),
    refetchInterval: 20_000,
    queryFn: async () => {
      const r = await client!.multicall({
        allowFailure: true,
        contracts: assets!.map((a) => ({ address: a.token, abi: erc20Abi, functionName: 'balanceOf', args: [owner!] }) as const),
      })
      return new Map(assets!.map((a, i) => [a.token.toLowerCase(), r[i].status === 'success' ? r[i].result ?? null : null]))
    },
  })
}

/** USDC (ERC-20, 6 decimals) balance of `owner` and allowance to `spender`. */
export function useUsdc(owner: Hex | undefined, spender: Hex | undefined) {
  const client = useArcClient()
  return useQuery({
    queryKey: ['bucket', 'usdc', owner, spender],
    enabled: Boolean(client && owner && spender),
    refetchInterval: 15_000,
    queryFn: async () => {
      const [balance, allowance] = await client!.multicall({
        allowFailure: false,
        contracts: [
          { address: ADDR.usdc, abi: erc20Abi, functionName: 'balanceOf', args: [owner!] },
          { address: ADDR.usdc, abi: erc20Abi, functionName: 'allowance', args: [owner!, spender!] },
        ],
      })
      return { balance, allowance }
    },
  })
}

/** Indices of held assets whose value couldn't be priced (amount > 0 but value 0: stale or missing price). */
export function unpriced(s: BucketState) {
  return s.tokens.map((_, i) => i).filter((i) => s.amounts[i] > 0n && s.valuesE18[i] === 0n)
}

/** Value share per holding (same order as s.tokens), or null when unknown (empty, or a held asset is unpriced). */
export function actualShares(s: BucketState): number[] | null {
  if (s.totalE18 === 0n || unpriced(s).length) return null
  return s.valuesE18.map((v) => Number(v) / 1e18)
}

/** Target weight per holding token (0 when the token is held but not targeted). */
export function targetFor(s: BucketState, token: string) {
  const i = s.targets.tokens.findIndex((t) => t.toLowerCase() === token.toLowerCase())
  return i >= 0 ? s.targets.weights[i] : 0
}
