// Risk + rebalance planning helpers for the bucket pages. Pure functions mirror BucketAccount.rebalance()
// (sells first, then buys, each capped at maxTradeBps of value, buys skipped at risk >= 2, risk 3 exits to USDC).
import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { ADDR, registryAbi } from '@/lib/contracts'
import type { ListedAsset } from '@/lib/assets'
import { e18 } from '@/lib/format'
import { duration, until, useArcClient, type BucketState, type Hex } from './data'

export const RISK = [
  { label: 'Normal', tone: 'up', action: 'Trades normally.' },
  { label: 'Watch', tone: 'warn', action: 'Monitored by the risk workflow; trades normally for now.' },
  { label: 'No buys', tone: 'down', action: 'Rebalances and SIP runs skip buying it; existing units stay and can still be sold if overweight.' },
  { label: 'Exit', tone: 'down', action: 'Its target moves to USDC: the next rebalance sells it, even inside the band.' },
] as const

export const riskOf = (level: number) => RISK[Math.max(0, Math.min(3, level))]

export const assetOf = (token: string, assets: ListedAsset[] | undefined) =>
  assets?.find((a) => a.token.toLowerCase() === token.toLowerCase())

export const isUsdc = (token: string) => token.toLowerCase() === ADDR.usdc.toLowerCase()

/** Registry maxStaleness (seconds). Prices older than this revert valueE18, which blocks rebalancing. */
export function useMaxStaleness() {
  const client = useArcClient()
  return useQuery({
    queryKey: ['registry', 'maxStaleness'],
    enabled: Boolean(client),
    staleTime: 300_000,
    queryFn: async () => Number(await client!.readContract({ address: ADDR.registry, abi: registryAbi, functionName: 'maxStaleness' })),
  })
}

/** Query string after `#/path?`. Read on mount and on hash changes. */
export function useHashQuery() {
  const read = () => new URLSearchParams(window.location.hash.split('?')[1] ?? '')
  const [q, setQ] = useState(read)
  useEffect(() => {
    const on = () => setQ(read())
    window.addEventListener('hashchange', on)
    return () => window.removeEventListener('hashchange', on)
  }, [])
  return q
}

