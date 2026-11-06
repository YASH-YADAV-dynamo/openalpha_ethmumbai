// Market order ticket. Price shown = the same price-book row as the header/chart (on-chain oracle);
// the quote comes from the venue (v4 Quoter for EURC, MirrorVenue.quote for mirrors). Approve → Swap via useTx.
import { useEffect, useMemo, useState } from 'react'
import { useAccount, useSwitchChain } from 'wagmi'
import { arcTestnet } from 'viem/chains'
import { ConnectKitButton } from 'connectkit'
import { erc20Abi, formatUnits, parseUnits } from 'viem'
import { ADDR, USDC_EURC_POOL, venueAbi } from '@/lib/contracts'
import type { PriceRow } from '@/lib/prices'
import { useTx } from '@/lib/tx'
import { amt, usd } from '@/lib/format'
import { isV4, revertReason, useAllowance, useDebounced, useQuote, useVenueName, USDC_DECIMALS, type Side } from './hooks'
import type { QuoteInfo } from './ChartPanel'
import { signedPct, Skel } from './ui'

const SLIPS = [10, 50, 100] // bps

function toUnits(s: string, decimals: number): bigint | null {
  if (!s || !/^\d*\.?\d*$/.test(s) || s === '.') return null
  const [i, f = ''] = s.split('.')
  try {
    const v = parseUnits(`${i || '0'}.${f.slice(0, decimals) || '0'}`, decimals)
    return v > 0n ? v : null
  } catch {
    return null
  }
}

type Props = {
  row: PriceRow
  balances: Record<string, bigint> | undefined
  balancesLoading: boolean
  onDone: () => void
  defaultSide?: Side
  defaultAmount?: string
  onQuote?: (q: QuoteInfo | null) => void
}

