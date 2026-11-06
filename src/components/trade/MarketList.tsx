// Market sidebar. Rows come from the shared price book, so last/24h match the header, chart and ticket.
import { useMemo, useState } from 'react'
import { Star } from 'lucide-react'
import { ASSET_NAME } from '@/lib/assets'
import type { PriceRow } from '@/lib/prices'
import { navigate } from '@/lib/router'
import { usd } from '@/lib/format'
import { useFavs } from './favs'
import { MirrorBadge, RiskDot, signedPct, Skel, toneOf } from './ui'

const TABS = ['★', 'All', 'FX', 'Crypto', 'Yield', 'RWA'] as const

export function MarketList({ rows, loading, current, onPick }: { rows: PriceRow[]; loading: boolean; current?: string; onPick?: () => void }) {
  const { favs, isFav, toggle } = useFavs()
  const [tab, setTab] = useState<(typeof TABS)[number]>('All')
  const [q, setQ] = useState('')
  const list = useMemo(() => {
    const s = q.trim().toLowerCase()
    return rows
      .filter((r) => r.asset.category !== 'Cash')
      .filter((r) => (tab === '★' ? favs.includes(r.asset.display) : tab === 'All' || r.asset.category === tab))
      .filter((r) => !s || r.asset.display.toLowerCase().includes(s) || (ASSET_NAME[r.asset.display] ?? '').toLowerCase().includes(s))
  }, [rows, tab, q, favs])

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="space-y-2 border-b border-line p-2.5">
        <input className="field h-9" placeholder="Search markets" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search markets" />
        <div className="flex gap-0.5 overflow-x-auto" role="tablist" aria-label="Category">
          {TABS.map((t) => (
            <button key={t} type="button" role="tab" aria-selected={tab === t} aria-label={t === '★' ? 'Favourites' : t} onClick={() => setTab(t)}
              className={`tab shrink-0 px-2 py-1 text-xs ${tab === t ? 'tab-on' : ''} ${t === '★' ? 'text-warn' : ''}`}>
              {t}
            </button>
          ))}
        </div>
      </div>
      <div className="grid grid-cols-[minmax(0,1fr)_5.5rem_3.75rem] gap-1 px-3 pb-1 pt-2 font-mono text-[10px] uppercase tracking-wide text-faint">
        <span>Pair</span>
        <span className="text-right">Last</span>
        <span className="text-right">24h</span>
      </div>
      <ul className="min-h-0 flex-1 overflow-y-auto px-1.5 pb-1.5">
        {loading &&
          Array.from({ length: 7 }).map((_, i) => (
            <li key={i} className="flex items-center justify-between px-2 py-2.5">
              <Skel className="h-7 w-24" />
              <Skel className="h-7 w-20" />
            </li>
          ))}
        {!loading && list.length === 0 && <li className="px-2 py-6 text-center text-xs text-muted">{tab === '★' ? 'Star a market to pin it here.' : 'No markets match.'}</li>}
        {list.map((r) => {
          const a = r.asset
          const on = a.display.toLowerCase() === current?.toLowerCase()
          const fav = isFav(a.display)
          return (
            <li key={a.token} className={`group flex items-center rounded-lg transition ${on ? 'bg-panel2' : 'hover:bg-panel2/60'}`}>
              <button type="button" onClick={() => toggle(a.display)} aria-pressed={fav} aria-label={fav ? `Unstar ${a.display}` : `Star ${a.display}`}
                className="grid h-11 w-7 shrink-0 place-items-center text-faint hover:text-warn">
                <Star size={12} className={fav ? 'fill-warn text-warn' : ''} />
              </button>
              <button type="button" aria-current={on ? 'page' : undefined}
                onClick={() => { navigate(`/trade/${a.display}`); onPick?.() }}
                className="grid min-h-11 min-w-0 flex-1 grid-cols-[minmax(0,1fr)_5.5rem_3.75rem] items-center gap-1 py-1.5 pr-1.5 text-left">
                <span className="min-w-0">
                  <span className="flex items-center gap-1.5">
                    <span className="truncate text-[13px] font-semibold">{a.display}<span className="font-normal text-faint">/USDC</span></span>
                    <RiskDot level={a.risk} />
                  </span>
                  <span className="mt-0.5 flex items-center gap-1"><MirrorBadge mirror={a.mirror} /></span>
                </span>
                <span className={`text-right font-mono text-xs num ${r.stale ? 'text-down' : ''}`}>{r.stale ? 'stale' : usd(r.last)}</span>
                <span className={`text-right font-mono text-xs num ${toneOf(r.change24h) || 'text-faint'}`}>{signedPct(r.change24h)}</span>
              </button>
            </li>
          )
        })}
      </ul>
    </div>
  )
}
