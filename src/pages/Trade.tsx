// Trade terminal. Desktop (xl): [markets 280] [pair header · chart · route] [ticket 340], bottom tabs full width.
// Below xl the market list opens as a sheet from the pair title; below lg one screen at a time (Chart | Trade | Trades)
// with sticky Buy/Sell buttons that open the ticket as a bottom sheet.
// All prices on this page come from ONE price-book row (usePriceBook) so every panel shows the same numbers.
import { useEffect, useState, type ReactNode } from 'react'
import { useAccount } from 'wagmi'
import { useIsFetching, useQueryClient } from '@tanstack/react-query'
import { X } from 'lucide-react'
import { usePriceBook, type PriceRow } from '@/lib/prices'
import { isUsdc, useTokenBalances, type Side } from '@/components/trade/hooks'
import { MarketList } from '@/components/trade/MarketList'
import { ChartBody, PairHeader, RoutePanel, type QuoteInfo } from '@/components/trade/ChartPanel'
import { OrderTicket } from '@/components/trade/OrderTicket'
import { BottomTabs } from '@/components/trade/BottomTabs'
import { Skel } from '@/components/trade/ui'

type Screen = 'chart' | 'trade' | 'trades'

// while the sticky Buy/Sell bar shows, lift the "Built with Arc Studio" badge (positioned by --badge-bottom) above it
const BADGE_LIFT = `@media (max-width: 767px){:root{--badge-bottom:calc(132px + env(safe-area-inset-bottom))}}@media (min-width: 768px) and (max-width: 1023px){:root{--badge-bottom:76px}}`

/** Prefill from the hash query, e.g. #/trade/EURC?amount=100&side=buy (landing quick-swap). */
function readPrefill(): { amount: string; side: Side | undefined } {
  const q = new URLSearchParams(window.location.hash.split('?')[1] ?? '')
  const amount = (q.get('amount') ?? '').replace(/[^0-9.]/g, '')
  const side = q.get('side')
  return { amount: Number(amount) > 0 ? amount : '', side: side === 'buy' || side === 'sell' ? side : undefined }
}

function usePrefill() {
  const [p, setP] = useState(readPrefill)
  useEffect(() => {
    const on = () => setP(readPrefill())
    window.addEventListener('hashchange', on)
    return () => window.removeEventListener('hashchange', on)
  }, [])
  return p
}

