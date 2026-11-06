// Owner-only controls: deposit, withdraw, targets, rules, template following, pause.
import { useMemo, useState, type ReactNode } from 'react'
import { useAccount } from 'wagmi'
import { useQueryClient } from '@tanstack/react-query'
import { erc20Abi, formatUnits, parseUnits } from 'viem'
import { ADDR, bucketAbi } from '@/lib/contracts'
import type { ListedAsset } from '@/lib/assets'
import { amt, bps } from '@/lib/format'
import { useTx } from '@/lib/tx'
import { NO_TEMPLATE, useTemplates, useUsdc, type BucketState, type Hex, type Params } from './data'
import { ParamsForm, paramsError } from './ParamsForm'
import { TargetsEditor, targetsError, type Row } from './TargetsEditor'
import { Notice, act } from './ui'

/** Parse a decimal string to base units; null when invalid or zero. */
export function parseAmount(v: string, decimals: number): bigint | null {
  if (!/^\d*\.?\d*$/.test(v.trim()) || !v.trim() || v.trim() === '.') return null
  try {
    const n = parseUnits(v.trim(), decimals)
    return n > 0n ? n : null
  } catch {
    return null
  }
}

function useRefresh() {
  const qc = useQueryClient()
  return () => qc.invalidateQueries({ queryKey: ['bucket'] })
}

function Deposit({ s }: { s: BucketState }) {
  const { address } = useAccount()
  const usdc = useUsdc(address, s.address)
  const { send, pending } = useTx()
  const refresh = useRefresh()
  const [v, setV] = useState('')
  const n = parseAmount(v, 6)
  const bal = usdc.data?.balance
  // Keep any approval an active SIP still needs, so a deposit's approve() doesn't overwrite it.
  const reserved = s.sip.active ? s.sip.amount * BigInt(s.sip.runsLeft) : 0n
  const needsApprove = n !== null && (usdc.data?.allowance ?? 0n) < n + reserved
  const over = n !== null && bal !== undefined && n > bal

  const go = async () => {
    if (!n) return
    if (needsApprove) {
      const a = await send('Approve USDC', { address: ADDR.usdc, abi: erc20Abi, functionName: 'approve', args: [s.address, n + reserved] })
      if (!a) return
    }
    const r = await send('Deposit USDC', { address: s.address, abi: bucketAbi, functionName: 'deposit', args: [n] })
    if (r) { setV(''); await refresh() }
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between text-xs text-muted">
        <span>Amount (USDC)</span>
        <button type="button" className="hover:text-ink" disabled={bal === undefined} onClick={() => bal !== undefined && setV(formatUnits(bal, 6))}>
          Wallet: <span className="num font-mono">{bal === undefined ? '—' : amt(bal, 6)}</span> · Max
        </button>
      </div>
      <input className="field num font-mono" inputMode="decimal" placeholder="0.00" value={v} onChange={(e) => setV(e.target.value)} />
      {over && <p className="text-xs text-down">More than your USDC balance.</p>}
      <button className="btn w-full" disabled={!n || over || pending !== null} onClick={act(go)}>
        {pending ?? (needsApprove ? 'Approve, then deposit' : 'Deposit')}
      </button>
      <p className="text-xs text-muted">Deposits land as USDC. The next rebalance buys toward your targets once drift passes the band.</p>
    </div>
  )
}

