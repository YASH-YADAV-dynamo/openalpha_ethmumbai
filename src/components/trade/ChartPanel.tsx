// Pair header, candle chart and route panel. Every number comes from ONE price-book row (src/lib/prices.ts):
// last = on-chain oracle (Chainlink CRE), ref = Arc mainnet market (GeckoTerminal), so header, chart line,
// market list and ticket always agree.
import { useMemo, useState } from 'react'
import { ChartCandlestick, ChartSpline, ChevronDown, ExternalLink, Star } from 'lucide-react'
import { USDC_EURC_POOL } from '@/lib/contracts'
import { TIMEFRAMES, useOhlcv, type Timeframe } from '@/lib/market'
import type { PriceRow } from '@/lib/prices'
import { usd } from '@/lib/format'
import { ago, isV4, RISK_LABEL, RISK_TONE, usePoolPrice, useQuote, type Side } from './hooks'
import { CandleChart, type RefLine } from './CandleChart'
import { useFavs } from './favs'
import { compactUsd, MirrorBadge, RiskDot, signedPct, Skel, toneOf, useMedia } from './ui'

export type QuoteInfo = { side: Side; size: string; rate: number; impact: number | null }

const GT_POOL = (pool: string) => `https://www.geckoterminal.com/arc/pools/${pool}`

/** 24h high/low from the last 24 1H mainnet candles (same query the chart uses by default). */
function use24h(row: PriceRow) {
  const c = useOhlcv(row.ref?.topPool, '1H', row.refToken)
  return useMemo(() => {
    const list = c.data ?? []
    const since = list.length ? list[list.length - 1].t - 86_400 + 3_600 : 0 // the last 24 hourly candles
    const day = list.filter((k) => k.t >= since)
    if (!day.length) return { hi: null, lo: null, loading: c.isLoading }
    return { hi: Math.max(...day.map((k) => k.h)), lo: Math.min(...day.map((k) => k.l)), loading: false }
  }, [c.data, c.isLoading])
}

export function PairHeader({ row, refLoading, onMarkets }: { row: PriceRow; refLoading: boolean; onMarkets?: () => void }) {
  const a = row.asset
  const { isFav, toggle } = useFavs()
  const fav = isFav(a.display)
  const hl = use24h(row)
  const ch = row.change24h
  return (
    <header className="flex flex-wrap items-center gap-x-6 gap-y-2 px-3 py-2.5 sm:px-4">
      <div className="flex min-w-0 items-center gap-2">
        <button type="button" onClick={() => toggle(a.display)} aria-pressed={fav} aria-label={fav ? `Remove ${a.display} from favourites` : `Add ${a.display} to favourites`}
          className="grid size-8 shrink-0 place-items-center rounded-lg text-faint hover:bg-panel2 hover:text-ink">
          <Star size={16} className={fav ? 'fill-warn text-warn' : ''} />
        </button>
        <button type="button" onClick={onMarkets} className="flex min-w-0 items-center gap-1 rounded-lg text-left xl:pointer-events-none" aria-label="Switch market">
          <h1 className="truncate text-lg font-semibold tracking-tight">{a.display}<span className="font-normal text-muted"> / USDC</span></h1>
          {onMarkets && <ChevronDown size={16} className="shrink-0 text-muted xl:hidden" />}
        </button>
        <MirrorBadge mirror={a.mirror} />
        <span className="flex items-center gap-1.5 text-[11px]" title={`Risk level ${a.risk}`}>
          <RiskDot level={a.risk} /><span className={`${RISK_TONE[a.risk] ?? ''} hidden sm:inline`}>{RISK_LABEL[a.risk] ?? '—'}</span>
        </span>
      </div>

      <div className="flex min-w-0 flex-wrap items-end gap-x-5 gap-y-1.5">
        <div title="On-chain oracle price (AssetRegistry, written by Chainlink CRE)">
          <p className="text-[11px] text-muted">Last · oracle</p>
          <p className={`font-mono text-lg font-semibold leading-6 num ${row.stale ? 'text-down' : toneOf(ch)}`}>{row.stale ? 'stale' : usd(row.last)}</p>
        </div>
        <HStat label="24h change" value={signedPct(ch)} cls={toneOf(ch)} loading={refLoading} />
        <HStat label="24h high" value={usd(hl.hi)} loading={refLoading || hl.loading} />
        <HStat label="24h low" value={usd(hl.lo)} loading={refLoading || hl.loading} />
        <HStat label="24h volume" value={compactUsd(row.ref?.volume24h)} loading={refLoading} />
        <HStat label="Liquidity" value={compactUsd(row.ref?.liquidityUsd)} loading={refLoading} />
        <HStat label="Oracle age" value={row.stale ? 'stale' : ago(a.observedAt)} cls={row.stale ? 'text-down' : ''} />
      </div>
    </header>
  )
}

