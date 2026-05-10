
import { ethers } from "ethers";
import { Hyperliquid } from "hyperliquid";

const DRY_RUN = (process.env.DRY_RUN ?? "true").toLowerCase() !== "false";
const PRIVATE_KEY = process.env.PRIVATE_KEY;
if (!PRIVATE_KEY) throw new Error("Set PRIVATE_KEY env var.");

const HYPEREVM_RPC  = "https://rpc.hyperliquid.xyz/evm";
const HYPERCORE_API = "https://api.hyperliquid.xyz";

// addresses that will be interacted with onchain
const ADDR = {
  HYPE:             "0x5555555555555555555555555555555555555555",
  USDC:             "0xb88339cb7199b77e23db6e890353e22632ba630f",
  HyperLend_Pool:   "0x00A89d7a5A02160f20150EbEA7a2b5E4879A1A8b",
  HyperSwap_Router: "0x4E2960a8cd19B467b82d26D83fAcb0fAE26b094D",
};

// Strategy parameters - these will be more mutable in production
const PARAMS = {
  perpMarket:        "WTIOIL-USDC",   // using oil for now; other assets or a combination later
  perpSide:          "short",         // capture positive funding
  splitToHyperLend:  0.75,            // 75% to spot lending
  splitToPerp:       0.25,            // 25% to perp margin
  hyperLendTargetLTV:0.30,            // 30% Conservative
  initialLeverage:   5,               // open at 5x
  targetLeverage:    20,              // re-leverage to extract margin
  swapSlippageBps:   50,              // 0.5%
};

const HYPE_DECIMALS = 18;
const USDC_DECIMALS = 6;

// ─────────────────────────────────────────────────────────────────────────
// Setup
// ─────────────────────────────────────────────────────────────────────────

const provider = new ethers.JsonRpcProvider(HYPEREVM_RPC);
const wallet   = new ethers.Wallet(PRIVATE_KEY, provider);
const hl = new Hyperliquid({
  privateKey: PRIVATE_KEY,
  testnet: false,          
});
const log = (...a) => console.log("[carry-vault-c]", ...a);
const dry = (label, payload) => log(`${DRY_RUN ? "DRY" : "SEND"} ${label}:`, JSON.stringify(payload, null, 2)); // if DRY is true nothing is broadcast to the hyperliquid exchange

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
];

const HYPERLEND_ABI = [
  "function supply(address asset, uint256 amount, address onBehalfOf, uint16 ref)",
  "function borrow(address asset, uint256 amount, uint256 mode, uint16 ref, address onBehalfOf)",
  "function getUserAccountData(address user) view returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor)",
];

const HYPERSWAP_ABI = [
  "function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] path, address to, uint deadline) returns (uint[] amounts)",
];

// ─────────────────────────────────────────────────────────────────────────
// Step 1: HyperLend supply + borrow
// ─────────────────────────────────────────────────────────────────────────

async function supplyAndBorrow(hypeAmount) {
  const hype = new ethers.Contract(ADDR.HYPE, ERC20_ABI, wallet);
  const pool = new ethers.Contract(ADDR.HyperLend_Pool, HYPERLEND_ABI, wallet);

  dry("approve HYPE → HyperLend", { amount: hypeAmount.toString() });
  if (!DRY_RUN) await (await hype.approve(ADDR.HyperLend_Pool, hypeAmount)).wait();

  dry("HyperLend.supply", { amount: hypeAmount.toString() });
  if (!DRY_RUN) await (await pool.supply(ADDR.HYPE, hypeAmount, wallet.address, 0)).wait();

  // Compute target borrow: 30% LTV against the supplied collateral
  const hypeUsd = 40; // this is for the purpose of simplicity in this example, normally we would read from api / oracle
  const collateralUsd = (Number(hypeAmount) / 1e18) * hypeUsd;
  const targetBorrowUsd = collateralUsd * PARAMS.hyperLendTargetLTV;
  const borrowUsdc = ethers.parseUnits(targetBorrowUsd.toFixed(6), USDC_DECIMALS);

  dry("HyperLend.borrow USDC", { amount: borrowUsdc.toString(), targetUsd: targetBorrowUsd });
  if (!DRY_RUN) await (await pool.borrow(ADDR.USDC, borrowUsdc, 2, 0, wallet.address)).wait();

  return borrowUsdc;
}