function Withdraw({ s, assets }: { s: BucketState; assets: ListedAsset[] | undefined }) {
  const { address } = useAccount()
  const { send, pending } = useTx()
  const refresh = useRefresh()
  const held = s.tokens.map((t, i) => ({ t, amount: s.amounts[i], a: assets?.find((x) => x.token.toLowerCase() === t.toLowerCase()) })).filter((h) => h.amount > 0n)
  const [token, setToken] = useState<Hex | ''>('')
  const [v, setV] = useState('')
  const [confirmAll, setConfirmAll] = useState(false)
  const sel = held.find((h) => h.t === token) ?? held[0]
  const dec = sel?.a?.decimals ?? 18
  const n = parseAmount(v, dec)
  const over = n !== null && sel !== undefined && n > sel.amount

  if (!held.length) return <p className="text-sm text-muted">Nothing to withdraw.</p>
  return (
    <div className="space-y-3">
      <div className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]">
        <select className="field" aria-label="Asset" value={sel?.t} onChange={(e) => { setToken(e.target.value as Hex); setV('') }}>
          {held.map((h) => <option key={h.t} value={h.t}>{h.a?.display ?? h.t}</option>)}
        </select>
        <div className="relative">
          <input className="field num pr-14 font-mono" inputMode="decimal" placeholder="0.0" value={v} onChange={(e) => setV(e.target.value)} />
          <button type="button" className="absolute right-2 top-1/2 -translate-y-1/2 text-xs text-muted hover:text-ink" onClick={() => sel && setV(formatUnits(sel.amount, dec))}>Max</button>
        </div>
      </div>
      <p className="text-xs text-muted">Held: <span className="num font-mono">{sel ? amt(sel.amount, dec) : '—'}</span> {sel?.a?.display}</p>
      {over && <p className="text-xs text-down">More than the bucket holds.</p>}
      <button
        className="btn w-full"
        disabled={!n || over || !address || pending !== null}
        onClick={act(async () => {
          const r = await send(`Withdraw ${sel.a?.display ?? ''}`.trim(), { address: s.address, abi: bucketAbi, functionName: 'withdraw', args: [sel.t, n!, address!] })
          if (r) { setV(''); await refresh() }
        })}
      >
        Withdraw to my wallet
      </button>
      <div className="border-t border-line pt-3">
        {confirmAll ? (
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-xs text-muted">Send every holding to your wallet?</span>
            <button
              className="btn-ghost h-9 border-down/50 text-down"
              disabled={!address || pending !== null}
              onClick={act(async () => {
                const r = await send('Withdraw all', { address: s.address, abi: bucketAbi, functionName: 'withdrawAll', args: [address!] })
                setConfirmAll(false)
                if (r) await refresh()
              })}
            >
              Yes, withdraw all
            </button>
            <button className="btn-ghost h-9" onClick={() => setConfirmAll(false)}>Cancel</button>
          </div>
        ) : (
          <button className="btn-ghost h-9" onClick={() => setConfirmAll(true)}>Withdraw all…</button>
        )}
      </div>
    </div>
  )
}

function Targets({ s, assets }: { s: BucketState; assets: ListedAsset[] | undefined }) {
  const initial = useMemo<Row[]>(() => s.targets.tokens.map((t, i) => ({ token: t, bps: s.targets.weights[i] })).filter((r) => r.bps > 0), [s.targets])
  const [rows, setRows] = useState<Row[]>(initial)
  const { send, pending } = useTx()
  const refresh = useRefresh()
  const err = targetsError(rows)
  return (
    <div className="space-y-3">
      {s.follow.following && <Notice tone="warn">Saving custom targets stops following the template.</Notice>}
      <TargetsEditor rows={rows} onChange={setRows} assets={assets} />
      <button
        className="btn w-full"
        disabled={Boolean(err) || pending !== null}
        onClick={act(async () => {
          const r = await send('Set targets', { address: s.address, abi: bucketAbi, functionName: 'setTargets', args: [rows.map((x) => x.token), rows.map((x) => x.bps)] })
          if (r) await refresh()
        })}
      >
        Save targets
      </button>
    </div>
  )
}

function Rules({ s }: { s: BucketState }) {
  const [p, setP] = useState<Params>(s.params)
  const { send, pending } = useTx()
  const refresh = useRefresh()
  const same = JSON.stringify(p) === JSON.stringify(s.params)
  return (
    <div className="space-y-3">
      <ParamsForm value={p} onChange={setP} />
      <button
        className="btn w-full"
        disabled={same || Boolean(paramsError(p)) || pending !== null}
        onClick={act(async () => {
          const r = await send('Update guardrails', { address: s.address, abi: bucketAbi, functionName: 'setParams', args: [p] })
          if (r) await refresh()
        })}
      >
        Save guardrails
      </button>
    </div>
  )
}