export function OrderTicket({ row, balances, balancesLoading, onDone, defaultSide = 'buy', defaultAmount = '', onQuote }: Props) {
  const asset = row.asset
  const { address, isConnected, chainId } = useAccount()
  const { switchChain, isPending: switching } = useSwitchChain()
  const { send, pending } = useTx()
  const [side, setSide] = useState<Side>(defaultSide)
  const [amount, setAmount] = useState(defaultAmount)
  const [slip, setSlip] = useState(50)
  const [customSlip, setCustomSlip] = useState('')
  const wrongNet = isConnected && chainId !== arcTestnet.id
  const v4 = isV4(asset)

  const tokenIn = side === 'buy' ? ADDR.usdc : asset.token
  const tokenOut = side === 'buy' ? asset.token : ADDR.usdc
  const decIn = side === 'buy' ? USDC_DECIMALS : asset.decimals
  const decOut = side === 'buy' ? asset.decimals : USDC_DECIMALS
  const symIn = side === 'buy' ? 'USDC' : asset.display
  const symOut = side === 'buy' ? asset.display : 'USDC'

  const bal = balances?.[tokenIn.toLowerCase()]
  const amountIn = toUnits(amount, decIn)
  const debounced = useDebounced(amountIn, 400)
  const settled = debounced === amountIn
  const quote = useQuote(asset, side, debounced)
  const allowance = useAllowance(address, tokenIn, asset.venue)
  const venueName = useVenueName(asset)

  const customOk = customSlip !== '' && Number.isFinite(Number(customSlip)) && Number(customSlip) > 0 && Number(customSlip) <= 50
  const slipBps = customOk ? Math.round(Number(customSlip) * 100) : slip
  const out = settled && quote.data !== undefined && quote.data > 0n ? quote.data : null
  const minOut = out !== null ? (out * BigInt(10000 - slipBps)) / 10000n : null

  // price per token in USDC implied by the quote, and its gap to the oracle (same row as header/chart)
  const px = row.last
  const { rate, impact } = useMemo(() => {
    if (out === null || !amountIn) return { rate: null, impact: null }
    const inN = Number(formatUnits(amountIn, decIn))
    const outN = Number(formatUnits(out, decOut))
    const r = side === 'buy' ? inN / outN : outN / inN
    return { rate: Number.isFinite(r) ? r : null, impact: px && Number.isFinite(r) ? (side === 'buy' ? (r / px - 1) * 100 : (1 - r / px) * 100) : null }
  }, [out, amountIn, decIn, decOut, side, px])

  useEffect(() => {
    onQuote?.(rate !== null ? { side, size: `${amount} ${symIn}`, rate, impact } : null)
  }, [onQuote, rate, impact, side, amount, symIn])
  useEffect(() => () => onQuote?.(null), [onQuote])

  // reasons the venue would refuse this trade (checked before the wallet ever opens)
  const blocked =
    asset.mirror && row.stale
      ? 'Price is stale, so the mirror venue cannot quote. Trading resumes when the oracle updates.'
      : asset.mirror && side === 'buy' && asset.risk >= 2
        ? `Buys are paused: risk level ${asset.risk} (${asset.risk >= 3 ? 'Exit' : 'No buys'}). Sells still work.`
        : null

  let error: string | null = null
  if (amount && !amountIn) error = 'Enter a valid amount.'
  else if (amountIn && bal !== undefined && amountIn > bal) error = `Insufficient ${symIn} balance.`
  else if (settled && quote.error) error = revertReason(quote.error)

  const needsApprove = Boolean(amountIn && allowance.data !== undefined && allowance.data < amountIn)
  const quoting = Boolean(amountIn) && (!settled || quote.isFetching) && quote.data === undefined
  const canSubmit = Boolean(isConnected && !wrongNet && amountIn && !blocked && !error && out !== null && minOut !== null && !pending && allowance.data !== undefined)

  // why the main button is disabled, shown on the button itself
  const why = blocked
    ? side === 'buy' && asset.risk >= 2 && !row.stale ? 'Buys paused (risk)' : 'Price stale'
    : !amountIn
      ? 'Enter an amount'
      : error?.startsWith('Insufficient')
        ? `Insufficient ${symIn}`
        : error
          ? 'Cannot trade this size'
          : quoting
            ? 'Fetching quote…'
            : null

  const setPct = (p: number) => {
    if (!bal) return setAmount('')
    const v = (bal * BigInt(p)) / 100n
    setAmount(v > 0n ? formatUnits(v, decIn) : '')
  }

  const approve = async () => {
    if (!amountIn) return
    const r = await send(`Approve ${symIn}`, { address: tokenIn, abi: erc20Abi, functionName: 'approve', args: [asset.venue, amountIn] })
    if (r) await allowance.refetch()
  }
  const swap = async () => {
    if (!amountIn || minOut === null || !address) return
    const r = await send(`${side === 'buy' ? 'Buy' : 'Sell'} ${asset.display}`, { address: asset.venue, abi: venueAbi, functionName: 'swap', args: [tokenIn, tokenOut, amountIn, minOut, address] })
    if (r) {
      setAmount('')
      onDone()
      void allowance.refetch()
    }
  }

  const sideBtn = (s: Side) => `h-9 flex-1 rounded-lg text-sm font-semibold transition ${side === s ? (s === 'buy' ? 'bg-up text-onaccent' : 'bg-down text-onaccent') : 'text-muted hover:text-ink'}`
  const outUsd = out !== null ? (side === 'buy' ? (px !== null ? Number(formatUnits(out, decOut)) * px : null) : Number(formatUnits(out, decOut))) : null
  const fee = v4 ? `${(USDC_EURC_POOL.fee / 10_000).toFixed(2)}% pool fee` : '0.30% spread'

  return (
    <div className="flex h-full flex-col gap-3 p-3 text-sm sm:p-4">
      <div className="flex rounded-xl bg-panel2 p-1" role="group" aria-label="Side">
        <button type="button" className={sideBtn('buy')} aria-pressed={side === 'buy'} onClick={() => { setSide('buy'); setAmount('') }}>Buy</button>
        <button type="button" className={sideBtn('sell')} aria-pressed={side === 'sell'} onClick={() => { setSide('sell'); setAmount('') }}>Sell</button>
      </div>

      <div className="flex items-center justify-between text-xs">
        <span className="text-muted">Market · oracle price</span>
        <span className={`font-mono num ${row.stale ? 'text-down' : 'text-ink'}`} title="On-chain oracle price (Chainlink CRE)">{row.stale ? 'stale' : usd(px)}</span>
      </div>

      <label className="block">
        <span className="flex items-center justify-between text-xs text-muted">
          <span>{side === 'buy' ? 'You pay' : 'You sell'}</span>
          <span>
            Balance{' '}
            {!isConnected ? <span className="font-mono">—</span> : balancesLoading || bal === undefined ? <Skel className="inline-block h-3 w-16 align-middle" /> : <span className="font-mono text-ink num">{amt(bal, decIn)}</span>}
          </span>
        </span>
        <div className="mt-1 flex h-11 items-center rounded-xl border border-line bg-panel2 px-3 focus-within:border-accent">
          <input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value.replace(/,/g, '.').replace(/[^0-9.]/g, ''))} placeholder="0.00" className="w-full min-w-0 bg-transparent font-mono text-base outline-none placeholder:text-faint" aria-label={`Amount in ${symIn}`} />
          <span className="shrink-0 pl-2 text-xs font-semibold text-muted">{symIn}</span>
        </div>
      </label>

      <div className="grid grid-cols-4 gap-1">
        {[25, 50, 75, 100].map((p) => (
          <button key={p} type="button" disabled={!bal} onClick={() => setPct(p)} className="h-8 rounded-lg border border-line font-mono text-[11px] text-muted hover:bg-panel2 hover:text-ink disabled:opacity-40">{p === 100 ? 'Max' : `${p}%`}</button>
        ))}
      </div>

      <div className="rounded-xl bg-panel2/60 px-3 py-2.5">
        <p className="text-xs text-muted">You receive (est.)</p>
        <div className="mt-0.5 flex items-baseline justify-between gap-2">
          {quoting ? <Skel className="h-6 w-28" /> : <p className="truncate font-mono text-lg font-semibold num">{out !== null ? amt(out, decOut) : '—'} <span className="text-xs font-normal text-muted">{symOut}</span></p>}
          <span className="shrink-0 font-mono text-[11px] text-faint num">{outUsd !== null ? `≈ ${usd(outUsd)}` : ''}</span>
        </div>
      </div>

      <div className="flex items-center gap-1 text-xs">
        <span className="mr-auto text-muted">Slippage</span>
        {SLIPS.map((b) => (
          <button key={b} type="button" onClick={() => { setSlip(b); setCustomSlip('') }} className={`h-7 rounded-lg px-2 font-mono ${!customOk && slip === b ? 'bg-panel2 text-ink' : 'text-muted hover:text-ink'}`}>{b / 100}%</button>
        ))}
        <div className={`flex h-7 w-[4.25rem] items-center rounded-lg border bg-panel2 px-1.5 focus-within:border-accent ${customSlip && !customOk ? 'border-down' : 'border-line'}`}>
          <input inputMode="decimal" value={customSlip} onChange={(e) => setCustomSlip(e.target.value.replace(/[^0-9.]/g, ''))} placeholder="Custom" className="w-full min-w-0 bg-transparent font-mono text-[11px] outline-none placeholder:text-faint" aria-label="Custom slippage percent (max 50)" />
          <span className="text-[10px] text-faint">%</span>
        </div>
      </div>

      <dl className="space-y-1.5 border-t border-line pt-3 text-xs">
        <Row k="Rate" loading={quoting} v={rate !== null ? `1 ${asset.display} = ${usd(rate).replace('$', '')} USDC` : '—'} />
        <Row k="Price impact (vs oracle)" loading={quoting} v={signedPct(impact)} cls={impact !== null && Math.abs(impact) > 1 ? 'text-warn' : ''} />
        <Row k={`Min received (${(slipBps / 100).toFixed(2)}%)`} loading={quoting} v={minOut !== null ? `${amt(minOut, decOut)} ${symOut}` : '—'} />
        <Row k="Fee" v={fee} />
        <Row k="Venue" v={venueName ?? '—'} loading={!venueName && !v4} />
      </dl>

      {impact !== null && Math.abs(impact) > 1 && !error && (
        <p role="alert" className="rounded-xl border border-warn/40 bg-warn/10 p-2.5 text-xs text-warn">
          This quote is {Math.abs(impact).toFixed(2)}% {impact > 0 ? 'worse' : 'better'} than the oracle price.{v4 ? ' The testnet pool is thin; consider a smaller size.' : ''}
        </p>
      )}
      {!asset.mirror && row.stale && <p className="text-xs text-warn">No fresh oracle price. The quote comes straight from the pool.</p>}
      {blocked && <p role="alert" className="rounded-xl border border-down/40 bg-down/10 p-2.5 text-xs text-down">{blocked}</p>}
      {!blocked && error && <p role="alert" className="text-xs text-down">{error}</p>}

      <div className="mt-auto space-y-2 pt-1">
        {!isConnected ? (
          <ConnectKitButton.Custom>
            {({ show, isConnecting }) => (
              <button type="button" className="btn h-11 w-full" onClick={show} disabled={isConnecting}>{isConnecting ? 'Connecting…' : 'Connect wallet'}</button>
            )}
          </ConnectKitButton.Custom>
        ) : wrongNet ? (
          <>
            <button type="button" className="btn h-11 w-full !bg-warn" onClick={() => switchChain({ chainId: arcTestnet.id })} disabled={switching}>{switching ? 'Switching…' : 'Switch to Arc Testnet'}</button>
            <p className="text-center text-[11px] text-warn">Your wallet is on another network.</p>
          </>
        ) : needsApprove && !blocked ? (
          <button type="button" className="btn h-11 w-full" onClick={approve} disabled={!canSubmit} aria-busy={Boolean(pending)}>{pending ? `${pending}…` : (why ?? `Approve ${symIn}`)}</button>
        ) : (
          <button type="button" onClick={swap} disabled={!canSubmit || needsApprove} aria-busy={Boolean(pending)}
            className={`btn h-11 w-full ${side === 'buy' ? '!bg-up' : '!bg-down'}`}>
            {pending ? `${pending}…` : (why ?? `${side === 'buy' ? 'Buy' : 'Sell'} ${asset.display}`)}
          </button>
        )}
        <p className="text-center text-[11px] text-faint">Arc Testnet · test tokens only · not investment advice</p>
      </div>
    </div>
  )
}

function Row({ k, v, cls = '', loading }: { k: string; v: string; cls?: string; loading?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-2">
      <dt className="text-muted">{k}</dt>
      {loading ? <Skel className="h-3.5 w-20" /> : <dd className={`truncate text-right font-mono num ${cls}`}>{v}</dd>}
    </div>
  )
}
