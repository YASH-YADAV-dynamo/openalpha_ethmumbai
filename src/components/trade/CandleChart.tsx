// Candlestick / area chart in plain SVG (no chart library): OHLC candles + volume pane, right price axis,
// crosshair with an OHLC/volume legend, and horizontal reference lines (on-chain oracle last price, testnet pool mid).
// Reference lines are overlays only: historical candles are never rewritten.
import { useEffect, useId, useMemo, useRef, useState } from 'react'
import type { Candle, Timeframe } from '@/lib/market'
import { compactUsd } from './ui'

export type RefLine = { price: number; label: string; tone: 'up' | 'down' | 'muted' | 'warn'; dashed?: 'long' | 'short' }

const PAD = { t: 28, r: 74, b: 22, l: 4 }
const VOL_FRAC = 0.18
const TONE = { up: 'rgb(var(--up))', down: 'rgb(var(--down))', muted: 'rgb(var(--muted))', warn: 'rgb(var(--warn))' } as const

function niceStep(raw: number) {
  const e = 10 ** Math.floor(Math.log10(raw))
  const f = raw / e
  return (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * e
}
const fmtN = (v: number, d: number) => v.toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d })

const NONE: RefLine[] = []

export function CandleChart({ candles, tf, mode, lines = NONE, height = 360 }: { candles: Candle[]; tf: Timeframe; mode: 'candle' | 'area'; lines?: RefLine[]; height?: number }) {
  const box = useRef<HTMLDivElement>(null)
  const [w, setW] = useState(0)
  const [hover, setHover] = useState<{ i: number; y: number } | null>(null)
  const gid = useId().replace(/:/g, '')

  useEffect(() => {
    const el = box.current
    if (!el) return
    const ro = new ResizeObserver(([e]) => setW(Math.floor(e.contentRect.width)))
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  const g = useMemo(() => {
    const n = candles.length
    if (n < 2 || w < 120) return null
    const iw = w - PAD.l - PAD.r
    const ih = height - PAD.t - PAD.b
    const ph = ih * (1 - VOL_FRAC) - 6 // price pane
    const vTop = PAD.t + ih * (1 - VOL_FRAC)
    const vh = ih * VOL_FRAC

    let lo = Infinity
    let hi = -Infinity
    for (const c of candles) {
      lo = Math.min(lo, mode === 'area' ? c.c : c.l)
      hi = Math.max(hi, mode === 'area' ? c.c : c.h)
    }
    // pull reference lines into view only when they sit near the candles; far ones are pinned to the edge
    const near = Math.max(hi - lo, ((hi + lo) / 2) * 0.004)
    for (const l of lines) if (l.price >= lo - near && l.price <= hi + near) { lo = Math.min(lo, l.price); hi = Math.max(hi, l.price) }
    const span = hi - lo || hi * 0.002 || 1
    const min = lo - span * 0.08
    const max = hi + span * 0.08
    const step = niceStep((max - min) / Math.max(3, Math.min(7, Math.floor(ph / 48))))
    const dec = Math.min(8, Math.max(0, 1 - Math.floor(Math.log10(step))))
    const ticks: number[] = []
    for (let v = Math.ceil(min / step) * step; v <= max; v += step) ticks.push(v)

    const slot = iw / n
    const bw = Math.max(1, Math.min(14, slot * 0.68))
    const x = (i: number) => PAD.l + (i + 0.5) * slot
    const y = (v: number) => PAD.t + (1 - (v - min) / (max - min)) * ph
    const vMax = Math.max(...candles.map((c) => c.v), 0) || 1

    let upW = '', upB = '', dnW = '', dnB = '', upV = '', dnV = '', line = ''
    candles.forEach((c, i) => {
      const cx = x(i)
      const up = c.c >= c.o
      const wick = `M${cx.toFixed(1)},${y(c.h).toFixed(1)}V${y(c.l).toFixed(1)}`
      const top = y(Math.max(c.o, c.c))
      const bh = Math.max(1, y(Math.min(c.o, c.c)) - top)
      const body = `M${(cx - bw / 2).toFixed(1)},${top.toFixed(1)}h${bw.toFixed(1)}v${bh.toFixed(1)}h${(-bw).toFixed(1)}Z`
      const vhgt = Math.max(c.v > 0 ? 1 : 0, (c.v / vMax) * (vh - 2))
      const vol = vhgt > 0 ? `M${(cx - bw / 2).toFixed(1)},${(vTop + vh - vhgt).toFixed(1)}h${bw.toFixed(1)}v${vhgt.toFixed(1)}h${(-bw).toFixed(1)}Z` : ''
      if (up) { upW += wick; upB += body; upV += vol } else { dnW += wick; dnB += body; dnV += vol }
      line += `${i ? 'L' : 'M'}${cx.toFixed(1)},${y(c.c).toFixed(1)}`
    })
    const area = `${line}L${x(n - 1).toFixed(1)},${(PAD.t + ph).toFixed(1)}L${x(0).toFixed(1)},${(PAD.t + ph).toFixed(1)}Z`

    // time labels roughly every 90px
    const every = Math.max(1, Math.round(110 / slot))
    const xt: number[] = []
    for (let i = n - 1; i >= 0; i -= every) xt.push(i)

    return { n, iw, ph, vTop, vh, min, max, dec, ticks, slot, x, y, upW, upB, dnW, dnB, upV, dnV, line, area, xt, up: candles[n - 1].c >= candles[0].c }
  }, [candles, w, height, mode, lines])

  const fmtT = (t: number, long = false) => {
    const d = new Date(t * 1000)
    if (long) return d.toLocaleString('en-US', { month: 'short', day: 'numeric', ...(tf === '1D' ? {} : { hour: '2-digit', minute: '2-digit', hour12: false }) })
    if (tf === '4H' || tf === '1D') return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
    // sparse pools skip empty periods, so an intraday series can span days: keep the date in every label then
    if (candles.length > 1 && candles[candles.length - 1].t - candles[0].t > 2 * 86_400) return `${d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })} ${d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false })}`
    return d.getHours() === 0 && d.getMinutes() < (tf === '15m' ? 15 : 60) ? d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) : d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false })
  }

  const onMove = (e: React.PointerEvent<SVGSVGElement>) => {
    if (!g) return
    const r = e.currentTarget.getBoundingClientRect()
    const px = e.clientX - r.left - PAD.l
    const py = e.clientY - r.top
    if (px < 0 || px > g.iw) return setHover(null)
    setHover({ i: Math.max(0, Math.min(g.n - 1, Math.floor(px / g.slot))), y: py })
  }

  const cur = candles[hover?.i ?? candles.length - 1]
  const prev = candles[(hover?.i ?? candles.length - 1) - 1]
  const chg = cur && prev ? ((cur.c - prev.c) / prev.c) * 100 : null
  const dec = g?.dec ?? 4
  const legendTone = cur && cur.c >= cur.o ? 'text-up' : 'text-down'

  // right-axis labels for reference lines, nudged apart so they never overlap
  const refs = g
    ? lines
        .map((l) => {
          const raw = g.y(l.price)
          const top = PAD.t + 8
          const bot = PAD.t + g.ph - 8
          return { ...l, y: Math.min(bot, Math.max(top, raw)), off: raw < top ? 'above' : raw > bot ? 'below' : null }
        })
        .sort((a, b) => a.y - b.y)
    : []
  for (let i = 1; i < refs.length; i++) if (refs[i].y - refs[i - 1].y < 18) refs[i].y = refs[i - 1].y + 18

  const hoverPrice = g && hover && hover.y >= PAD.t && hover.y <= PAD.t + g.ph ? g.min + (1 - (hover.y - PAD.t) / g.ph) * (g.max - g.min) : null

  return (
    <div ref={box} className="relative w-full" style={{ height }}>
      {cur && (
        <div className="pointer-events-none absolute left-2 right-[78px] top-1.5 z-10 flex flex-wrap items-center gap-x-2.5 gap-y-0.5 font-mono text-[11px] num leading-4">
          <span className="text-muted">{fmtT(cur.t, true)}</span>
          <span className="text-faint">O<span className={`ml-1 ${legendTone}`}>{fmtN(cur.o, dec)}</span></span>
          <span className="text-faint">H<span className={`ml-1 ${legendTone}`}>{fmtN(cur.h, dec)}</span></span>
          <span className="text-faint">L<span className={`ml-1 ${legendTone}`}>{fmtN(cur.l, dec)}</span></span>
          <span className="text-faint">C<span className={`ml-1 ${legendTone}`}>{fmtN(cur.c, dec)}</span></span>
          {chg !== null && <span className={chg >= 0 ? 'text-up' : 'text-down'}>{chg >= 0 ? '+' : '−'}{Math.abs(chg).toFixed(2)}%</span>}
          <span className="text-faint">Vol<span className="ml-1 text-muted">{compactUsd(cur.v)}</span></span>
        </div>
      )}
      {g && (
        <svg width={w} height={height} className="block select-none" style={{ touchAction: 'pan-y' }} onPointerMove={onMove} onPointerDown={onMove} onPointerLeave={() => setHover(null)}
          role="img" aria-label={`${mode === 'area' ? 'Area' : 'Candlestick'} chart, ${tf} candles, ${candles.length} periods`}>
          <defs>
            <linearGradient id={`a${gid}`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={g.up ? TONE.up : TONE.down} stopOpacity="0.22" />
              <stop offset="100%" stopColor={g.up ? TONE.up : TONE.down} stopOpacity="0" />
            </linearGradient>
          </defs>
          {/* grid + price axis */}
          {g.ticks.map((v) => (
            <g key={v}>
              <line x1={PAD.l} x2={PAD.l + g.iw} y1={g.y(v)} y2={g.y(v)} stroke="rgb(var(--line))" strokeOpacity="0.7" />
              <text x={PAD.l + g.iw + 8} y={g.y(v) + 3.5} fill="rgb(var(--faint))" className="font-mono text-[10px]">{fmtN(v, g.dec)}</text>
            </g>
          ))}
          <line x1={PAD.l + g.iw} x2={PAD.l + g.iw} y1={PAD.t - 6} y2={height - PAD.b} stroke="rgb(var(--line))" />
          <line x1={PAD.l} x2={PAD.l + g.iw} y1={g.vTop - 3} y2={g.vTop - 3} stroke="rgb(var(--line))" strokeOpacity="0.5" />
          {g.xt.map((i) => (
            <text key={i} x={Math.min(Math.max(g.x(i), PAD.l + 22), PAD.l + g.iw - 22)} y={height - 6} textAnchor="middle" fill="rgb(var(--faint))" className="font-mono text-[10px]">{fmtT(candles[i].t)}</text>
          ))}

          {/* volume */}
          <path d={g.upV} fill={TONE.up} fillOpacity="0.28" />
          <path d={g.dnV} fill={TONE.down} fillOpacity="0.28" />

          {/* price */}
          {mode === 'candle' ? (
            <>
              <path d={g.upW} stroke={TONE.up} strokeWidth={1} fill="none" />
              <path d={g.dnW} stroke={TONE.down} strokeWidth={1} fill="none" />
              <path d={g.upB} fill={TONE.up} />
              <path d={g.dnB} fill={TONE.down} />
            </>
          ) : (
            <>
              <path d={g.area} fill={`url(#a${gid})`} />
              <path d={g.line} fill="none" stroke={g.up ? TONE.up : TONE.down} strokeWidth={1.6} strokeLinejoin="round" />
            </>
          )}

          {/* reference lines (oracle last, testnet pool) */}
          {refs.map((l) => (
            <g key={l.label}>
              {!l.off && <line x1={PAD.l} x2={PAD.l + g.iw} y1={g.y(l.price)} y2={g.y(l.price)} stroke={TONE[l.tone]} strokeWidth={1} strokeDasharray={l.dashed === 'short' ? '2 3' : '6 4'} />}
              <rect x={PAD.l + g.iw + 1} y={l.y - 8} width={PAD.r - 3} height={16} rx={3} fill={TONE[l.tone]} fillOpacity={l.tone === 'muted' ? 0.9 : 1} />
              <text x={PAD.l + g.iw + 6} y={l.y + 3.5} fill="rgb(var(--onaccent))" className="font-mono text-[10px] font-semibold">
                {l.off === 'above' ? '▲' : l.off === 'below' ? '▼' : ''}{fmtN(l.price, g.dec)}
              </text>
            </g>
          ))}

          {/* crosshair */}
          {hover && (
            <g pointerEvents="none">
              <line x1={g.x(hover.i)} x2={g.x(hover.i)} y1={PAD.t - 6} y2={height - PAD.b} stroke="rgb(var(--muted))" strokeOpacity="0.6" strokeDasharray="3 3" />
              {hoverPrice !== null && (
                <>
                  <line x1={PAD.l} x2={PAD.l + g.iw} y1={hover.y} y2={hover.y} stroke="rgb(var(--muted))" strokeOpacity="0.6" strokeDasharray="3 3" />
                  <rect x={PAD.l + g.iw + 1} y={hover.y - 8} width={PAD.r - 3} height={16} rx={3} fill="rgb(var(--panel2))" stroke="rgb(var(--line))" />
                  <text x={PAD.l + g.iw + 6} y={hover.y + 3.5} fill="rgb(var(--ink))" className="font-mono text-[10px]">{fmtN(hoverPrice, g.dec)}</text>
                </>
              )}
              <rect x={Math.min(Math.max(g.x(hover.i) - 46, PAD.l), PAD.l + g.iw - 92)} y={height - PAD.b + 2} width={92} height={17} rx={3} fill="rgb(var(--panel2))" stroke="rgb(var(--line))" />
              <text x={Math.min(Math.max(g.x(hover.i), PAD.l + 46), PAD.l + g.iw - 46)} y={height - 6} textAnchor="middle" fill="rgb(var(--ink))" className="font-mono text-[10px]">{fmtT(candles[hover.i].t, true)}</text>
            </g>
          )}
        </svg>
      )}
    </div>
  )
}
