// #/buckets/:address: one bucket as an exchange "auto-rebalance" product page.
// Tabs: Overview · Holdings · Rebalance · SIP · History · Settings (?tab= keeps the choice in the URL).
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { isAddress } from 'viem'
import { ArrowLeft, ExternalLink } from 'lucide-react'
import { useAssets } from '@/lib/assets'
import { addrUrl, bps, e18, short, usd } from '@/lib/format'
import { Link } from '@/lib/router'
import { RebalanceButton, RunSipButton, useTemplateLabel } from '@/components/bucket/BucketCard'
import { Donut } from '@/components/bucket/charts'
import { HoldingsTable } from '@/components/bucket/HoldingsTable'
import { History } from '@/components/bucket/History'
import { FundsPanel, SettingsPanel } from '@/components/bucket/OwnerPanel'
import { RebalancePlan } from '@/components/bucket/RebalancePlan'
import { SipPanel } from '@/components/bucket/SipPanel'
import { actualShares, dateTime, duration, targetFor, unpriced, until, useBucket, useCreation, useNow, type BucketState } from '@/components/bucket/data'
import { RISK, assetOf, replaceHashQuery, useHashQuery } from '@/components/bucket/plan'
import { AddrLink, DriftBar, Notice, RiskBadge, Section, Skeleton, Stat, Tabs, VizStyles } from '@/components/bucket/ui'
import type { ListedAsset } from '@/lib/assets'

const TABS = ['Overview', 'Holdings', 'Rebalance', 'SIP', 'History', 'Settings'] as const
type Tab = (typeof TABS)[number]

export default function BucketDetail({ address }: { address: `0x${string}` }) {
  if (!isAddress(address)) {
    return (
      <div className="mx-auto max-w-3xl px-4 py-10">
        <p className="text-sm text-muted">That isn't a valid bucket address.</p>
        <Link to="/portfolio" className="btn-ghost mt-4">Back to portfolio</Link>
      </div>
    )
  }
  return <Detail address={address} />
}

/** Guardrails in plain language. */
export function Guardrails({ s }: { s: BucketState }) {
  const rows = [
    ['Band', bps(s.params.bandBps), `Rebalances only when an asset drifts more than ${bps(s.params.bandBps)} from its target.`],
    ['Max trade', bps(s.params.maxTradeBps), `Each order is at most ${bps(s.params.maxTradeBps)} of bucket value; large drifts close over several rebalances.`],
    ['Max slippage', bps(s.params.maxSlippageBps), `A fill worse than ${bps(s.params.maxSlippageBps)} vs the oracle price reverts the whole rebalance.`],
    ['Cooldown', duration(s.params.cooldown), `At least ${duration(s.params.cooldown)} between rebalances.`],
  ] as const
  return (
    <dl className="divide-y divide-line">
      {rows.map(([k, v, help]) => (
        <div key={k} className="grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-x-3 gap-y-0.5 py-2 text-sm sm:grid-cols-[96px_64px_minmax(0,1fr)]">
          <dt className="text-muted">{k}</dt>
          <dd className="num text-right font-mono">{v}</dd>
          <dd className="col-span-2 text-xs text-muted sm:col-span-1">{help}</dd>
        </div>
      ))}
    </dl>
  )
}

function RiskList({ s, assets }: { s: BucketState; assets: ListedAsset[] | undefined }) {
  const flagged = s.tokens
    .map((t, i) => ({ a: assetOf(t, assets), held: s.amounts[i] > 0n, target: targetFor(s, t) }))
    .filter((x): x is typeof x & { a: ListedAsset } => Boolean(x.a) && x.a!.risk >= 1 && (x.held || x.target > 0))
  if (!flagged.length) return <p className="text-sm text-muted">No asset in this bucket is flagged by the registry.</p>
  return (
    <ul className="divide-y divide-line">
      {flagged.map(({ a }) => (
        <li key={a.token} className="py-2 text-sm">
          <div className="flex items-center justify-between gap-2"><span className="font-medium">{a.display}</span><RiskBadge level={a.risk} /></div>
          <p className="mt-0.5 text-xs text-muted">{RISK[a.risk].action}</p>
        </li>
      ))}
    </ul>
  )
}

