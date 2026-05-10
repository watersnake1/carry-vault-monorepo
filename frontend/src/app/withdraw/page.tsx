"use client";

import { useEffect, useState } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { formatEther, formatUnits } from "viem";
import VaultAbi from "@/abi/VaultCore.json";
import { VAULT_ADDRESS } from "@/lib/wagmi";

const VAULT_LEVEL = ["NORMAL", "STRESS", "EMERGENCY", "WINDDOWN"];
const LIFECYCLE = { NONE: 0, OPEN: 1, REPAYING: 2, CLOSED: 3, FORCE_CLOSED: 4 };

type UserView = {
  position: {
    state: number;
    hypeDeposit: bigint;
    hyperLendDebtUsd: bigint;
    perpMarginWithdrawnUsd: bigint;
    spotReserveBalance: bigint;
  };
  shares: bigint;
  pendingWithdrawalShares: bigint;
  withdrawalUnlockAt: bigint;
  hasPendingWithdrawal: boolean;
};

type VaultView = {
  level: number;
};

export default function WithdrawPage() {
  const { address, isConnected } = useAccount();

  const [now, setNow] = useState(Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);

  // Reads
  const { data: userView, refetch: refetchUser } = useReadContract({
    address: VAULT_ADDRESS,
    abi: VaultAbi,
    functionName: "getUserView",
    args: address ? [address] : undefined,
    query: { enabled: !!address, refetchInterval: 5000 },
  });

  const { data: vaultView } = useReadContract({
    address: VAULT_ADDRESS,
    abi: VaultAbi,
    functionName: "getVaultView",
    query: { refetchInterval: 5000 },
  });

  // Writes
  const repayTx    = useWriteContract();
  const requestTx  = useWriteContract();
  const fulfillTx  = useWriteContract();
  const cancelTx   = useWriteContract();

  const repayWait    = useWaitForTransactionReceipt({ hash: repayTx.data });
  const requestWait  = useWaitForTransactionReceipt({ hash: requestTx.data });
  const fulfillWait  = useWaitForTransactionReceipt({ hash: fulfillTx.data });
  const cancelWait   = useWaitForTransactionReceipt({ hash: cancelTx.data });

  // Refetch after any success
  useEffect(() => {
    if (
      repayWait.isSuccess ||
      requestWait.isSuccess ||
      fulfillWait.isSuccess ||
      cancelWait.isSuccess
    ) {
      refetchUser();
    }
  }, [
    repayWait.isSuccess,
    requestWait.isSuccess,
    fulfillWait.isSuccess,
    cancelWait.isSuccess,
    refetchUser,
  ]);

  const view = userView as UserView | undefined;
  const vault = vaultView as VaultView | undefined;

  if (!isConnected) {
    return (
      <div className="border border-zinc-800 rounded-lg p-8 text-center text-zinc-400">
        Connect your wallet to withdraw.
      </div>
    );
  }

  if (!view || !vault) {
    return <div className="text-zinc-400">Loading…</div>;
  }

  const isOpen = view.position.state === LIFECYCLE.OPEN;
  const isStress = vault.level === 1 || vault.level === 2;
  const hasPending = view.hasPendingWithdrawal;
  const unlockAt = Number(view.withdrawalUnlockAt);
  const isUnlocked = hasPending && now >= unlockAt;
  const secondsRemaining = hasPending ? Math.max(0, unlockAt - now) : 0;

  // -- No position --
  if (!isOpen && !hasPending) {
    return (
      <div className="space-y-4 max-w-2xl">
        <h2 className="text-2xl font-semibold">Withdraw</h2>
        <div className="border border-zinc-800 rounded-lg p-8 text-center text-zinc-400">
          No active position. Visit the{" "}
          <a href="/deposit" className="text-zinc-100 underline">
            deposit page
          </a>{" "}
          to open one.
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-8 max-w-2xl">
      <div>
        <h2 className="text-2xl font-semibold mb-1">Withdraw</h2>
        <p className="text-sm text-zinc-400">
          Vault is currently <span className={stateColor(vault.level)}>{VAULT_LEVEL[vault.level]}</span>.
        </p>
      </div>

      {/* Position summary */}
      <div className="border border-zinc-800 rounded-lg p-4 space-y-2">
        <h3 className="text-sm text-zinc-400 mb-2">Your Position</h3>
        <Row label="Deposited" value={`${formatEther(view.position.hypeDeposit)} HYPE`} />
        <Row label="Shares" value={formatEther(view.shares + view.pendingWithdrawalShares)} />
        <Row label="HyperLend Debt" value={`${formatUnits(view.position.hyperLendDebtUsd, 6)} USDC`} />
        <Row label="Perp Margin" value={`${formatUnits(view.position.perpMarginWithdrawnUsd, 6)} USDC`} />
        <Row label="Spot Reserve" value={`${formatEther(view.position.spotReserveBalance)} HYPE`} />
      </div>

      {/* Pending withdrawal block */}
      {hasPending ? (
        <div className="border border-amber-900 bg-amber-950/40 rounded-lg p-4 space-y-3">
          <div>
            <h3 className="text-sm text-amber-400 mb-1">Withdrawal Queued</h3>
            <p className="text-xs text-amber-300/80">
              {isUnlocked
                ? "Ready to fulfill — your position will unwind and HYPE will return to your wallet."
                : `Unlocks in ${formatDuration(secondsRemaining)}.`}
            </p>
          </div>
          <Row
            label="Queued Shares"
            value={formatEther(view.pendingWithdrawalShares)}
          />
          <div className="flex gap-3 pt-2">
            <button
              onClick={() =>
                fulfillTx.writeContract({
                  address: VAULT_ADDRESS,
                  abi: VaultAbi as never,
                  functionName: "fulfillWithdraw",
                })
              }
              disabled={!isUnlocked || fulfillTx.isPending || fulfillWait.isLoading}
              className="flex-1 py-3 rounded-lg bg-emerald-500 text-emerald-950 font-medium disabled:bg-zinc-800 disabled:text-zinc-500"
            >
              {fulfillTx.isPending
                ? "Confirming…"
                : fulfillWait.isLoading
                ? "Fulfilling…"
                : isUnlocked
                ? "Fulfill Withdrawal"
                : "Locked"}
            </button>
            <button
              onClick={() =>
                cancelTx.writeContract({
                  address: VAULT_ADDRESS,
                  abi: VaultAbi as never,
                  functionName: "cancelWithdraw",
                })
              }
              disabled={cancelTx.isPending || cancelWait.isLoading}
              className="flex-1 py-3 rounded-lg border border-zinc-700 hover:bg-zinc-900 disabled:opacity-40"
            >
              {cancelTx.isPending
                ? "Confirming…"
                : cancelWait.isLoading
                ? "Cancelling…"
                : "Cancel"}
            </button>
          </div>
        </div>
      ) : isStress ? (
        // -- STRESS: queue request --
        <div className="space-y-3">
          <div className="border border-amber-900 bg-amber-950/40 rounded-lg p-4 text-amber-300/80 text-sm">
            Vault is in stress. Repay is unavailable; instead you can queue a
            withdrawal that settles after a 12-hour delay.
          </div>
          <button
            onClick={() =>
              requestTx.writeContract({
                address: VAULT_ADDRESS,
                abi: VaultAbi as never,
                functionName: "requestWithdraw",
                args: [view.shares],
              })
            }
            disabled={
              view.shares === 0n || requestTx.isPending || requestWait.isLoading
            }
            className="w-full py-3 rounded-lg bg-amber-500 text-amber-950 font-medium disabled:bg-zinc-800 disabled:text-zinc-500"
          >
            {requestTx.isPending
              ? "Confirming…"
              : requestWait.isLoading
              ? "Queueing…"
              : `Queue Withdrawal (${formatEther(view.shares)} shares)`}
          </button>
        </div>
      ) : (
        // -- NORMAL: full repay --
        <div className="space-y-3">
          <div className="border border-zinc-800 rounded-lg p-4 text-zinc-400 text-sm">
            Closing your position will unwind both legs (perp + HyperLend) and
            return your HYPE in a single transaction.
          </div>
          <button
            onClick={() =>
              repayTx.writeContract({
                address: VAULT_ADDRESS,
                abi: VaultAbi as never,
                functionName: "repay",
              })
            }
            disabled={repayTx.isPending || repayWait.isLoading}
            className="w-full py-3 rounded-lg bg-emerald-500 text-emerald-950 font-medium disabled:bg-zinc-800 disabled:text-zinc-500"
          >
            {repayTx.isPending
              ? "Confirming…"
              : repayWait.isLoading
              ? "Repaying…"
              : "Repay & Close Position"}
          </button>
        </div>
      )}

      {/* Errors */}
      {(repayTx.error || requestTx.error || fulfillTx.error || cancelTx.error) && (
        <div className="border border-red-900 bg-red-950/40 rounded-lg p-3 text-red-300 text-xs">
          {(repayTx.error || requestTx.error || fulfillTx.error || cancelTx.error)
            ?.message}
        </div>
      )}
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between text-sm">
      <span className="text-zinc-500">{label}</span>
      <span>{value}</span>
    </div>
  );
}

function formatDuration(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return `${h}h ${m}m ${s}s`;
}

function stateColor(level: number) {
  switch (level) {
    case 0:
      return "text-emerald-400";
    case 1:
      return "text-amber-400";
    case 2:
      return "text-red-400";
    default:
      return "text-zinc-400";
  }
}