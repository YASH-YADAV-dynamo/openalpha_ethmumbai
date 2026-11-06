// One bucket as a "strategy" card on Portfolio, plus the public maintenance buttons reused on the detail page.
import { useQueryClient } from '@tanstack/react-query'
import { ArrowDownToLine, Play, RefreshCw, SlidersHorizontal } from 'lucide-react'
import { useAccount } from 'wagmi'
import { bucketAbi } from '@/lib/contracts'
import { useAssets } from '@/lib/assets'
import { e18, short, usd } from '@/lib/format'
import { Link } from '@/lib/router'
import { useTx } from '@/lib/tx'
import { NO_TEMPLATE, actualShares, bucketStateKey, dateTime, duration, sipDue, targetFor, unpriced, until, useBucket, useNow, useTemplates, type BucketState, type Hex } from './data'
import { Donut } from './charts'
import { assetOf, rebalanceChecks } from './plan'
import { DriftBar, RiskBadge, Skeleton, act } from './ui'

export function RebalanceButton({ s, compact, hideReason }: { s: BucketState; compact?: boolean; hideReason?: boolean }) {
  const now = useNow()
  const { data: assets } = useAssets()
  const { isConnected } = useAccount()
  const { send, pending } = useTx()
  const qc = useQueryClient()
  const gate = rebalanceChecks(s, now, assets)
  const label = `Rebalance ${short(s.address)}`
  const run = async () => {
    const r = await send(label, { address: s.address, abi: bucketAbi, functionName: 'rebalance' })
    if (r) await qc.invalidateQueries({ queryKey: ['bucket'] })
  }
  const why = !isConnected && gate.ok ? 'Connect a wallet to run it (anyone can)' : gate.reason
  return (
    <div className="flex min-w-0 flex-col items-stretch gap-1">
      <button className={compact ? 'btn h-9 px-2 text-xs sm:text-sm' : 'btn'} disabled={!gate.ok || !isConnected || pending !== null} onClick={act(run)} title={why}>
        <RefreshCw size={14} className={pending === label ? 'animate-spin' : ''} /> Rebalance
      </button>
      {!hideReason && <span className="text-xs text-muted">{why}</span>}
    </div>
  )
}

export function RunSipButton({ s }: { s: BucketState }) {
  const now = useNow()
  const { isConnected } = useAccount()
  const { send, pending } = useTx()
  const qc = useQueryClient()
  const label = `Run SIP ${short(s.address)}`
  if (!sipDue(s, now)) return null
  return (
    <button
      className="btn-ghost h-9"
      disabled={!isConnected || pending !== null}
      onClick={act(async () => {
        const r = await send(label, { address: s.address, abi: bucketAbi, functionName: 'executeSip' })
        if (r) await qc.invalidateQueries({ queryKey: bucketStateKey(s.address) })
      })}
    >
      <Play size={14} /> Run SIP now
    </button>
  )
}

export function sipSummary(s: BucketState, now: number) {
  if (!s.sip.active || s.sip.runsLeft === 0) return 'Off'
  return `${usd(Number(s.sip.amount) / 1e6)} / ${duration(s.sip.interval)} · ${s.sip.runsLeft} left · next ${now >= s.sip.nextAt ? 'due now' : until(s.sip.nextAt, now)}`
}

