// The exchange markets table, shared by the landing page and #/markets. Every number comes from usePriceBook.
import { useMemo, useState } from 'react'
import { ArrowDown, ArrowUp, ArrowUpDown, Search } from 'lucide-react'
import { ASSET_NAME, CATEGORIES, type Category } from '@/lib/assets'
import type { PriceRow } from '@/lib/prices'
import { pct, usd } from '@/lib/format'
import { Link, navigate } from '@/lib/router'
import { AssetIcon, KindBadge, RiskDot, Skel, changeTone, compactUsd, useFlash } from './ui'
import { Sparkline } from './Sparkline'

type Tab = 'All' | Category
const TAB_ORDER: Tab[] = ['All', ...(['FX', 'Crypto', 'RWA', 'Yield', 'Cash'] as const).filter((c) => CATEGORIES.includes(c))]
type SortKey = 'price' | 'change' | 'liq'
type Sort = { key: SortKey; dir: 'asc' | 'desc' } | null

const valueOf = (r: PriceRow, k: SortKey) => (k === 'price' ? r.last : k === 'change' ? r.change24h : (r.ref?.liquidityUsd ?? null))

export function MarketsTable({ rows, loading, error }: { rows: PriceRow[]; loading: boolean; error?: boolean }) {
  const [tab, setTab] = useState<Tab>('All')
  const [q, setQ] = useState('')
  const [sort, setSort] = useState<Sort>(null)

  const shown = useMemo(() => {
    const s = q.trim().toLowerCase()
    const out = rows
      .filter((r) => tab === 'All' || r.asset.category === tab)
      .filter((r) => !s || r.asset.display.toLowerCase().includes(s) || (ASSET_NAME[r.asset.display] ?? '').toLowerCase().includes(s))
    if (!sort) return out
    return out.slice().sort((a, b) => {
      const x = valueOf(a, sort.key)
      const y = valueOf(b, sort.key)
      if (x === null && y === null) return 0
      if (x === null) return 1 // unknown values always last
      if (y === null) return -1
      return sort.dir === 'asc' ? x - y : y - x
    })
  }, [rows, tab, q, sort])

  const toggle = (key: SortKey) =>
    setSort((s) => (s?.key !== key ? { key, dir: 'desc' } : s.dir === 'desc' ? { key, dir: 'asc' } : null))

  return (
    <div className="card overflow-hidden">
      <div className="flex flex-col gap-2 border-b border-line p-2 sm:flex-row sm:items-center sm:justify-between">
        <div className="-mx-1 flex gap-0.5 overflow-x-auto px-1 [scrollbar-width:none]" role="tablist" aria-label="Category">
          {TAB_ORDER.map((t) => (
            <button
              key={t}
              type="button"
              role="tab"
              aria-selected={tab === t}
              onClick={() => setTab(t)}
              className={`tab h-9 shrink-0 px-2.5 text-[13px] sm:px-3 ${tab === t ? 'tab-on font-medium' : ''}`}
            >
              {t}
            </button>
          ))}
        </div>
        <label className="relative block sm:w-56">
          <span className="sr-only">Search markets</span>
          <Search size={14} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-faint" />
          <input className="field h-9 pl-8 text-[13px]" placeholder="Search" value={q} onChange={(e) => setQ(e.target.value)} />
        </label>
      </div>

      <table className="w-full table-fixed text-[13px]">
        <thead>
          <tr className="border-b border-line font-mono text-[10px] uppercase tracking-wide text-faint">
            <th scope="col" className="px-3 py-2 text-left font-normal">Asset</th>
            <SortTh label="Price" k="price" sort={sort} onSort={toggle} className="w-[96px] sm:w-[120px]" />
            <SortTh label="24h" k="change" sort={sort} onSort={toggle} className="w-[76px] sm:w-[92px]" />
            <th scope="col" className="hidden w-[128px] px-3 py-2 text-right font-normal md:table-cell">24h chart</th>
            <SortTh label="Liquidity" k="liq" sort={sort} onSort={toggle} className="hidden w-[112px] sm:table-cell" title="Arc mainnet reference pool" />
            <th scope="col" className="hidden w-[60px] px-3 py-2 text-left font-normal sm:table-cell lg:w-[96px]">Risk</th>
            <th scope="col" className="hidden w-[92px] px-3 py-2 font-normal sm:table-cell"><span className="sr-only">Trade</span></th>
          </tr>
        </thead>
        <tbody>
          {loading &&
            Array.from({ length: 6 }).map((_, i) => (
              <tr key={i} className="border-b border-line/60 last:border-0">
                <td className="px-3 py-3"><Skel className="h-7 w-32" /></td>
                <td className="px-3"><Skel className="ml-auto h-4 w-16" /></td>
                <td className="px-3"><Skel className="ml-auto h-4 w-12" /></td>
                <td className="hidden px-3 md:table-cell"><Skel className="ml-auto h-6 w-24" /></td>
                <td className="hidden px-3 sm:table-cell"><Skel className="ml-auto h-4 w-14" /></td>
                <td className="hidden px-3 sm:table-cell"><Skel className="h-4 w-10" /></td>
                <td className="hidden px-3 sm:table-cell" />
              </tr>
            ))}
          {!loading && error && rows.length === 0 && (
            <tr><td colSpan={7} className="px-3 py-8 text-center text-muted">Couldn't read listed assets from Arc Testnet. Retrying…</td></tr>
          )}
          {!loading && !error && shown.length === 0 && (
            <tr>
              <td colSpan={7} className="px-3 py-8 text-center text-muted">
                No markets match.{' '}
                <button type="button" className="text-accent hover:underline" onClick={() => { setQ(''); setTab('All') }}>Clear filters</button>
              </td>
            </tr>
          )}
          {!loading && shown.map((r) => <Row key={r.asset.token} r={r} />)}
        </tbody>
      </table>
    </div>
  )
}

