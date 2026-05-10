// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { Script, console2 } from "forge-std/Script.sol";

import { VaultCore }       from "../src/core/VaultCore.sol";
import { StrategyEngine }  from "../src/core/StrategyEngine.sol";
import { PositionManager } from "../src/core/PositionManager.sol";
import { RiskManager }     from "../src/core/RiskManager.sol";
import { YieldRouter }     from "../src/core/YieldRouter.sol";
import { OracleLayer }     from "../src/core/OracleLayer.sol";

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock HYPE/USDC for local + testnet deploys. Skip on mainnet.
contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract Deploy is Script {

    struct Deployment {
        address hype;
        address usdc;
        address oracle;
        address positionManager;
        address riskManager;
        address yieldRouter;
        address strategyEngine;
        address vault;
    }

    function run() external returns (Deployment memory d) {
        // ── Inputs ──────────────────────────────────────────────────────────
        // Required env vars:
        //   ADMIN              — receives admin role on every contract
        //   ORACLE_ADMIN       — feeder/admin for OracleLayer
        //   STRATEGY_GOVERNOR  — first arg to StrategyEngine (whitelist admin)
        //   DEPLOY_MOCKS       — "true" to deploy mock HYPE/USDC, else use HYPE/USDC env
        //   HYPE               — HYPE token address (only if DEPLOY_MOCKS != "true")
        //   USDC               — USDC token address (only if DEPLOY_MOCKS != "true")
        // ────────────────────────────────────────────────────────────────────

        address admin            = vm.envAddress("ADMIN");
        address oracleAdmin      = vm.envAddress("ORACLE_ADMIN");
        address strategyGovernor = vm.envAddress("STRATEGY_GOVERNOR");
        bool    deployMocks      = vm.envOr("DEPLOY_MOCKS", false);

        vm.startBroadcast();

        // ── Tokens ──────────────────────────────────────────────────────────
        if (deployMocks) {
            d.hype = address(new MockToken("Mock HYPE", "HYPE"));
            d.usdc = address(new MockToken("Mock USDC", "USDC"));
            console2.log("Deployed Mock HYPE:", d.hype);
            console2.log("Deployed Mock USDC:", d.usdc);
        } else {
            d.hype = vm.envAddress("HYPE");
            d.usdc = vm.envAddress("USDC");
        }

        // ── Oracle (no dependencies) ────────────────────────────────────────
        d.oracle = address(new OracleLayer(oracleAdmin));

        // ── PositionManager (depends on oracle + tokens) ────────────────────
        d.positionManager = address(new PositionManager(d.oracle, d.hype, d.usdc));

        // ── RiskManager (depends on PM + oracle) ────────────────────────────
        d.riskManager = address(new RiskManager(d.positionManager, d.oracle));

        // ── YieldRouter (depends on PM) ─────────────────────────────────────
        d.yieldRouter = address(new YieldRouter(d.positionManager));

        // ── StrategyEngine (depends on PM, oracle, RM) ──────────────────────
        d.strategyEngine = address(new StrategyEngine(
            strategyGovernor,
            d.positionManager,
            d.oracle,
            d.riskManager,
            admin
        ));

        // ── VaultCore (depends on everything) ───────────────────────────────
        d.vault = address(new VaultCore(
            ERC20(d.hype),
            ERC20(d.usdc),
            d.strategyEngine,
            d.positionManager,
            d.riskManager,
            d.yieldRouter,
            d.oracle,
            admin
        ));

        // ── Initialize circular deps ────────────────────────────────────────
        PositionManager(d.positionManager).initialize(d.vault, d.riskManager);
        YieldRouter(d.yieldRouter).initialize(d.vault);
        RiskManager(d.riskManager).initialize(d.vault);

        vm.stopBroadcast();

        // ── Log everything ──────────────────────────────────────────────────
        console2.log("");
        console2.log("=== Carry Vault Deployment ===");
        console2.log("HYPE             :", d.hype);
        console2.log("USDC             :", d.usdc);
        console2.log("OracleLayer      :", d.oracle);
        console2.log("PositionManager  :", d.positionManager);
        console2.log("RiskManager      :", d.riskManager);
        console2.log("YieldRouter      :", d.yieldRouter);
        console2.log("StrategyEngine   :", d.strategyEngine);
        console2.log("VaultCore        :", d.vault);
        console2.log("Admin            :", admin);
    }
}