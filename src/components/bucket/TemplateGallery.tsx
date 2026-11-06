// Curated default buckets from TemplateRegistry, each copyable into the user's own bucket.
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useQueryClient } from '@tanstack/react-query'
import { parseEventLogs, type TransactionReceipt } from 'viem'
import { Copy } from 'lucide-react'
import { ConnectKitButton } from 'connectkit'
import { ADDR, factoryAbi } from '@/lib/contracts'
import { useAssets } from '@/lib/assets'
import { bps } from '@/lib/format'
import { navigate } from '@/lib/router'
import { useTx } from '@/lib/tx'
import { useTemplates, type Template } from './data'
import { WeightsBar } from './charts'
import { Skeleton, act } from './ui'

/** Address of the bucket a createBucket / createFromTemplate receipt created. */
export function createdBucket(r: TransactionReceipt | null): `0x${string}` | null {
  if (!r) return null
  const ev = parseEventLogs({ abi: factoryAbi, eventName: 'BucketCreated', logs: r.logs })
  return ev[0]?.args.bucket ?? null
}

function TemplateCard({ t }: { t: Template }) {
  const { data: assets } = useAssets()
  const { isConnected } = useAccount()
  const { send, pending } = useTx()
  const qc = useQueryClient()
  const [follow, setFollow] = useState(true)
  const label = `Copy ${t.name}`

  const copy = async () => {
    const r = await send(label, { address: ADDR.factory, abi: factoryAbi, functionName: 'createFromTemplate', args: [t.id, follow] })
    const b = createdBucket(r)
    if (b) {
      await qc.invalidateQueries({ queryKey: ['bucket'] })
      navigate(`/buckets/${b}`)
    }
  }

  return (
    <article className="card flex min-w-0 flex-col gap-3 p-4">
      <div className="flex items-start justify-between gap-2">
        <h3 className="min-w-0 font-semibold">{t.name || `Template #${t.id}`}</h3>
        <span className="badge shrink-0 bg-panel2 text-muted">v{t.version}</span>
      </div>
      <p className="text-sm leading-snug text-muted">{t.description || '—'}</p>
      <WeightsBar tokens={t.tokens} weights={t.weightsBps} assets={assets} />
      <dl className="grid grid-cols-2 gap-2 text-xs">
        <div><dt className="text-muted">Band</dt><dd className="num font-mono">{bps(t.bandBps)}</dd></div>
        <div className="min-w-0">
          <dt className="text-muted">Curator rationale</dt>
          <dd className="truncate font-mono" title={t.rationaleHash}>{`${t.rationaleHash.slice(0, 10)}…`}</dd>
        </div>
      </dl>
      <div className="mt-auto flex flex-wrap items-center justify-between gap-2 pt-1">
        <label className="flex cursor-pointer items-center gap-2 text-xs text-muted" title="When the curator publishes a new version, the next rebalance adopts its weights">
          <input type="checkbox" className="accent-[rgb(var(--accent))]" checked={follow} onChange={(e) => setFollow(e.target.checked)} />
          Follow updates
        </label>
        {isConnected ? (
          <button className="btn h-9" disabled={pending !== null} onClick={act(copy)}>
            <Copy size={14} /> {pending === label ? 'Copying…' : 'Copy to my portfolio'}
          </button>
        ) : (
          <ConnectKitButton.Custom>
            {({ show }) => <button className="btn-ghost h-9" onClick={show}>Connect to copy</button>}
          </ConnectKitButton.Custom>
        )}
      </div>
    </article>
  )
}

export function TemplateGallery() {
  const { data, isLoading, isError } = useTemplates()
  if (isLoading) {
    return (
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {[0, 1, 2].map((i) => <Skeleton key={i} className="h-56" />)}
      </div>
    )
  }
  if (isError) return <p className="text-sm text-muted">Couldn't load templates from the registry.</p>
  if (!data?.length) return <p className="text-sm text-muted">No templates published yet.</p>
  return (
    <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      {data.map((t) => <TemplateCard key={String(t.id)} t={t} />)}
    </div>
  )
}