function SortTh({ label, k, sort, onSort, className = '', title }: { label: string; k: SortKey; sort: Sort; onSort: (k: SortKey) => void; className?: string; title?: string }) {
  const on = sort?.key === k
  const Icon = !on ? ArrowUpDown : sort.dir === 'desc' ? ArrowDown : ArrowUp
  return (
    <th scope="col" aria-sort={on ? (sort.dir === 'desc' ? 'descending' : 'ascending') : 'none'} className={`px-3 py-2 text-right font-normal ${className}`}>
      <button type="button" onClick={() => onSort(k)} title={title} className={`inline-flex items-center gap-1 uppercase hover:text-ink ${on ? 'text-ink' : ''}`}>
        {label}
        <Icon size={11} aria-hidden />
      </button>
    </th>
  )
}

function Row({ r }: { r: PriceRow }) {
  const a = r.asset
  const flash = useFlash<HTMLTableRowElement>(r.last)
  const to = `/trade/${a.display}`
  const isCash = a.display === 'USDC'
  return (
    <tr
      ref={flash}
      onClick={() => !isCash && navigate(to)}
      className={`border-b border-line/60 transition-colors last:border-0 ${isCash ? '' : 'cursor-pointer hover:bg-panel2/60'}`}
    >
      <td className="px-3 py-2.5">
        <div className="flex min-w-0 items-center gap-2.5">
          <AssetIcon symbol={a.display} />
          <div className="min-w-0">
            <div className="flex min-w-0 items-center gap-1.5">
              {isCash ? (
                <span className="truncate font-semibold">{a.display}</span>
              ) : (
                <Link to={to} className="truncate font-semibold hover:text-accent focus-visible:text-accent" onClick={(e) => e.stopPropagation()}>{a.display}</Link>
              )}
              <span className="hidden sm:inline-flex"><KindBadge asset={a} /></span>
            </div>
            <div className="flex min-w-0 items-center gap-1.5 text-[11px] text-muted">
              <span className="sm:hidden"><KindBadge asset={a} /></span>
              <span className="truncate">{ASSET_NAME[a.display] ?? a.category}</span>
            </div>
          </div>
        </div>
      </td>
      <td className="num px-3 text-right font-mono" title={r.stale ? 'No fresh on-chain price: trading paused' : 'On-chain oracle price (what trades settle against)'}>
        {r.stale ? <span className="text-warn">—</span> : usd(r.last)}
      </td>
      <td className={`num px-3 text-right font-mono ${changeTone(r.change24h)}`} title="24h change of the Arc mainnet reference">{pct(r.change24h)}</td>
      <td className="hidden px-3 md:table-cell">
        <Sparkline pool={r.ref?.topPool} />
      </td>
      <td className="num hidden px-3 text-right font-mono text-muted sm:table-cell">{compactUsd(r.ref?.liquidityUsd)}</td>
      <td className="hidden px-3 sm:table-cell">
        <span className="lg:hidden"><RiskDot level={a.risk} label={false} /></span>
        <span className="hidden lg:inline"><RiskDot level={a.risk} /></span>
      </td>
      <td className="hidden px-3 text-right sm:table-cell">
        {isCash ? (
          <span className="text-[11px] text-faint">Quote</span>
        ) : (
          <Link to={to} onClick={(e) => e.stopPropagation()} className="btn-ghost h-8 px-3 text-xs hover:border-accent/60 hover:text-accent">
            Trade
          </Link>
        )}
      </td>
    </tr>
  )
}
