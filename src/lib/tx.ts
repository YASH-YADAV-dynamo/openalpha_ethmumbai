// One way to send transactions: switches to Arc Testnet if needed, enforces the 20 gwei fee floor,
// waits for the receipt (sub-second finality on Arc) and toasts the explorer link.
import { useCallback, useState } from 'react'
import { useAccount, usePublicClient, useSwitchChain, useWalletClient } from 'wagmi'
import { arcTestnet } from 'viem/chains'
import { parseGwei, type Abi } from 'viem'
import { toast } from 'sonner'
import { txUrl } from './format'

export const FEES = { maxFeePerGas: parseGwei('40'), maxPriorityFeePerGas: parseGwei('2') } // Arc floor is 20 gwei

type WriteReq = { address: `0x${string}`; abi: Abi | readonly unknown[]; functionName: string; args?: readonly unknown[] }

export function useTx() {
  const { address, chainId } = useAccount()
  const { data: wallet } = useWalletClient()
  const client = usePublicClient({ chainId: arcTestnet.id })
  const { switchChainAsync } = useSwitchChain()
  const [pending, setPending] = useState<string | null>(null)

  const send = useCallback(
    async (label: string, req: WriteReq) => {
      if (!wallet || !address || !client) { toast.error('Connect a wallet first'); return null }
      setPending(label)
      const id = toast.loading(`${label}…`)
      try {
        if (chainId !== arcTestnet.id) await switchChainAsync({ chainId: arcTestnet.id })
        // simulate first so reverts show a readable reason before the wallet pops up
        const { request } = await client.simulateContract({ ...(req as object), account: address } as never)
        const hash = await wallet.writeContract({ ...(request as object), ...FEES } as never)
        const r = await client.waitForTransactionReceipt({ hash })
        if (r.status !== 'success') throw new Error('Transaction reverted')
        toast.success(label, { id, description: 'Confirmed on Arc Testnet', action: { label: 'View', onClick: () => window.open(txUrl(hash), '_blank') } })
        return r
      } catch (e) {
        const msg = (e as { shortMessage?: string; message?: string }).shortMessage ?? (e as Error).message ?? 'Failed'
        toast.error(label, { id, description: msg.slice(0, 180) })
        return null
      } finally {
        setPending(null)
      }
    },
    [wallet, address, client, chainId, switchChainAsync],
  )
  return { send, pending, ready: Boolean(wallet && address) }
}
