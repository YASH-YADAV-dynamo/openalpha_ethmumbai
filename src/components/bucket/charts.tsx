// Actual-vs-target donut and a stacked weights bar. Pure SVG/CSS, colors from ui.colorFor.
import type { ListedAsset } from '@/lib/assets'
import { colorFor, symbolOf } from './ui'

type Slice = { token: string; frac: number }

function Ring({ slices, r, width, assets, label }: { slices: Slice[]; r: number; width: number; assets?: ListedAsset[]; label: string }) {
  const C = 2 * Math.PI * r
  const gap = slices.filter((s) => s.frac > 0).length > 1 ? 2 : 0 // 2px surface gap between segments
  const starts = slices.map((_, i) => slices.slice(0, i).reduce((a, x) => a + Math.max(0, x.frac) * C, 0))
  return (
    <g>
      <circle r={r} fill="none" stroke="rgb(var(--panel2))" strokeWidth={width} />
      {slices.map((s, i) => {
        if (s.frac <= 0) return null
        const len = Math.max(0, s.frac * C - gap)
        return (
          <circle
            key={s.token}
            r={r}
            fill="none"
            stroke={colorFor(s.token, assets)}
            strokeWidth={width}
            strokeDasharray={`${len} ${C - len}`}
            strokeDashoffset={-starts[i]}
            transform="rotate(-90)"
          >
            <title>{`${label} ${symbolOf(s.token, assets)}: ${(s.frac * 100).toFixed(2)}%`}</title>
          </circle>
        )
      })}
    </g>
  )
}

/** Outer ring = actual value share, inner ring = target weight. `actual` null = unknown (stale price / empty). */
export function Donut({
  tokens,
  actual,
  target,
  assets,
  size = 112,
}: {
  tokens: readonly string[]
  actual: readonly number[] | null
  target: readonly number[]
  assets?: ListedAsset[]
  size?: number
}) {
  const sum = (a: readonly number[]) => a.reduce((x, y) => x + y, 0)
  const tSum = sum(target) || 1
  const aSum = actual ? sum(actual) : 0
  const outer = actual && aSum > 0 ? tokens.map((t, i) => ({ token: t, frac: actual[i] / aSum })) : []
  const inner = tokens.map((t, i) => ({ token: t, frac: target[i] / tSum }))
  return (
    <svg viewBox="-60 -60 120 120" width={size} height={size} role="img" aria-label="Actual (outer ring) versus target (inner ring) allocation" className="shrink-0">
      <Ring slices={outer} r={50} width={12} assets={assets} label="Actual" />
      <Ring slices={inner} r={33} width={8} assets={assets} label="Target" />
    </svg>
  )
}

/** Single-ring target allocation (weights in bps) with an optional centre label. Used by the create wizard. */
export function AllocationDonut({
  tokens,
  weights,
  assets,
  size = 168,
  center,
  sub,
}: {
  tokens: readonly string[]
  weights: readonly number[]
  assets?: ListedAsset[]
  size?: number
  center?: string
  sub?: string
}) {
  const sum = weights.reduce((a, b) => a + Math.max(0, b), 0)
  const slices = sum > 0 ? tokens.map((t, i) => ({ token: t, frac: Math.max(0, weights[i]) / sum })) : []
  return (
    <svg viewBox="-60 -60 120 120" width={size} height={size} role="img" aria-label="Target allocation" className="shrink-0">
      <Ring slices={slices} r={46} width={14} assets={assets} label="Target" />
      {center && (
        <text textAnchor="middle" dy={sub ? -1 : 4} className="num font-mono" fill="rgb(var(--ink))" style={{ fontSize: 13, fontWeight: 600 }}>
          {center}
        </text>
      )}
      {sub && (
        <text textAnchor="middle" dy={12} fill="rgb(var(--muted))" style={{ fontSize: 7 }}>
          {sub}
        </text>
      )}
    </svg>
  )
}

/** Horizontal stacked bar of weights (bps), with a legend underneath. */
export function WeightsBar({ tokens, weights, assets }: { tokens: readonly string[]; weights: readonly number[]; assets?: ListedAsset[] }) {
  const total = weights.reduce((a, b) => a + b, 0) || 1
  const items = tokens.map((t, i) => ({ t, w: weights[i] })).filter((x) => x.w > 0)
  return (
    <div className="min-w-0">
      <div className="flex h-2.5 w-full gap-[2px] overflow-hidden rounded-full bg-panel2">
        {items.map(({ t, w }) => (
          <div key={t} className="h-full first:rounded-l-full last:rounded-r-full" style={{ width: `${(w / total) * 100}%`, background: colorFor(t, assets) }} title={`${symbolOf(t, assets)} ${(w / 100).toFixed(2)}%`} />
        ))}
      </div>
      <ul className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-muted">
        {items.map(({ t, w }) => (
          <li key={t} className="flex items-center gap-1.5">
            <span aria-hidden="true" className="h-2 w-2 rounded-full" style={{ background: colorFor(t, assets) }} />
            <span className="text-ink">{symbolOf(t, assets)}</span>
            <span className="num font-mono">{(w / 100).toFixed(w % 100 ? 2 : 0)}%</span>
          </li>
        ))}
      </ul>
    </div>
  )
}
