import { Link } from '@/lib/router'
import { NAV, type NavKey } from './nav'
import { ThemeToggle } from './ThemeToggle'
import { NetworkPill, UsdcChip, WalletControls } from './WalletControls'

export function Wordmark() {
  return (
    <Link to="/" className="flex shrink-0 items-center gap-2 text-ink" aria-label="Arc Treasury home">
      <span aria-hidden className="relative inline-block h-5 w-5 rounded-md bg-accent">
        <span className="absolute inset-[5px] rounded-[3px] bg-onaccent/90" />
      </span>
      <span className="text-[15px] font-semibold tracking-tight">Arc Treasury</span>
    </Link>
  )
}

export function TopBar({ active }: { active: NavKey }) {
  return (
    <div className="border-b border-line bg-bg/90 backdrop-blur-md">
      <div className="mx-auto flex h-14 max-w-[1600px] items-center gap-3 px-4 lg:gap-6">
        <Wordmark />
        <nav className="hidden items-center gap-0.5 md:flex" aria-label="Main">
          {NAV.map((n) => (
            <Link key={n.key} to={n.to} className={`tab ${active === n.key ? 'tab-on font-medium' : ''}`} aria-current={active === n.key ? 'page' : undefined}>
              {n.label}
            </Link>
          ))}
        </nav>
        <div className="ml-auto flex min-w-0 items-center gap-2">
          <NetworkPill />
          <UsdcChip />
          <ThemeToggle />
          <WalletControls />
        </div>
      </div>
    </div>
  )
}
