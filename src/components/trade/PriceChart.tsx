// SVG area chart with a hover crosshair (no chart library). Width tracks the container so text never stretches.
import { useEffect, useId, useMemo, useRef, useState } from 'react'
import type { Candle } from '@/lib/market'
import { usd } from '@/lib/format'

const PAD = { t: 12, r: 64, b: 22, l: 8 }

export function PriceChart({ candles, height = 320 }: { candles: Candle[]; height?: number }) {
  const box = useRef<HTMLDivElement>(null)
  const [w, setW] = useState(0)
  const [hover, setHover] = useState<number | null>(null)
  const gid = useId().replace(/:/g, '')

  useEffect(() => {
    const el = box.current
    if (!el) return
    const ro = new ResizeObserver(([e]) => setW(Math.floor(e.contentRect.width)))
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  const g = useMemo(() => {
    if (candles.length < 2 || w < 80) return null
    const lo = Math.min(...candles.map((c) => c.l > 0 ? c.l : c.c))
    const hi = Math.max(...candles.map((c) => c.h > 0 ? c.h : c.c))
    const span = hi - lo || hi * 0.01 || 1
    const min = lo - span * 0.06
    const max = hi + span * 0.06
    const iw = w - PAD.l - PAD.r
    const ih = height - PAD.t - PAD.b
    const x = (i: number) => PAD.l + (i / (candles.length - 1)) * iw
    const y = (v: number) => PAD.t + (1 - (v - min) / (max - min)) * ih
    const line = candles.map((c, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(c.c).toFixed(1)}`).join('')
    const area = `${line}L${x(candles.length - 1).toFixed(1)},${PAD.t + ih}L${x(0).toFixed(1)},${PAD.t + ih}Z`
    const ticks = [0, 1, 2, 3].map((k) => min + ((max - min) * (k + 0.5)) / 4)
    const xt = [0, 0.33, 0.66, 1].map((f) => Math.round(f * (candles.length - 1)))
    const up = candles[candles.length - 1].c >= candles[0].c
    return { x, y, line, area, ticks, xt, up, iw, ih }
  }, [candles, w, height])

  const spanH = candles.length ? (candles[candles.length - 1].t - candles[0].t) / 3600 : 0
  const fmtT = (t: number) => {
    const d = new Date(t * 1000)
    return spanH <= 30 ? d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' }) : d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
  }

  const onMove = (e: React.PointerEvent<SVGSVGElement>) => {
    if (!g) return
    const r = e.currentTarget.getBoundingClientRect()
    const px = e.clientX - r.left - PAD.l
    const i = Math.round((px / g.iw) * (candles.length - 1))
    setHover(Math.max(0, Math.min(candles.length - 1, i)))
  }

  const tone = g?.up ? 'text-up' : 'text-down'
  const h = hover !== null ? candles[hover] : null

  return (
    <div ref={box} className={`relative w-full ${tone}`} style={{ height }}>
      {g && (
        <svg width={w} height={height} className="block touch-none select-none" onPointerMove={onMove} onPointerLeave={() => setHover(null)} role="img" aria-label="Price chart, mainnet hourly closes">
          <defs>
            <linearGradient id={`fill${gid}`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="currentColor" stopOpacity="0.22" />
              <stop offset="100%" stopColor="currentColor" stopOpacity="0" />
            </linearGradient>
          </defs>
          {g.ticks.map((v) => (
            <g key={v}>
              <line x1={PAD.l} x2={PAD.l + g.iw} y1={g.y(v)} y2={g.y(v)} className="stroke-line" strokeDasharray="2 4" />
              <text x={w - PAD.r + 6} y={g.y(v) + 3.5} className="fill-faint font-mono text-[10px]">{usd(v)}</text>
            </g>
          ))}
          {g.xt.map((i) => (
            <text key={i} x={Math.min(Math.max(g.x(i), PAD.l + 18), PAD.l + g.iw - 18)} y={height - 6} textAnchor="middle" className="fill-faint font-mono text-[10px]">
              {fmtT(candles[i].t)}
            </text>
          ))}
          <path d={g.area} fill={`url(#fill${gid})`} />
          <path d={g.line} fill="none" stroke="currentColor" strokeWidth={1.6} strokeLinejoin="round" />
          {h && hover !== null && (
            <g>
              <line x1={g.x(hover)} x2={g.x(hover)} y1={PAD.t} y2={PAD.t + g.ih} className="stroke-muted" strokeDasharray="3 3" />
              <line x1={PAD.l} x2={PAD.l + g.iw} y1={g.y(h.c)} y2={g.y(h.c)} className="stroke-muted" strokeDasharray="3 3" />
              <circle cx={g.x(hover)} cy={g.y(h.c)} r={3.5} fill="currentColor" className="stroke-panel" strokeWidth={2} />
              <rect x={w - PAD.r + 2} y={g.y(h.c) - 9} width={PAD.r - 4} height={18} rx={4} className="fill-panel2 stroke-line" />
              <text x={w - PAD.r + 6} y={g.y(h.c) + 3.5} className="fill-ink font-mono text-[10px]">{usd(h.c)}</text>
            </g>
          )}
        </svg>
      )}
      {h && (
        <div className="pointer-events-none absolute left-2 top-1 max-w-[calc(100%-4.5rem)] truncate rounded-md bg-panel2/90 px-2 py-1 font-mono text-[11px] text-ink">
          {new Date(h.t * 1000).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })} · O {usd(h.o)} H {usd(h.h)} L {usd(h.l)} C {usd(h.c)}
        </div>
      )}
    </div>
  )
}
