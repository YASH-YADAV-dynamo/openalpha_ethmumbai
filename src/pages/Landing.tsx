// Exchange home: hero + quick swap, market overview, markets table, bucket templates, how it works, trust strip.
import { usePriceBook } from '@/lib/prices'
import { Link } from '@/lib/router'
import { Hero } from '@/components/landing/Hero'
import { BucketsShowcase } from '@/components/landing/BucketsShowcase'
import { HowItWorks, TrustStrip } from '@/components/landing/HowItWorks'
import { MarketsTable } from '@/components/markets/MarketsTable'
import { OverviewStrip } from '@/components/markets/OverviewStrip'

export default function Landing() {
  const book = usePriceBook()
  return (
    <div className="mx-auto w-full max-w-6xl px-4">
      <Hero />
      <OverviewStrip rows={book.rows} loading={book.isLoading} />
      <section className="pt-6">
        <div className="mb-3 flex items-end justify-between gap-3">
          <div>
            <h2 className="text-lg font-semibold tracking-tight">Markets</h2>
            <p className="text-xs text-muted">Price = on-chain oracle. 24h, chart and liquidity = Arc mainnet reference. MIRROR = testnet token priced from Arc mainnet.</p>
          </div>
          <Link to="/markets" className="hidden shrink-0 text-xs text-muted hover:text-ink sm:inline">All markets →</Link>
        </div>
        <MarketsTable rows={book.rows} loading={book.isLoading} error={Boolean(book.error)} />
      </section>
      <BucketsShowcase />
      <HowItWorks />
      <TrustStrip />
    </div>
  )
}
