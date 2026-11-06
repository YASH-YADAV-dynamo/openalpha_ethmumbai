// #/portfolio: the exchange's "Earn / Automation" account overview — buckets as strategies, risk, oracle health,
// spot balances and the template registry. Prices come from the shared price book (oracle `last`).
import { useQueries } from '@tanstack/react-query'
import { useAccount } from 'wagmi'
import { ConnectKitButton } from 'connectkit'
import { AlertTriangle, Plus, ShieldCheck } from 'lucide-react'
import { ADDR } from '@/lib/contracts'
import { amt, usd } from '@/lib/format'
import { usePriceBook, type PriceRow } from '@/lib/prices'
import { Link } from '@/lib/router'
import { BucketCard } from '@/components/bucket/BucketCard'
import { TemplateGallery } from '@/components/bucket/TemplateGallery'
import { WeightsBar } from '@/components/bucket/charts'
import { bucketStateKey, readBucket, unpriced, until, useArcClient, useBucketsOf, useCreationsByOwner, useNow, useWalletBalances, type BucketState, type Hex } from '@/components/bucket/data'
import { RISK, aggregate, toBps, useMaxStaleness } from '@/components/bucket/plan'
import { Dot, KindBadge, RiskBadge, Section, Skeleton, Stat, VizStyles, colorFor } from '@/components/bucket/ui'
import type { ListedAsset } from '@/lib/assets'

const ageTxt = (sec: number | null) => (sec === null ? '—' : sec < 60 ? `${sec}s` : sec < 3600 ? `${Math.round(sec / 60)}m` : `${(sec / 3600).toFixed(1)}h`)

