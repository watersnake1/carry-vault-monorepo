"use client";

import { useEffect, useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { formatEther, formatUnits } from "viem";
import Link from "next/link";
import VaultAbi from "@/abi/VaultCore.json";
import { VAULT_ADDRESS } from "@/lib/wagmi";

const VAULT_LEVEL = ["NORMAL", "STRESS", "EMERGENCY", "WINDDOWN"];
const LIFECYCLE = ["NONE", "OPEN", "REPAYING", "CLOSED", "FORCE_CLOSED"];

// Stub HYPE/USDC price for V1 (matches OracleLayer default)
const HYPE_PRICE_USDC = 40;

type UserView = {
  position: {
    user: `0x${string}`;
    openedAt: bigint;
    hypeDeposit: bigint;
    allocationSplitBps: number;
    reserveSplitBps: number;
    profile: number;
    termMonths: number;
    perpMarketId: `0x${string}`;
    hyperLendDebtUsd: bigint;
    perpMarginWithdrawnUsd: bigint;
    spotReserveBalance: bigint;
    smoothingReserveBalance: bigint;
    creditBalance: bigint;
    state: number;
  };
  shares: bigint;
  pendingWithdrawalShares: bigint;
  withdrawalUnlockAt: bigint;
  hasPendingWithdrawal: boolean;
};

type VaultView = { level: number };

export default function DashboardPage() {
  const { address, isConnected } = useAccount();

  const [now, setNow] = useState(Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);

  const { data: userView } = useReadContract({
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

  if (!isConnected) {
    return (
      <div className="border border-zinc-800 rounded-lg p-8 text-center text-zinc-400">
        Connect your wallet to view your dashboard.
      </div>
    );
  }

  const view = userView as UserView | undefined;
  const vault = vaultView as VaultView | undefined;

  if (!view || !vault) return <div className="text-zinc-400">Loading…</div>;

  const isOpen = view.position.state === 1;

  // -- No position state --
  if (!isOpen && !view.hasPendingWithdrawal) {
    return (
      <div className="space-y-6 max-w-3xl">
        <h2 className="text-2xl font-semibold">Dashboard</h2>
        <div className="border border-zinc-800 rounded-lg p-8 text-center space-y-4">
          <p className="text-zinc-400">You don&apos;t have an open position yet.</p>
          <Link
            href="/deposit"
            className="inline-block px-6 py-2 rounded-lg bg-emerald-500 text-emerald-950 font-medium"
          >
            Open a Position
          </Link>
        </div>
      </div>
    );
  }

  // -- Derived metrics --
  const depositUsd = Number(formatEther(view.position.hypeDeposit)) * HYPE_PRICE_USDC;
  const debtUsd = Number(formatUnits(view.position.hyperLendDebtUsd, 6));
  const ltv = depositUsd > 0 ? (debtUsd / depositUsd) * 100 : 0;
  const totalUsdRecovered =
    Number(formatUnits(view.position.hyperLendDebtUsd, 6)) +
    Number(formatUnits(view.position.perpMarginWithdrawnUsd, 6));

  const unlockAt = Number(view.withdrawalUnlockAt);
  const isUnlocked = view.hasPendingWithdrawal && now >= unlockAt;
  const secondsRemaining = view.hasPendingWithdrawal
    ? Math.max(0, unlockAt - now)
    : 0;

  return (
    <div className="space-y-8 max-w-4xl">
      {/* Header */}
      <div className="flex items-end justify-between">
        <div>
          <h2 className="text-2xl font-semibold mb-1">Dashboard</h2>
          <p className="text-sm text-zinc-400">
            Vault state:{" "}
            <span className={vaultStateColor(vault.level)}>
              {VAULT_LEVEL[vault.level]}
            </span>{" "}
            • Profile:{" "}
            <span className="text-zinc-300">
              {view.position.profile === 0 ? "Conservative" : "Risky"}
            </span>{" "}
            • Term: {view.position.termMonths}mo
          </p>
        </div>
        <div className="flex gap-2">
          <Link
            href="/withdraw"
            className="px-4 py-2 rounded-lg border border-zinc-700 hover:bg-zinc-900 text-sm"
          >
            Withdraw
          </Link>
          <Link
            href="/deposit"
            className="px-4 py-2 rounded-lg bg-zinc-100 text-zinc-900 text-sm font-medium"
          >
            Deposit
          </Link>
        </div>
      </div>

      {/* Headline cards */}
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <Stat
          label="Deposited"
          value={`${formatEther(view.position.hypeDeposit)} HYPE`}
          sub={`~$${depositUsd.toFixed(2)}`}
        />
        <Stat
          label="USDC Borrowed"
          value={`$${totalUsdRecovered.toFixed(2)}`}
          sub={`HyperLend $${debtUsd.toFixed(2)} + Perp $${(totalUsdRecovered - debtUsd).toFixed(2)}`}
        />
        <Stat
          label="Shares"
          value={formatEther(view.shares + view.pendingWithdrawalShares)}
          sub={view.hasPendingWithdrawal ? "incl. queued" : ""}
        />
      </div>

      {/* Pending withdrawal callout */}
      {view.hasPendingWithdrawal && (
        <div className="border border-amber-900 bg-amber-950/40 rounded-lg p-4 space-y-2">
          <h3 className="text-sm text-amber-400">Withdrawal Queued</h3>
          <p className="text-xs text-amber-300/80">
            {isUnlocked
              ? "Ready to fulfill — visit Withdraw to settle."
              : `Unlocks in ${formatDuration(secondsRemaining)}.`}
          </p>
          <Row
            label="Queued Shares"
            value={formatEther(view.pendingWithdrawalShares)}
          />
        </div>
      )}

      {/* Position breakdown */}
      <div className="border border-zinc-800 rounded-lg p-5 space-y-3">
        <h3 className="text-sm text-zinc-400 mb-2">Position Breakdown</h3>
        <Row
          label="HyperLend Debt"
          value={`${formatUnits(view.position.hyperLendDebtUsd, 6)} USDC`}
        />
        <Row
          label="Perp Margin Withdrawn"
          value={`${formatUnits(view.position.perpMarginWithdrawnUsd, 6)} USDC`}
        />
        <Row
          label="Spot Reserve"
          value={`${formatEther(view.position.spotReserveBalance)} HYPE`}
        />
        <Row
          label="Smoothing Reserve"
          value={`${formatUnits(view.position.smoothingReserveBalance, 6)} USDC`}
        />
        <Row
          label="Credit Balance"
          value={`${formatUnits(view.position.creditBalance, 6)} USDC`}
        />
        <Row
          label="Allocation"
          value={`${view.position.allocationSplitBps / 100}% lending / ${(10000 - view.position.allocationSplitBps) / 100}% perp`}
        />
        <Row
          label="Reserve Split"
          value={`${view.position.reserveSplitBps / 100}%`}
        />
      </div>

      {/* Health bar (LTV-based, simple V1) */}
      <div className="border border-zinc-800 rounded-lg p-5 space-y-3">
        <div className="flex justify-between items-center">
          <h3 className="text-sm text-zinc-400">HyperLend LTV</h3>
          <span className={ltvColor(ltv, view.position.profile)}>
            {ltv.toFixed(1)}%
          </span>
        </div>
        <ProgressBar
          value={ltv}
          target={view.position.profile === 0 ? 30 : 50}
          max={view.position.profile === 0 ? 60 : 80}
        />
        <p className="text-xs text-zinc-500">
          Target {view.position.profile === 0 ? "30%" : "50%"}, liquidation around{" "}
          {view.position.profile === 0 ? "60%" : "80%"}.
        </p>
      </div>

      <p className="text-xs text-zinc-600">
        Note: Using stub HYPE price of ${HYPE_PRICE_USDC}. Live prices will be
        sourced from OracleLayer once integrated.
      </p>
    </div>
  );
}

function Stat({
  label,
  value,
  sub,
}: {
  label: string;
  value: string;
  sub?: string;
}) {
  return (
    <div className="border border-zinc-800 rounded-lg p-4">
      <div className="text-xs text-zinc-500 mb-1">{label}</div>
      <div className="text-lg font-medium">{value}</div>
      {sub && <div className="text-xs text-zinc-500 mt-1">{sub}</div>}
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between text-sm">
      <span className="text-zinc-500">{label}</span>
      <span className="font-mono">{value}</span>
    </div>
  );
}

function ProgressBar({
  value,
  target,
  max,
}: {
  value: number;
  target: number;
  max: number;
}) {
  const pct = Math.min(100, (value / max) * 100);
  const targetPct = (target / max) * 100;

  return (
    <div className="relative h-2 bg-zinc-800 rounded-full overflow-hidden">
      <div
        className={`h-full ${
          value < target * 0.9
            ? "bg-emerald-500"
            : value < target * 1.1
            ? "bg-amber-500"
            : "bg-red-500"
        }`}
        style={{ width: `${pct}%` }}
      />
      <div
        className="absolute top-0 bottom-0 w-px bg-zinc-300"
        style={{ left: `${targetPct}%` }}
      />
    </div>
  );
}

function ltvColor(ltv: number, profile: number) {
  const target = profile === 0 ? 30 : 50;
  if (ltv < target * 0.9) return "text-emerald-400";
  if (ltv < target * 1.1) return "text-amber-400";
  return "text-red-400";
}

function vaultStateColor(level: number) {
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

function formatDuration(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return `${h}h ${m}m ${s}s`;
}