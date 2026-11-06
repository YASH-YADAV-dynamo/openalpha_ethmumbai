import { Link } from '@/lib/router'
import { NAV, type NavKey } from './nav'

/** Bottom tab bar below md. Shell reserves space for it; the Studio badge sits above it via --badge-bottom. */
export function MobileTabs({ active }: { active: NavKey }) {
  return (
    <nav
      aria-label="Main"
      className="fixed inset-x-0 bottom-0 z-40 border-t border-line bg-bg/95 pb-[env(safe-area-inset-bottom)] backdrop-blur-md md:hidden"
    >
      <ul className="grid grid-cols-4">
        {NAV.map((n) => {
          const on = active === n.key
          const Icon = n.icon
          return (
            <li key={n.key}>
              <Link
                to={n.to}
                aria-current={on ? 'page' : undefined}
                className={`flex h-14 flex-col items-center justify-center gap-1 text-[11px] font-medium transition ${on ? 'text-accent' : 'text-muted hover:text-ink'}`}
              >
                <Icon size={18} strokeWidth={on ? 2.25 : 1.75} />
                {n.label}
              </Link>
            </li>
          )
        })}
      </ul>
    </nav>
  )
}
