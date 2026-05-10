"use client";

import { useReadContract } from "wagmi";
import { formatEther, formatUnits } from "viem";
import VaultAbi from "@/abi/VaultCore.json";
import { VAULT_ADDRESS } from "@/lib/wagmi";
import { useHypePrice, useMarketData } from "@/lib/usePrices";

const VAULT_STATE_LABELS = ["NORMAL", "STRESS", "EMERGENCY", "WINDDOWN"];

console.log("Chain config:", {
  USE_ANVIL: process.env.NEXT_PUBLIC_USE_ANVIL,
  vault: VAULT_ADDRESS,
});

export default function StatsPage() {
  const { data, isLoading, error } = useReadContract({
    address: VAULT_ADDRESS,
    abi: VaultAbi,
    functionName: "getVaultView",
    query: { refetchInterval: 10_000 },
  });
  const { priceUsd: hypePrice } = useHypePrice();
  const btc = useMarketData("BTC");
  const eth = useMarketData("ETH");

  if (isLoading) return <Loading />;
  if (error)     return <ErrorBox message={error.message} />;
  if (!data)     return <ErrorBox message="No data returned" />;

  const view = data as {
    level: number;
    totalAssetsHype: bigint;
    totalSharesIssued: bigint;
    activeUsersCount: bigint;
    accumulatedProtocolFees: bigint;
    depositsEnabled: boolean;
    isPaused: boolean;
    strategyEngine: `0x${string}`;
    positionManager: `0x${string}`;
    riskManager: `0x${string}`;
    yieldRouter: `0x${string}`;
  };

  return (
    <div className="space-y-8">
      <div>
        <h2 className="text-2xl font-semibold mb-1">Vault Stats</h2>
        <p className="text-sm text-zinc-400">Live protocol metrics. Refreshes every 10s.</p>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <Stat label="Vault State" value={VAULT_STATE_LABELS[view.level]} accent={stateColor(view.level)} />
        <Stat label="Active Users" value={view.activeUsersCount.toString()} />
        <Stat label="Total HYPE NAV" value={`${formatEther(view.totalAssetsHype)} HYPE`} />
        <Stat label="Total Shares" value={formatEther(view.totalSharesIssued)} />
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Stat label="Protocol Fees Accrued" value={`${formatUnits(view.accumulatedProtocolFees, 6)} USDC`} />
        <Stat
          label="Status Flags"
          value={`${view.depositsEnabled ? "Deposits ON" : "Deposits OFF"} • ${view.isPaused ? "PAUSED" : "Live"}`}
        />
      </div>
      <div className="border border-zinc-800 rounded-lg p-5 space-y-4">
  <h3 className="text-sm text-zinc-400">Live Market Data</h3>

  <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
      <Stat label="HYPE Spot" value={`$${hypePrice.toFixed(4)}`} />
      {btc.markPrice !== undefined && (
        <Stat
          label="BTC Perp"
          value={`$${btc.markPrice.toFixed(0)}`}
          accent={btc.fundingHourlyPct > 0 ? "text-emerald-400" : "text-red-400"}
        />
      )}
      {eth.markPrice !== undefined && (
        <Stat
          label="ETH Perp"
          value={`$${eth.markPrice.toFixed(2)}`}
          accent={eth.fundingHourlyPct > 0 ? "text-emerald-400" : "text-red-400"}
        />
      )}
    </div>

    {btc.markPrice !== undefined && (
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 text-xs">
        <div className="text-zinc-500">
          BTC funding: <span className="text-zinc-300">{btc.fundingHourlyPct.toFixed(4)}%/h</span>{" "}
          <span className="text-zinc-600">({btc.fundingAnnualPct.toFixed(1)}% annualized)</span>
        </div>
        {eth.markPrice !== undefined && (
          <div className="text-zinc-500">
            ETH funding: <span className="text-zinc-300">{eth.fundingHourlyPct.toFixed(4)}%/h</span>{" "}
            <span className="text-zinc-600">({eth.fundingAnnualPct.toFixed(1)}% annualized)</span>
          </div>
        )}
      </div>
    )}
  </div>
      <div className="border border-zinc-800 rounded-lg p-4 text-xs text-zinc-500 space-y-1">
        <h3 className="text-zinc-400 mb-2 text-sm">Component Addresses</h3>
        <Row label="Strategy"   value={view.strategyEngine} />
        <Row label="Position"   value={view.positionManager} />
        <Row label="Risk"       value={view.riskManager} />
        <Row label="YieldRouter" value={view.yieldRouter} />
      </div>
    </div>
  );
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: string }) {
  return (
    <div className="border border-zinc-800 rounded-lg p-4">
      <div className="text-xs text-zinc-500 mb-1">{label}</div>
      <div className={`text-lg font-medium ${accent ?? ""}`}>{value}</div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between font-mono">
      <span className="text-zinc-500">{label}</span>
      <span>{value}</span>
    </div>
  );
}

function Loading() { return <div className="text-zinc-400">Loading vault stats…</div>; }
function ErrorBox({ message }: { message: string }) {
  return <div className="border border-red-900 bg-red-950/40 rounded-lg p-4 text-red-300 text-sm">Failed to load: {message}</div>;
}

function stateColor(level: number) {
  switch (level) {
    case 0: return "text-emerald-400";
    case 1: return "text-amber-400";
    case 2: return "text-red-400";
    case 3: return "text-zinc-400";
    default: return "";
  }
}