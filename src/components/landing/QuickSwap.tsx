// Compact USDC → asset quote card. Live quote from the same venue hooks the trade ticket uses;
// "Swap" opens the trade terminal with the amount prefilled (#/trade/:symbol?amount=…&side=buy).
import { useState } from 'react'
import { parseUnits } from 'viem'
import { ArrowDown } from 'lucide-react'
import { usePriceBook } from '@/lib/prices'
import { ASSET_NAME } from '@/lib/assets'
import { amt, usd } from '@/lib/format'
import { navigate } from '@/lib/router'
import { USDC_DECIMALS, isV4, revertReason, useDebounced, useQuote } from '@/components/trade/hooks'
import { AssetIcon, KindBadge, Skel } from '@/components/markets/ui'

const AMOUNT_RE = /^\d*\.?\d{0,6}$/

function toUnits(v: string): bigint | null {
  if (!v || v === '.') return null
  try {
    const n = parseUnits(v, USDC_DECIMALS)
    return n > 0n ? n : null
  } catch {
    return null
  }
}

export function QuickSwap() {
  const book = usePriceBook()
  const options = book.rows.filter((r) => r.asset.display !== 'USDC')
  const [sym, setSym] = useState('EURC')
  const [amount, setAmount] = useState('100')
  const row = book.bySymbol.get(sym.toLowerCase()) ?? options[0]
  const asset = row?.asset
  const units = toUnits(amount)
  const debounced = useDebounced(units, 400)
  const quote = useQuote(asset, 'buy', debounced)
  const settling = units !== debounced

  const reason = !row
    ? book.isLoading ? 'Loading markets…' : 'No markets available'
    : row.stale ? 'No fresh on-chain price: trading paused'
    : row.asset.risk >= 2 ? 'Buys paused by this asset’s risk level'
    : !units ? 'Enter an amount'
    : null

  const go = () => asset && units && navigate(`/trade/${asset.display}?amount=${amount}&side=buy`)

  return (
    <div className="card p-3 sm:p-4">
      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-sm font-semibold">Quick swap</h2>
        <span className="font-mono text-[10px] uppercase tracking-wide text-faint">Market · Arc Testnet</span>
      </div>

      <label className="block rounded-xl border border-line bg-panel2 p-3 focus-within:border-accent">
        <span className="flex items-center justify-between text-[11px] text-muted">
          <span>You pay</span>
        </span>
        <span className="mt-1 flex items-center gap-2">
          <input
            inputMode="decimal"
            autoComplete="off"
            aria-label="Amount in USDC"
            className="num min-w-0 flex-1 bg-transparent font-mono text-xl text-ink outline-none placeholder:text-faint"
            placeholder="0.00"
            value={amount}
            onChange={(e) => AMOUNT_RE.test(e.target.value) && setAmount(e.target.value)}
          />
          <span className="inline-flex shrink-0 items-center gap-1.5 rounded-lg bg-panel px-2 py-1 text-[13px] font-semibold">
            <AssetIcon symbol="USDC" size={18} /> USDC
          </span>
        </span>
      </label>

      <div className="relative z-10 -my-2 flex justify-center">
        <span className="inline-flex h-7 w-7 items-center justify-center rounded-lg border border-line bg-panel text-muted"><ArrowDown size={14} /></span>
      </div>

      <div className="rounded-xl border border-line bg-panel2 p-3">
        <span className="text-[11px] text-muted">You receive (estimate)</span>
        <div className="mt-1 flex items-center gap-2">
          <div className="num min-w-0 flex-1 truncate font-mono text-xl">
            {!asset || reason ? (
              <span className="text-faint">—</span>
            ) : quote.isLoading || settling ? (
              <Skel className="h-6 w-28" />
            ) : quote.data !== undefined ? (
              amt(quote.data, asset.decimals)
            ) : (
              <span className="text-faint">—</span>
            )}
          </div>
          <label className="relative shrink-0">
            <span className="sr-only">Asset to buy</span>
            <select
              className="h-9 appearance-none rounded-lg border border-line bg-panel pl-2 pr-7 text-[13px] font-semibold text-ink outline-none focus:border-accent"
              value={asset?.display ?? ''}
              onChange={(e) => setSym(e.target.value)}
              disabled={!options.length}
            >
              {options.map((r) => (
                <option key={r.asset.token} value={r.asset.display}>
                  {r.asset.display}
                </option>
              ))}
            </select>
            <span aria-hidden className="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 text-[10px] text-muted">▼</span>
          </label>
        </div>
      </div>

      <dl className="mt-3 space-y-1 text-xs">
        <div className="flex items-center justify-between gap-2">
          <dt className="text-muted">Asset</dt>
          <dd className="flex min-w-0 items-center gap-1.5">
            <span className="truncate">{asset ? (ASSET_NAME[asset.display] ?? asset.display) : '—'}</span>
            {asset && <KindBadge asset={asset} />}
          </dd>
        </div>
        <div className="flex justify-between gap-2">
          <dt className="text-muted">Oracle price</dt>
          <dd className="num font-mono">{row && !row.stale ? usd(row.last) : '—'}</dd>
        </div>
        <div className="flex justify-between gap-2">
          <dt className="text-muted">Route</dt>
          <dd>{asset ? (isV4(asset) ? 'Uniswap v4 pool' : 'MirrorVenue') : '—'}</dd>
        </div>
      </dl>

      {quote.error && !reason && <p className="mt-2 text-xs text-down">{revertReason(quote.error)}</p>}
      {reason && units !== null && <p className="mt-2 text-xs text-warn">{reason}</p>}

      <button type="button" className="btn mt-3 h-11 w-full" disabled={Boolean(reason)} onClick={go}>
        {reason && units === null ? reason : `Swap USDC → ${asset?.display ?? '…'}`}
      </button>
      <p className="mt-2 text-center text-[11px] text-faint">Opens the trade ticket with this amount; you review and sign there.</p>
    </div>
  )
}
