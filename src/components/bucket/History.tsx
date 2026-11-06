// Bucket activity as an exchange-style fills table. Events from DEPLOY_BLOCK, scanned in 10k-block chunks, newest first.
import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { ExternalLink } from 'lucide-react'
import { bucketAbi } from '@/lib/contracts'
import type { ListedAsset } from '@/lib/assets'
import { amt, bps, e18, short, txUrl, usd } from '@/lib/format'
import { NO_TEMPLATE, blockChunks, dateTime, pool, useArcClient, type Hex } from './data'
import { isUsdc } from './plan'
import { Section, Skeleton, symbolOf } from './ui'

const WANTED = ['Rebalanced', 'TradeExecuted', 'SipExecuted', 'TargetsSet', 'Deposited', 'Withdrawn'] as const
type Name = (typeof WANTED)[number]
type Ev = { name: Name; args: Record<string, unknown>; tx: Hex; block: bigint; index: number }

const FILTERS = { All: WANTED, Trades: ['TradeExecuted'], Rebalances: ['Rebalanced'], SIP: ['SipExecuted'], Funds: ['Deposited', 'Withdrawn'], Targets: ['TargetsSet'] } as const satisfies Record<string, readonly Name[]>
type Filter = keyof typeof FILTERS

const PAGE = 25

type RowView = { type: string; side?: 'Buy' | 'Sell'; asset?: string; size?: string; price?: string; detail: string }