export default function Trade({ symbol }: { symbol: string }) {
  const [screen, setScreen] = useState<Screen>('chart')
  const [marketsOpen, setMarketsOpen] = useState(false)
  const [sheet, setSheet] = useState<Side | null>(null)
  const [quote, setQuote] = useState<QuoteInfo | null>(null)
  const prefill = usePrefill()
  const { address } = useAccount()
  const qc = useQueryClient()
  const book = usePriceBook()
  const searching = useIsFetching({ queryKey: ['refTokens'] }) > 0
  const rows = book.rows
  const row = book.bySymbol.get(symbol.toLowerCase())
  const tradable: PriceRow | undefined = row && !isUsdc(row.asset.token) ? row : undefined
  const balances = useTokenBalances(address, rows.map((r) => r.asset.token))
  const refLoading = Boolean(tradable && !tradable.ref && (tradable.asset.mainnetRef || (!tradable.refToken && searching)))

  const afterSwap = () => {
    void balances.refetch()
    void qc.invalidateQueries({ queryKey: ['trade', 'swaps'] })
    void qc.invalidateQueries({ queryKey: ['trade', 'quote'] })
  }

  const show = (s: Screen) => (screen === s ? 'flex' : 'hidden lg:flex')
  const panel = 'card min-w-0 flex-col overflow-hidden'
  const ticket = (side?: Side, report = false) =>
    tradable ? (
      <OrderTicket key={`${tradable.asset.token}-${side ?? prefill.side ?? ''}-${prefill.amount}`} row={tradable} defaultSide={side ?? prefill.side} defaultAmount={side && side !== prefill.side ? '' : prefill.amount} balances={balances.data} balancesLoading={balances.isLoading} onDone={afterSwap} onQuote={report ? setQuote : undefined} />
    ) : null

  return (
    <div className="mx-auto w-full max-w-[1760px] px-2 pb-28 pt-2 lg:px-3 lg:pb-6 lg:pt-3">
      {tradable && screen !== 'trade' && <style>{BADGE_LIFT}</style>}

      <div className="grid grid-cols-1 gap-2 lg:grid-cols-[minmax(0,1fr)_320px] xl:grid-cols-[280px_minmax(0,1fr)_340px]">
        {/* markets (desktop xl) */}
        <section aria-label="Markets" className={`${panel} relative hidden min-h-[560px] xl:col-start-1 xl:row-span-3 xl:row-start-1 xl:flex`}>
          <div className="absolute inset-0 flex flex-col">
            <MarketList rows={rows} loading={book.isLoading} current={tradable?.asset.display} />
          </div>
        </section>

        {/* pair header (always visible) */}
        <section aria-label="Pair" className={`${panel} flex lg:col-start-1 lg:row-start-1 xl:col-start-2`}>
          {book.isLoading ? (
            <div className="flex gap-4 p-4"><Skel className="h-8 w-40" /><Skel className="h-8 w-24" /><Skel className="h-8 w-24" /></div>
          ) : tradable ? (
            <PairHeader row={tradable} refLoading={refLoading} onMarkets={() => setMarketsOpen(true)} />
          ) : (
            <NotFound symbol={symbol} error={Boolean(book.error)} onBrowse={() => setMarketsOpen(true)} />
          )}
        </section>

        {/* mobile screen switch */}
        <nav aria-label="Trade screens" className="sticky top-[88px] z-20 -mx-2 bg-bg/90 px-2 py-1 backdrop-blur lg:hidden">
          <div className="grid grid-cols-3 rounded-xl bg-panel2 p-1">
            {([['chart', 'Chart'], ['trade', 'Trade'], ['trades', 'Trades']] as const).map(([s, l]) => (
              <button key={s} type="button" aria-pressed={screen === s} onClick={() => setScreen(s)}
                className={`h-9 rounded-lg text-sm transition ${screen === s ? 'bg-panel font-semibold text-ink shadow-sm' : 'text-muted'}`}>{l}</button>
            ))}
          </div>
        </nav>

        {/* chart + route */}
        <section aria-label="Chart" className={`${panel} ${show('chart')} lg:col-start-1 lg:row-start-2 xl:col-start-2`}>
          {book.isLoading ? (
            <div className="space-y-3 p-4"><Skel className="h-8 w-1/2" /><Skel className="h-[300px] w-full lg:h-[400px]" /></div>
          ) : tradable ? (
            <>
              <ChartBody key={tradable.asset.token} row={tradable} refLoading={refLoading} />
              <RoutePanel row={tradable} quote={quote} />
            </>
          ) : (
            <div className="h-[300px]" />
          )}
        </section>

        {/* order ticket */}
        <section aria-label="Order ticket" className={`${panel} ${show('trade')} lg:col-start-2 lg:row-span-2 lg:row-start-1 xl:col-start-3`}>
          {tradable ? ticket(undefined, true) : (
            <div className="space-y-3 p-4">
              {book.isLoading ? <><Skel className="h-9 w-full" /><Skel className="h-11 w-full" /><Skel className="h-24 w-full" /></> : <p className="text-sm text-muted">Pick a market to trade.</p>}
            </div>
          )}
        </section>

        {/* bottom tabs */}
        <section aria-label="Trades and balances" className={`${panel} ${show('trades')} lg:col-span-2 lg:col-start-1 lg:row-start-3 xl:col-start-2`}>
          {tradable ? (
            <BottomTabs row={tradable} rows={rows} balances={balances.data} balancesLoading={balances.isLoading} />
          ) : book.isLoading ? (
            <div className="p-4"><Skel className="h-32 w-full" /></div>
          ) : (
            <p className="p-4 text-sm text-muted">Trades and balances appear once you pick a market.</p>
          )}
        </section>
      </div>

      {/* sticky Buy / Sell (mobile, when the ticket screen is not showing) */}
      {tradable && screen !== 'trade' && (
        <div className="fixed inset-x-0 bottom-[calc(3.5rem+env(safe-area-inset-bottom))] z-30 border-t border-line bg-bg/95 px-3 py-2 backdrop-blur-md md:bottom-0 lg:hidden">
          <div className="mx-auto grid max-w-xl grid-cols-2 gap-2">
            <button type="button" className="btn h-11 !bg-up" onClick={() => setSheet('buy')}>Buy {tradable.asset.display}</button>
            <button type="button" className="btn h-11 !bg-down" onClick={() => setSheet('sell')}>Sell {tradable.asset.display}</button>
          </div>
        </div>
      )}

      {sheet && tradable && (
        <Sheet title={`${tradable.asset.display} / USDC`} onClose={() => setSheet(null)}>{ticket(sheet)}</Sheet>
      )}
      {marketsOpen && (
        <Sheet title="Markets" onClose={() => setMarketsOpen(false)} tall>
          <MarketList rows={rows} loading={book.isLoading} current={tradable?.asset.display} onPick={() => setMarketsOpen(false)} />
        </Sheet>
      )}
    </div>
  )
}

function Sheet({ title, onClose, children, tall }: { title: string; onClose: () => void; children: ReactNode; tall?: boolean }) {
  useEffect(() => {
    const k = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', k)
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => { window.removeEventListener('keydown', k); document.body.style.overflow = prev }
  }, [onClose])
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center" role="dialog" aria-modal="true" aria-label={title}>
      <button type="button" aria-label="Close" className="absolute inset-0 bg-black/50" onClick={onClose} />
      <div className={`relative flex w-full max-w-md flex-col overflow-hidden rounded-t-2xl border border-line bg-panel pb-[env(safe-area-inset-bottom)] sm:rounded-2xl ${tall ? 'h-[85dvh]' : 'max-h-[90dvh]'}`}>
        <div className="flex items-center justify-between border-b border-line px-4 py-2">
          <p className="text-sm font-semibold">{title}</p>
          <button type="button" onClick={onClose} aria-label="Close" className="grid size-9 place-items-center rounded-lg text-muted hover:bg-panel2 hover:text-ink"><X size={18} /></button>
        </div>
        <div className="flex min-h-0 flex-1 flex-col overflow-y-auto">{children}</div>
      </div>
    </div>
  )
}

function NotFound({ symbol, error, onBrowse }: { symbol: string; error: boolean; onBrowse: () => void }) {
  return (
    <div className="flex w-full flex-col items-start gap-2 p-4">
      <p className="eyebrow">{error ? 'Could not load markets' : 'Market not found'}</p>
      <p className="max-w-md text-sm text-muted">
        {error ? 'The asset registry did not respond. It will retry automatically.' : `"${symbol}" is not a tradable market. USDC is the quote currency for every pair.`}
      </p>
      <button type="button" className="btn-ghost xl:hidden" onClick={onBrowse}>Browse markets</button>
    </div>
  )
}