function TemplateTab({ s }: { s: BucketState }) {
  const { data: templates } = useTemplates()
  const { send, pending } = useTx()
  const refresh = useRefresh()
  const linked = s.follow.templateId !== NO_TEMPLATE ? templates?.find((t) => t.id === s.follow.templateId) : undefined
  const [pick, setPick] = useState<string>('')
  const chosen = templates?.find((t) => String(t.id) === pick)
  const follow = async (id: bigint, on: boolean) => {
    const r = await send(on ? 'Follow template' : 'Stop following', { address: s.address, abi: bucketAbi, functionName: 'followTemplate', args: [id, on] })
    if (r) await refresh()
  }
  return (
    <div className="space-y-3 text-sm">
      {s.follow.templateId === NO_TEMPLATE ? (
        <p className="text-muted">Custom targets; not linked to a template.</p>
      ) : (
        <div className="rounded-xl border border-line p-3">
          <p>
            {linked?.name ?? `Template #${s.follow.templateId}`} <span className="font-mono text-xs text-muted">v{s.follow.version}</span>
            {s.follow.following ? <span className="badge ml-2 bg-up/15 text-up">Following</span> : <span className="badge ml-2 bg-panel2 text-muted">Not following</span>}
          </p>
          {linked && s.follow.following && linked.version > s.follow.version && (
            <p className="mt-1 text-xs text-warn">v{linked.version} is published; the next rebalance adopts it.</p>
          )}
          <div className="mt-2">
            {s.follow.following ? (
              <button className="btn-ghost h-9" disabled={pending !== null} onClick={act(() => follow(s.follow.templateId, false))}>Stop following</button>
            ) : (
              <button className="btn-ghost h-9" disabled={pending !== null} onClick={act(() => follow(s.follow.templateId, true))}>Follow again (replaces targets)</button>
            )}
          </div>
        </div>
      )}
      <div className="flex flex-col gap-2 sm:flex-row">
        <select className="field" aria-label="Template" value={pick} onChange={(e) => setPick(e.target.value)}>
          <option value="">Follow a different template…</option>
          {templates?.map((t) => <option key={String(t.id)} value={String(t.id)}>{t.name} · band {bps(t.bandBps)}</option>)}
        </select>
        <button className="btn shrink-0" disabled={!chosen || pending !== null} onClick={act(async () => { if (chosen) await follow(chosen.id, true) })}>Follow</button>
      </div>
      <p className="text-xs text-muted">Following replaces your targets with the template's weights now, and adopts new versions at each rebalance. Your rules (band, slippage, trade size, cooldown) stay as set.</p>
    </div>
  )
}

function PauseButton({ s }: { s: BucketState }) {
  const { send, pending } = useTx()
  const refresh = useRefresh()
  return (
    <button
      className={`btn-ghost h-8 text-xs ${s.paused ? 'border-warn/50 text-warn' : ''}`}
      disabled={pending !== null}
      onClick={act(async () => {
        const r = await send(s.paused ? 'Resume bucket' : 'Pause bucket', { address: s.address, abi: bucketAbi, functionName: 'setPaused', args: [!s.paused] })
        if (r) await refresh()
      })}
      title="Paused buckets can't be rebalanced and SIP runs are blocked; deposits and withdrawals still work"
    >
      {s.paused ? 'Resume' : 'Pause'}
    </button>
  )
}

function Panel<T extends string>({ title, tabs, aside, render }: { title: string; tabs: readonly T[]; aside?: ReactNode; render: (t: T) => ReactNode }) {
  const [tab, setTab] = useState<T>(tabs[0])
  return (
    <section className="card min-w-0 p-4 sm:p-5">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-semibold">{title}</h2>
        {aside}
      </div>
      <div className="mb-4 grid gap-1 rounded-xl bg-panel2 p-1" style={{ gridTemplateColumns: `repeat(${tabs.length}, minmax(0, 1fr))` }} role="tablist">
        {tabs.map((t) => (
          <button key={t} type="button" role="tab" aria-selected={tab === t} className={`min-h-[36px] rounded-lg px-2 text-sm transition ${tab === t ? 'bg-panel font-medium text-ink shadow-sm' : 'text-muted hover:text-ink'}`} onClick={() => setTab(t)}>{t}</button>
        ))}
      </div>
      {render(tab)}
    </section>
  )
}

/** Owner funds: deposit USDC / withdraw any holding. */
export function FundsPanel({ s, assets }: { s: BucketState; assets: ListedAsset[] | undefined }) {
  return <Panel title="Funds" tabs={['Deposit', 'Withdraw'] as const} render={(t) => (t === 'Deposit' ? <Deposit s={s} /> : <Withdraw s={s} assets={assets} />)} />
}

/** Owner settings: targets, guardrails, template following, pause. */
export function SettingsPanel({ s, assets }: { s: BucketState; assets: ListedAsset[] | undefined }) {
  return (
    <Panel
      title="Settings"
      tabs={['Targets', 'Guardrails', 'Template'] as const}
      aside={<PauseButton s={s} />}
      render={(t) =>
        t === 'Targets' ? <Targets key={s.targets.tokens.join() + s.targets.weights.join()} s={s} assets={assets} /> : t === 'Guardrails' ? <Rules key={JSON.stringify(s.params)} s={s} /> : <TemplateTab s={s} />
      }
    />
  )
}

export function OwnerPanel({ s, assets }: { s: BucketState; assets: ListedAsset[] | undefined }) {
  return (
    <div className="space-y-4">
      <FundsPanel s={s} assets={assets} />
      <SettingsPanel s={s} assets={assets} />
    </div>
  )
}
