// Surfaces the real wallet-connect error (instead of ConnectKit's generic "connection failed"), plus a
// new-tab escape hatch when the app runs inside the Arc Studio preview iframe, where extensions often block.
import { useState } from 'react'
import { useMutationState } from '@tanstack/react-query'
import { ExternalLink, TriangleAlert, X } from 'lucide-react'

const IN_IFRAME = (() => {
  try {
    return window.self !== window.top
  } catch {
    return true // cross-origin parent: we are framed
  }
})()

type WalletError = { name?: string; shortMessage?: string; message?: string; code?: number; cause?: unknown }

/** Readable wallet error text; keeps the wallet's own message when we don't have a better one. */
export function connectErrorText(e: unknown): string {
  const err = (e ?? {}) as WalletError
  const code = err.code ?? (err.cause as WalletError | undefined)?.code
  if (code === 4001 || err.name === 'UserRejectedRequestError') return 'Request rejected in your wallet.'
  if (code === -32002) return 'Your wallet already has a pending request. Open the extension to approve or reject it.'
  if (err.name === 'ProviderNotFoundError' || err.name === 'ConnectorNotFoundError') return 'No browser wallet found. Install or enable a wallet extension.'
  return err.shortMessage || err.message || 'Wallet connection failed.'
}

export function ConnectNotice() {
  // wagmi's useConnect (used inside ConnectKit) runs as a react-query mutation keyed ['connect'] on our QueryClient.
  const attempts = useMutationState({
    filters: { mutationKey: ['connect'] },
    select: (m) => ({ status: m.state.status, error: m.state.error, at: m.state.submittedAt }),
  })
  const [dismissed, setDismissed] = useState(0)
  const last = attempts[attempts.length - 1]
  if (!last || last.status !== 'error' || last.at === dismissed) return null

  return (
    <div role="alert" className="border-b border-warn/30 bg-warn/10">
      <div className="mx-auto flex max-w-[1600px] items-start gap-2 px-4 py-2 text-xs text-ink">
        <TriangleAlert size={14} className="mt-0.5 shrink-0 text-warn" />
        <div className="min-w-0 flex-1 space-y-0.5">
          <p className="break-words">
            <span className="font-semibold">Wallet didn't connect:</span> {connectErrorText(last.error)}
          </p>
          {IN_IFRAME && (
            <p className="text-muted">
              Wallet extensions can block connections inside the Studio preview.{' '}
              <a href={window.location.href} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-0.5 font-semibold text-accent hover:underline">
                Open the app in a new tab <ExternalLink size={11} />
              </a>
            </p>
          )}
        </div>
        <button type="button" onClick={() => setDismissed(last.at)} aria-label="Dismiss" className="-m-1 inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-lg text-muted hover:bg-panel2 hover:text-ink">
          <X size={14} />
        </button>
      </div>
    </div>
  )
}
