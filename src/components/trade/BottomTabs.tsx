// Bottom panel: Recent trades (Swapped logs) · My trades · Balances · Buckets holding this asset.
import { useState, type ReactNode } from 'react'
import { useAccount } from 'wagmi'
import { useQueries } from '@tanstack/react-query'
import { ADDR } from '@/lib/contracts'
import type { PriceRow } from '@/lib/prices'
import { amt, short, txUrl, usd } from '@/lib/format'
import { navigate } from '@/lib/router'
import { bucketStateKey, readBucket, useArcClient, useBucketsOf, type Hex } from '@/components/bucket/data'
import { ago, isUsdc, useRecentSwaps, USDC_DECIMALS, type SwapRow } from './hooks'
import { Skel } from './ui'

type Tab = 'trades' | 'mine' | 'balances' | 'buckets'

export function BottomTabs({ row, rows, balances, balancesLoading }: { row: PriceRow; rows: PriceRow[]; balances: Record<string, bigint> | undefined; balancesLoading: boolean }) {
  const [tab, setTab] = useState<Tab>('trades')
  const asset = row.asset
  const tabBtn = (on: boolean) => `-mb-px h-10 shrink-0 border-b-2 px-1 text-[13px] ${on ? 'border-accent font-semibold text-ink' : 'border-transparent text-muted hover:text-ink'}`
  return (
    <div className="flex min-w-0 flex-col">
      <div className="flex gap-4 overflow-x-auto border-b border-line px-3 sm:px-4" role="tablist">
        {([['trades', 'Recent trades'], ['mine', 'My trades'], ['balances', 'Balances'], ['buckets', `Buckets · ${asset.display}`]] as const).map(([k, l]) => (
          <button key={k} type="button" role="tab" aria-selected={tab === k} onClick={() => setTab(k)} className={tabBtn(tab === k)}>{l}</button>
        ))}
      </div>
      <div className="min-h-[200px] overflow-x-auto">
        {tab === 'trades' && <Trades row={row} />}
        {tab === 'mine' && <Trades row={row} mine />}
        {tab === 'balances' && <Balances rows={rows} balances={balances} loading={balancesLoading} />}
        {tab === 'buckets' && <Buckets row={row} />}
      </div>
    </div>
  )
}

function Table({ head, children, empty, loading, right = [], minW = 'min-w-[520px]' }: { head: string[]; children: ReactNode[]; empty: string; loading?: boolean; right?: number[]; minW?: string }) {
  return (
    <table className={`w-full ${minW} text-left text-xs [&_td]:px-3 [&_td]:py-2 [&_th]:px-3 [&_th]:py-2 sm:[&_td]:px-4 sm:[&_th]:px-4`}>
      <thead className="text-[11px] text-muted">
        <tr>{head.map((h, i) => <th key={i} className={`font-normal ${right.includes(i) ? 'text-right' : ''}`}>{h}</th>)}</tr>
      </thead>
      <tbody className="divide-y divide-line">
        {loading
          ? Array.from({ length: 3 }).map((_, i) => (
              <tr key={i}>{head.map((_, j) => <td key={j}><Skel className="h-4 w-full max-w-24" /></td>)}</tr>
            ))
          : children.length
            ? children
            : <tr><td colSpan={head.length} className="py-8 text-center text-muted">{empty}</td></tr>}
      </tbody>
    </table>
  )
}

const Note = ({ children }: { children: ReactNode }) => <p className="px-4 py-8 text-center text-xs text-muted">{children}</p>

function Trades({ row, mine }: { row: PriceRow; mine?: boolean }) {
  const asset = row.asset
  const { address } = useAccount()
  const q = useRecentSwaps(asset)
  if (mine && !address) return <Note>Connect a wallet to see your trades.</Note>
  if (q.error && !q.data) return <Note>Could not load trades from the RPC. Retrying shortly.</Note>
  const d = q.data
  const list: SwapRow[] = (d?.rows ?? []).filter((r) => !mine || r.caller.toLowerCase() === address?.toLowerCase())
  const scope = d ? (d.complete ? 'since the venues were deployed' : `since block ${d.scannedFrom.toString()}`) : ''
  const empty = !d ? '' : mine ? `No ${asset.display} trades from your wallet among the latest swaps ${scope}.` : `No ${asset.display} swaps ${scope}.`
  return (
    <Table head={['Time', 'Side', 'Price', asset.display, 'USDC', mine ? 'Tx' : 'Trader', ...(mine ? [] : ['Tx'])]} right={[2, 3, 4]} empty={empty} loading={q.isLoading}>
      {list.map((r) => {
        const tok = Number(r.tokenAmt) / 10 ** asset.decimals
        const usdcN = Number(r.usdcAmt) / 1e6
        return (
          <tr key={`${r.hash}-${r.tokenAmt}`}>
            <td className="whitespace-nowrap text-muted">{ago(r.at)}</td>
            <td className={r.side === 'buy' ? 'text-up' : 'text-down'}>{r.side === 'buy' ? 'Buy' : 'Sell'}</td>
            <td className={`text-right font-mono num ${r.side === 'buy' ? 'text-up' : 'text-down'}`}>{tok > 0 ? usd(usdcN / tok) : '—'}</td>
            <td className="text-right font-mono num">{amt(r.tokenAmt, asset.decimals)}</td>
            <td className="text-right font-mono num">{amt(r.usdcAmt, USDC_DECIMALS, 2)}</td>
            {!mine && <td className="font-mono text-muted">{short(r.caller)}</td>}
            <td><a href={txUrl(r.hash)} target="_blank" rel="noopener noreferrer" className="font-mono text-accent hover:underline">{short(r.hash)} ↗</a></td>
          </tr>
        )
      })}
    </Table>
  )
}