// ─────────────────────────────────────────────────────────────────────────
// Step 2: Convert HYPE → USDC for perp margin
// ─────────────────────────────────────────────────────────────────────────

async function swapHypeToUsdc(hypeAmount) {
  const hype   = new ethers.Contract(ADDR.HYPE, ERC20_ABI, wallet);
  const router = new ethers.Contract(ADDR.HyperSwap_Router, HYPERSWAP_ABI, wallet);

  dry("approve HYPE → HyperSwap", { amount: hypeAmount.toString() });
  if (!DRY_RUN) await (await hype.approve(ADDR.HyperSwap_Router, hypeAmount)).wait();

  // Compute min-out with slippage tolerance
  const hypeUsd = 40; // see above
  const expectedUsdc = (Number(hypeAmount) / 1e18) * hypeUsd;
  const minOutUsdc = ethers.parseUnits(
    (expectedUsdc * (1 - PARAMS.swapSlippageBps / 10000)).toFixed(6),
    USDC_DECIMALS
  );

  dry("HyperSwap HYPE→USDC", { amountIn: hypeAmount.toString(), minOut: minOutUsdc.toString() });
  if (!DRY_RUN) {
    const tx = await router.swapExactTokensForTokens(
      hypeAmount, minOutUsdc, [ADDR.HYPE, ADDR.USDC],
      wallet.address, Math.floor(Date.now() / 1000) + 300
    );
    await tx.wait();
  }
  return ethers.parseUnits(expectedUsdc.toFixed(6), USDC_DECIMALS); // approximate; read on-chain in real impl
}

// ─────────────────────────────────────────────────────────────────────────
// Step 3: Move USDC to HyperCore perp margin account
// ─────────────────────────────────────────────────────────────────────────

async function depositToPerpMargin(usdcAmount) {
  // Hyperliquid uses a "send to perp" bridge from the EVM-side USDC to the
  // HyperCore perp account. Mechanism: signed transfer via Hyperliquid SDK.
  dry("Hyperliquid usdClassTransfer (spot → perp)", { amount: usdcAmount.toString() });
  if (DRY_RUN) return;

  await hl.exchange.usdClassTransfer({ amount: usdcAmount, toPerp: true });
  //throw new Error("Wire Hyperliquid SDK for usdClassTransfer here");
}

// ─────────────────────────────────────────────────────────────────────────
// Step 4: Open WTI short at initial leverage
// ─────────────────────────────────────────────────────────────────────────

async function openPerpShort(market, marginUsdc, leverage) {
  const notionalUsd = (Number(marginUsdc) / 1e6) * leverage;

  // Fetch market mark price for the order
  const res = await fetch(`${HYPERCORE_API}/info`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ type: "metaAndAssetCtxs" }),
  });
  const [meta, ctxs] = await res.json();
  const i = meta.universe.findIndex(u => `${u.name}-USDC` === market || u.name === market);
  if (i < 0) throw new Error(`Market not found: ${market}`);
  const markPx = parseFloat(ctxs[i].markPx);
  const sz = notionalUsd / markPx;

  const order = {
    coin:      meta.universe[i].name,
    is_buy:    false,                     // SHORT
    sz:        Number(sz.toFixed(meta.universe[i].szDecimals)),
    limit_px:  markPx * 0.995,            // 50bp slippage tolerance
    order_type:{ limit: { tif: "Ioc" } },
    reduce_only: false,
    leverage:  leverage,
  };

  dry("Hyperliquid placeOrder (open short)", order);
  if (DRY_RUN) return { sz, notionalUsd, markPx };

  await hl.exchange.updateLeverage(meta.universe[i].name, leverage, false);
  await hl.exchange.placeOrder(order);
  //throw new Error("Wire Hyperliquid SDK for placeOrder here");
}

// ─────────────────────────────────────────────────────────────────────────
// Step 5: Adjust leverage to 20x (frees margin)
// ─────────────────────────────────────────────────────────────────────────

async function adjustLeverage(market, newLeverage) {
  dry("Hyperliquid updateLeverage", { market, newLeverage });
  if (DRY_RUN) return;
  await hl.exchange.updateLeverage(market, newLeverage, /*isCross*/ false);
  //throw new Error("Wire Hyperliquid SDK for updateLeverage here");
}