export function History({ address, assets }: { address: Hex; assets: ListedAsset[] | undefined }) {
  const client = useArcClient()
  const [shown, setShown] = useState(PAGE)
  const [filter, setFilter] = useState<Filter>('All')

  const events = useQuery({
    queryKey: ['bucket', 'history', address.toLowerCase()],
    enabled: Boolean(client),
    refetchInterval: 30_000,
    queryFn: async (): Promise<Ev[]> => {
      const c = client!
      const chunks = await blockChunks(c)
      const parts = await pool(chunks, 4, ([fromBlock, toBlock]) => c.getContractEvents({ address, abi: bucketAbi, fromBlock, toBlock }))
      return parts
        .flat()
        .filter((l) => (WANTED as readonly string[]).includes(l.eventName))
        .map((l) => ({ name: l.eventName as Name, args: l.args as Record<string, unknown>, tx: l.transactionHash, block: l.blockNumber, index: l.logIndex }))
        .sort((a, b) => (a.block === b.block ? b.index - a.index : a.block > b.block ? -1 : 1))
    },
  })

  const filtered = (events.data ?? []).filter((e) => (FILTERS[filter] as readonly Name[]).includes(e.name))
  const visible = filtered.slice(0, shown)
  const blocks = [...new Set(visible.map((e) => e.block))]
  const times = useQuery({
    queryKey: ['bucket', 'blocktimes', blocks.map(String).join()],
    enabled: Boolean(client && blocks.length),
    staleTime: Infinity,
    queryFn: async () => {
      const got = await pool(blocks, 4, (b) => client!.getBlock({ blockNumber: b }).then((x) => [b, Number(x.timestamp)] as const))
      return new Map(got)
    },
  })

  const dec = (t: unknown) => assets?.find((a) => a.token.toLowerCase() === String(t).toLowerCase())?.decimals
  const tokenAmt = (t: unknown, v: unknown) => {
    const d = dec(t)
    return d === undefined ? '—' : `${amt(v as bigint, d)} ${symbolOf(String(t), assets)}`
  }
  const units = (t: unknown, v: unknown) => {
    const d = dec(t)
    return d === undefined ? null : Number(v) / 10 ** d
  }

  const view = (e: Ev): RowView => {
    const a = e.args
    switch (e.name) {
      case 'TradeExecuted': {
        const buy = isUsdc(String(a.tokenIn))
        const assetTok = buy ? a.tokenOut : a.tokenIn
        const usdcAmt = units(buy ? a.tokenIn : a.tokenOut, buy ? a.amountIn : a.amountOut)
        const assetAmt = units(assetTok, buy ? a.amountOut : a.amountIn)
        const px = usdcAmt !== null && assetAmt ? usdcAmt / assetAmt : null
        return {
          type: 'Fill',
          side: buy ? 'Buy' : 'Sell',
          asset: `${symbolOf(String(assetTok), assets)}/USDC`,
          size: buy ? tokenAmt(a.tokenOut, a.amountOut) : tokenAmt(a.tokenIn, a.amountIn),
          price: usd(px),
          detail: `${buy ? 'Paid' : 'Got'} ${usdcAmt === null ? '—' : usd(usdcAmt)}`,
        }
      }
      case 'Rebalanced':
        return { type: 'Rebalance', detail: `Drift ${bps(Number(a.maxDriftBps))} · ${usd(e18(a.valueBeforeE18 as bigint))} → ${usd(e18(a.valueAfterE18 as bigint))} · tip ${amt(a.tipUsdc as bigint, 6)} USDC to ${short(String(a.caller))}` }
      case 'SipExecuted':
        return { type: 'SIP run', size: `${amt(a.amountUsdc as bigint, 6)} USDC`, detail: `${Number(a.runsLeft)} runs left · by ${short(String(a.caller))}` }
      case 'TargetsSet': {
        const toks = a.tokens as readonly Hex[]
        const w = a.weightsBps as readonly number[]
        const mix = toks.map((t, i) => [t, Number(w[i])] as const).filter(([, x]) => x > 0).map(([t, x]) => `${symbolOf(t, assets)} ${bps(x)}`).join(' · ')
        const tid = a.templateId as bigint
        return { type: 'Targets', detail: `${mix}${tid !== NO_TEMPLATE ? ` (template #${tid} v${Number(a.templateVersion)})` : ''}` }
      }
      case 'Deposited':
        return { type: 'Deposit', size: `${amt(a.usdcAmount as bigint, 6)} USDC`, detail: `from ${short(String(a.from))}` }
      case 'Withdrawn':
        return { type: 'Withdraw', size: tokenAmt(a.token, a.amount), detail: `to ${short(String(a.to))}` }
    }
  }

  return (
    <Section
      title="History"
      aside={
        <div className="-mx-1 flex max-w-full gap-1 overflow-x-auto px-1" role="radiogroup" aria-label="Filter">
          {(Object.keys(FILTERS) as Filter[]).map((f) => (
            <button key={f} type="button" role="radio" aria-checked={filter === f} onClick={() => { setFilter(f); setShown(PAGE) }} className={`tab shrink-0 px-2 py-1 text-xs ${filter === f ? 'tab-on' : ''}`}>{f}</button>
          ))}
        </div>
      }
    >
      {events.isLoading ? (
        <div className="space-y-2">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-8" />)}</div>
      ) : events.isError ? (
        <p className="text-sm text-muted">Couldn't load events from the RPC.</p>
      ) : !filtered.length ? (
        <p className="text-sm text-muted">{events.data?.length ? 'Nothing in this filter yet.' : 'No activity yet. Deposit USDC to start.'}</p>
      ) : (
        <>
          <div className="-mx-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
            <table className="w-full min-w-[720px] text-[13px]">
              <thead>
                <tr className="border-b border-line text-left">
                  {['Time', 'Type', 'Side', 'Market', 'Size', 'Fill price', 'Detail', ''].map((h, i) => (
                    <th key={h || 'tx'} className={`eyebrow whitespace-nowrap pb-2 font-normal ${i >= 4 && i <= 5 ? 'text-right' : ''}`}>{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {visible.map((e) => {
                  const r = view(e)
                  const ts = times.data?.get(e.block)
                  return (
                    <tr key={`${e.tx}-${e.index}`} className="align-top hover:bg-panel2/40">
                      <td className="num whitespace-nowrap py-2 pr-3 font-mono text-xs text-muted">{ts ? dateTime(ts) : `#${e.block}`}</td>
                      <td className="whitespace-nowrap py-2 pr-3">{r.type}</td>
                      <td className={`py-2 pr-3 font-medium ${r.side === 'Buy' ? 'text-up' : r.side === 'Sell' ? 'text-down' : 'text-muted'}`}>{r.side ?? '—'}</td>
                      <td className="whitespace-nowrap py-2 pr-3">{r.asset ?? '—'}</td>
                      <td className="num whitespace-nowrap py-2 pr-3 text-right font-mono">{r.size ?? '—'}</td>
                      <td className="num whitespace-nowrap py-2 pr-3 text-right font-mono">{r.price ?? '—'}</td>
                      <td className="num py-2 pr-2 font-mono text-xs text-muted [overflow-wrap:anywhere]">{r.detail}</td>
                      <td className="py-1 text-right">
                        <a href={txUrl(e.tx)} target="_blank" rel="noreferrer" className="inline-flex rounded-lg p-1.5 text-muted hover:bg-panel2 hover:text-ink" aria-label="View transaction on explorer" title="View on explorer">
                          <ExternalLink size={14} />
                        </a>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
          {filtered.length > shown && (
            <button className="btn-ghost mt-3 h-9 w-full" onClick={() => setShown((n) => n + PAGE)}>Show more ({filtered.length - shown})</button>
          )}
          <p className="mt-2 text-[11px] text-faint">Fill price is USDC paid or received per unit, from the TradeExecuted event.</p>
        </>
      )}
    </Section>
  )
}
