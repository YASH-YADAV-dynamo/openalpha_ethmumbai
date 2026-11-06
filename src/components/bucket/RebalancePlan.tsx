// Rebalance tab: every gate the contract checks, then the planned orders (sells first, then buys) before the tx.
import { ArrowDownRight, ArrowUpRight, Check, Minus, X } from 'lucide-react'
import type { ListedAsset } from '@/lib/assets'
import { bps, e18, usd } from '@/lib/format'
import { dateTime, useNow, type BucketState } from './data'
import { RebalanceButton } from './BucketCard'
import { assetOf, planRebalance, rebalanceChecks } from './plan'
import { Dot, Notice, Section, colorFor, symbolOf } from './ui'

export function RebalancePlan({ s, assets }: { s: BucketState; assets: ListedAsset[] | undefined }) {
  const now = useNow()
  const gate = rebalanceChecks(s, now, assets)
  const orders = planRebalance(s, assets)
  const total = e18(s.totalE18)
  const cap = (s.params.maxTradeBps / 10_000) * total
  const multi = orders?.some((o) => o.capped)
  const tip = Math.min(0.05, total * 0.001)

  return (
    <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_320px]">
      <Section
        title="Planned orders"
        aside={<span className="text-xs text-muted">{gate.ok ? 'Executes if you rebalance now' : 'Preview · not executable yet'}</span>}
      >
        {!orders ? (
          <p className="text-sm text-muted">{s.totalE18 === 0n ? 'Empty bucket: deposit USDC and the first rebalance buys toward the targets.' : 'No plan while a price is stale: the contract cannot compute drift.'}</p>
        ) : orders.length === 0 ? (
          <p className="text-sm text-muted">Every asset is exactly on target. Nothing to trade.</p>
        ) : (
          <>
            <div className="-mx-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
              <table className="w-full min-w-[600px] text-[13px]">
                <thead>
                  <tr className="border-b border-line text-left">
                    {['#', 'Asset', 'Side', 'Drift', 'Est. size', 'Min out (slippage)', 'Note'].map((h, i) => (
                      <th key={h} className={`eyebrow whitespace-nowrap pb-2 font-normal ${i >= 3 && i <= 5 ? 'text-right' : ''}`}>{h}</th>
                    ))}
                  </tr>
                </thead>
                <tbody className="divide-y divide-line">
                  {orders.map((o) => {
                    const a = assetOf(o.token, assets)
                    const Icon = o.side === 'Sell' ? ArrowDownRight : o.side === 'Buy' ? ArrowUpRight : Minus
                    return (
                      <tr key={o.token} className={o.side === 'Skip' ? 'text-muted' : ''}>
                        <td className="num py-2 pr-2 font-mono text-xs text-faint">{o.step}</td>
                        <td className="py-2 pr-2">
                          <span className="flex items-center gap-2"><Dot color={colorFor(o.token, assets)} /><span className="font-medium">{a?.display ?? symbolOf(o.token, assets)}</span></span>
                        </td>
                        <td className={`py-2 pr-2 font-medium ${o.side === 'Sell' ? 'text-down' : o.side === 'Buy' ? 'text-up' : ''}`}>
                          <span className="inline-flex items-center gap-1"><Icon size={14} aria-hidden="true" />{o.side}</span>
                        </td>
                        <td className="num py-2 pr-2 text-right font-mono" title={o.driftBps > 0 ? 'Overweight' : 'Underweight'}>
                          {o.driftBps > 0 ? '+' : '−'}{bps(Math.abs(o.driftBps))}
                        </td>
                        <td className="num whitespace-nowrap py-2 pr-2 text-right font-mono">
                          {o.side === 'Skip' ? '—' : usd(o.sizeUsd)}
                          {o.capped && <span className="ml-1 text-[10px] text-warn" title={`Capped at ${bps(s.params.maxTradeBps)} of value (${usd(cap)})`}>cap</span>}
                        </td>
                        <td className="num whitespace-nowrap py-2 pr-2 text-right font-mono text-muted">{o.side === 'Skip' ? '—' : usd(o.minOutUsd)}</td>
                        <td className="py-2 text-xs text-muted">{o.note}</td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
            <ul className="mt-3 space-y-1 text-xs leading-relaxed text-muted">
              <li>1 · Overweight assets are sold to USDC first; 2 · their proceeds fund buys of underweight assets.</li>
              <li>Each order is capped at {bps(s.params.maxTradeBps)} of bucket value ({usd(cap)}){multi ? '; capped orders finish over later rebalances' : ''}.</li>
              <li>Each fill must be within {bps(s.params.maxSlippageBps)} of the oracle price or the whole rebalance reverts (min out shown in USD).</li>
              <li>Sizes are estimates at the oracle price; the contract recomputes them on-chain at execution.</li>
            </ul>
          </>
        )}
      </Section>

      <div className="min-w-0 space-y-4">
        <Section title="Gates">
          <ul className="space-y-2.5">
            {gate.checks.map((c) => (
              <li key={c.label} className="flex gap-2 text-sm">
                <span className={`mt-0.5 inline-flex h-4 w-4 shrink-0 items-center justify-center rounded-full ${c.ok ? 'bg-up/15 text-up' : 'bg-down/15 text-down'}`}>
                  {c.ok ? <Check size={11} /> : <X size={11} />}
                </span>
                <div className="min-w-0">
                  <p className="font-medium">{c.label}</p>
                  <p className="text-xs text-muted">{c.detail}</p>
                </div>
              </li>
            ))}
          </ul>
          <div className="mt-4 border-t border-line pt-4">
            <RebalanceButton s={s} />
            <p className="mt-2 text-[11px] text-faint">
              Anyone can trigger it once the gates pass; the caller gets a small USDC tip from the bucket (0.1% of value, capped at 0.05 USDC; here about {usd(tip)}). Last rebalance: {s.lastRebalance ? dateTime(s.lastRebalance) : 'never'}.
            </p>
          </div>
        </Section>
        {gate.exitHeld && <Notice tone="down">An asset at risk level 3 (Exit) is held. Its target weight moves to USDC and the next rebalance sells it, even inside the band.</Notice>}
      </div>
    </div>
  )
}
