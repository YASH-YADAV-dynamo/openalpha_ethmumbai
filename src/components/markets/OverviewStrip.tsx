// Top gainer / top loser / deepest liquidity, from the same price book as the table (Arc mainnet reference data).
import type { PriceRow } from '@/lib/prices'
import { pct, usd } from '@/lib/format'
import { Link } from '@/lib/router'
import { AssetIcon, Skel, changeTone, compactUsd } from './ui'

function pickBy(rows: PriceRow[], v: (r: PriceRow) => number | null, best: (a: number, b: number) => boolean) {
  let out: PriceRow | null = null
  for (const r of rows) {
    const x = v(r)
    if (x === null || r.asset.display === 'USDC') continue
    const cur = out ? v(out) : null
    if (cur === null || best(x, cur)) out = r
  }
  return out
}

export function OverviewStrip({ rows, loading }: { rows: PriceRow[]; loading: boolean }) {
  const gainer = pickBy(rows, (r) => (r.change24h !== null && r.change24h > 0 ? r.change24h : null), (a, b) => a > b)
  const loser = pickBy(rows, (r) => (r.change24h !== null && r.change24h < 0 ? r.change24h : null), (a, b) => a < b)
  const deepest = pickBy(rows, (r) => r.ref?.liquidityUsd ?? null, (a, b) => a > b)
  return (
    <div className="grid gap-2 sm:grid-cols-3">
      <Card title="Top gainer · 24h" row={gainer} loading={loading} empty="No gainers in the last 24h" metric={gainer ? pct(gainer.change24h) : '—'} tone={changeTone(gainer?.change24h)} />
      <Card title="Top loser · 24h" row={loser} loading={loading} empty="No decliners in the last 24h" metric={loser ? pct(loser.change24h) : '—'} tone={changeTone(loser?.change24h)} />
      <Card title="Deepest liquidity" row={deepest} loading={loading} empty="No mainnet liquidity data yet" metric={compactUsd(deepest?.ref?.liquidityUsd)} tone="text-ink" />
    </div>
  )
}

function Card({ title, row, metric, tone, loading, empty }: { title: string; row: PriceRow | null; metric: string; tone: string; loading: boolean; empty: string }) {
  const body = loading ? (
    <div className="flex items-center gap-2.5"><Skel className="h-7 w-7 rounded-full" /><Skel className="h-4 w-24" /></div>
  ) : !row ? (
    <p className="text-[13px] text-muted">{empty}</p>
  ) : (
    <div className="flex items-center gap-2.5">
      <AssetIcon symbol={row.asset.display} />
      <div className="min-w-0 flex-1">
        <div className="truncate text-[13px] font-semibold">{row.asset.display}</div>
        <div className="num font-mono text-[11px] text-muted">{row.stale ? '—' : usd(row.last)}</div>
      </div>
      <div className={`num font-mono text-base font-semibold ${tone}`}>{metric}</div>
    </div>
  )
  const cls = 'card flex min-h-[84px] flex-col justify-between gap-2 p-3'
  return row && !loading ? (
    <Link to={`/trade/${row.asset.display}`} className={`${cls} transition hover:border-accent/60`}>
      <span className="eyebrow">{title}</span>
      {body}
    </Link>
  ) : (
    <div className={cls}>
      <span className="eyebrow">{title}</span>
      {body}
    </div>
  )
}
