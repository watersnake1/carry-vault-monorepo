// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { Test }            from "forge-std/Test.sol";
import { ERC20 }           from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { VaultCore }       from "../../src/core/VaultCore.sol";
import { RiskManager }     from "../../src/core/RiskManager.sol";
import { PositionManager } from "../../src/core/PositionManager.sol";
import { OracleLayer }     from "../../src/core/OracleLayer.sol";
import { YieldRouter }     from "../../src/core/YieldRouter.sol";
import { StrategyEngine }  from "../../src/core/StrategyEngine.sol";

contract MockHype is ERC20 {
    constructor() ERC20("Mock HYPE", "HYPE") {}
}

contract CascadeTest is Test {

    VaultCore       internal vault;
    RiskManager     internal rm;
    PositionManager internal pm;
    OracleLayer     internal oracle;
    YieldRouter     internal yr;
    StrategyEngine  internal se;
    MockHype        internal hype;
    MockHype        internal usdc;

    address internal admin   = address(this);
    address internal keeper  = address(0xCAFE);
    bytes32 internal constant WTI = keccak256("WTI-USDC");

    function setUp() public {
        hype   = new MockHype();
        usdc   = new MockHype();
        oracle = new OracleLayer(address(0xA));

        pm = new PositionManager(address(oracle), address(hype), address(usdc));
        rm = new RiskManager(address(pm), address(oracle));
        yr = new YieldRouter(address(pm));
        se = new StrategyEngine(address(0x1), address(pm), address(oracle), address(rm), address(this));

        vault = new VaultCore(hype, usdc, address(se), address(pm), address(rm), address(yr), address(oracle), address(this));

        pm.initialize(address(vault), address(rm));
        yr.initialize(address(vault));
        rm.initialize(address(vault));
        rm.grantRole(rm.KEEPER_ROLE(), keeper);

        // Open a Conservative position so cascade has something to act on
        deal(address(hype), address(this), 100 ether);
        hype.approve(address(vault), type(uint256).max);
        vault.depositWithProfile(100 ether, 7500, VaultCore.RiskProfile.CONSERVATIVE, 12);
    }

    function _seedWtiOracle(uint16 mmBps) internal {
        uint16 imBps = mmBps + 500 <= 10000 ? mmBps + 500 : 10000;
        oracle.updateMarketData(WTI, 70 * 1e18, int256(24e12), imBps, mmBps, 1_000_000 * 1e18);
    }

    /* ─────────── Cascade scenarios ─────────── */

    function test_cascadeNoOpWhenHealthy() public {
        // No oracle seed → MM = 0 → distance = 2000 BPS → above floor (1500). Healthy.
        assertFalse(rm.requiresCascade(address(this)));

        vm.prank(keeper);
        rm.executeCascade(address(this));

        // Position state unchanged
        ( , , , , , , , , , , uint256 spot, , , VaultCore.LifecycleState state) =
            vault.positions(address(this));
        assertEq(uint8(state), uint8(VaultCore.LifecycleState.OPEN));
        assertEq(spot,         15 ether,                              "spot reserve untouched");
    }

    function test_cascadeStageARecoversWithSufficientReserve() public {
        // MM = 15% drives distance to floor (1500). Stage A should add USDC
        // until distance recovers above floor.
        _seedWtiOracle(1500);

        // Pre-cascade: distance = 500 BPS, well below floor
        assertEq(rm.perpLiquidationDistance(address(this)), 500);

        vm.prank(keeper);
        rm.executeCascade(address(this));

        // Position remains open; perp distance recovered
        ( , , , , , , , , , , uint256 spot, , , VaultCore.LifecycleState state) =
            vault.positions(address(this));
        assertEq(uint8(state), uint8(VaultCore.LifecycleState.OPEN));
        assertLt(spot,         15 ether,                              "spot reserve drawn down");
        assertGt(rm.perpLiquidationDistance(address(this)), 1500,     "perp distance above floor");
    }

    function test_cascadeStageBExecutesWhenReserveDrained() public {
        // Drain spot reserve manually before cascade so Stage A can't help.
        vm.prank(address(rm));
        vault.updateSpotReserve(address(this), 0);

        _seedWtiOracle(1500);   // perp unsafe

        vm.prank(keeper);
        rm.executeCascade(address(this));

        // Stage B should have closed perp size at least once. Position still open
        // (Stage B can recover perp without lending issues).
        ( , , , , , , , , , uint256 perpDebt, , , , VaultCore.LifecycleState state) =
            vault.positions(address(this));
        assertEq(uint8(state), uint8(VaultCore.LifecycleState.OPEN));
        // Perp notional is reduced (not necessarily to 0)
        assertLt(pm.getPerpNotionalUsd(address(this)), 1700e6);
    }

    function test_cascadeStageCForceClosesWhenLendingUnhealthy() public {
        vm.prank(address(rm));
        vault.updateSpotReserve(address(this), 0);

        // Force RM's view of HyperLend debt to look unhealthy
        vm.mockCall(
            address(pm),
            abi.encodeWithSignature("getHyperLendDebt(address)", address(this)),
            abi.encode(uint256(2400e6))
        );

        assertTrue(rm.requiresCascade(address(this)));

        vm.prank(keeper);
        rm.executeCascade(address(this));

        ( , , , , , , , , uint256 debt, , , , , VaultCore.LifecycleState state) =
            vault.positions(address(this));

        assertEq(uint8(state), uint8(VaultCore.LifecycleState.FORCE_CLOSED));
        assertEq(debt,         0);
        assertEq(vault.balanceOf(address(this)), 0);
        assertFalse(yr.registered(address(this)));
    }

    function test_cascadeOnlyAuthorized() public {
        _seedWtiOracle(1500);
        // Random caller (not vaultCore, not keeper) should be rejected
        vm.expectRevert(abi.encodeWithSelector(
            RiskManager.UnauthorizedCaller.selector, address(0xBAD)
        ));
        vm.prank(address(0xBAD));
        rm.executeCascade(address(this));
    }

    /* ─────────── rebalance() ─────────── */

    function test_rebalanceTriggersCascadeForUnhealthyUser() public {
        _seedWtiOracle(1500);   // perp distance below floor → cascade required
        assertTrue(rm.requiresCascade(address(this)));

        // Advance past the rate-limit interval set in setUp
        vm.warp(block.timestamp + 61);

        vault.rebalance();

        // Cascade Stage A should have replenished margin and pushed perp distance
        // above the safe target. Position stays OPEN, reserve drawn down.
        ( , , , , , , , , , , uint256 spot, , , VaultCore.LifecycleState state) =
            vault.positions(address(this));
        assertEq(uint8(state), uint8(VaultCore.LifecycleState.OPEN));
        assertLt(spot,         15 ether);
    }

    function test_rebalanceNoOpsWhenAllHealthy() public {
        // No oracle seed → MM = 0 → distance well above floor → no cascade needed
        vm.warp(block.timestamp + 61);

        uint256 spotBefore;
        ( , , , , , , , , , , spotBefore, , ,) = vault.positions(address(this));

        vault.rebalance();

        ( , , , , , , , , , , uint256 spotAfter, , , VaultCore.LifecycleState state) =
            vault.positions(address(this));
        assertEq(uint8(state), uint8(VaultCore.LifecycleState.OPEN));
        assertEq(spotAfter,    spotBefore);
    }

    function test_rebalanceRateLimited() public {
        // First call within MIN_REBALANCE_INTERVAL is a silent no-op.
        // setUp already set lastRebalance recently (during deposit's flow),
        // so calling immediately should not advance it.
        uint64 lastBefore;
        (, , , lastBefore, , ) = vault.vaultState();

        vault.rebalance();

        uint64 lastAfter;
        (, , , lastAfter, , ) = vault.vaultState();

        assertEq(lastAfter, lastBefore, "rate-limited; lastRebalance unchanged");
    }

    function test_rebalanceUpdatesLastRebalance() public {
        vm.warp(block.timestamp + 61);
        vault.rebalance();

        uint64 lastAfter;
        (, , , lastAfter, , ) = vault.vaultState();
        assertEq(lastAfter, uint64(block.timestamp));
    }

    function test_rebalanceForceCloseRemovesAndContinues() public {
        // Set up the existing user so Stage C will fire (mock high HyperLend debt).
        vm.prank(address(rm));
        vault.updateSpotReserve(address(this), 0);

        vm.mockCall(
            address(pm),
            abi.encodeWithSignature("getHyperLendDebt(address)", address(this)),
            abi.encode(uint256(2400e6))
        );

        // Add a second healthy user to verify the iteration continues after the
        // first one gets force-closed.
        address user2 = address(0xBEE);
        deal(address(hype), user2, 50 ether);
        vm.startPrank(user2);
        hype.approve(address(vault), type(uint256).max);
        vault.depositWithProfile(50 ether, 7500, VaultCore.RiskProfile.CONSERVATIVE, 12);
        vm.stopPrank();

        assertEq(vault.activeUsers(0), address(this));
        assertEq(vault.activeUsers(1), user2);

        vm.warp(block.timestamp + 61);
        vault.rebalance();

        // First user force-closed
        ( , , , , , , , , , , , , , VaultCore.LifecycleState s1) = vault.positions(address(this));
        assertEq(uint8(s1), uint8(VaultCore.LifecycleState.FORCE_CLOSED));

        // Second user untouched (healthy)
        ( , , , , , , , , , , , , , VaultCore.LifecycleState s2) = vault.positions(user2);
        assertEq(uint8(s2), uint8(VaultCore.LifecycleState.OPEN));

        // Active users now contains only user2
        assertEq(vault.activeUsers(0), user2);
    }

    function test_rebalancePermissionlessAnyCaller() public {
        vm.warp(block.timestamp + 61);
        vm.prank(address(0xBAD));
        vault.rebalance();

        // No revert; just verify lastRebalance advanced
        uint64 lastAfter;
        (, , , lastAfter, , ) = vault.vaultState();
        assertEq(lastAfter, uint64(block.timestamp));
    }

}