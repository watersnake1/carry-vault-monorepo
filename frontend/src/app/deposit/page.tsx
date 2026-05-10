"use client";

import { useEffect, useState } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { parseEther, formatEther, erc20Abi } from "viem";
import VaultAbi from "@/abi/VaultCore.json";
import { VAULT_ADDRESS, HYPE_ADDRESS } from "@/lib/wagmi";

enum RiskProfile {
  CONSERVATIVE = 0,
  RISKY = 1,
}

export default function DepositPage() {
  const { address, isConnected } = useAccount();

  // Form state
  const [amount, setAmount] = useState("");
  const [profile, setProfile] = useState<RiskProfile>(RiskProfile.CONSERVATIVE);
  const [allocationSplit, setAllocationSplit] = useState(7500); // bps
  const [term, setTerm] = useState(12);

  // Read user's HYPE balance
  const { data: balance, refetch: refetchBalance } = useReadContract({
    address: HYPE_ADDRESS,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  // Read current allowance
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: HYPE_ADDRESS,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, VAULT_ADDRESS] : undefined,
    query: { enabled: !!address },
  });

  // Read user's existing position (to block double-open)
  const { data: position, refetch: refetchPosition } = useReadContract({
    address: VAULT_ADDRESS,
    abi: VaultAbi,
    functionName: "getUserPosition",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  // Write hooks
  const {
    writeContract: writeApprove,
    data: approveHash,
    isPending: approvePending,
    error: approveError,
  } = useWriteContract();

  const {
    writeContract: writeDeposit,
    data: depositHash,
    isPending: depositPending,
    error: depositError,
  } = useWriteContract();

  // Wait for transactions
  const { isLoading: approveConfirming, isSuccess: approveSuccess } =
    useWaitForTransactionReceipt({ hash: approveHash });
  const { isLoading: depositConfirming, isSuccess: depositSuccess } =
    useWaitForTransactionReceipt({ hash: depositHash });

  const amountWei = amount && Number(amount) > 0 ? parseEther(amount) : 0n;
  const balanceBig = (balance as bigint) ?? 0n;
  const allowanceBig = (allowance as bigint) ?? 0n;
  const needsApproval = amountWei > 0n && allowanceBig < amountWei;
  const insufficientBalance = amountWei > balanceBig;
  //const hasOpenPosition =
    //position && (position as { state: number }).state === 1; // 1 = OPEN
  const hasOpenPosition = Boolean(
    position && (position as { state: number }).state === 1
    );

  // Refetch on success
  useEffect(() => {
    if (approveSuccess) refetchAllowance();
  }, [approveSuccess, refetchAllowance]);

  useEffect(() => {
    if (depositSuccess) {
      refetchBalance();
      refetchAllowance();
      refetchPosition();
      setAmount("");
    }
  }, [depositSuccess, refetchBalance, refetchAllowance, refetchPosition]);

  // Preview math (mirror VaultCore's splits)
  const reserveBps = profile === RiskProfile.CONSERVATIVE ? 1500 : 500;
  const spotReserve = (amountWei * BigInt(reserveBps)) / 10000n;
  const allocatable = amountWei - spotReserve;
  const lendingLeg = (allocatable * BigInt(allocationSplit)) / 10000n;
  const perpLeg = allocatable - lendingLeg;

  const handleApprove = () => {
    writeApprove({
      address: HYPE_ADDRESS,
      abi: erc20Abi,
      functionName: "approve",
      args: [VAULT_ADDRESS, amountWei],
    });
  };

  const handleDeposit = () => {
    writeDeposit({
      address: VAULT_ADDRESS,
      abi: VaultAbi as never,
      functionName: "depositWithProfile",
      args: [amountWei, allocationSplit, profile, term],
    });
  };

  if (!isConnected) {
    return (
      <div className="border border-zinc-800 rounded-lg p-8 text-center text-zinc-400">
        Connect your wallet to deposit.
      </div>
    );
  }

  return (
    <div className="space-y-8 max-w-2xl">
      <div>
        <h2 className="text-2xl font-semibold mb-1">Deposit</h2>
        <p className="text-sm text-zinc-400">
          Open a position. Choose a risk profile and allocation split.
        </p>
      </div>

      {hasOpenPosition && (
        <div className="border border-amber-900 bg-amber-950/40 rounded-lg p-4 text-amber-300 text-sm">
          You already have an open position. Repay or fulfill withdrawal before
          opening a new one.
        </div>
      )}

      {/* Amount */}
      <div className="space-y-2">
        <div className="flex justify-between text-sm">
          <label className="text-zinc-400">Amount</label>
          <button
            onClick={() => setAmount(formatEther(balanceBig))}
            className="text-zinc-500 hover:text-zinc-300"
          >
            Balance: {formatEther(balanceBig)} HYPE (max)
          </button>
        </div>
        <div className="flex items-center border border-zinc-800 rounded-lg px-4 py-3 focus-within:border-zinc-600">
          <input
            type="number"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="0.0"
            min="0"
            step="0.01"
            className="bg-transparent flex-1 outline-none text-lg"
          />
          <span className="text-zinc-500 text-sm">HYPE</span>
        </div>
        {insufficientBalance && (
          <p className="text-sm text-red-400">Insufficient balance</p>
        )}
      </div>

      {/* Risk Profile */}
      <div className="space-y-2">
        <label className="text-sm text-zinc-400">Risk Profile</label>
        <div className="grid grid-cols-2 gap-3">
          <ProfileButton
            active={profile === RiskProfile.CONSERVATIVE}
            onClick={() => setProfile(RiskProfile.CONSERVATIVE)}
            title="Conservative"
            subtitle="5x lev • 30% LTV • 15% reserve"
          />
          <ProfileButton
            active={profile === RiskProfile.RISKY}
            onClick={() => setProfile(RiskProfile.RISKY)}
            title="Risky"
            subtitle="10x lev • 50% LTV • 5% reserve"
          />
        </div>
      </div>

      {/* Allocation Split */}
      <div className="space-y-2">
        <div className="flex justify-between text-sm">
          <label className="text-zinc-400">Allocation Split</label>
          <span className="text-zinc-300">
            {allocationSplit / 100}% lending /{" "}
            {(10000 - allocationSplit) / 100}% perp
          </span>
        </div>
        <input
          type="range"
          min="1000"
          max="9000"
          step="500"
          value={allocationSplit}
          onChange={(e) => setAllocationSplit(Number(e.target.value))}
          className="w-full accent-zinc-500"
        />
      </div>

      {/* Term */}
      <div className="space-y-2">
        <div className="flex justify-between text-sm">
          <label className="text-zinc-400">Term</label>
          <span className="text-zinc-300">{term} months</span>
        </div>
        <input
          type="range"
          min="1"
          max="24"
          step="1"
          value={term}
          onChange={(e) => setTerm(Number(e.target.value))}
          className="w-full accent-zinc-500"
        />
      </div>

      {/* Preview */}
      {amountWei > 0n && (
        <div className="border border-zinc-800 rounded-lg p-4 space-y-2">
          <h3 className="text-sm text-zinc-400 mb-3">Preview</h3>
          <PreviewRow label="Spot Reserve" value={`${formatEther(spotReserve)} HYPE`} />
          <PreviewRow label="Lending Leg" value={`${formatEther(lendingLeg)} HYPE`} />
          <PreviewRow label="Perp Leg" value={`${formatEther(perpLeg)} HYPE`} />
        </div>
      )}

      {/* Action Buttons */}
      <div className="space-y-3">
        {needsApproval ? (
          <button
            onClick={handleApprove}
            disabled={
              approvePending ||
              approveConfirming ||
              insufficientBalance ||
              hasOpenPosition ||
              amountWei === 0n
            }
            className="w-full py-3 rounded-lg bg-zinc-100 text-zinc-900 font-medium disabled:bg-zinc-800 disabled:text-zinc-500"
          >
            {approvePending
              ? "Confirming in wallet…"
              : approveConfirming
              ? "Approving…"
              : `Approve ${amount || "0"} HYPE`}
          </button>
        ) : (
          <button
            onClick={handleDeposit}
            disabled={
              depositPending ||
              depositConfirming ||
              insufficientBalance ||
              hasOpenPosition ||
              amountWei === 0n
            }
            className="w-full py-3 rounded-lg bg-emerald-500 text-emerald-950 font-medium disabled:bg-zinc-800 disabled:text-zinc-500"
          >
            {depositPending
              ? "Confirming in wallet…"
              : depositConfirming
              ? "Depositing…"
              : "Deposit"}
          </button>
        )}

        {(approveError || depositError) && (
          <div className="border border-red-900 bg-red-950/40 rounded-lg p-3 text-red-300 text-xs">
            {(approveError || depositError)?.message}
          </div>
        )}

        {depositSuccess && (
          <div className="border border-emerald-900 bg-emerald-950/40 rounded-lg p-3 text-emerald-300 text-sm">
            Position opened. Check the Dashboard.
          </div>
        )}
      </div>
    </div>
  );
}

function ProfileButton({
  active,
  onClick,
  title,
  subtitle,
}: {
  active: boolean;
  onClick: () => void;
  title: string;
  subtitle: string;
}) {
  return (
    <button
      onClick={onClick}
      className={`text-left p-4 rounded-lg border ${
        active
          ? "border-zinc-300 bg-zinc-900"
          : "border-zinc-800 hover:border-zinc-700"
      }`}
    >
      <div className="font-medium">{title}</div>
      <div className="text-xs text-zinc-500 mt-1">{subtitle}</div>
    </button>
  );
}

function PreviewRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between text-sm">
      <span className="text-zinc-500">{label}</span>
      <span>{value}</span>
    </div>
  );
}