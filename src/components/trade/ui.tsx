import { useEffect, useState } from 'react'

export function Skel({ className = '' }: { className?: string }) {
  return <span aria-hidden="true" className={`block animate-pulse rounded bg-panel2 ${className}`} />
}

export function Stat({ label, value, className = '', loading }: { label: string; value: string; className?: string; loading?: boolean }) {
  return (
    <div className="min-w-0">
      <p className="text-[11px] text-muted">{label}</p>
      {loading ? <Skel className="mt-1 h-4 w-14" /> : <p className={`font-mono text-[13px] num ${className}`}>{value}</p>}
    </div>
  )
}

/** Compact USD for liquidity/volume: $1.2M, $830K. */
export function compactUsd(n: number | null | undefined): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return '—'
  return `$${n.toLocaleString('en-US', { notation: 'compact', maximumFractionDigits: 2 })}`
}

/** Signed percent with a unicode minus; null -> "—". */
export const signedPct = (n: number | null | undefined, d = 2) =>
  n === null || n === undefined || !Number.isFinite(n) ? '—' : `${n >= 0 ? '+' : '−'}${Math.abs(n).toFixed(d)}%`

export const toneOf = (n: number | null | undefined) => (n === null || n === undefined || !Number.isFinite(n) ? '' : n >= 0 ? 'text-up' : 'text-down')

/** matchMedia as state (SSR-safe default false). */
export function useMedia(query: string) {
  const [on, setOn] = useState(() => typeof window !== 'undefined' && window.matchMedia(query).matches)
  useEffect(() => {
    const m = window.matchMedia(query)
    const f = () => setOn(m.matches)
    f()
    m.addEventListener('change', f)
    return () => m.removeEventListener('change', f)
  }, [query])
  return on
}

export function MirrorBadge({ mirror }: { mirror: boolean }) {
  return (
    <span className={`badge ${mirror ? 'bg-panel2 text-muted' : 'bg-accent/15 text-accent'}`} title={mirror ? 'Priced from Arc mainnet, testnet token' : 'Real asset: Uniswap v4 on Arc Testnet'}>
      {mirror ? 'Mirror' : 'Real'}
    </span>
  )
}

const DOT = ['bg-up', 'bg-warn', 'bg-down', 'bg-down'] as const
export function RiskDot({ level }: { level: number }) {
  return <span aria-hidden="true" className={`inline-block size-2 shrink-0 rounded-full ${DOT[level] ?? 'bg-faint'}`} />
}
