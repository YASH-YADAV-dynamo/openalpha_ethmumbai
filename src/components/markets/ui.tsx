// Small shared pieces for the exchange chrome, landing and #/markets (all read from usePriceBook).
import { useEffect, useRef } from 'react'
import type { ListedAsset } from '@/lib/assets'
import { RISK_LABEL, RISK_TONE } from '@/components/trade/hooks'

/** Stable per-asset colour (icons, allocation bars). Known symbols get distinct hues; others hash to a hue. */
const KNOWN: Record<string, string> = {
  USDC: '#2775ca', EURC: '#14b8a6', cirBTC: '#f7931a', WETH: '#8b7cf6', GBPA: '#e0569b',
  syrupUSDC: '#7cc242', XAUM: '#d4a72c', ASTOCK: '#0ea5e9',
}
export function assetColor(symbol: string): string {
  if (KNOWN[symbol]) return KNOWN[symbol]
  let h = 0
  for (const ch of symbol) h = (h * 31 + ch.charCodeAt(0)) % 360
  return `hsl(${h} 55% 55%)`
}

export function AssetIcon({ symbol, size = 28 }: { symbol: string; size?: number }) {
  const initials = symbol.replace(/^(cir|syrup)/, '').slice(0, 2).toUpperCase()
  return (
    <span
      aria-hidden
      className="inline-flex shrink-0 items-center justify-center rounded-full font-mono font-semibold text-white"
      style={{ width: size, height: size, fontSize: Math.round(size * 0.36), background: assetColor(symbol) }}
    >
      {initials}
    </span>
  )
}

/** REAL = traded on Arc Testnet as the actual token; MIRROR = testnet token priced from Arc mainnet. */
export function KindBadge({ asset }: { asset: Pick<ListedAsset, 'mirror'> }) {
  return asset.mirror ? (
    <span className="badge shrink-0 border border-line text-muted" title="Priced from Arc mainnet, testnet token">Mirror</span>
  ) : (
    <span className="badge shrink-0 bg-accent/15 text-accent" title="Real token on Arc Testnet">Real</span>
  )
}

export function RiskDot({ level, label = true }: { level: number; label?: boolean }) {
  const i = Math.min(Math.max(level, 0), 3)
  return (
    <span className={`inline-flex items-center gap-1.5 text-xs ${RISK_TONE[i]}`} title={`Risk level ${i}: ${RISK_LABEL[i]}`}>
      <span aria-hidden className="h-2 w-2 rounded-full bg-current" />
      {label ? <span>{RISK_LABEL[i]}</span> : <span className="sr-only">{RISK_LABEL[i]}</span>}
    </span>
  )
}

export const changeTone = (n: number | null | undefined) => (n === null || n === undefined ? 'text-faint' : n >= 0 ? 'text-up' : 'text-down')

/** Compact USD for liquidity: $1.2M, $830K. */
export function compactUsd(n: number | null | undefined): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return '—'
  return `$${n.toLocaleString('en-US', { notation: 'compact', maximumFractionDigits: 2 })}`
}

export function Skel({ className = '' }: { className?: string }) {
  return <span aria-hidden className={`block animate-pulse rounded bg-panel2 ${className}`} />
}

/**
 * Tints an element up/down for 600 ms when `value` changes (Web Animations API, no re-render).
 * Skipped under prefers-reduced-motion.
 */
export function useFlash<T extends HTMLElement>(value: number | null | undefined) {
  const ref = useRef<T>(null)
  const prev = useRef(value)
  useEffect(() => {
    const before = prev.current
    prev.current = value
    const el = ref.current
    if (!el || before === null || before === undefined || value === null || value === undefined || before === value) return
    if (typeof window.matchMedia === 'function' && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const token = value > before ? '--up' : '--down'
    el.animate?.([{ backgroundColor: `rgb(var(${token}) / 0.18)` }, { backgroundColor: 'transparent' }], { duration: 600, easing: 'ease-out' })
  }, [value])
  return ref
}
