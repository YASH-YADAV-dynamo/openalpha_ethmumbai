// #/buckets/new: 3-step wizard — 1 template or custom · 2 weights & guardrails · 3 fund & SIP — then create via the factory.
// Accepts ?template=<id> (landing "Invest") and ?asset=<SYMBOL> (trade ticket "Add to a bucket").
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useQueryClient } from '@tanstack/react-query'
import { ConnectKitButton } from 'connectkit'
import { erc20Abi, formatUnits } from 'viem'
import { ArrowLeft, Check, ChevronRight, PencilRuler } from 'lucide-react'
import { ADDR, bucketAbi, factoryAbi } from '@/lib/contracts'
import { findAsset, useAssets } from '@/lib/assets'
import { amt, bps, usd } from '@/lib/format'
import { Link, navigate } from '@/lib/router'
import { useTx } from '@/lib/tx'
import { BOUNDS, DEFAULT_PARAMS, duration, useTemplates, useUsdc, type Params, type Template } from '@/components/bucket/data'
import { ParamsForm, paramsError } from '@/components/bucket/ParamsForm'
import { TargetsEditor, targetsError, type Row } from '@/components/bucket/TargetsEditor'
import { createdBucket } from '@/components/bucket/TemplateGallery'
import { parseAmount } from '@/components/bucket/OwnerPanel'
import { AllocationDonut, WeightsBar } from '@/components/bucket/charts'
import { useHashQuery } from '@/components/bucket/plan'
import { Dot, Notice, Section, Skeleton, VizStyles, act, colorFor, symbolOf } from '@/components/bucket/ui'

const STEPS = ['Strategy', 'Weights & guardrails', 'Fund & SIP'] as const
const SHORT = ['Strategy', 'Weights', 'Fund'] as const
const INTERVALS = [
  { label: 'Daily', sec: 86_400 },
  { label: 'Weekly', sec: 604_800 },
  { label: 'Monthly', sec: 2_592_000 },
] as const

const templateParams = (t: Template): Params => ({ ...DEFAULT_PARAMS, bandBps: t.bandBps }) // BucketFactory.createFromTemplate defaults
const sameRows = (rows: Row[], t: Template) =>
  rows.length === t.tokens.length && rows.every((r, i) => r.token.toLowerCase() === t.tokens[i].toLowerCase() && r.bps === t.weightsBps[i])

type Phase = { label: string; state: 'todo' | 'run' | 'done' | 'fail' }

