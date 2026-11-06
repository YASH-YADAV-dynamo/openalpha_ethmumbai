// "How it works" (3 steps) + trust strip with explorer links to the deployed contracts.
import { ArrowUpRight } from 'lucide-react'
import { ADDR } from '@/lib/contracts'
import { addrUrl, short } from '@/lib/format'

const STEPS = [
  { n: '1', title: 'Deposit USDC', line: 'Into your own bucket contract. USDC also pays gas.' },
  { n: '2', title: 'Bucket trades to target weights', line: 'Swaps route via Uniswap v4 or the mirror venue, with slippage and size caps.' },
  { n: '3', title: 'SIP + guardrails keep it there', line: 'Chainlink CRE prices; risk level 3 exits the asset to USDC.' },
]

const CONTRACTS: { label: string; addr: string }[] = [
  { label: 'Asset registry', addr: ADDR.registry },
  { label: 'Template registry', addr: ADDR.templates },
  { label: 'Bucket factory', addr: ADDR.factory },
  { label: 'Uniswap v4 venue', addr: ADDR.uniVenue },
  { label: 'Mirror venue', addr: ADDR.mirrorVenue },
]

export function HowItWorks() {
  return (
    <section className="py-6">
      <h2 className="mb-3 text-lg font-semibold tracking-tight">How it works</h2>
      <ol className="grid gap-px overflow-hidden rounded-2xl border border-line bg-line md:grid-cols-3">
        {STEPS.map((s) => (
          <li key={s.n} className="flex gap-3 bg-panel p-4">
            <span className="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-accent/15 font-mono text-xs font-semibold text-accent">{s.n}</span>
            <div className="min-w-0">
              <div className="text-sm font-semibold">{s.title}</div>
              <div className="mt-0.5 text-xs text-muted">{s.line}</div>
            </div>
          </li>
        ))}
      </ol>
    </section>
  )
}

export function TrustStrip() {
  return (
    <section className="pb-8 pt-2">
      <div className="card flex flex-col gap-3 p-4 lg:flex-row lg:items-center lg:justify-between">
        <ul className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted">
          <li>Prices via Chainlink CRE</li>
          <li>Per-user bucket contracts, never pooled</li>
        </ul>
        <ul className="flex flex-wrap gap-x-4 gap-y-1.5 font-mono text-[11px]">
          {CONTRACTS.map((c) => (
            <li key={c.addr}>
              <a href={addrUrl(c.addr)} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-muted hover:text-ink" title={c.addr}>
                <span className="text-ink">{c.label}</span> {short(c.addr)}
                <ArrowUpRight size={11} />
              </a>
            </li>
          ))}
        </ul>
      </div>
    </section>
  )
}