function Balances({ rows, balances, loading }: { rows: PriceRow[]; balances: Record<string, bigint> | undefined; loading: boolean }) {
  const { isConnected } = useAccount()
  if (!isConnected) return <Note>Connect a wallet to see your balances.</Note>
  // exactly one USDC row (ERC-20, 6 decimals), then every other listed asset priced from the same price book
  const list = [
    { key: ADDR.usdc as string, sym: 'USDC', dec: USDC_DECIMALS, price: 1 as number | null, nav: null as string | null },
    ...rows.filter((r) => !isUsdc(r.asset.token)).map((r) => ({ key: r.asset.token as string, sym: r.asset.display, dec: r.asset.decimals, price: r.last, nav: r.asset.category === 'Cash' ? null : r.asset.display })),
  ]
  return (
    <Table head={['Asset', 'Balance', 'Price (oracle)', 'Value']} right={[1, 2, 3]} empty="No assets." loading={loading} minW="min-w-[360px]">
      {list.map((r) => {
        const b = balances?.[r.key.toLowerCase()]
        const value = b !== undefined && r.price !== null ? (Number(b) / 10 ** r.dec) * r.price : null
        return (
          <tr key={r.key} className={r.nav ? 'cursor-pointer hover:bg-panel2/50' : ''} onClick={() => r.nav && navigate(`/trade/${r.nav}`)}>
            <td className="font-semibold">{r.sym}</td>
            <td className="text-right font-mono num">{b !== undefined ? amt(b, r.dec) : '—'}</td>
            <td className="text-right font-mono num text-muted">{usd(r.price)}</td>
            <td className="text-right font-mono num">{usd(value)}</td>
          </tr>
        )
      })}
    </Table>
  )
}

function Buckets({ row }: { row: PriceRow }) {
  const asset = row.asset
  const { address } = useAccount()
  const client = useArcClient()
  const list = useBucketsOf(address)
  const states = useQueries({
    queries: (list.data ?? []).map((b) => ({
      queryKey: bucketStateKey(b),
      queryFn: () => readBucket(client!, b as Hex),
      enabled: Boolean(client),
      refetchInterval: 30_000,
    })),
  })
  if (!address) return <Note>Connect a wallet to see your buckets.</Note>
  const loading = list.isLoading || states.some((s) => s.isLoading)
  const tok = asset.token.toLowerCase()
  const holding = states
    .map((s) => s.data)
    .filter((s): s is NonNullable<typeof s> => Boolean(s))
    .map((s) => {
      const i = s.tokens.findIndex((t) => t.toLowerCase() === tok)
      const ti = s.targets.tokens.findIndex((t) => t.toLowerCase() === tok)
      const total = Number(s.totalE18) / 1e18
      const value = i >= 0 ? Number(s.valuesE18[i]) / 1e18 : 0
      return { s, amount: i >= 0 ? s.amounts[i] : 0n, value, share: total > 0 ? (value / total) * 100 : null, target: ti >= 0 ? s.targets.weights[ti] / 100 : null }
    })
    .filter((x) => x.amount > 0n || x.target !== null)
  return (
    <Table head={['Bucket', `${asset.display} held`, 'Value', 'Weight', 'Target']} right={[1, 2, 3, 4]} loading={loading} minW="min-w-[440px]"
      empty={list.data?.length ? `None of your buckets hold ${asset.display}.` : 'You have no buckets yet.'}>
      {holding.map(({ s, amount, value, share, target }) => (
        <tr key={s.address} className="cursor-pointer hover:bg-panel2/50" onClick={() => navigate(`/buckets/${s.address}`)}>
          <td className="font-mono text-accent">{short(s.address)}</td>
          <td className="text-right font-mono num">{amt(amount, asset.decimals)}</td>
          <td className="text-right font-mono num">{usd(value)}</td>
          <td className="text-right font-mono num">{share !== null ? `${share.toFixed(1)}%` : '—'}</td>
          <td className="text-right font-mono num text-muted">{target !== null ? `${target.toFixed(1)}%` : '—'}</td>
        </tr>
      ))}
    </Table>
  )
}
