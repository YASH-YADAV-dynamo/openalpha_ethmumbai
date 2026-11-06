// Small presentational pieces shared by the bucket pages.
import type { ReactNode } from 'react'
import { clsx } from 'clsx'
import type { ListedAsset } from '@/lib/assets'
import { addrUrl, short } from '@/lib/format'

// Categorical palette (fixed order, one slot per registry asset; never cycled).
// Dark is the app default; `.light` on <html> swaps to the light steps.
const LIGHT = ['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4', '#008300', '#6250d6', '#e34948']
const DARK = ['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181', '#008300', '#9085e9', '#e66767']
const css =
  `:root{${DARK.map((c, i) => `--bk-s${i}:${c};`).join('')}--bk-other:#7c8290}` +
  `.light{${LIGHT.map((c, i) => `--bk-s${i}:${c};`).join('')}--bk-other:#9aa0ab}`

/** Mount once per page so the series colors exist in both themes. */
export function VizStyles() {
  return <style>{css}</style>
}

/** Color follows the asset (its slot in the registry), not its rank in a bucket. */
export function colorFor(token: string, assets: ListedAsset[] | undefined) {
  const i = assets?.findIndex((a) => a.token.toLowerCase() === token.toLowerCase()) ?? -1
  return i >= 0 && i < LIGHT.length ? `var(--bk-s${i})` : 'var(--bk-other)'
}

export const symbolOf = (token: string, assets: ListedAsset[] | undefined) =>
  assets?.find((a) => a.token.toLowerCase() === token.toLowerCase())?.display ?? short(token)

export function Skeleton({ className }: { className?: string }) {
  return <div className={clsx('animate-pulse rounded-lg bg-panel2', className)} aria-hidden="true" />
}

export function Stat({ label, children, className }: { label: string; children: ReactNode; className?: string }) {
  return (
    <div className={clsx('min-w-0', className)}>
      <dt className="eyebrow">{label}</dt>
      <dd className="num mt-1 truncate text-lg font-semibold">{children}</dd>
    </div>
  )
}

export function KindBadge({ asset }: { asset: ListedAsset | undefined }) {
  if (!asset) return null
  return asset.mirror ? (
    <span className="badge bg-warn/15 text-warn" title="Testnet mirror priced from Arc mainnet">Mirror</span>
  ) : (
    <span className="badge bg-up/15 text-up" title="Real testnet asset">Real</span>
  )
}

export function Dot({ color }: { color: string }) {
  return <span aria-hidden="true" className="inline-block h-2.5 w-2.5 shrink-0 rounded-full" style={{ background: color }} />
}

export function AddrLink({ address, className }: { address: string; className?: string }) {
  return (
    <a href={addrUrl(address)} target="_blank" rel="noreferrer" className={clsx('num font-mono text-muted hover:text-ink hover:underline', className)}>
      {short(address)}
    </a>
  )
}

export function Notice({ tone = 'muted', children }: { tone?: 'muted' | 'warn' | 'down'; children: ReactNode }) {
  return (
    <p
      className={clsx(
        'rounded-xl border px-3 py-2 text-xs leading-relaxed',
        tone === 'warn' && 'border-warn/40 bg-warn/10 text-ink',
        tone === 'down' && 'border-down/40 bg-down/10 text-ink',
        tone === 'muted' && 'border-line bg-panel2 text-muted',
      )}
    >
      {children}
    </p>
  )
}

export function Section({ title, aside, children, className }: { title: string; aside?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={clsx('card min-w-0 p-4 sm:p-5', className)}>
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-semibold">{title}</h2>
        {aside}
      </div>
      {children}
    </section>
  )
}

/** Drift color against the band: within band, approaching (>= 75% of band), past band. */
export function driftTone(absBps: number, bandBps: number) {
  if (absBps > bandBps) return 'text-down'
  if (absBps >= bandBps * 0.75) return 'text-warn'
  return 'text-muted'
}

/** Event handler for an async action (errors are already toasted by useTx). */
export const act = (fn: () => Promise<unknown>) => () => {
  void fn()
}

/** Registry risk level as a coloured dot + label (0 Normal · 1 Watch · 2 No buys · 3 Exit). */
export function RiskBadge({ level, className }: { level: number; className?: string }) {
  const l = Math.max(0, Math.min(3, level))
  const label = ['Normal', 'Watch', 'No buys', 'Exit'][l]
  return (
    <span
      className={clsx(
        'inline-flex items-center gap-1.5 whitespace-nowrap text-xs',
        l === 0 && 'text-muted',
        l === 1 && 'text-warn',
        l >= 2 && 'text-down',
        className,
      )}
      title={`Registry risk level ${l}`}
    >
      <span aria-hidden="true" className={clsx('h-2 w-2 rounded-full', l === 0 && 'bg-up', l === 1 && 'bg-warn', l >= 2 && 'bg-down')} />
      {label}
    </span>
  )
}

/** Bar fill colour against the band: green inside, amber near (>= 75% of band), red past it. */
export function driftFill(absBps: number, bandBps: number) {
  if (absBps > bandBps) return 'bg-down'
  if (absBps >= bandBps * 0.75) return 'bg-warn'
  return 'bg-up'
}

/** Max drift as a bar with the band marked. Scale = 1.5x band (or the drift, if larger). */
export function DriftBar({ drift, band, className }: { drift: number | null; band: number; className?: string }) {
  const scale = Math.max(band * 1.5, drift ?? 0)
  const at = (band / scale) * 100
  return (
    <div className={clsx('min-w-0', className)}>
      <div className="flex items-baseline justify-between gap-2 text-xs">
        <span className="text-muted">Drift vs band</span>
        <span className="num font-mono">
          <span className={drift === null ? 'text-muted' : drift > band ? 'text-down' : drift >= band * 0.75 ? 'text-warn' : 'text-up'}>{drift === null ? '—' : `${(drift / 100).toFixed(2)}%`}</span>
          <span className="text-muted"> / {(band / 100).toFixed(2)}%</span>
        </span>
      </div>
      <div className="relative mt-1.5 h-1.5 w-full rounded-full bg-panel2" role="meter" aria-label="Max drift versus band" aria-valuemin={0} aria-valuemax={scale} aria-valuenow={drift ?? undefined}>
        {drift !== null && <div className={clsx('h-full rounded-full', driftFill(drift, band))} style={{ width: `${Math.min(100, (drift / scale) * 100)}%` }} />}
        <span aria-hidden="true" className="absolute -top-1 h-3.5 w-px bg-ink/60" style={{ left: `${at}%` }} />
      </div>
    </div>
  )
}

/** Underline tab bar, horizontally scrollable on small screens. */
export function Tabs<T extends string>({ tabs, value, onChange, className }: { tabs: readonly T[]; value: T; onChange: (t: T) => void; className?: string }) {
  return (
    <div role="tablist" className={clsx('-mx-4 flex gap-1 overflow-x-auto overflow-y-hidden border-b border-line px-4 [scrollbar-width:none] sm:mx-0 sm:px-0 [&::-webkit-scrollbar]:hidden', className)}>
      {tabs.map((t) => (
        <button
          key={t}
          role="tab"
          type="button"
          aria-selected={value === t}
          onClick={() => onChange(t)}
          className={clsx(
            '-mb-px min-h-[40px] shrink-0 border-b-2 px-3 text-sm transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/60',
            value === t ? 'border-accent font-medium text-ink' : 'border-transparent text-muted hover:text-ink',
          )}
        >
          {t}
        </button>
      ))}
    </div>
  )
}
