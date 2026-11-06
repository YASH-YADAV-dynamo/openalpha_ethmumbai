// Pick assets and target weights. Weights are integer bps that must sum to exactly 10,000.
import { useState } from 'react'
import { Plus, Scale, X } from 'lucide-react'
import { CATEGORIES, type ListedAsset } from '@/lib/assets'
import { BOUNDS, type Hex } from './data'
import { KindBadge, colorFor, Dot } from './ui'

export type Row = { token: Hex; bps: number }

/** Scale weights to sum 10,000 (largest-remainder rounding, every weight >= 1 bps). */
export function normalize(rows: Row[]): Row[] {
  if (!rows.length) return rows
  const sum = rows.reduce((a, r) => a + Math.max(0, r.bps), 0)
  const raw = rows.map((r) => (sum > 0 ? (Math.max(0, r.bps) / sum) * 10_000 : 10_000 / rows.length))
  const floor = raw.map((x) => Math.max(1, Math.floor(x)))
  let left = 10_000 - floor.reduce((a, b) => a + b, 0)
  const order = raw.map((x, i) => ({ i, rem: x - Math.floor(x) })).sort((a, b) => b.rem - a.rem)
  for (let k = 0; left !== 0 && k < order.length * 4; k++) {
    const i = order[k % order.length].i
    if (left > 0) { floor[i]++; left-- } else if (floor[i] > 1) { floor[i]--; left++ }
  }
  return rows.map((r, i) => ({ ...r, bps: floor[i] }))
}

export function targetsError(rows: Row[]): string | null {
  if (!rows.length) return 'Add at least one asset'
  if (rows.length > BOUNDS.maxAssets) return `At most ${BOUNDS.maxAssets} assets`
  if (rows.some((r) => !Number.isInteger(r.bps) || r.bps <= 0)) return 'Every asset needs a weight above 0%'
  const sum = rows.reduce((a, r) => a + r.bps, 0)
  if (sum !== 10_000) return `Weights sum to ${(sum / 100).toFixed(2)}%, need exactly 100.00%`
  return null
}

export function TargetsEditor({ rows, onChange, assets, disabled }: { rows: Row[]; onChange: (r: Row[]) => void; assets: ListedAsset[] | undefined; disabled?: boolean }) {
  const [picking, setPicking] = useState(false)
  const sum = rows.reduce((a, r) => a + r.bps, 0)
  const err = targetsError(rows)
  const chosen = new Set(rows.map((r) => r.token.toLowerCase()))
  const find = (t: string) => assets?.find((a) => a.token.toLowerCase() === t.toLowerCase())
  const set = (i: number, bps: number) => onChange(rows.map((r, k) => (k === i ? { ...r, bps: Math.max(0, Math.min(10_000, Math.round(bps))) } : r)))
  const add = (a: ListedAsset) => {
    if (rows.length >= BOUNDS.maxAssets) return
    const next = [...rows, { token: a.token, bps: Math.max(0, 10_000 - sum) }]
    onChange(next)
    if (next.length >= BOUNDS.maxAssets) setPicking(false)
  }

  return (
    <div className="min-w-0 space-y-3">
      {rows.length === 0 && <p className="text-sm text-muted">No assets yet. Add one below.</p>}
      <ul className="space-y-3">
        {rows.map((r, i) => {
          const a = find(r.token)
          return (
            <li key={r.token} className="rounded-xl border border-line bg-panel2/50 p-3">
              <div className="flex items-center gap-2">
                <Dot color={colorFor(r.token, assets)} />
                <span className="min-w-0 truncate text-sm font-medium">{a?.display ?? r.token}</span>
                <KindBadge asset={a} />
                {a && a.risk >= 2 && <span className="badge bg-down/15 text-down" title="Risk level blocks buys">No buys</span>}
                {a && a.priceE8 === null && <span className="badge bg-warn/15 text-warn" title="No fresh price; trades revert until it updates">Stale</span>}
                <div className="ml-auto flex items-center gap-1">
                  <input
                    type="number"
                    inputMode="decimal"
                    aria-label={`${a?.display ?? 'Asset'} weight percent`}
                    className="field num h-8 w-20 text-right font-mono"
                    min={0}
                    max={100}
                    step={0.01}
                    value={r.bps / 100}
                    disabled={disabled}
                    onChange={(e) => set(i, Number(e.target.value) * 100)}
                  />
                  <span className="text-xs text-muted">%</span>
                  <button type="button" className="ml-1 rounded-lg p-1.5 text-muted hover:bg-panel2 hover:text-ink" aria-label="Remove asset" disabled={disabled} onClick={() => onChange(rows.filter((_, k) => k !== i))}>
                    <X size={14} />
                  </button>
                </div>
              </div>
              <input
                type="range"
                aria-label={`${a?.display ?? 'Asset'} weight`}
                className="mt-2 w-full accent-[rgb(var(--accent))]"
                min={0}
                max={10_000}
                step={50}
                value={r.bps}
                disabled={disabled}
                onChange={(e) => set(i, Number(e.target.value))}
              />
            </li>
          )
        })}
      </ul>

      <div className="flex flex-wrap items-center gap-2">
        <button type="button" className="btn-ghost h-9" disabled={disabled || rows.length >= BOUNDS.maxAssets} onClick={() => setPicking((v) => !v)}>
          <Plus size={14} /> Add asset
        </button>
        <button type="button" className="btn-ghost h-9" disabled={disabled || !rows.length} onClick={() => onChange(normalize(rows))}>
          <Scale size={14} /> Auto-normalize
        </button>
        <span className={`num ml-auto font-mono text-sm ${sum === 10_000 ? 'text-up' : 'text-down'}`}>
          {(sum / 100).toFixed(2)}% <span className="text-muted">/ 100.00%</span>
        </span>
      </div>
      <p className="text-xs text-muted">{rows.length}/{BOUNDS.maxAssets} assets</p>

      {picking && (
        <div className="rounded-xl border border-line p-3">
          {!assets ? (
            <p className="text-sm text-muted">Loading assets…</p>
          ) : (
            CATEGORIES.map((cat) => {
              const list = assets.filter((a) => a.category === cat)
              if (!list.length) return null
              return (
                <div key={cat} className="mb-3 last:mb-0">
                  <p className="eyebrow mb-1.5">{cat}</p>
                  <div className="flex flex-wrap gap-1.5">
                    {list.map((a) => {
                      const on = chosen.has(a.token.toLowerCase())
                      return (
                        <button
                          key={a.token}
                          type="button"
                          disabled={on || disabled}
                          onClick={() => add(a)}
                          className="inline-flex items-center gap-1.5 rounded-lg border border-line px-2 py-1 text-sm hover:bg-panel2 disabled:opacity-40"
                        >
                          <Dot color={colorFor(a.token, assets)} />
                          {a.display}
                          <KindBadge asset={a} />
                        </button>
                      )
                    })}
                  </div>
                </div>
              )
            })
          )}
        </div>
      )}
      {err && rows.length > 0 && <p className="text-xs text-down">{err}</p>}
    </div>
  )
}
