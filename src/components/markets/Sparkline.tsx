import { useEffect, useRef, useState } from 'react'
import { useCandles } from '@/lib/market'

/**
 * Last-24h hourly close line from the Arc mainnet reference pool. Fetches only once the cell is on screen
 * (GeckoTerminal is rate-limited) and reuses the react-query cache shared with the trade chart.
 */
export function Sparkline({ pool, width = 96, height = 28 }: { pool: string | null | undefined; width?: number; height?: number }) {
  const ref = useRef<HTMLSpanElement>(null)
  const [seen, setSeen] = useState(false)
  useEffect(() => {
    const el = ref.current
    if (!el || seen || !pool) return
    if (typeof IntersectionObserver === 'undefined') {
      const t = setTimeout(() => setSeen(true), 0)
      return () => clearTimeout(t)
    }
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        setSeen(true)
        io.disconnect()
      }
    })
    io.observe(el)
    return () => io.disconnect()
  }, [pool, seen])

  const candles = useCandles(seen ? pool : null)
  const pts = (candles.data ?? []).slice(-24).map((c) => c.c)

  let body = null
  if (pts.length >= 2) {
    const lo = Math.min(...pts)
    const hi = Math.max(...pts)
    const span = hi - lo || 1
    const d = pts.map((p, i) => `${((i / (pts.length - 1)) * width).toFixed(1)},${(height - 2 - ((p - lo) / span) * (height - 4)).toFixed(1)}`).join(' ')
    const up = pts[pts.length - 1] >= pts[0]
    body = (
      <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} className={up ? 'text-up' : 'text-down'} role="img" aria-label="24h price line (Arc mainnet reference)">
        <polyline points={d} fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" strokeLinecap="round" />
      </svg>
    )
  } else if (seen && candles.isLoading) {
    body = <span aria-hidden className="block h-full w-full animate-pulse rounded bg-panel2" />
  }

  return (
    <span ref={ref} className="ml-auto block" style={{ width, height }}>
      {body}
    </span>
  )
}
