// Scrolling ticker of every listed asset (price book: on-chain oracle price + Arc mainnet 24h change).
// Pauses on hover/focus; with prefers-reduced-motion it is a static, horizontally scrollable strip.
import { useReducedMotion } from 'framer-motion'
import { usePriceBook, type PriceRow } from '@/lib/prices'
import { pct, usd } from '@/lib/format'
import { changeTone, useFlash } from '@/components/markets/ui'

export function TickerTape() {
  const { rows, isLoading } = usePriceBook()
  const reduce = useReducedMotion()
  const loop = !reduce && rows.length > 0
  // Each half of the loop must be wider than the screen, so short lists repeat; the second half is decorative.
  const reps = loop ? Math.max(1, Math.ceil(12 / rows.length)) : 1
  const half = Array.from({ length: reps }, (_, k) => rows.map((r) => ({ r, key: `${k}-${r.asset.token}`, hidden: k > 0 }))).flat()

  return (
    <div className="h-8 overflow-hidden border-b border-line bg-panel2/90 backdrop-blur-md" aria-label="Prices">
      {isLoading && rows.length === 0 ? (
        <div className="flex h-full items-center px-4 font-mono text-[11px] text-faint">Loading prices…</div>
      ) : (
        <div className={`h-full ${loop ? '' : 'overflow-x-auto'}`}>
          <ul className={`flex h-full w-max items-center ${loop ? 'tape' : ''}`}>
            {half.map((x) => <Item key={x.key} r={x.r} hidden={x.hidden} />)}
            {loop && half.map((x) => <Item key={`dup-${x.key}`} r={x.r} hidden />)}
          </ul>
        </div>
      )}
    </div>
  )
}

function Item({ r, hidden }: { r: PriceRow; hidden?: boolean }) {
  const ref = useFlash<HTMLAnchorElement>(r.last)
  const a = r.asset
  const tradable = a.display !== 'USDC'
  return (
    <li aria-hidden={hidden} className="h-full shrink-0 border-r border-line/60">
      <a
        ref={ref}
        href={tradable ? `#/trade/${a.display}` : '#/markets'}
        tabIndex={hidden ? -1 : undefined}
        className="flex h-full items-center gap-2 px-3 font-mono text-[11px] transition-colors hover:bg-panel"
        title={a.mirror ? 'MIRROR: priced from Arc mainnet, testnet token' : 'REAL token on Arc Testnet'}
      >
        <span className="font-semibold text-ink">{a.display}</span>
        <span className="num text-ink">{r.stale ? '—' : usd(r.last)}</span>
        <span className={`num ${changeTone(r.change24h)}`}>{pct(r.change24h)}</span>
        <span className={`text-[9px] uppercase tracking-wide ${a.mirror ? 'text-faint' : 'text-accent'}`}>{a.mirror ? 'Mirror' : 'Real'}</span>
      </a>
    </li>
  )
}