export default function BucketNew() {
  const { address, isConnected } = useAccount()
  const { data: assets } = useAssets()
  const templates = useTemplates()
  const usdc = useUsdc(address, ADDR.factory)
  const { send } = useTx()
  const qc = useQueryClient()
  const q = useHashQuery()

  const [step, setStep] = useState(0)
  const [from, setFrom] = useState<Template | null>(null)
  const [name, setName] = useState('')
  const [rows, setRows] = useState<Row[]>([])
  const [params, setParams] = useState<Params>(DEFAULT_PARAMS)
  const [follow, setFollow] = useState(true)
  const [dep, setDep] = useState('')
  const [sipOn, setSipOn] = useState(false)
  const [sipAmt, setSipAmt] = useState('')
  const [every, setEvery] = useState<number>(INTERVALS[1].sec)
  const [runs, setRuns] = useState('12')
  const [phases, setPhases] = useState<Phase[] | null>(null)
  const [prefilled, setPrefilled] = useState(false)

  const pick = (t: Template | null) => {
    setFrom(t)
    if (t) {
      setRows(t.tokens.map((token, i) => ({ token, bps: t.weightsBps[i] })))
      setParams(templateParams(t))
      setName(t.name)
    } else {
      setRows([])
      setParams(DEFAULT_PARAMS)
      setName('')
    }
  }

  // Deep links: ?template=<id> or ?asset=<SYMBOL>, applied once (state adjusted during render, not in an effect).
  if (!prefilled) {
    const tid = q.get('template')
    const sym = q.get('asset')
    if (tid !== null && templates.data) {
      const t = templates.data.find((x) => String(x.id) === tid)
      if (t) { pick(t); setStep(1) }
      setPrefilled(true)
    } else if (sym && assets) {
      const a = findAsset(assets, sym)
      if (a) { setFrom(null); setRows([{ token: a.token, bps: 10_000 }]); setStep(1) }
      setPrefilled(true)
    } else if ((tid === null && !sym) || (tid !== null && templates.isError)) setPrefilled(true)
  }

  const asTemplate = from !== null && sameRows(rows, from) && JSON.stringify(params) === JSON.stringify(templateParams(from))
  const weightsErr = targetsError(rows) ?? paramsError(params)
  const depN = dep.trim() ? parseAmount(dep, 6) : 0n
  const sipN = sipOn ? parseAmount(sipAmt, 6) : 0n
  const r = Number(runs)
  const runsOk = !sipOn || (Number.isInteger(r) && r >= BOUNDS.runs[0] && r <= BOUNDS.runs[1])
  const approveTotal = (depN ?? 0n) + (sipOn && sipN ? sipN * BigInt(runsOk ? r : 0) : 0n)
  const bal = usdc.data?.balance
  const fundErr =
    depN === null ? 'Enter a valid deposit amount' : sipOn && !sipN ? 'Enter a SIP amount per run' : !runsOk ? 'Runs must be 1 to 520' : !asTemplate && !name.trim() ? 'Give the bucket a name' : bal !== undefined && depN > bal ? 'Deposit is more than your USDC balance' : null
  const busy = phases?.some((p) => p.state === 'run') ?? false

  const run = async () => {
    const createLabel = asTemplate ? `Create from ${from.name}` : 'Create bucket'
    type Job = { label: string; go: (b: `0x${string}`) => Promise<unknown> }
    const jobs: Job[] = []
    if (approveTotal > 0n) jobs.push({ label: `Approve ${amt(approveTotal, 6)} USDC`, go: (b) => send(`Approve ${amt(approveTotal, 6)} USDC`, { address: ADDR.usdc, abi: erc20Abi, functionName: 'approve', args: [b, approveTotal] }) })
    if (depN) jobs.push({ label: `Deposit ${amt(depN, 6)} USDC`, go: (b) => send(`Deposit ${amt(depN, 6)} USDC`, { address: b, abi: bucketAbi, functionName: 'deposit', args: [depN] }) })
    if (sipOn && sipN) jobs.push({ label: `Start SIP ${amt(sipN, 6)} USDC / ${duration(every)}`, go: (b) => send('Start SIP', { address: b, abi: bucketAbi, functionName: 'setSip', args: [sipN, every, r] }) })
    const mark = (i: number, state: Phase['state']) => setPhases((p) => p?.map((x, k) => (k === i ? { ...x, state } : x)) ?? null)
    setPhases([{ label: createLabel, state: 'run' }, ...jobs.map((j) => ({ label: j.label, state: 'todo' as const }))])
    const created = asTemplate
      ? await send(createLabel, { address: ADDR.factory, abi: factoryAbi, functionName: 'createFromTemplate', args: [from.id, follow] })
      : await send(createLabel, { address: ADDR.factory, abi: factoryAbi, functionName: 'createBucket', args: [name.trim(), rows.map((x) => x.token), rows.map((x) => x.bps), params] })
    const b = createdBucket(created)
    if (!b) { mark(0, 'fail'); return }
    mark(0, 'done')
    for (let k = 0; k < jobs.length; k++) {
      mark(k + 1, 'run')
      const ok = await jobs[k].go(b)
      mark(k + 1, ok ? 'done' : 'fail')
      if (!ok) break
    }
    await qc.invalidateQueries({ queryKey: ['bucket'] })
    navigate(`/buckets/${b}`)
  }

  const canNext = step === 0 ? true : step === 1 ? !weightsErr : false

  return (
    <div className="mx-auto w-full max-w-6xl px-4 py-6 sm:px-6">
      <VizStyles />
      <Link to="/portfolio" className="inline-flex items-center gap-1 text-sm text-muted hover:text-ink"><ArrowLeft size={14} /> Portfolio</Link>
      <div className="mt-2 flex flex-wrap items-end justify-between gap-2">
        <div>
          <p className="eyebrow">Earn · New bucket</p>
          <h1 className="mt-1 text-2xl font-semibold">Create an auto-rebalancing bucket</h1>
        </div>
        <span className="text-xs text-muted">Templates, not recommendations.</span>
      </div>

      <ol className="mt-5 grid grid-cols-3 gap-2" aria-label="Steps">
        {STEPS.map((s, i) => (
          <li key={s}>
            <button
              type="button"
              disabled={i > step || busy}
              onClick={() => setStep(i)}
              className={`flex w-full min-w-0 items-center gap-2 rounded-xl border px-2 py-2 text-left text-xs transition sm:px-3 sm:text-sm ${i === step ? 'border-accent bg-panel text-ink' : i < step ? 'border-line bg-panel text-ink hover:bg-panel2' : 'border-line text-muted'}`}
              aria-current={i === step ? 'step' : undefined}
            >
              <span className={`num inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full font-mono text-[11px] ${i < step ? 'bg-up/20 text-up' : i === step ? 'bg-accent text-onaccent' : 'bg-panel2'}`}>
                {i < step ? <Check size={12} /> : i + 1}
              </span>
              <span className="truncate"><span className="sm:hidden">{SHORT[i]}</span><span className="hidden sm:inline">{s}</span></span>
            </button>
          </li>
        ))}
      </ol>

      <div className="mt-4 grid gap-4 lg:grid-cols-[minmax(0,1fr)_320px]">
        <div className="min-w-0 space-y-4">
          {step === 0 && (
            <Section title="Choose a starting point">
              {templates.isLoading ? (
                <div className="grid gap-3 sm:grid-cols-2">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-32" />)}</div>
              ) : (
                <div className="grid gap-3 sm:grid-cols-2">
                  {(templates.data ?? []).map((t) => {
                    const on = from?.id === t.id
                    return (
                      <button key={String(t.id)} type="button" onClick={() => pick(t)} aria-pressed={on} className={`flex min-w-0 flex-col gap-2 rounded-xl border p-3 text-left transition hover:bg-panel2/60 ${on ? 'border-accent bg-panel2/40' : 'border-line'}`}>
                        <div className="flex w-full items-center justify-between gap-2">
                          <span className="truncate font-medium">{t.name || `Template #${t.id}`}</span>
                          <span className="badge shrink-0 bg-panel2 text-muted">v{t.version} · band {bps(t.bandBps)}</span>
                        </div>
                        <span className="line-clamp-2 text-xs text-muted">{t.description || '—'}</span>
                        <WeightsBar tokens={t.tokens} weights={t.weightsBps} assets={assets} />
                      </button>
                    )
                  })}
                  <button type="button" onClick={() => pick(null)} aria-pressed={from === null && rows.length === 0} className={`flex min-h-[128px] flex-col items-start justify-center gap-1 rounded-xl border border-dashed p-3 text-left transition hover:bg-panel2/60 ${from === null ? 'border-accent' : 'border-line'}`}>
                    <PencilRuler size={16} className="text-muted" />
                    <span className="font-medium">Custom</span>
                    <span className="text-xs text-muted">Pick up to 12 listed assets and your own weights.</span>
                  </button>
                </div>
              )}
              {templates.isError && <p className="mt-2 text-sm text-muted">Couldn't load templates; you can still build a custom bucket.</p>}
              <p className="mt-3 text-xs text-muted">Templates are curated weight sets published on-chain by a curator. They are starting points, not recommendations, and say nothing about future performance.</p>
            </Section>
          )}

          {step === 1 && (
            <>
              <Section title="Assets and target weights" aside={from && <span className="badge bg-panel2 text-muted">from {from.name}</span>}>
                <TargetsEditor rows={rows} onChange={setRows} assets={assets} />
                <p className="mt-3 text-xs text-muted">Deposits arrive as USDC; USDC is always held as cash even at 0% target. Assets marked No buys are skipped when buying; Exit-level assets are sold to USDC.</p>
              </Section>
              <Section title="Guardrails">
                <ParamsForm value={params} onChange={setParams} />
              </Section>
            </>
          )}

          {step === 2 && (
            <>
              <Section title="Name">
                {asTemplate ? (
                  <>
                    <p className="text-sm">{from.name}</p>
                    <label className="mt-3 flex cursor-pointer items-start gap-2 text-sm">
                      <input type="checkbox" className="mt-0.5 accent-[rgb(var(--accent))]" checked={follow} onChange={(e) => setFollow(e.target.checked)} />
                      <span>Follow curator updates<span className="block text-xs text-muted">When the curator publishes a new version, the next rebalance adopts its weights. Your guardrails stay as set.</span></span>
                    </label>
                  </>
                ) : (
                  <>
                    <input className="field" maxLength={40} placeholder="e.g. Euro savings" value={name} onChange={(e) => setName(e.target.value)} />
                    <p className="mt-1 text-xs text-muted">{from ? 'Edited from the template, so it is created as a custom bucket (no curator updates).' : 'Stored in the creation event; shown on your portfolio.'}</p>
                  </>
                )}
              </Section>

              <Section title="Initial deposit" aside={<span className="text-xs text-muted">optional</span>}>
                <div className="flex items-center justify-between text-xs text-muted">
                  <span>Amount (USDC)</span>
                  <button type="button" className="hover:text-ink" disabled={bal === undefined} onClick={() => bal !== undefined && setDep(formatUnits(bal, 6))}>
                    Wallet: <span className="num font-mono">{bal === undefined ? '—' : amt(bal, 6)}</span> · Max
                  </button>
                </div>
                <input className="field num mt-1 font-mono" inputMode="decimal" placeholder="0.00" value={dep} onChange={(e) => setDep(e.target.value)} />
                <p className="mt-1 text-xs text-muted">Lands as USDC; the first rebalance (anyone can trigger it once drift passes the band) buys toward the targets.</p>
              </Section>

              <Section title="SIP · auto-invest" aside={
                <label className="flex cursor-pointer items-center gap-2 text-xs text-muted">
                  <input type="checkbox" className="accent-[rgb(var(--accent))]" checked={sipOn} onChange={(e) => setSipOn(e.target.checked)} /> Enable
                </label>
              }>
                {sipOn ? (
                  <div className="grid gap-3 sm:grid-cols-3">
                    <label className="block text-xs text-muted">
                      Amount per run (USDC)
                      <input className="field num mt-1 font-mono" inputMode="decimal" placeholder="25" value={sipAmt} onChange={(e) => setSipAmt(e.target.value)} />
                    </label>
                    <div className="text-xs text-muted">
                      Every
                      <div className="mt-1 flex gap-1" role="radiogroup" aria-label="Interval">
                        {INTERVALS.map((i) => (
                          <button key={i.sec} type="button" role="radio" aria-checked={every === i.sec} className={`tab h-10 flex-1 border border-line px-1 ${every === i.sec ? 'tab-on' : ''}`} onClick={() => setEvery(i.sec)}>{i.label}</button>
                        ))}
                      </div>
                    </div>
                    <label className="block text-xs text-muted">
                      Runs (1–520)
                      <input className="field num mt-1 font-mono" inputMode="numeric" value={runs} onChange={(e) => setRuns(e.target.value.replace(/\D/g, ''))} />
                    </label>
                    <p className="text-xs text-muted sm:col-span-3">Each run pulls the amount from your wallet and buys your targets (skipping No-buys assets). First run is one interval after it starts; anyone can execute a due run.</p>
                  </div>
                ) : (
                  <p className="text-sm text-muted">Off. You can schedule recurring buys later from the bucket's SIP tab.</p>
                )}
              </Section>
            </>
          )}

          <div className="card flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
            <p className={`text-sm ${(step === 1 && weightsErr) || (step === 2 && fundErr) ? 'text-down' : 'text-muted'}`}>
              {step === 0
                ? from ? `${from.name} selected.` : rows.length ? 'Custom mix.' : 'Pick a template or Custom.'
                : step === 1
                  ? weightsErr ?? 'Weights sum to 100%; guardrails are within contract bounds.'
                  : fundErr ?? `${1 + (approveTotal > 0n ? 1 : 0) + (depN ? 1 : 0) + (sipOn && sipN ? 1 : 0)} wallet confirmation(s). Gas is paid in USDC.`}
            </p>
            <div className="flex shrink-0 gap-2">
              {step > 0 && <button type="button" className="btn-ghost" disabled={busy} onClick={() => setStep(step - 1)}>Back</button>}
              {step < 2 ? (
                <button type="button" className="btn" disabled={!canNext} onClick={() => setStep(step + 1)}>Continue <ChevronRight size={16} /></button>
              ) : isConnected ? (
                <button type="button" className="btn" disabled={Boolean(fundErr) || Boolean(weightsErr) || busy} onClick={act(run)}>
                  {busy ? 'Working…' : depN || (sipOn && sipN) ? 'Create & fund' : 'Create bucket'}
                </button>
              ) : (
                <ConnectKitButton />
              )}
            </div>
          </div>

          {phases && (
            <Section title="Progress">
              <ol className="space-y-1.5 text-sm">
                {phases.map((p, i) => (
                  <li key={p.label} className="flex items-center gap-2">
                    <span className={`num inline-flex h-5 w-5 items-center justify-center rounded-full font-mono text-[11px] ${p.state === 'done' ? 'bg-up/20 text-up' : p.state === 'fail' ? 'bg-down/20 text-down' : p.state === 'run' ? 'bg-accent text-onaccent' : 'bg-panel2 text-muted'}`}>
                      {p.state === 'done' ? <Check size={12} /> : i + 1}
                    </span>
                    <span className={p.state === 'todo' ? 'text-muted' : ''}>{p.label}</span>
                    {p.state === 'run' && <span className="text-xs text-muted">confirm in wallet…</span>}
                    {p.state === 'fail' && <span className="text-xs text-down">failed</span>}
                  </li>
                ))}
              </ol>
              <p className="mt-2 text-xs text-muted">If a funding step fails, the bucket still exists; finish from its page.</p>
            </Section>
          )}
        </div>

        <aside className="min-w-0 lg:sticky lg:top-28 lg:self-start">
          <Section title="Allocation preview">
            {rows.length ? (
              <>
                <div className="flex justify-center">
                  <AllocationDonut
                    tokens={rows.map((x) => x.token)}
                    weights={rows.map((x) => x.bps)}
                    assets={assets}
                    size={168}
                    center={`${(rows.reduce((a, x) => a + x.bps, 0) / 100).toFixed(rows.reduce((a, x) => a + x.bps, 0) % 100 ? 2 : 0)}%`}
                    sub={`${rows.length} asset${rows.length > 1 ? 's' : ''}`}
                  />
                </div>
                <ul className="mt-3 space-y-1 text-[13px]">
                  {rows.map((x) => (
                    <li key={x.token} className="flex items-center gap-2">
                      <Dot color={colorFor(x.token, assets)} />
                      <span className="min-w-0 truncate">{symbolOf(x.token, assets)}</span>
                      <span className="num ml-auto font-mono">{bps(x.bps)}</span>
                    </li>
                  ))}
                </ul>
              </>
            ) : (
              <p className="py-8 text-center text-sm text-muted">Pick a template or add assets.</p>
            )}
            <div className="mt-4 space-y-1.5 border-t border-line pt-3 text-xs text-muted">
              <p><span className="text-ink">Band {bps(params.bandBps)}</span> · trades only when an asset is that far off target.</p>
              <p><span className="text-ink">Max trade {bps(params.maxTradeBps)}</span> · of bucket value per order; big gaps close over several rebalances.</p>
              <p><span className="text-ink">Slippage {bps(params.maxSlippageBps)}</span> · worse fills vs the oracle price revert.</p>
              <p><span className="text-ink">Cooldown {duration(params.cooldown)}</span> · minimum time between rebalances.</p>
              {step === 2 && (depN || (sipOn && sipN)) ? (
                <p className="pt-1">
                  Funding: <span className="num font-mono text-ink">{depN ? usd(Number(depN) / 1e6) : '$0'}</span> now
                  {sipOn && sipN ? <> + <span className="num font-mono text-ink">{usd(Number(sipN) / 1e6)}</span> every {duration(every)} × {runsOk ? r : '—'}</> : null}
                </p>
              ) : null}
            </div>
          </Section>
          {rows.some((x) => assets?.find((a) => a.token.toLowerCase() === x.token.toLowerCase())?.priceE8 === null) && (
            <div className="mt-3"><Notice tone="warn">An asset in this mix has no fresh oracle price right now; rebalancing waits until it updates.</Notice></div>
          )}
        </aside>
      </div>
    </div>
  )
}