// ─────────────────────────────────────────────────────────────────────────
// Step 6: Withdraw freed margin from perp account back to spot
// ─────────────────────────────────────────────────────────────────────────

async function withdrawFromPerpMargin(usdcAmount) {
  dry("Hyperliquid usdClassTransfer (perp → spot)", { amount: usdcAmount.toString() });
  if (DRY_RUN) return;
  await hl.exchange.usdClassTransfer({ amount: usdcAmount, toPerp: false });
  //throw new Error("Wire Hyperliquid SDK for usdClassTransfer here");
}

async function main() {
  log(`Mode: ${DRY_RUN ? "DRY_RUN" : "LIVE"}`);
  log(`Wallet: ${wallet.address}`);

  const hype = new ethers.Contract(ADDR.HYPE, ERC20_ABI, provider);
  let hypeBalance;
  try {
    hypeBalance = await hype.balanceOf(wallet.address);
  } catch {
    throw new Error("Balance read failed.")
  }
  log(`Starting HYPE: ${ethers.formatUnits(hypeBalance, HYPE_DECIMALS)}`);

  // Compute split sizes
  const toHyperLend = (hypeBalance * BigInt(Math.floor(PARAMS.splitToHyperLend * 10000))) / 10000n;
  const toPerp      = hypeBalance - toHyperLend;
  log(`Allocation: HyperLend=${ethers.formatUnits(toHyperLend, 18)} HYPE, Perp=${ethers.formatUnits(toPerp, 18)} HYPE`);

  // Step 1: HyperLend supply + borrow
  const usdcFromHyperLend = await supplyAndBorrow(toHyperLend);
  log(`USDC from HyperLend: ${ethers.formatUnits(usdcFromHyperLend, USDC_DECIMALS)}`);

  // Step 2: Convert remaining HYPE to USDC for perp margin
  const usdcForMargin = await swapHypeToUsdc(toPerp);
  log(`USDC available for perp margin: ${ethers.formatUnits(usdcForMargin, USDC_DECIMALS)}`);

  // Step 3: Move USDC to HyperCore perp account
  await depositToPerpMargin(usdcForMargin);

  // Step 4: Open initial 5x WTI short
  const perpResult = await openPerpShort(PARAMS.perpMarket, usdcForMargin, PARAMS.initialLeverage);
  log(`Perp opened: ${PARAMS.perpMarket} short, sz=${perpResult.sz}, notional=$${perpResult.notionalUsd.toFixed(2)}`);

  // Step 5: Adjust leverage to 20x to free margin
  await adjustLeverage(PARAMS.perpMarket, PARAMS.targetLeverage);

  // Step 6: Compute and withdraw freed margin
  // Equity stays at usdcForMargin; new IM = notional / 20 = notional × 5%
  // Free = equity − new IM
  const notionalUsd = (Number(usdcForMargin) / 1e6) * PARAMS.initialLeverage;
  const newImUsd    = notionalUsd / PARAMS.targetLeverage;
  const freeMarginUsd = (Number(usdcForMargin) / 1e6) - newImUsd;
  const withdrawableUsdc = ethers.parseUnits(freeMarginUsd.toFixed(6), USDC_DECIMALS);
  log(`Free margin after re-leverage: $${freeMarginUsd.toFixed(2)}`);

  await withdrawFromPerpMargin(withdrawableUsdc);

  // Summary
  const totalUsdcOut = usdcFromHyperLend + withdrawableUsdc;
  log(`─────────────────────────────────────────────`);
  log(`Total USDC delivered to user: ${ethers.formatUnits(totalUsdcOut, USDC_DECIMALS)}`);
  log(`  HyperLend loan:         ${ethers.formatUnits(usdcFromHyperLend, USDC_DECIMALS)}`);
  log(`  Margin withdrawal:      ${ethers.formatUnits(withdrawableUsdc, USDC_DECIMALS)}`);
  log(`Open perp position: ${PARAMS.perpMarket} short, ~20x effective leverage`);
  log(`⚠️  Liquidation at ~5% adverse move. Monitor continuously.`);
}

main().catch(e => { console.error(e); process.exit(1); });