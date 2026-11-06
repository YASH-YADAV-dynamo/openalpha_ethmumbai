// #/markets — every listed asset, same table and price book as the landing page and the trade terminal.
import { usePriceBook } from '@/lib/prices'
import { MarketsTable } from '@/components/markets/MarketsTable'
import { OverviewStrip } from '@/components/markets/OverviewStrip'

export default function Markets() {
  const book = usePriceBook()
  return (
    <div className="mx-auto w-full max-w-6xl space-y-3 px-4 py-4 sm:py-6">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h1 className="text-xl font-semibold tracking-tight">Markets</h1>
          <p className="text-xs text-muted">Spot vs USDC on Arc Testnet. Prices are the on-chain oracle; 24h, chart and liquidity are Arc mainnet reference data.</p>
        </div>
      </div>
      <OverviewStrip rows={book.rows} loading={book.isLoading} />
      <MarketsTable rows={book.rows} loading={book.isLoading} error={Boolean(book.error)} />
      <p className="text-[11px] text-faint">
        MIRROR = testnet token priced from Arc mainnet, not the real asset. REAL = the actual token on Arc Testnet. Not investment advice.
      </p>
    </div>
  )
}