/** Update `?key=value` in the hash without firing hashchange (no scroll jump). */
export function replaceHashQuery(key: string, value: string) {
  const [path, qs] = window.location.hash.replace(/^#/, '').split('?')
  const q = new URLSearchParams(qs ?? '')
  q.set(key, value)
  history.replaceState(null, '', `#${path}?${q.toString()}`)
}

// ---------- gates ----------

export type Check = { label: string; ok: boolean; detail: string }
export type Gate = { ok: boolean; reason: string; checks: Check[]; exitHeld: boolean; readyAt: number }

/** Held (amount > 0, priced) assets the registry has flagged Exit (risk 3). */
export function exitHeld(s: BucketState, assets: ListedAsset[] | undefined) {
  return s.tokens.some((t, i) => (assetOf(t, assets)?.risk ?? 0) === 3 && s.amounts[i] > 0n && s.valuesE18[i] > 0n)
}

/**
 * Every rebalance precondition the UI can see, in contract order. Unlike data.rebalanceGate this also knows
 * that a held Exit-level asset triggers a rebalance even when drift is inside the band.
 */
export function rebalanceChecks(s: BucketState, now: number, assets: ListedAsset[] | undefined): Gate {
  const readyAt = s.lastRebalance + s.params.cooldown
  const exit = exitHeld(s, assets)
  const staleSyms = s.tokens.filter((t) => assetOf(t, assets)?.priceE8 === null).map((t) => assetOf(t, assets)?.display ?? t.slice(0, 8))
  const checks: Check[] = [
    { label: 'Not paused', ok: !s.paused, detail: s.paused ? 'The owner paused this bucket.' : 'Active.' },
    {
      label: 'Fresh oracle prices',
      ok: Boolean(s.drift),
      detail: s.drift ? 'Every asset in the bucket has a price within the registry staleness window.' : `No fresh on-chain price for ${staleSyms.join(', ') || 'a held asset'}; the contract can't value the bucket until the CRE workflow updates it.`,
    },
    { label: 'Has value', ok: s.totalE18 > 0n, detail: s.totalE18 > 0n ? 'Funded.' : 'Empty: deposit USDC first.' },
    {
      label: 'Drift past band',
      ok: Boolean(s.drift && (s.drift.max > s.params.bandBps || exit)),
      detail: !s.drift
        ? 'Unknown while a price is stale.'
        : exit
          ? 'An Exit-level asset is held, so the band is ignored.'
          : s.drift.max > s.params.bandBps
            ? `Max drift ${(s.drift.max / 100).toFixed(2)}% is past the ${(s.params.bandBps / 100).toFixed(2)}% band.`
            : `Max drift ${(s.drift.max / 100).toFixed(2)}% is within the ${(s.params.bandBps / 100).toFixed(2)}% band. Nothing to do.`,
    },
    {
      label: 'Cooldown ended',
      ok: now >= readyAt,
      detail: now >= readyAt ? `${duration(s.params.cooldown)} cooldown has passed.` : `${duration(s.params.cooldown)} cooldown, ready ${until(readyAt, now)}.`,
    },
  ]
  const first = checks.find((c) => !c.ok)
  const reason = first
    ? first.label === 'Drift past band' && s.drift
      ? 'Within band'
      : first.label === 'Cooldown ended'
        ? `Cooldown, ready ${until(readyAt, now)}`
        : first.label === 'Fresh oracle prices'
          ? 'Stale price: rebalance blocked'
          : first.label === 'Has value'
            ? 'Empty: deposit first'
            : 'Paused by owner'
    : exit
      ? 'Exit-level asset held'
      : 'Drift is past the band'
  return { ok: !first, reason, checks, exitHeld: exit, readyAt }
}

// ---------- order preview ----------

export type Order = {
  token: Hex
  step: 1 | 2
  side: 'Sell' | 'Buy' | 'Skip'
  driftBps: number
  wantUsd: number
  sizeUsd: number
  minOutUsd: number
  capped: boolean
  note: string
}

/**
 * Planned orders for the next rebalance from the contract's own drift numbers. Sizes are estimates at the
 * oracle price (the contract recomputes them on-chain); USDC available to buys includes sell proceeds.
 */
export function planRebalance(s: BucketState, assets: ListedAsset[] | undefined): Order[] | null {
  if (!s.drift || s.totalE18 === 0n) return null
  const total = e18(s.totalE18)
  const cap = (s.params.maxTradeBps / 10_000) * total
  const slip = 1 - s.params.maxSlippageBps / 10_000
  const usdcIdx = s.tokens.findIndex(isUsdc)
  let cash = usdcIdx >= 0 ? e18(s.valuesE18[usdcIdx]) : 0
  const sells: Order[] = []
  const buys: Order[] = []
  s.tokens.forEach((t, i) => {
    const d = s.drift!.perAsset[i] ?? 0
    if (isUsdc(t) || d === 0) return
    const want = (Math.abs(d) / 10_000) * total
    const risk = assetOf(t, assets)?.risk ?? 0
    if (d > 0) {
      const size = Math.min(want, cap, e18(s.valuesE18[i]))
      cash += size
      sells.push({ token: t, step: 1, side: 'Sell', driftBps: d, wantUsd: want, sizeUsd: size, minOutUsd: size * slip, capped: want > cap, note: risk === 3 ? 'Exit to USDC' : 'Overweight' })
    } else if (risk >= 2) {
      buys.push({ token: t, step: 2, side: 'Skip', driftBps: d, wantUsd: want, sizeUsd: 0, minOutUsd: 0, capped: false, note: risk === 3 ? 'Exit: never bought' : 'No buys (risk 2)' })
    } else {
      buys.push({ token: t, step: 2, side: 'Buy', driftBps: d, wantUsd: want, sizeUsd: 0, minOutUsd: 0, capped: want > cap, note: 'Underweight' })
    }
  })
  for (const b of buys) {
    if (b.side !== 'Buy') continue
    const size = Math.max(0, Math.min(b.wantUsd, cap, cash))
    cash -= size
    b.sizeUsd = size
    b.minOutUsd = size * slip
    if (size < Math.min(b.wantUsd, cap)) b.note = 'Limited by USDC on hand'
  }
  return [...sells, ...buys]
}

/** Per-token USD value across buckets (only fully priced buckets count), largest first. */
export function aggregate(states: (BucketState | undefined)[]) {
  const m = new Map<string, { token: Hex; usd: number }>()
  for (const s of states) {
    if (!s) continue
    s.tokens.forEach((t, i) => {
      const v = e18(s.valuesE18[i])
      if (v <= 0) return
      const k = t.toLowerCase()
      const cur = m.get(k)
      if (cur) cur.usd += v
      else m.set(k, { token: t, usd: v })
    })
  }
  return [...m.values()].sort((a, b) => b.usd - a.usd)
}

/** Integer bps that sum to 10,000 for a list of values (largest-remainder). */
export function toBps(values: number[]) {
  const sum = values.reduce((a, b) => a + b, 0)
  if (sum <= 0) return values.map(() => 0)
  const raw = values.map((v) => (v / sum) * 10_000)
  const out = raw.map(Math.floor)
  let left = 10_000 - out.reduce((a, b) => a + b, 0)
  raw.map((x, i) => ({ i, r: x - Math.floor(x) })).sort((a, b) => b.r - a.r).forEach(({ i }) => { if (left > 0) { out[i]++; left-- } })
  return out
}
