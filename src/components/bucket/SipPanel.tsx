// Recurring USDC buys (SIP). setSip needs the bucket approved for amount × runs of the owner's USDC;
// each run pulls `amount` from the owner's wallet, so balance and allowance must still be there when it runs.
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { useQueryClient } from '@tanstack/react-query'
import { erc20Abi } from 'viem'
import { ADDR, bucketAbi } from '@/lib/contracts'
import { amt, usd } from '@/lib/format'
import { useTx } from '@/lib/tx'
import { BOUNDS, dateTime, duration, sipDue, until, useNow, useUsdc, type BucketState } from './data'
import { RunSipButton } from './BucketCard'
import { parseAmount } from './OwnerPanel'
import { Notice, Section, act } from './ui'

const INTERVALS = [
  { label: 'Daily', sec: 86_400 },
  { label: 'Weekly', sec: 604_800 },
  { label: 'Monthly', sec: 2_592_000 }, // 30 days
] as const

export function SipPanel({ s, isOwner }: { s: BucketState; isOwner: boolean }) {
  const now = useNow()
  const { address } = useAccount()
  const usdc = useUsdc(s.owner, s.address)
  const { send, pending } = useTx()
  const qc = useQueryClient()
  const [v, setV] = useState('')
  const [every, setEvery] = useState<number>(INTERVALS[1].sec)
  const [runs, setRuns] = useState('12')

  const active = s.sip.active && s.sip.runsLeft > 0
  const n = parseAmount(v, 6)
  const r = Number(runs)
  const runsOk = Number.isInteger(r) && r >= BOUNDS.runs[0] && r <= BOUNDS.runs[1]
  const need = n !== null && runsOk ? n * BigInt(r) : null
  const allowance = usdc.data?.allowance
  const approved = need !== null && allowance !== undefined && allowance >= need
  const refresh = () => qc.invalidateQueries({ queryKey: ['bucket'] })

  // Funding check for the active schedule (executeSip reverts without it).
  const underfunded = active && usdc.data && (usdc.data.balance < s.sip.amount || usdc.data.allowance < s.sip.amount)

  return (
    <Section title="SIP · auto-invest" aside={active ? <span className="badge bg-up/15 text-up">Active</span> : <span className="badge bg-panel2 text-muted">Off</span>}>
      {active ? (
        <dl className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
          <div><dt className="eyebrow">Amount</dt><dd className="num mt-0.5 font-mono">{usd(Number(s.sip.amount) / 1e6)}</dd></div>
          <div><dt className="eyebrow">Every</dt><dd className="num mt-0.5 font-mono">{duration(s.sip.interval)}</dd></div>
          <div><dt className="eyebrow">Runs left</dt><dd className="num mt-0.5 font-mono">{s.sip.runsLeft}</dd></div>
          <div>
            <dt className="eyebrow">Next run</dt>
            <dd className="num mt-0.5 font-mono" title={dateTime(s.sip.nextAt)}>{now >= s.sip.nextAt ? 'Due now' : until(s.sip.nextAt, now)}</dd>
          </div>
        </dl>
      ) : (
        <p className="text-sm text-muted">No recurring buy scheduled.</p>
      )}

      <dl className="mt-3 grid grid-cols-1 gap-x-4 gap-y-1.5 rounded-xl border border-line bg-panel2/40 p-3 text-xs sm:grid-cols-3">
        <div className="flex justify-between gap-2 sm:block">
          <dt className="text-muted">Owner wallet USDC</dt>
          <dd className="num font-mono sm:mt-0.5">{usdc.data ? `${amt(usdc.data.balance, 6)}` : '—'}</dd>
        </div>
        <div className="flex justify-between gap-2 sm:block">
          <dt className="text-muted">Approved to bucket</dt>
          <dd className="num font-mono sm:mt-0.5">{usdc.data ? `${amt(usdc.data.allowance, 6)}` : '—'}</dd>
        </div>
        <div className="flex justify-between gap-2 sm:block">
          <dt className="text-muted">Needed for runs left</dt>
          <dd className={`num font-mono sm:mt-0.5 ${active && usdc.data && usdc.data.allowance < s.sip.amount * BigInt(s.sip.runsLeft) ? 'text-warn' : ''}`}>
            {active ? amt(s.sip.amount * BigInt(s.sip.runsLeft), 6) : '—'}
          </dd>
        </div>
      </dl>

      {active && (
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <RunSipButton s={s} />
          {active && !sipDue(s, now) && <span className="text-xs text-muted">{s.paused ? 'Paused: runs are blocked.' : `Anyone can run it from ${dateTime(s.sip.nextAt)}.`}</span>}
          {isOwner && (
            <button
              className="btn-ghost ml-auto h-9"
              disabled={pending !== null}
              onClick={act(async () => { if (await send('Cancel SIP', { address: s.address, abi: bucketAbi, functionName: 'cancelSip' })) await refresh() })}
            >
              Cancel SIP
            </button>
          )}
        </div>
      )}
      {underfunded && <div className="mt-3"><Notice tone="warn">The owner's wallet USDC balance or approval is below one run ({usd(Number(s.sip.amount) / 1e6)}); the next run will revert until it's topped up.</Notice></div>}

      {isOwner && (
        <div className="mt-4 space-y-3 border-t border-line pt-4">
          <p className="text-sm font-medium">{active ? 'Replace schedule' : 'Set up'}</p>
          <div className="grid gap-3 sm:grid-cols-3">
            <label className="block text-xs text-muted">
              Amount per run (USDC)
              <input className="field num mt-1 font-mono" inputMode="decimal" placeholder="25" value={v} onChange={(e) => setV(e.target.value)} />
            </label>
            <div className="text-xs text-muted">
              Every
              <div className="mt-1 flex gap-1" role="radiogroup" aria-label="Interval">
                {INTERVALS.map((i) => (
                  <button key={i.sec} type="button" role="radio" aria-checked={every === i.sec} className={`tab flex-1 border border-line px-2 ${every === i.sec ? 'tab-on' : ''}`} onClick={() => setEvery(i.sec)}>{i.label}</button>
                ))}
              </div>
            </div>
            <label className="block text-xs text-muted">
              Runs (1–520)
              <input className="field num mt-1 font-mono" inputMode="numeric" value={runs} onChange={(e) => setRuns(e.target.value.replace(/\D/g, ''))} />
            </label>
          </div>
          {!runsOk && runs !== '' && <p className="text-xs text-down">Runs must be between 1 and 520.</p>}
          <p className="text-xs text-muted">
            Total approval: <span className="num font-mono text-ink">{need === null ? '—' : `${amt(need, 6)} USDC`}</span> · current approval{' '}
            <span className="num font-mono">{allowance === undefined ? '—' : `${amt(allowance, 6)} USDC`}</span>. First run is one interval after you start. Each run buys your targets with the amount (skipping assets marked No buys).
          </p>
          <div className="flex flex-col gap-2 sm:flex-row">
            <button
              className={approved ? 'btn-ghost flex-1' : 'btn flex-1'}
              disabled={need === null || approved || pending !== null || !address}
              onClick={act(async () => { if (await send('Approve SIP USDC', { address: ADDR.usdc, abi: erc20Abi, functionName: 'approve', args: [s.address, need!] })) await usdc.refetch() })}
            >
              1. {approved ? 'Approved' : 'Approve USDC'}
            </button>
            <button
              className="btn flex-1"
              disabled={!approved || pending !== null}
              onClick={act(async () => {
                if (await send('Start SIP', { address: s.address, abi: bucketAbi, functionName: 'setSip', args: [n!, every, r] })) { setV(''); await refresh() }
              })}
            >
              2. {active ? 'Replace SIP' : 'Start SIP'}
            </button>
          </div>
        </div>
      )}
    </Section>
  )
}
