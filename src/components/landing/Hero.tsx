import { ArrowRight } from 'lucide-react'
import { Link } from '@/lib/router'
import { QuickSwap } from './QuickSwap'

export function Hero() {
  return (
    <section className="grid grid-cols-[minmax(0,1fr)] items-center gap-4 py-5 sm:py-8 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)] lg:gap-8">
      <div className="min-w-0">
        <p className="eyebrow mb-3">Spot exchange · Arc Testnet</p>
        <h1 className="max-w-2xl text-[1.75rem] font-semibold leading-[1.1] tracking-tight sm:text-4xl lg:text-[2.75rem]">
          Trade FX, gold, BTC and RWAs on Arc. <span className="text-accent">Let buckets rebalance for you.</span>
        </h1>
        <p className="mt-3 font-mono text-xs text-muted sm:text-[13px]">Non-custodial · USDC gas · sub-second finality</p>
        <div className="mt-5 flex flex-col gap-2 min-[400px]:flex-row">
          <Link to="/trade/EURC" className="btn h-11 px-5">
            Start trading <ArrowRight size={16} />
          </Link>
          <Link to="/buckets/new" className="btn-ghost h-11 px-5">
            Create a bucket
          </Link>
        </div>
      </div>
      <QuickSwap />
    </section>
  )
}