/** "Global FX v2" / "Custom" from the bucket's follow state. */
export function useTemplateLabel(s: BucketState | undefined) {
  const { data: templates } = useTemplates()
  if (!s || s.follow.templateId === NO_TEMPLATE) return { name: 'Custom', following: false }
  const t = templates?.find((x) => x.id === s.follow.templateId)
  return { name: `${t?.name ?? `Template #${s.follow.templateId}`} v${s.follow.version}`, following: s.follow.following }
}

export function BucketCard({ address, name }: { address: Hex; name?: string }) {
  const { data: s, isLoading, isError } = useBucket(address)
  const { data: assets } = useAssets()
  const now = useNow()
  const tpl = useTemplateLabel(s)

  if (isLoading) return <Skeleton className="h-[260px]" />
  if (isError || !s) {
    return (
      <div className="card p-4 text-sm text-muted">
        Couldn't read <span className="font-mono">{short(address)}</span>. <Link to={`/buckets/${address}`} className="text-ink underline">Open</Link>
      </div>
    )
  }
  const stale = unpriced(s).length > 0
  const flagged = s.tokens
    .map((t, i) => ({ a: assetOf(t, assets), held: s.amounts[i] > 0n }))
    .filter((x): x is { a: NonNullable<typeof x.a>; held: boolean } => x.held && Boolean(x.a) && x.a!.risk >= 1)
  const sipOn = s.sip.active && s.sip.runsLeft > 0
  const gate = rebalanceChecks(s, now, assets)

  return (
    <article className="card flex min-w-0 flex-col p-4">
      <div className="flex items-start gap-3">
        <Donut tokens={s.tokens} actual={actualShares(s)} target={s.tokens.map((t) => targetFor(s, t))} assets={assets} size={44} />
        <div className="min-w-0 flex-1">
          <div className="flex min-w-0 items-center gap-2">
            <Link to={`/buckets/${address}`} className="min-w-0 truncate font-semibold hover:underline">{name || short(address)}</Link>
            {s.paused && <span className="badge shrink-0 bg-warn/15 text-warn">Paused</span>}
          </div>
          <div className="mt-1 flex min-w-0 flex-wrap items-center gap-1.5">
            <span className="badge max-w-full truncate bg-panel2 text-muted" title={tpl.following ? 'Adopts curator updates at each rebalance' : undefined}>
              {tpl.name}{tpl.following ? ' · following' : ''}
            </span>
            <span className="num font-mono text-[11px] text-faint">{short(address)}</span>
          </div>
        </div>
      </div>

      <div className="mt-4 flex items-baseline justify-between gap-2">
        <span className="eyebrow">Value</span>
        <span className="num font-mono text-xl font-semibold">
          {usd(e18(s.totalE18))}
          {stale && <span className="ml-1 font-sans text-xs font-normal text-warn" title="A held asset has no fresh oracle price and is excluded">partial</span>}
        </span>
      </div>

      <DriftBar className="mt-3" drift={s.drift?.max ?? null} band={s.params.bandBps} />

      <dl className="mt-3 grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1.5 border-t border-line pt-3 text-xs">
        <dt className="text-muted">Last rebalance</dt>
        <dd className="num text-right font-mono" title={s.lastRebalance ? dateTime(s.lastRebalance) : undefined}>{s.lastRebalance ? until(s.lastRebalance, now) : 'Never'}</dd>
        <dt className="text-muted">SIP</dt>
        <dd className={`num min-w-0 truncate text-right font-mono ${sipOn ? '' : 'text-muted'}`} title={sipOn ? `Next run ${dateTime(s.sip.nextAt)}` : undefined}>
          {sipOn ? `${usd(Number(s.sip.amount) / 1e6)} / ${duration(s.sip.interval)} · ${now >= s.sip.nextAt ? 'due now' : `next ${until(s.sip.nextAt, now)}`}` : 'Off'}
        </dd>
        {flagged.length > 0 && (
          <>
            <dt className="text-muted">Risk</dt>
            <dd className="flex min-w-0 flex-wrap justify-end gap-x-2">
              {flagged.map(({ a }) => (
                <span key={a.token} className="inline-flex items-center gap-1"><span className="text-ink">{a.display}</span><RiskBadge level={a.risk} /></span>
              ))}
            </dd>
          </>
        )}
      </dl>

      <div className="mt-auto pt-4">
        <div className="grid grid-cols-3 gap-2">
          <RebalanceButton s={s} compact hideReason />
          <Link to={`/buckets/${address}?tab=Overview`} className="btn-ghost h-9 px-2 text-xs sm:text-sm"><ArrowDownToLine size={14} /> Deposit</Link>
          <Link to={`/buckets/${address}?tab=Settings`} className="btn-ghost h-9 px-2 text-xs sm:text-sm"><SlidersHorizontal size={14} /> Manage</Link>
        </div>
        <div className="mt-2 flex min-h-[20px] flex-wrap items-center justify-between gap-2">
          <p className={`text-[11px] ${gate.ok ? 'text-up' : 'text-muted'}`}>{gate.ok ? `Ready · ${gate.reason}` : gate.reason}</p>
          <RunSipButton s={s} />
        </div>
      </div>
    </article>
  )
}
