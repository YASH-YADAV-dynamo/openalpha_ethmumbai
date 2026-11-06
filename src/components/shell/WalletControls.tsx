import { ConnectKitButton } from 'connectkit'
import { useAccount, useReadContract, useSwitchChain } from 'wagmi'
import { arcTestnet } from 'viem/chains'
import { erc20Abi, formatUnits } from 'viem'
import { toast } from 'sonner'
import { TriangleAlert, Wallet } from 'lucide-react'
import { ADDR } from '@/lib/contracts'
import { connectErrorText } from './ConnectNotice'

/** Green "Arc Testnet" when on 5042002; amber "Switch network" otherwise (wagmi adds the chain on error 4902). */
export function NetworkPill() {
  const { isConnected, chainId } = useAccount()
  const { switchChain, isPending } = useSwitchChain()
  if (isConnected && chainId !== arcTestnet.id) {
    return (
      <button
        type="button"
        onClick={() => switchChain({ chainId: arcTestnet.id }, { onError: (e) => toast.error(connectErrorText(e)) })}
        disabled={isPending}
        title="Switch to Arc Testnet"
        className="inline-flex h-9 shrink-0 items-center gap-1.5 rounded-xl border border-warn/50 bg-warn/10 px-2.5 text-xs font-semibold text-warn transition hover:bg-warn/20 disabled:opacity-50"
      >
        <TriangleAlert size={14} />
        <span className="hidden sm:inline">{isPending ? 'Switching…' : 'Switch to Arc Testnet'}</span>
        <span className="sm:hidden">{isPending ? '…' : 'Switch'}</span>
      </button>
    )
  }
  return (
    <span
      className="hidden h-9 shrink-0 items-center gap-1.5 rounded-xl border border-line px-2.5 text-xs text-muted sm:inline-flex"
      title={isConnected ? 'Connected to Arc Testnet (5042002)' : 'Arc Testnet (5042002)'}
    >
      <span aria-hidden className={`h-2 w-2 rounded-full ${isConnected ? 'bg-up' : 'bg-faint'}`} />
      Arc Testnet
    </span>
  )
}

/** USDC balance via the 6-decimal ERC-20 interface (never the native 18-decimal balance). */
export function UsdcChip() {
  const { address, chainId } = useAccount()
  const bal = useReadContract({
    address: ADDR.usdc,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    chainId: arcTestnet.id,
    query: { enabled: Boolean(address), refetchInterval: 15_000 },
  })
  if (!address || chainId !== arcTestnet.id) return null
  const n = bal.data === undefined ? null : Number(formatUnits(bal.data, 6))
  return (
    <span className="hidden h-9 shrink-0 items-center gap-1.5 rounded-xl border border-line px-2.5 font-mono text-xs lg:inline-flex" title="USDC balance on Arc Testnet">
      <span className="num text-ink">{n === null ? '—' : n.toLocaleString('en-US', { maximumFractionDigits: 2 })}</span>
      <span className="text-muted">USDC</span>
    </span>
  )
}

export function WalletControls() {
  return (
    <ConnectKitButton.Custom>
      {({ show, isConnected, isConnecting, truncatedAddress, ensName }) => (
        <button
          type="button"
          onClick={show}
          className={isConnected ? 'btn-ghost h-9 min-w-0 max-w-[9.5rem] px-3 font-mono text-xs' : 'btn h-9 shrink-0 px-3'}
        >
          {isConnected ? (
            <span className="truncate">{ensName ?? truncatedAddress}</span>
          ) : (
            <>
              <Wallet size={15} />
              <span>{isConnecting ? 'Connecting…' : 'Connect'}</span>
            </>
          )}
        </button>
      )}
    </ConnectKitButton.Custom>
  )
}
