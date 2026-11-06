import { ChartCandlestick, ChartPie, Layers, LayoutList, type LucideIcon } from 'lucide-react'

export type NavKey = 'markets' | 'trade' | 'buckets' | 'portfolio'
export type NavItem = { key: NavKey; label: string; to: string; icon: LucideIcon }

export const NAV: NavItem[] = [
  { key: 'markets', label: 'Markets', to: '/markets', icon: LayoutList },
  { key: 'trade', label: 'Trade', to: '/trade/EURC', icon: ChartCandlestick },
  { key: 'buckets', label: 'Buckets', to: '/buckets/new', icon: Layers },
  { key: 'portfolio', label: 'Portfolio', to: '/portfolio', icon: ChartPie },
]

/** Which nav item a route belongs to. The landing page is the exchange home, so it lights up Markets. */
export function activeKey([page]: string[]): NavKey {
  if (page === 'trade') return 'trade'
  if (page === 'portfolio') return 'portfolio'
  if (page === 'buckets') return 'buckets'
  return 'markets'
}
