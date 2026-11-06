// Holdings: oracle price (shared price book), amount, value, actual vs target, contract drift and registry risk.
import type { ListedAsset } from '@/lib/assets'
import { amt, bps, e18, usd } from '@/lib/format'
import { usePriceBook } from '@/lib/prices'
import { Link } from '@/lib/router'
import { targetFor, unpriced, type BucketState } from './data'
import { Dot, KindBadge, RiskBadge, colorFor, driftTone } from './ui'

const age = (sec: number | null) => (sec === null ? '—' : sec < 60 ? `${sec}s` : sec < 3600 ? `${Math.round(sec / 60)}m` : `${Math.round(sec / 3600)}h`)

export function HoldingsTable({ s, assets, compact }: { s: BucketState; assets: ListedAsset[] | undefined; compact?: boolean }) {
  const book = usePriceBook()
  const total = e18(s.totalE18)
  const band = s.params.bandBps
  const complete = unpriced(s).length === 0
  const cols = compact ? ['Asset', 'Value', 'Actual', 'Target', 'Drift'] : ['Asset', 'Price', 'Amount', 'Value', 'Actual', 'Target', 'Drift', 'Risk']
  return (
    <div className="min-w-0">
      <div className="-mx-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
        <table className={`w-full text-[13px] ${compact ? 'min-w-[420px]' : 'min-w-[760px]'}`}>
          <thead>
            <tr className="border-b border-line text-left">
              {cols.map((h, i) => (
                <th key={h} className={`eyebrow whitespace-nowrap pb-2 font-normal ${i ? 'text-right' : ''}`}>{h}</th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-line">
            {s.tokens.map((t, i) => {
              const a = assets?.find((x) => x.token.toLowerCase() === t.toLowerCase())
              const row = a ? book.bySymbol.get(a.display.toLowerCase()) : undefined
              const priced = !(s.amounts[i] > 0n && s.valuesE18[i] === 0n)
              const value = priced ? e18(s.valuesE18[i]) : null
              const actual = complete && total > 0 && value !== null ? (value / total) * 100 : null
              const drift = s.drift?.perAsset[i]
              const target = targetFor(s, t)
              return (
                <tr key={t} className="hover:bg-panel2/40">
                  <td className="py-2.5 pr-2">
                    <div className="flex items-center gap-2">
                      <Dot color={colorFor(t, assets)} />
                      {a ? <Link to={`/trade/${a.display}`} className="font-medium hover:underline">{a.display}</Link> : <span className="font-mono">{t.slice(0, 8)}</span>}
                      {!compact && <KindBadge asset={a} />}
                      {compact && a && a.risk >= 1 && <RiskBadge level={a.risk} />}
                    </div>
                  </td>
                  {!compact && (
                    <td className="num whitespace-nowrap py-2.5 text-right font-mono">
                      {row?.last == null ? <span className="text-warn" title="No fresh oracle price">stale</span> : usd(row.last)}
                      <span className="ml-1 text-[11px] text-faint" title="Oracle age">{age(row?.oracleAgeSec ?? null)}</span>
                    </td>
                  )}
                  {!compact && <td className="num py-2.5 text-right font-mono">{a ? amt(s.amounts[i], a.decimals) : String(s.amounts[i])}</td>}
                  <td className="num py-2.5 text-right font-mono">{value === null ? <span className="text-warn" title="No fresh price">—</span> : usd(value)}</td>
                  <td className="num py-2.5 text-right font-mono">{actual === null ? '—' : `${actual.toFixed(2)}%`}</td>
                  <td className="num py-2.5 text-right font-mono text-muted">{bps(target)}</td>
                  <td className={`num py-2.5 text-right font-mono ${drift === undefined ? 'text-muted' : driftTone(Math.abs(drift), band)}`}>
                    {drift === undefined ? '—' : `${drift > 0 ? '+' : drift < 0 ? '−' : ''}${bps(Math.abs(drift))}`}
                  </td>
                  {!compact && <td className="py-2.5 pl-2 text-right">{a ? <RiskBadge level={a.risk} /> : '—'}</td>}
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      {!compact && (
        <p className="mt-2 text-xs text-muted">
          Price is the on-chain oracle price (Chainlink CRE) used for valuation and trade bounds; small grey figure is its age. Drift is actual minus target from the contract:{' '}
          <span className="text-warn">amber</span> is within 75% of the {bps(band)} band, <span className="text-down">red</span> is past it.
          {!s.drift && ' Drift is unavailable while an asset in the bucket has no fresh price.'}
        </p>
      )}
    </div>
  )
}