function HStat({ label, value, cls = '', loading }: { label: string; value: string; cls?: string; loading?: boolean }) {
  return (
    <div className="min-w-0">
      <p className="text-[11px] text-muted">{label}</p>
      {loading ? <Skel className="mt-1 h-4 w-14" /> : <p className={`font-mono text-[13px] leading-5 num ${cls}`}>{value}</p>}
    </div>
  )
}

export function ChartBody({ row, refLoading }: { row: PriceRow; refLoading: boolean }) {
  const [tf, setTf] = useState<Timeframe>('1H')
  const [mode, setMode] = useState<'candle' | 'area'>('candle')
  const wide = useMedia('(min-width: 1024px)')
  const height = wide ? 400 : 300
  const a = row.asset
  const v4 = isV4(a)
  const pool = row.ref?.topPool ?? null
  const c = useOhlcv(pool, tf, row.refToken)
  const poolPx = usePoolPrice(v4)
  const pmid = v4 ? (poolPx.data ?? null) : null
  const poolDev = pmid !== null && row.last ? ((pmid - row.last) / row.last) * 100 : null

  const lines = useMemo(() => {
    const out: RefLine[] = []
    if (row.last !== null) out.push({ price: row.last, label: 'Oracle', tone: row.change24h === null ? 'muted' : row.change24h >= 0 ? 'up' : 'down', dashed: 'long' })
    if (pmid !== null) out.push({ price: pmid, label: 'Testnet pool', tone: 'warn', dashed: 'short' })
    return out
  }, [row.last, row.change24h, pmid])

  const candles = c.data ?? []
  const waitingPool = refLoading || (Boolean(row.refToken) && !row.ref)
  const noMarket = !waitingPool && !pool

  return (
    <div>
      <div className="flex flex-wrap items-center gap-2 border-b border-line px-2 py-1.5 sm:px-3">
        <div className="flex gap-0.5" role="group" aria-label="Timeframe">
          {(Object.keys(TIMEFRAMES) as Timeframe[]).map((k) => (
            <button key={k} type="button" onClick={() => setTf(k)} aria-pressed={tf === k}
              className={`h-8 min-w-9 rounded-md px-2 font-mono text-xs transition ${tf === k ? 'bg-panel2 text-ink' : 'text-muted hover:text-ink'}`}>{k}</button>
          ))}
        </div>
        <span className="h-4 w-px bg-line" aria-hidden="true" />
        <div className="flex gap-0.5" role="group" aria-label="Chart type">
          {([['candle', ChartCandlestick, 'Candles'], ['area', ChartSpline, 'Line']] as const).map(([k, Icon, l]) => (
            <button key={k} type="button" onClick={() => setMode(k)} aria-pressed={mode === k} aria-label={l} title={l}
              className={`grid h-8 w-9 place-items-center rounded-md transition ${mode === k ? 'bg-panel2 text-ink' : 'text-muted hover:text-ink'}`}><Icon size={16} /></button>
          ))}
        </div>
        {c.isFetching && candles.length > 0 && <span className="text-[11px] text-faint">updating…</span>}
        <div className="ml-auto flex flex-wrap items-center justify-end gap-x-3 gap-y-0.5 font-mono text-[11px] num">
          {row.last !== null ? (
            <span className="flex items-center gap-1.5 text-muted"><span className="inline-block h-0 w-4 border-t border-dashed border-current" aria-hidden="true" />Oracle <span className="text-ink">{usd(row.last)}</span></span>
          ) : (
            <span className="text-down" title="The on-chain oracle price is older than the registry's max staleness">Oracle stale</span>
          )}
          {pmid !== null && (
            <span className="flex items-center gap-1.5 text-warn" title="Uniswap v4 USDC/EURC pool mid price on Arc Testnet (StateView slot0)">
              <span className="inline-block h-0 w-4 border-t border-dotted border-current" aria-hidden="true" />Testnet pool <span className="text-ink">{usd(pmid)}</span>
              <span className={poolDev !== null && Math.abs(poolDev) > 1 ? 'text-warn' : 'text-muted'}>({signedPct(poolDev)})</span>
            </span>
          )}
        </div>
      </div>

      {waitingPool || (c.isLoading && pool) ? (
        <ChartSkeleton height={height} />
      ) : noMarket ? (
        <Empty height={height} title="No Arc mainnet market" text={`${a.display} has no Arc mainnet pool to chart. Trades still settle on the on-chain oracle price above.`} />
      ) : candles.length < 2 ? (
        <Empty height={height} title="Chart data unavailable" text="GeckoTerminal did not return candles for this pool. Retrying every minute." />
      ) : (
        <div className="px-1 pt-1"><CandleChart candles={candles} tf={tf} mode={mode} lines={lines} height={height} /></div>
      )}

      <p className="flex flex-wrap items-center gap-x-1 border-t border-line px-3 py-1.5 text-[11px] text-faint">
        <span>Chart: Arc mainnet {a.display}/USDC (deepest pool)</span>
        {pool && <a href={GT_POOL(pool)} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-0.5 text-muted hover:text-ink">GeckoTerminal<ExternalLink size={10} /></a>}
        <span>· Last: on-chain oracle (Chainlink CRE)</span>
      </p>
    </div>
  )
}

function ChartSkeleton({ height }: { height: number }) {
  return (
    <div className="flex items-end gap-1 px-4 pb-6 pt-8" style={{ height }} aria-busy="true" aria-label="Loading chart">
      {Array.from({ length: 36 }).map((_, i) => (
        <span key={i} className="block flex-1 animate-pulse rounded-sm bg-panel2" style={{ height: `${30 + ((i * 37) % 45)}%` }} />
      ))}
    </div>
  )
}

function Empty({ height, title, text }: { height: number; title: string; text: string }) {
  return (
    <div className="flex flex-col items-center justify-center gap-1.5 px-6 text-center" style={{ height }}>
      <p className="eyebrow">{title}</p>
      <p className="max-w-sm text-xs text-muted">{text}</p>
    </div>
  )
}

const REF_SIZE = 100_000_000n // 100 USDC reference buy, used while the ticket has no amount

/** Route + price comparison: oracle vs Arc mainnet market, testnet pool vs oracle, quote vs oracle. */
export function RoutePanel({ row, quote }: { row: PriceRow; quote: QuoteInfo | null }) {
  const a = row.asset
  const v4 = isV4(a)
  const poolPx = usePoolPrice(v4)
  const pmid = v4 ? (poolPx.data ?? null) : null
  const refQ = useQuote(a, 'buy', quote ? null : REF_SIZE)
  const refRate = !quote && refQ.data && refQ.data > 0n ? 100 / (Number(refQ.data) / 10 ** a.decimals) : null
  const refImpact = refRate !== null && row.last ? (refRate / row.last - 1) * 100 : null
  const q = quote ?? (refRate !== null ? { side: 'buy' as const, size: '100 USDC', rate: refRate, impact: refImpact } : null)
  const dev = row.deviation !== null ? row.deviation * 100 : null
  const poolDev = pmid !== null && row.last ? ((pmid - row.last) / row.last) * 100 : null
  const warn = (n: number | null, lim = 1) => (n !== null && Math.abs(n) > lim ? '!text-warn' : '')

  return (
    <div className="grid grid-cols-2 gap-x-4 gap-y-2.5 border-t border-line px-3 py-3 text-xs sm:grid-cols-3 sm:px-4 2xl:grid-cols-6">
      <KV k="Route" v={v4 ? `Uniswap v4 · fee ${(USDC_EURC_POOL.fee / 10_000).toFixed(2)}%` : 'MirrorVenue · 0.30% spread'} sub={v4 ? 'USDC/EURC pool, Arc Testnet' : 'Fills at oracle price, max 5,000 USDC'} mono={false} />
      <KV k="Oracle (Chainlink CRE)" v={row.stale ? 'stale' : usd(row.last)} sub={row.stale ? (a.mirror ? 'mirror trading paused' : 'no fresh oracle price') : ago(a.observedAt)} cls={row.stale ? 'text-down' : ''} />
      <KV k="Arc mainnet market" v={usd(row.ref?.priceUsd)} sub={`oracle vs market ${signedPct(dev)}`} subCls={warn(dev)} />
      {v4 && <KV k="Testnet pool mid" v={usd(pmid)} sub={`vs oracle ${signedPct(poolDev)}`} subCls={warn(poolDev)} loading={poolPx.isLoading} />}
      <KV k={q ? `Quote · ${q.side} ${q.size}` : 'Quote'} v={q ? usd(q.rate) : '—'} sub={`vs oracle ${signedPct(q?.impact ?? null)}`} subCls={warn(q?.impact ?? null)} loading={!quote && refQ.isLoading} />
      <KV k="Mainnet liquidity" v={compactUsd(row.ref?.liquidityUsd)} sub={`24h vol ${compactUsd(row.ref?.volume24h)}`} />
    </div>
  )
}

function KV({ k, v, sub, cls = '', subCls = '', mono = true, loading }: { k: string; v: string; sub?: string; cls?: string; subCls?: string; mono?: boolean; loading?: boolean }) {
  return (
    <div className="min-w-0">
      <p className="truncate text-[11px] text-muted">{k}</p>
      {loading ? <Skel className="mt-1 h-4 w-20" /> : <p className={`truncate ${mono ? 'font-mono num' : 'font-medium'} text-[13px] ${cls}`}>{v}</p>}
      {sub && <p className={`truncate font-mono text-[11px] num text-faint ${subCls}`}>{sub}</p>}
    </div>
  )
}
