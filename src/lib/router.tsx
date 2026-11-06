// Tiny hash router (no dependency). Routes: #/ , #/trade/EURC , #/portfolio , #/buckets/new , #/buckets/0xabc
import { useEffect, useState, type AnchorHTMLAttributes, type ReactNode } from 'react'

const read = () => (window.location.hash.replace(/^#/, '') || '/').split('?')[0]

export function useRoute(): string[] {
  const [path, setPath] = useState(read)
  useEffect(() => {
    const on = () => { setPath(read()); window.scrollTo(0, 0) }
    window.addEventListener('hashchange', on)
    return () => window.removeEventListener('hashchange', on)
  }, [])
  return path.split('/').filter(Boolean) // "/trade/EURC" -> ["trade","EURC"]
}

export const navigate = (to: string) => { window.location.hash = to }

export function Link({ to, children, ...rest }: { to: string; children: ReactNode } & AnchorHTMLAttributes<HTMLAnchorElement>) {
  return <a href={`#${to}`} {...rest}>{children}</a>
}
