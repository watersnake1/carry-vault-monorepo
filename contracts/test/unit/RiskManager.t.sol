// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { Test }        from "forge-std/Test.sol";
import { RiskManager } from "../../src/core/RiskManager.sol";
import { ERC20 }           from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { PositionManager } from "../../src/core/PositionManager.sol";
import { OracleLayer }     from "../../src/core/OracleLayer.sol";

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract RiskManagerTest is Test {

    RiskManager internal rm;
    address internal admin = address(this);
    address internal user  = address(0xBE);

    address internal vaultCoreAddr       = address(0x1);
    address internal positionManagerAddr = address(0x2);
    address internal oracleLayerAddr     = address(0x3);

    PositionManager internal pm;
    OracleLayer     internal oracle;
    MockToken       internal hype;
    MockToken       internal usdc;
    address         internal vaultCore = address(0xCA11);

    bytes32 internal constant WTI = keccak256("WTI-USDC");

    function setUp() public {
        hype   = new MockToken("HYPE", "HYPE");
        usdc   = new MockToken("USDC", "USDC");
        oracle = new OracleLayer(address(0xA));

        pm = new PositionManager(address(oracle), address(hype), address(usdc));
        rm = new RiskManager(address(pm), address(oracle));

        pm.initialize(vaultCore, address(rm));
        rm.initialize(vaultCore);

        hype.mint(vaultCore, 1000 ether);
        vm.prank(vaultCore);
        hype.approve(address(pm), type(uint256).max);

        vm.mockCall(
            vaultCore,
            abi.encodeWithSignature("getUserRiskProfile(address)"),
            abi.encode(uint8(0))
        );
    }

    /* ─── Constructor and immutables ─── */

    function test_constructorSetsImmutableRefs() public {
        assertEq(rm.vaultCore(),       vaultCore);
        assertEq(rm.positionManager(), address(pm));
        assertEq(rm.oracleLayer(),     address(oracle));
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(RiskManager.ZeroAddress.selector);
        new RiskManager(address(0), address(oracle));

        vm.expectRevert(RiskManager.ZeroAddress.selector);
        new RiskManager(vaultCoreAddr, address(0));

        //vm.expectRevert(RiskManager.ZeroAddress.selector);
        //new RiskManager(vaultCoreAddr, positionManagerAddr, address(0));
    }

    function test_initializeRejectsZero() public {
        RiskManager fresh = new RiskManager(address(pm), address(oracle));
        vm.expectRevert(RiskManager.ZeroAddress.selector);
        fresh.initialize(address(0));
    }

    function test_initializeRejectsDouble() public {
        vm.expectRevert(RiskManager.AlreadyInitialized.selector);
        rm.initialize(vaultCore);
    }

    /* ─── Profile parameters ─── */

    function test_conservativeProfileDefaults() public {
        RiskManager.ProfileParams memory p = rm.getProfileParams(0);
        assertEq(p.hyperLendTargetLtvBps,        3000);
        assertEq(p.hyperLendAutoDeleverageBps,   4500);
        assertEq(p.hyperLendHardLiquidationBps,  5500);
        assertEq(p.perpEffectiveLeverageBps,     50000);
        assertEq(p.liquidationDistanceFloorBps,  1500);
        assertEq(p.liquidationDistanceStageABps, 2000);
        assertEq(p.reserveSplitBps,              1500);
        assertEq(p.cascadeTriggerHealthBps,      10500);
        assertEq(p.safeHealthTargetBps,          12000);
    }

    function test_riskyProfileDefaults() public {
        RiskManager.ProfileParams memory p = rm.getProfileParams(1);
        assertEq(p.hyperLendTargetLtvBps,        5000);
        assertEq(p.hyperLendAutoDeleverageBps,   6000);
        assertEq(p.hyperLendHardLiquidationBps,  6500);
        assertEq(p.perpEffectiveLeverageBps,     100000);
        assertEq(p.liquidationDistanceFloorBps,  800);
        assertEq(p.reserveSplitBps,              500);
    }

    function test_individualGettersMatchStruct() public {
        assertEq(rm.getPerpLeverageForProfile(0),    50000);
        assertEq(rm.getPerpLeverageForProfile(1),    100000);
        assertEq(rm.getReserveSplitForProfile(0),    1500);
        assertEq(rm.getReserveSplitForProfile(1),    500);
        assertEq(rm.getHyperLendTargetLtv(0),        3000);
        assertEq(rm.getHyperLendTargetLtv(1),        5000);
    }

    function test_unknownProfileReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RiskManager.UnknownProfile.selector, uint8(2)));
        rm.getProfileParams(2);

        vm.expectRevert(abi.encodeWithSelector(RiskManager.UnknownProfile.selector, uint8(255)));
        rm.getPerpLeverageForProfile(255);
    }

    /* ─── setProfileParams ─── */

    function test_setProfileParamsHappyPath() public {
        RiskManager.ProfileParams memory updated = RiskManager.ProfileParams({
            hyperLendTargetLtvBps:        3500,
            hyperLendAutoDeleverageBps:   5000,
            hyperLendHardLiquidationBps:  5800,
            perpEffectiveLeverageBps:     60000,
            liquidationDistanceFloorBps:  1300,
            liquidationDistanceStageABps: 1800,
            reserveSplitBps:              1700,
            cascadeTriggerHealthBps:      11000,
            safeHealthTargetBps:          12500
        });
        rm.setProfileParams(0, updated);

        RiskManager.ProfileParams memory readback = rm.getProfileParams(0);
        assertEq(readback.hyperLendTargetLtvBps,    3500);
        assertEq(readback.perpEffectiveLeverageBps, 60000);
        assertEq(readback.cascadeTriggerHealthBps,  11000);
    }

    function test_setProfileParamsRejectsNonMonotonicHyperLend() public {
        RiskManager.ProfileParams memory bad = _validParams();
        bad.hyperLendAutoDeleverageBps = bad.hyperLendTargetLtvBps;  // not strictly greater
        vm.expectRevert(RiskManager.InvalidProfileParams.selector);
        rm.setProfileParams(0, bad);
    }

    function test_setProfileParamsRejectsNonMonotonicCascade() public {
        RiskManager.ProfileParams memory bad = _validParams();
        bad.safeHealthTargetBps = bad.cascadeTriggerHealthBps;  // not strictly greater
        vm.expectRevert(RiskManager.InvalidProfileParams.selector);
        rm.setProfileParams(0, bad);
    }

    function test_setProfileParamsRejectsZeroLeverage() public {
        RiskManager.ProfileParams memory bad = _validParams();
        bad.perpEffectiveLeverageBps = 0;
        vm.expectRevert(RiskManager.InvalidProfileParams.selector);
        rm.setProfileParams(0, bad);
    }

    function test_setProfileParamsOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();   // OZ AccessControl reverts
        rm.setProfileParams(0, _validParams());
    }

    function test_setProfileParamsRejectsUnknownProfile() public {
        vm.expectRevert(abi.encodeWithSelector(RiskManager.UnknownProfile.selector, uint8(2)));
        rm.setProfileParams(2, _validParams());
    }

    /* ─── LTV / health views (stubs) ─── */

    function _openConservativePosition() internal {
        vm.startPrank(vaultCore);
        pm.supplyToHyperLendAndBorrow(user, 63.75 ether, 3000);
        pm.openPerpLegAndExtractMargin(user, WTI, 21.25 ether, 50000);
        vm.stopPrank();
    }

    function _seedWtiOracle(uint16 mmBps) internal {
        uint16 imBps = mmBps + 500 <= 10000 ? mmBps + 500 : 10000;
        require(imBps > mmBps, "test setup: MM too high");
        oracle.updateMarketData(WTI, 70 * 1e18, int256(24e12), imBps, mmBps, 1_000_000 * 1e18);    
    }

    /* ─────────── hyperLendLtv ─────────── */

    function test_hyperLendLtvWithoutPosition() public {
        assertEq(rm.hyperLendLtv(user), 0);
    }

    function test_hyperLendLtvAfterDeposit() public {
        _openConservativePosition();
        // 765e6 debt / 2550e6 collateral = 3000 BPS (30%)
        assertEq(rm.hyperLendLtv(user), 3000);
    }

    function test_hyperLendLtvAtRiskyTarget() public {
        // 71.25 HYPE supply at 50% LTV → debt 1425e6, collateral 2850e6 → 5000 BPS
        vm.prank(vaultCore);
        pm.supplyToHyperLendAndBorrow(user, 71.25 ether, 5000);
        assertEq(rm.hyperLendLtv(user), 5000);
    }

    /* ─────────── perpEffectiveLeverage ─────────── */

    function test_perpEffectiveLeverageWithoutPosition() public {
        assertEq(rm.perpEffectiveLeverage(user), 0);
    }

    function test_perpEffectiveLeverageAfterDeposit() public {
        _openConservativePosition();
        // 1700e6 notional / 340e6 margin = 50000 BPS (5x)
        assertEq(rm.perpEffectiveLeverage(user), 50000);
    }

    function test_perpEffectiveLeverageRiskyDeposit() public {
        // 23.75 HYPE → margin $950, target 10x → notional 1900e6, margin retained 190e6
        vm.prank(vaultCore);
        pm.openPerpLegAndExtractMargin(user, WTI, 23.75 ether, 100000);
        assertEq(rm.perpEffectiveLeverage(user), 100000);
    }

    /* ─────────── perpLiquidationDistance ─────────── */

    function test_perpLiquidationDistanceWithoutPosition() public {
        assertEq(rm.perpLiquidationDistance(user), 0);
    }

    function test_perpLiquidationDistanceWithoutOracleSeed() public {
        _openConservativePosition();
        // MM = 0 (oracle not seeded). distance = margin/notional = 340/1700 = 2000 BPS
        assertEq(rm.perpLiquidationDistance(user), 2000);
    }

    function test_perpLiquidationDistanceWithMm() public {
        _openConservativePosition();
        _seedWtiOracle(500);   // MM = 5%
        // mmReq = 1700 * 500/10000 = 85; safety = 340 - 85 = 255
        // distance = 255 * 10000 / 1700 = 1500 BPS (15%)
        assertEq(rm.perpLiquidationDistance(user), 1500);
    }

    function test_perpLiquidationDistanceMarginBelowMmReturnsZero() public {
        _openConservativePosition();
        _seedWtiOracle(2500);   // MM = 25% → mmReq = 425 > margin (340)
        assertEq(rm.perpLiquidationDistance(user), 0);
    }

    /* ─────────── combinedHealth / requiresCascade ─────────── */

    function test_combinedHealthSafeWithRealData() public {
        _openConservativePosition();
        // No oracle seed → MM = 0 → distance = 2000
        // lendHealth = 5500*10000/3000 = 18333; perpHealth = 2000*10000/1500 = 13333
        // combinedHealth = min = 13333 (above cascadeTrigger 10500 → safe)
        uint256 health = rm.combinedHealth(user);
        assertEq(health, 13333);
        assertFalse(rm.requiresCascade(user));
    }

    function test_combinedHealthAtFloorWithMm() public {
        _openConservativePosition();
        _seedWtiOracle(500);   // MM = 5% → distance = 1500 = floor
        // perpHealth = 1500 * 10000 / 1500 = 10000 (= 1.0)
        // lendHealth = 18333
        // combinedHealth = 10000 → below cascadeTrigger (10500) → cascade required
        assertEq(rm.combinedHealth(user), 10000);
        assertTrue(rm.requiresCascade(user));
    }

    function test_getHealthSnapshotProducesAllMetrics() public {
        _openConservativePosition();
        _seedWtiOracle(500);

        (
            uint256 ltv,
            uint256 lev,
            uint256 dist,
            uint256 health,
            bool    cascade
        ) = rm.getHealthSnapshot(user);

        assertEq(ltv,    3000);
        assertEq(lev,    50000);
        assertEq(dist,   1500);
        assertEq(health, 10000);
        assertTrue(cascade);
    }


    /* ─── Helper ─── */

    function _validParams() internal pure returns (RiskManager.ProfileParams memory) {
        return RiskManager.ProfileParams({
            hyperLendTargetLtvBps:        3000,
            hyperLendAutoDeleverageBps:   4500,
            hyperLendHardLiquidationBps:  5500,
            perpEffectiveLeverageBps:     50000,
            liquidationDistanceFloorBps:  1500,
            liquidationDistanceStageABps: 2000,
            reserveSplitBps:              1500,
            cascadeTriggerHealthBps:      10500,
            safeHealthTargetBps:          12000
        });
    }
}