import { formatUnits } from 'viem'

export const EXPLORER = 'https://explorer.testnet.arc.io'
export const txUrl = (h: string) => `${EXPLORER}/tx/${h}`
export const addrUrl = (a: string) => `${EXPLORER}/address/${a}`
export const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '')

/** USD with sensible precision: $75,512 · $2,223.35 · $1.1778 · $0.003134 */
export function usd(n: number | null | undefined): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return '—'
  const a = Math.abs(n)
  const d = a >= 1000 ? 0 : a >= 10 ? 2 : a >= 0.01 ? 4 : 6
  return `$${n.toLocaleString('en-US', { minimumFractionDigits: Math.min(d, 2), maximumFractionDigits: d })}`
}
export const pct = (n: number | null | undefined, digits = 2) =>
  n === null || n === undefined || !Number.isFinite(n) ? '—' : `${n >= 0 ? '+' : '−'}${Math.abs(n).toFixed(digits)}%`

/** Token amount (bigint, decimals) -> short human string. */
export function amt(v: bigint, decimals: number, max = 6): string {
  const s = Number(formatUnits(v, decimals))
  return s.toLocaleString('en-US', { maximumFractionDigits: s >= 1000 ? 2 : max })
}

/** E18 USD value (contracts' valuesE18) -> number */
export const e18 = (v: bigint) => Number(v) / 1e18
/** E8 price (registry priceE8) -> number */
export const e8 = (v: bigint) => Number(v) / 1e8
export const bps = (v: number | bigint) => `${(Number(v) / 100).toFixed(Number(v) % 100 ? 2 : 0)}%`
