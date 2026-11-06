// Favourite markets, per browser (localStorage, best effort). Shared across components via a tiny event bus.
import { useCallback, useEffect, useState } from 'react'

const KEY = 'arcx.favs'
const EVT = 'arcx:favs'
let memory: string[] | null = null // fallback when storage is blocked

function read(): string[] {
  try {
    const v = JSON.parse(localStorage.getItem(KEY) ?? '[]') as unknown
    return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []
  } catch {
    return memory ?? []
  }
}

export function useFavs() {
  const [favs, setFavs] = useState<string[]>(read)
  useEffect(() => {
    const sync = () => setFavs(read())
    window.addEventListener(EVT, sync)
    window.addEventListener('storage', sync)
    return () => {
      window.removeEventListener(EVT, sync)
      window.removeEventListener('storage', sync)
    }
  }, [])
  const toggle = useCallback((sym: string) => {
    const cur = read()
    const next = cur.includes(sym) ? cur.filter((s) => s !== sym) : [...cur, sym]
    try {
      localStorage.setItem(KEY, JSON.stringify(next))
    } catch {
      memory = next // storage blocked: keep in memory for this session
    }
    setFavs(next)
    window.dispatchEvent(new Event(EVT))
  }, [])
  return { favs, isFav: (sym: string) => favs.includes(sym), toggle }
}
