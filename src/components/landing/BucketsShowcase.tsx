// Default bucket templates from the on-chain TemplateRegistry, as horizontally scrolling strategy cards.
import { ArrowRight } from 'lucide-react'
import { useAssets } from '@/lib/assets'
import { bps } from '@/lib/format'
import { Link } from '@/lib/router'
import { useTemplates, type Template } from '@/components/bucket/data'
import { RISK_LABEL } from '@/components/trade/hooks'
import { RiskDot, Skel, assetColor } from '@/components/markets/ui'

export function BucketsShowcase() {
  const templates = useTemplates()
  const assets = useAssets()
  const byToken = new Map((assets.data ?? []).map((a) => [a.token.toLowerCase(), a]))

  return (
    <section className="py-6">
      <div className="mb-3 flex items-end justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold tracking-tight">Buckets</h2>
          <p className="text-xs text-muted">Templates, not recommendations. Read live from the template registry.</p>
        </div>
        <Link to="/buckets/new" className="inline-flex shrink-0 items-center gap-1 text-xs text-muted hover:text-ink">
          Build your own <ArrowRight size={13} />
        </Link>
      </div>

      {templates.isError ? (
        <div className="card p-4 text-sm text-muted">Couldn't read templates from Arc Testnet right now.</div>
      ) : templates.isLoading || !templates.data ? (
        <div className="flex gap-2 overflow-hidden">
          {[0, 1, 2].map((i) => (
            <div key={i} className="card w-[260px] shrink-0 space-y-3 p-4" aria-hidden>
              <Skel className="h-5 w-28" />
              <Skel className="h-2 w-full" />
              <Skel className="h-4 w-3/4" />
            </div>
          ))}
        </div>
      ) : templates.data.length === 0 ? (
        <div className="card p-4 text-sm text-muted">No templates published yet. <Link to="/buckets/new" className="text-accent hover:underline">Build a custom bucket</Link></div>
      ) : (
        <ul className="-mx-4 flex snap-x gap-2 overflow-x-auto px-4 pb-2">
          {templates.data.map((t) => (
            <Card key={t.id.toString()} t={t} symbolOf={(tok) => byToken.get(tok.toLowerCase())?.display ?? `${tok.slice(0, 6)}…`} riskOf={(tok) => byToken.get(tok.toLowerCase())?.risk ?? 0} />
          ))}
        </ul>
      )}
    </section>
  )
}

function Card({ t, symbolOf, riskOf }: { t: Template; symbolOf: (token: string) => string; riskOf: (token: string) => number }) {
  const parts = t.tokens.map((tok, i) => ({ tok, sym: symbolOf(tok), w: t.weightsBps[i] ?? 0 }))
  const worst = Math.max(0, ...t.tokens.map(riskOf))
  return (
    <li className="card flex w-[272px] shrink-0 snap-start flex-col gap-3 p-4">
      <div className="min-w-0">
        <h3 className="truncate text-[15px] font-semibold">{t.name}</h3>
        <p className="mt-0.5 line-clamp-2 min-h-8 text-xs text-muted">{t.description}</p>
      </div>
      <div>
        <div className="flex h-2 w-full gap-[2px] overflow-hidden rounded-full" role="img" aria-label={parts.map((p) => `${p.sym} ${bps(p.w)}`).join(', ')}>
          {parts.map((p) => (
            <div key={p.tok} className="h-full" style={{ width: `${p.w / 100}%`, background: assetColor(p.sym) }} />
          ))}
        </div>
        <ul className="mt-2 flex flex-wrap gap-x-2.5 gap-y-1 text-[11px]">
          {parts.map((p) => (
            <li key={p.tok} className="flex items-center gap-1">
              <span aria-hidden className="h-2 w-2 rounded-sm" style={{ background: assetColor(p.sym) }} />
              <span>{p.sym}</span>
              <span className="num font-mono text-muted">{bps(p.w)}</span>
            </li>
          ))}
        </ul>
      </div>
      <div className="mt-auto flex items-center justify-between gap-2 border-t border-line pt-3">
        <div className="space-y-0.5 font-mono text-[11px] text-muted">
          <div>Band ±{bps(t.bandBps)}</div>
          <div className="flex items-center gap-1" title={`Highest constituent risk level: ${RISK_LABEL[Math.min(worst, 3)]}`}>
            Risk <RiskDot level={worst} />
          </div>
        </div>
        <Link to={`/buckets/new?template=${t.id.toString()}`} className="btn h-9 px-3 text-xs">
          Invest
        </Link>
      </div>
    </li>
  )
}
