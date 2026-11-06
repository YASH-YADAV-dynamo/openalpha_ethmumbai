// Rebalance parameters with the contract's bounds (BucketAccount._validateParams) and one-line help.
import { BOUNDS, type Params } from './data'

type Field = { key: keyof Params; label: string; min: number; max: number; step: number; unit: '%' | 'min'; help: string }

const FIELDS: Field[] = [
  { key: 'bandBps', label: 'Drift band', min: BOUNDS.band[0], max: BOUNDS.band[1], step: 50, unit: '%', help: 'Rebalance only when an asset is this far off its target. 1% to 20%.' },
  { key: 'maxSlippageBps', label: 'Max slippage', min: BOUNDS.slippage[0], max: BOUNDS.slippage[1], step: 10, unit: '%', help: 'Each trade reverts if it fills worse than this vs the registry price. 0.1% to 3%; keep 1% or more, since mirror trades carry a 0.3% spread and the testnet EURC pool is thin.' },
  { key: 'maxTradeBps', label: 'Max trade size', min: BOUNDS.maxTrade[0], max: BOUNDS.maxTrade[1], step: 100, unit: '%', help: 'Largest single trade as a share of bucket value; big drifts take several rebalances. 5% to 50%.' },
  { key: 'cooldown', label: 'Cooldown', min: BOUNDS.cooldownMin / 60, max: 7 * 24 * 60, step: 10, unit: 'min', help: 'Minimum wait between rebalances. At least 10 minutes.' },
]

const toUi = (f: Field, v: number) => (f.unit === '%' ? v / 100 : v / 60)
const fromUi = (f: Field, v: number) => Math.round(f.unit === '%' ? v * 100 : v * 60)

export function paramsError(p: Params): string | null {
  if (p.bandBps < BOUNDS.band[0] || p.bandBps > BOUNDS.band[1]) return 'Drift band must be 1% to 20%'
  if (p.maxSlippageBps < BOUNDS.slippage[0] || p.maxSlippageBps > BOUNDS.slippage[1]) return 'Max slippage must be 0.1% to 3%'
  if (p.maxTradeBps < BOUNDS.maxTrade[0] || p.maxTradeBps > BOUNDS.maxTrade[1]) return 'Max trade size must be 5% to 50%'
  if (!Number.isInteger(p.cooldown) || p.cooldown < BOUNDS.cooldownMin || p.cooldown > 2 ** 32 - 1) return 'Cooldown must be at least 10 minutes'
  return null
}

export function ParamsForm({ value, onChange, disabled }: { value: Params; onChange: (p: Params) => void; disabled?: boolean }) {
  const err = paramsError(value)
  return (
    <div className="space-y-4">
      {FIELDS.map((f) => {
        const ui = toUi(f, value[f.key])
        const sliderMax = f.unit === 'min' ? 24 * 60 : toUi(f, f.max)
        return (
          <div key={f.key} className="min-w-0">
            <div className="flex items-center justify-between gap-2">
              <label htmlFor={`p-${f.key}`} className="text-sm font-medium">{f.label}</label>
              <div className="flex items-center gap-1.5">
                <input
                  id={`p-${f.key}`}
                  type="number"
                  inputMode="decimal"
                  className="field num h-8 w-24 text-right font-mono"
                  min={toUi(f, f.min)}
                  max={f.unit === 'min' ? undefined : toUi(f, f.max)}
                  step={f.unit === '%' ? 0.1 : 1}
                  value={Number.isFinite(ui) ? ui : ''}
                  disabled={disabled}
                  onChange={(e) => onChange({ ...value, [f.key]: fromUi(f, Number(e.target.value)) })}
                />
                <span className="w-7 text-xs text-muted">{f.unit}</span>
              </div>
            </div>
            <input
              type="range"
              aria-label={f.label}
              className="mt-2 w-full accent-[rgb(var(--accent))]"
              min={toUi(f, f.min)}
              max={sliderMax}
              step={f.unit === '%' ? f.step / 100 : f.step}
              value={Math.min(ui, sliderMax)}
              disabled={disabled}
              onChange={(e) => onChange({ ...value, [f.key]: fromUi(f, Number(e.target.value)) })}
            />
            <p className="mt-1 text-xs leading-snug text-muted">{f.help}</p>
          </div>
        )
      })}
      {err && <p className="text-xs text-down">{err}</p>}
      {!err && value.maxSlippageBps < 100 && <p className="text-xs text-warn">Below 1% slippage, mirror and EURC trades are likely to revert.</p>}
    </div>
  )
}