export default function Portfolio() {
  const { address, isConnected } = useAccount()
  const client = useArcClient()
  const book = usePriceBook()
  const assets = book.rows.length ? book.rows.map((r) => r.asset) : undefined
  const buckets = useBucketsOf(address)
  const names = useCreationsByOwner(address)
  const wallet = useWalletBalances(address, assets)
  const now = useNow(15_000)
  const list: readonly Hex[] = buckets.data ?? []
  const states = useQueries({
    queries: list.map((b) => ({ queryKey: bucketStateKey(b), queryFn: () => readBucket(client!, b), enabled: Boolean(client), refetchInterval: 15_000, retry: 1 })),
  })
  const loaded = states.map((q) => q.data).filter((x): x is BucketState => Boolean(x))

  const bucketsLoading = isConnected && (buckets.isLoading || states.some((q) => q.isLoading))
  const bucketTotal = loaded.reduce((a, s) => a + Number(s.totalE18) / 1e18, 0)
  const bucketPartial = states.some((q) => q.isError || (q.data && unpriced(q.data).length > 0))

  const priceOf = (a: ListedAsset) => book.bySymbol.get(a.display.toLowerCase())?.last ?? null
  const walletRows = (assets ?? [])
    .map((a) => ({ a, bal: wallet.data?.get(a.token.toLowerCase()) ?? null }))
    .filter((r): r is { a: ListedAsset; bal: bigint } => r.bal !== null && r.bal > 0n)
    .map((r) => {
      const px = priceOf(r.a)
      return { ...r, px, value: px === null ? null : (Number(r.bal) / 10 ** r.a.decimals) * px }
    })
  const walletTotal = walletRows.reduce((a, r) => a + (r.value ?? 0), 0)
  const walletPartial = walletRows.some((r) => r.value === null)
  const walletLoading = isConnected && (wallet.isLoading || !assets)
  const usdcBal = wallet.data?.get(ADDR.usdc.toLowerCase()) ?? null

  const sipNext = loaded.filter((s) => s.sip.active && s.sip.runsLeft > 0).map((s) => s.sip.nextAt).sort((a, b) => a - b)[0]
  const agg = aggregate(loaded)
  const aggBps = toBps(agg.map((x) => x.usd))

  return (
    <div className="mx-auto w-full max-w-6xl px-4 py-6 sm:px-6">
      <VizStyles />
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="min-w-0">
          <p className="eyebrow">Earn · Automation</p>
          <h1 className="mt-1 text-2xl font-semibold">Portfolio</h1>
          <p className="mt-1 text-sm text-muted">Risk-managed rebalancing and SIP auto-invest. One bucket contract per strategy, owned by you, never pooled.</p>
        </div>
        <Link to="/buckets/new" className="btn"><Plus size={16} /> New bucket</Link>
      </div>

      {!isConnected ? (
        <div className="mt-6 grid gap-4 lg:grid-cols-[minmax(0,1fr)_340px]">
          <div className="card flex flex-col items-start gap-3 p-5">
            <p className="text-sm text-muted">Connect a wallet to see your buckets, balances and SIP schedule on Arc Testnet. Templates below are browsable without one.</p>
            <ConnectKitButton />
          </div>
          <OracleHealth rows={book.rows} heldTokens={null} />
        </div>
      ) : (
        <>
          <section className="card mt-6 p-4 sm:p-5" aria-label="Account overview">
            <dl className="grid grid-cols-2 gap-4 sm:grid-cols-4">
              <Stat label="Total value" className="col-span-2 sm:col-span-1">
                {bucketsLoading || walletLoading ? <Skeleton className="h-7 w-28" /> : <span className="font-mono">{usd(bucketTotal + walletTotal)}</span>}
                {(bucketPartial || walletPartial) && !bucketsLoading && <span className="ml-1 text-xs font-normal text-warn" title="Some holdings have no fresh oracle price and are excluded">partial</span>}
              </Stat>
              <Stat label="USDC available">{walletLoading ? <Skeleton className="h-7 w-20" /> : <span className="font-mono">{usdcBal === null ? '—' : amt(usdcBal, 6)}</span>}</Stat>
              <Stat label="Buckets">{buckets.isLoading ? <Skeleton className="h-7 w-10" /> : <span className="font-mono">{list.length}</span>}</Stat>
              <Stat label="Next SIP due">{bucketsLoading ? <Skeleton className="h-7 w-16" /> : <span className="font-mono">{sipNext === undefined ? '—' : now >= sipNext ? 'Due now' : until(sipNext, now)}</span>}</Stat>
            </dl>
            <div className="mt-4 border-t border-line pt-4">
              <div className="mb-2 flex flex-wrap items-baseline justify-between gap-2 text-xs">
                <span className="eyebrow">Allocation across buckets</span>
                <span className="num font-mono text-muted">
                  In buckets {bucketsLoading ? '…' : usd(bucketTotal)} · in wallet {walletLoading ? '…' : usd(walletTotal)}
                </span>
              </div>
              {bucketsLoading ? (
                <Skeleton className="h-8" />
              ) : agg.length ? (
                <WeightsBar tokens={agg.map((x) => x.token)} weights={aggBps} assets={assets} />
              ) : (
                <p className="text-xs text-muted">No priced holdings in buckets yet.</p>
              )}
            </div>
          </section>

          <div className="mt-6 grid gap-4 lg:grid-cols-[minmax(0,1fr)_340px]">
            <div className="order-2 min-w-0 lg:order-1">
              <div className="mb-3 flex items-baseline justify-between gap-2">
                <h2 className="text-sm font-semibold">Strategies</h2>
                <span className="text-xs text-muted">Value at oracle prices</span>
              </div>
              {buckets.isLoading ? (
                <div className="grid gap-3 sm:grid-cols-2">{[0, 1].map((i) => <Skeleton key={i} className="h-[260px]" />)}</div>
              ) : buckets.isError ? (
                <p className="text-sm text-muted">Couldn't read your buckets from the factory.</p>
              ) : list.length === 0 ? (
                <div className="card flex flex-col items-start gap-3 p-5">
                  <p className="text-sm text-muted">No buckets yet. Start from a template or build your own mix.</p>
                  <Link to="/buckets/new" className="btn-ghost"><Plus size={16} /> Create a bucket</Link>
                </div>
              ) : (
                <div className="grid gap-3 sm:grid-cols-2">
                  {[...list].reverse().map((b) => <BucketCard key={b} address={b} name={names.data?.get(b.toLowerCase())?.name} />)}
                </div>
              )}
            </div>
            <aside className="order-1 min-w-0 space-y-4 lg:order-2">
              <RiskPanel states={loaded} names={names.data} rows={book.rows} wallet={walletRows} loading={bucketsLoading} />
              <OracleHealth rows={book.rows} heldTokens={loaded.flatMap((s) => s.tokens.map((t) => t.toLowerCase()))} />
            </aside>
          </div>

          <section className="mt-6">
            <h2 className="mb-3 text-sm font-semibold">Spot balances</h2>
            <div className="card overflow-hidden">
              {walletLoading ? (
                <div className="space-y-2 p-4">{[0, 1].map((i) => <Skeleton key={i} className="h-6" />)}</div>
              ) : walletRows.length === 0 ? (
                <p className="p-4 text-sm text-muted">No listed assets in this wallet.</p>
              ) : (
                <table className="w-full text-[13px]">
                  <thead>
                    <tr className="border-b border-line text-left">
                      <th className="eyebrow px-4 py-2 font-normal">Asset</th>
                      <th className="eyebrow hidden px-2 py-2 text-right font-normal sm:table-cell">Price</th>
                      <th className="eyebrow px-2 py-2 text-right font-normal">Balance</th>
                      <th className="eyebrow px-4 py-2 text-right font-normal">Value</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-line">
                    {walletRows.map(({ a, bal, px, value }) => (
                      <tr key={a.token} className="hover:bg-panel2/40">
                        <td className="px-4 py-2.5">
                          <div className="flex min-w-0 items-center gap-2">
                            <Dot color={colorFor(a.token, assets)} />
                            <Link to={`/trade/${a.display}`} className="truncate font-medium hover:underline">{a.display}</Link>
                            <span className="hidden sm:inline"><KindBadge asset={a} /></span>
                          </div>
                        </td>
                        <td className="num hidden px-2 py-2.5 text-right font-mono sm:table-cell">{px === null ? <span className="text-warn">stale</span> : usd(px)}</td>
                        <td className="num px-2 py-2.5 text-right font-mono text-muted">{amt(bal, a.decimals)}</td>
                        <td className="num px-4 py-2.5 text-right font-mono">{usd(value)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          </section>
        </>
      )}

      <section className="mt-8">
        <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
          <h2 className="text-sm font-semibold">Templates</h2>
          <span className="text-xs text-muted">Templates, not recommendations.</span>
        </div>
        <p className="mb-3 text-xs text-muted">Curated mixes from the on-chain template registry. Copying creates a bucket you own; following adopts the curator's later versions at the next rebalance.</p>
        <TemplateGallery />
      </section>
    </div>
  )
}

type WalletRow = { a: ListedAsset; bal: bigint }

/** Every held asset the registry flags (risk >= 1), what it means, and which buckets hold it. */
function RiskPanel({ states, names, rows, wallet, loading }: { states: BucketState[]; names?: Map<string, { name: string }>; rows: PriceRow[]; wallet: WalletRow[]; loading: boolean }) {
  const flagged = rows
    .map((r) => r.asset)
    .filter((a) => a.risk >= 1)
    .map((a) => {
      const k = a.token.toLowerCase()
      const inBuckets = states.filter((s) => s.tokens.some((t, i) => t.toLowerCase() === k && (s.amounts[i] > 0n || (s.targets.weights[s.targets.tokens.findIndex((x) => x.toLowerCase() === k)] ?? 0) > 0)))
      const inWallet = wallet.some((w) => w.a.token.toLowerCase() === k)
      return { a, inBuckets, inWallet }
    })
    .filter((x) => x.inBuckets.length || x.inWallet)
    .sort((x, y) => y.a.risk - x.a.risk)

  return (
    <Section title="Risk" aside={flagged.length ? <AlertTriangle size={14} className="text-warn" /> : <ShieldCheck size={14} className="text-up" />}>
      {loading ? (
        <Skeleton className="h-16" />
      ) : flagged.length === 0 ? (
        <p className="text-sm text-muted">Nothing you hold is flagged by the registry risk workflow.</p>
      ) : (
        <ul className="divide-y divide-line">
          {flagged.map(({ a, inBuckets, inWallet }) => (
            <li key={a.token} className="py-2.5 first:pt-0 last:pb-0">
              <div className="flex items-center justify-between gap-2 text-sm">
                <Link to={`/trade/${a.display}`} className="font-medium hover:underline">{a.display}</Link>
                <RiskBadge level={a.risk} />
              </div>
              <p className="mt-0.5 text-xs text-muted">{RISK[a.risk].action}</p>
              <p className="mt-1 text-[11px] text-faint">
                {[...inBuckets.map((s) => names?.get(s.address.toLowerCase())?.name || `${s.address.slice(0, 6)}…`), inWallet ? 'wallet' : null].filter(Boolean).join(' · ')}
              </p>
            </li>
          ))}
        </ul>
      )}
      <p className="mt-3 border-t border-line pt-3 text-[11px] leading-relaxed text-faint">
        Levels from the on-chain registry: 1 Watch · 2 No buys · 3 Exit to USDC on the next rebalance.
      </p>
    </Section>
  )
}

/** Oracle freshness: stale prices block rebalances of any bucket that contains the asset. */
function OracleHealth({ rows, heldTokens }: { rows: PriceRow[]; heldTokens: string[] | null }) {
  const max = useMaxStaleness()
  const priced = rows.filter((r) => r.asset.display !== 'USDC')
  const stale = priced.filter((r) => r.stale)
  const staleHeld = heldTokens ? stale.filter((r) => heldTokens.includes(r.asset.token.toLowerCase())) : []
  const ages = priced.map((r) => r.oracleAgeSec).filter((x): x is number => x !== null && !Number.isNaN(x))
  const oldest = ages.length ? Math.max(...ages) : null
  const freshest = ages.length ? Math.min(...ages) : null
  return (
    <Section title="Oracle" aside={<span className={`badge ${stale.length ? 'bg-warn/15 text-warn' : 'bg-up/15 text-up'}`}>{rows.length ? (stale.length ? `${stale.length} stale` : 'Fresh') : '—'}</span>}>
      <dl className="grid grid-cols-3 gap-2 text-xs">
        <div><dt className="text-muted">Freshest</dt><dd className="num font-mono">{ageTxt(freshest)}</dd></div>
        <div><dt className="text-muted">Oldest</dt><dd className="num font-mono">{ageTxt(oldest)}</dd></div>
        <div><dt className="text-muted">Max age</dt><dd className="num font-mono">{max.data ? ageTxt(max.data) : '—'}</dd></div>
      </dl>
      {stale.length > 0 && (
        <p className="mt-3 rounded-xl border border-warn/40 bg-warn/10 px-3 py-2 text-xs leading-relaxed">
          No fresh price for {stale.map((r) => r.asset.display).join(', ')}.{' '}
          {heldTokens === null
            ? 'Any bucket containing it cannot rebalance until the CRE workflow updates the price.'
            : staleHeld.length
              ? `Rebalancing is blocked for your buckets containing ${staleHeld.map((r) => r.asset.display).join(', ')} until the CRE workflow updates the price.`
              : 'None of your buckets contain it.'}
        </p>
      )}
      <p className="mt-3 text-[11px] text-faint">Prices on-chain via Chainlink CRE; buckets value and bound every trade at these prices.</p>
    </Section>
  )
}