function Detail({ address }: { address: `0x${string}` }) {
  const { address: me } = useAccount()
  const { data: assets } = useAssets()
  const { data: s, isLoading, isError } = useBucket(address)
  const creation = useCreation(address)
  const tpl = useTemplateLabel(s)
  const now = useNow()
  const q = useHashQuery()
  const initial = TABS.find((t) => t.toLowerCase() === (q.get('tab') ?? '').toLowerCase()) ?? 'Overview'
  const [tab, setTabState] = useState<Tab>(initial)
  const setTab = (t: Tab) => { setTabState(t); replaceHashQuery('tab', t) }

  const back = (
    <Link to="/portfolio" className="inline-flex items-center gap-1 text-sm text-muted hover:text-ink"><ArrowLeft size={14} /> Portfolio</Link>
  )

  if (isLoading) {
    return (
      <div className="mx-auto w-full max-w-6xl space-y-4 px-4 py-6 sm:px-6">
        {back}
        <Skeleton className="h-36" />
        <Skeleton className="h-10" />
        <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]"><Skeleton className="h-72" /><Skeleton className="h-72" /></div>
      </div>
    )
  }
  if (isError || !s) {
    return (
      <div className="mx-auto w-full max-w-3xl px-4 py-6 sm:px-6">
        {back}
        <p className="mt-4 text-sm text-muted">Couldn't read a bucket at <span className="font-mono">{short(address)}</span> on Arc Testnet.</p>
      </div>
    )
  }

  const isOwner = Boolean(me && me.toLowerCase() === s.owner.toLowerCase())
  const name = creation.data?.name || short(address)
  const stale = unpriced(s)
  const staleNames = s.tokens.filter((t) => assetOf(t, assets)?.priceE8 === null).map((t) => assetOf(t, assets)?.display ?? short(t))
  const sipOn = s.sip.active && s.sip.runsLeft > 0

  return (
    <div className="mx-auto w-full max-w-6xl px-4 py-6 sm:px-6">
      <VizStyles />
      {back}

      <header className="card mt-3 p-4 sm:p-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <p className="eyebrow">Auto-rebalance bucket{isOwner && ' · yours'}</p>
            <h1 className="mt-1 flex flex-wrap items-center gap-2 text-2xl font-semibold">
              <span className="min-w-0 break-words">{creation.isLoading ? <Skeleton className="h-7 w-40" /> : name}</span>
              <span className="badge bg-panel2 text-muted">{tpl.name}</span>
              {tpl.following && <span className="badge bg-up/15 text-up">Following</span>}
              {s.paused && <span className="badge bg-warn/15 text-warn">Paused</span>}
            </h1>
            <a href={addrUrl(address)} target="_blank" rel="noreferrer" className="num mt-1 inline-flex items-center gap-1 font-mono text-xs text-muted hover:text-ink">
              {short(address)} <ExternalLink size={12} />
            </a>
          </div>
          <div className="flex flex-wrap items-start gap-2">
            <RunSipButton s={s} />
            <RebalanceButton s={s} />
          </div>
        </div>
        <dl className="mt-4 grid grid-cols-2 gap-4 border-t border-line pt-4 sm:grid-cols-3 lg:grid-cols-[1.1fr_1.6fr_1fr_1fr_1fr]">
          <Stat label="Value">
            <span className="font-mono">{usd(e18(s.totalE18))}</span>
            {stale.length > 0 && <span className="ml-1 text-xs font-normal text-warn">partial</span>}
          </Stat>
          <div className="col-span-2 min-w-0 self-end sm:col-span-2 lg:col-span-1"><DriftBar drift={s.drift?.max ?? null} band={s.params.bandBps} /></div>
          <Stat label="Last rebalance"><span className="font-mono text-base" title={s.lastRebalance ? dateTime(s.lastRebalance) : undefined}>{s.lastRebalance ? until(s.lastRebalance, now) : 'Never'}</span></Stat>
          <Stat label="Next SIP"><span className="font-mono text-base" title={sipOn ? dateTime(s.sip.nextAt) : undefined}>{sipOn ? (now >= s.sip.nextAt ? 'Due now' : until(s.sip.nextAt, now)) : 'Off'}</span></Stat>
          <Stat label="Owner"><AddrLink address={s.owner} className="text-base" /></Stat>
        </dl>
      </header>

      {staleNames.length > 0 && (
        <div className="mt-4">
          <Notice tone="warn">
            Oracle price is stale for {staleNames.join(', ')}. Rebalancing is blocked until the CRE workflow posts a fresh price{stale.length ? '; stale holdings are left out of the value' : ''}.
          </Notice>
        </div>
      )}

      <Tabs className="mt-5" tabs={TABS} value={tab} onChange={setTab} />

      <div className="mt-4">
        {tab === 'Overview' && (
          <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]">
            <div className="min-w-0 space-y-4">
              <Section title="Allocation" aside={<button type="button" className="text-xs text-muted hover:text-ink" onClick={() => setTab('Holdings')}>Full holdings →</button>}>
                <div className="flex flex-col gap-4 sm:flex-row sm:items-start">
                  <div className="flex shrink-0 flex-col items-center gap-1">
                    <Donut tokens={s.tokens} actual={actualShares(s)} target={s.tokens.map((t) => targetFor(s, t))} assets={assets} size={132} />
                    <span className="text-[11px] text-faint">Outer: now · inner: target</span>
                  </div>
                  <div className="min-w-0 flex-1"><HoldingsTable s={s} assets={assets} compact /></div>
                </div>
              </Section>
              <Section title="Guardrails"><Guardrails s={s} /></Section>
            </div>
            <aside className="min-w-0 space-y-4">
              {isOwner ? (
                <FundsPanel s={s} assets={assets} />
              ) : (
                <Section title="Read-only">
                  <p className="text-sm text-muted">
                    Only the owner can deposit from this page, change settings or withdraw. Anyone can trigger <span className="text-ink">Rebalance</span> once the gates pass, or run a due SIP, and receives a small USDC tip.
                  </p>
                </Section>
              )}
              <Section title="Risk"><RiskList s={s} assets={assets} /></Section>
            </aside>
          </div>
        )}
        {tab === 'Holdings' && <Section title="Holdings"><HoldingsTable s={s} assets={assets} /></Section>}
        {tab === 'Rebalance' && <RebalancePlan s={s} assets={assets} />}
        {tab === 'SIP' && <SipPanel s={s} isOwner={isOwner} />}
        {tab === 'History' && <History address={address} assets={assets} />}
        {tab === 'Settings' && (
          <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]">
            {isOwner ? (
              <>
                <SettingsPanel s={s} assets={assets} />
                <aside className="min-w-0"><Section title="Current guardrails"><Guardrails s={s} /></Section></aside>
              </>
            ) : (
              <Section title="Settings">
                <p className="mb-3 text-sm text-muted">Only the owner ({short(s.owner)}) can change targets, guardrails or template following.</p>
                <Guardrails s={s} />
              </Section>
            )}
          </div>
        )}
      </div>
    </div>
  )
}
