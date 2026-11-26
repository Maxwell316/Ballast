// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {HookFixture} from "../utils/HookFixture.sol";
import {ConfigFixture} from "../utils/ConfigFixture.sol";
import {BallastStandby} from "../../src/BallastStandby.sol";
import {BallastShares} from "../../src/BallastShares.sol";
import {IBallastErrors} from "../../src/interfaces/IBallastErrors.sol";
import {Range} from "../../src/types/Types.sol";

/// @notice INV-13 / R-ACL-1: a static access-control audit. (1) Every external selector of every production contract
/// is listed here with its caller class; adding or renaming a function fails the test until it is classified.
/// (2) No function name suggests an owner, pauser, upgrade or withdrawal path. (3) Every restricted function rejects a
/// stranger with the expected error.
/// @custom:invariant INV-13
/// @custom:requirement R-ACL-1 R-SBY-7 R-SPLIT-1
contract AccessControlTest is HookFixture {
    address internal constant STRANGER = address(0xBAD);
    uint256 internal v;

    function setUp() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        v = _provide(-6000, 6000, 1e19);
    }

    // ─── (1) every selector is classified ───

    function _sel(string memory contractName) internal view returns (string[] memory) {
        string memory json = vm.readFile(string.concat("out/", contractName, ".sol/", contractName, ".json"));
        return vm.parseJsonKeys(json, ".methodIdentifiers");
    }

    function _has(string[] memory list, string memory s) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (keccak256(bytes(list[i])) == keccak256(bytes(s))) return true;
        }
        return false;
    }

    function _same(string memory name, string[] memory expected) internal view {
        string[] memory actual = _sel(name);
        for (uint256 i; i < actual.length; ++i) {
            assertTrue(_has(expected, actual[i]), string.concat(name, ": unclassified external function ", actual[i]));
        }
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(_has(actual, expected[i]), string.concat(name, ": stale entry ", expected[i]));
        }
    }

    function test_Hook_ExternalSurface() public view {
        string[] memory e = new string[](22);
        // PoolManager-only callbacks (BaseHook): the five Ballast uses plus the defaults that revert.
        e[0] = "afterAddLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),int256,int256,bytes)";
        e[1] = "afterDonate(address,(address,address,uint24,int24,address),uint256,uint256,bytes)";
        e[2] = "afterInitialize(address,(address,address,uint24,int24,address),uint160,int24)";
        e[3] = "afterRemoveLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),int256,int256,bytes)";
        e[4] = "afterSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),int256,bytes)";
        e[5] = "beforeAddLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)";
        e[6] = "beforeDonate(address,(address,address,uint24,int24,address),uint256,uint256,bytes)";
        e[7] = "beforeInitialize(address,(address,address,uint24,int24,address),uint160)";
        e[8] = "beforeRemoveLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)";
        e[9] = "beforeSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),bytes)";
        // vaults-only
        e[10] = "enterVaultOp()";
        // permissionless
        e[11] = "evaluateStress()";
        e[12] = "pokeStress()";
        // views
        e[13] = "collateralIsCurrency0()";
        e[14] = "config()";
        e[15] = "getHookPermissions()";
        e[16] = "lockState()";
        e[17] = "poolId()";
        e[18] = "poolManager()";
        e[19] = "stressInfo()";
        e[20] = "twapTick(uint32)";
        e[21] = "vaults()";
        _same("BallastHook", e);
    }

    function test_Vaults_ExternalSurface() public view {
        string[] memory e = new string[](19);
        e[0] = "cancelRedeem(uint256)"; // ticket owner
        e[1] = "checkpoint(uint256)"; // anyone
        e[2] = "claimCuratorFees(uint256,address)"; // curator
        e[3] = "claimRedeem(uint256,address)"; // ticket owner or operator
        e[4] = "configHash()";
        e[5] = "createVault((int24,int24)[],uint128,uint16)"; // anyone
        e[6] = "deployIdle(uint256,(int24,int24),uint128)"; // curator
        e[7] = "deposit(uint256,uint128,uint128,uint128,address)"; // anyone
        e[8] = "depthCalc()";
        e[9] = "extsload(bytes32,uint256)";
        e[10] = "hook()";
        e[11] = "poolManager()";
        e[12] = "requestRedeem(uint256,uint128)"; // share holder
        e[13] = "rerange(uint256,(int24,int24)[],uint128[])"; // curator
        e[14] = "seed(uint256,uint128[],uint128,uint128,address)"; // curator
        e[15] = "setCommitment(uint256,uint128)"; // curator
        e[16] = "shareToken()";
        e[17] = "standby()";
        e[18] = "unlockCallback(bytes)"; // PoolManager
        _same("BallastVaults", e);
    }

    function test_Standby_Shares_Depth_Lens_Advisor_ExternalSurface() public view {
        string[] memory s = new string[](7);
        s[0] = "accrue(uint128,uint32)"; // vaults
        s[1] = "fundStandby(uint128)"; // sponsor
        s[2] = "poolManager()";
        s[3] = "setStandbyRate(uint128)"; // sponsor
        s[4] = "standbyInfo()";
        s[5] = "unlockCallback(bytes)"; // PoolManager
        s[6] = "vaults()";
        _same("BallastStandby", s);

        string[] memory sh = new string[](13);
        sh[0] = "allowance(address,address,uint256)";
        sh[1] = "approve(address,uint256,uint256)";
        sh[2] = "balanceOf(address,uint256)";
        sh[3] = "burn(address,uint256,uint256)"; // vaults
        sh[4] = "isOperator(address,address)";
        sh[5] = "mint(address,uint256,uint256)"; // vaults
        sh[6] = "move(address,address,uint256,uint256)"; // vaults
        sh[7] = "setOperator(address,bool)";
        sh[8] = "supportsInterface(bytes4)";
        sh[9] = "totalSupply(uint256)";
        sh[10] = "transfer(address,uint256,uint256)";
        sh[11] = "transferFrom(address,address,uint256,uint256)";
        sh[12] = "vaults()";
        _same("BallastShares", sh);

        string[] memory d = new string[](2);
        d[0] = "measure(bool,int24,int24,uint160,uint24,(int24,int24,uint128)[])";
        d[1] = "shrinkLiquidity(int24,int24,uint128,uint160,uint256,bool)";
        _same("BallastDepth", d);

        string[] memory l = new string[](18);
        l[0] = "committedDepth()";
        l[1] = "exitingShares(uint256,uint32)";
        l[2] = "hook()";
        l[3] = "liveDepth(uint16,uint32)";
        l[4] = "lockState()";
        l[5] = "poolAbsorbable(uint16)";
        l[6] = "poolManager()";
        l[7] = "positionsOf(uint256)";
        l[8] = "previewDeposit(uint256,uint128)";
        l[9] = "previewRedeem(uint256,uint128)";
        l[10] = "shareToken()";
        l[11] = "ticket(uint256)";
        l[12] = "vault(uint256)";
        l[13] = "vaultCount()";
        l[14] = "vaultDepth(uint256)";
        l[15] = "vaultRecord(uint256)";
        l[16] = "vaultStatus(uint256)";
        l[17] = "vaults()";
        _same("BallastLens", l);

        string[] memory a = new string[](3);
        a[0] = "WAD()";
        a[1] = "depthOracle()";
        a[2] = "suggestedCap(uint256,uint16,uint32)";
        _same("SupplyCapAdvisor", a);
    }

    // ─── (2) no privileged-looking function exists ───

    function _startsWith(string memory s, string memory p) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(p);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function test_NoOwnerPauseUpgradeOrWithdrawalFunctionExists() public view {
        string[7] memory names = [
            "BallastHook", "BallastVaults", "BallastStandby", "BallastShares", "BallastDepth", "BallastLens", "SupplyCapAdvisor"
        ];
        string[12] memory banned = [
            "owner", "transferOwnership", "renounceOwnership", "pause", "unpause", "upgrade",
            "withdraw", "sweep", "rescue", "setImplementation", "setHook", "setVaults"
        ];
        for (uint256 i; i < names.length; ++i) {
            string[] memory sel = _sel(names[i]);
            for (uint256 j; j < sel.length; ++j) {
                for (uint256 k; k < banned.length; ++k) {
                    assertFalse(_startsWith(sel[j], banned[k]), string.concat(names[i], " has ", sel[j]));
                }
            }
        }
    }

    // ─── (3) restricted functions reject strangers ───

    function test_PoolManagerOnly_HookCallbacksAndUnlockCallbacks() public {
        vm.startPrank(STRANGER);
        vm.expectRevert();
        hook.beforeSwap(STRANGER, key, SwapParams(true, -1, 1), "");
        vm.expectRevert();
        hook.beforeAddLiquidity(STRANGER, key, ModifyLiquidityParams(-60, 60, 1, 0), "");
        vm.expectRevert();
        hook.beforeRemoveLiquidity(STRANGER, key, ModifyLiquidityParams(-60, 60, -1, 0), "");
        vm.expectRevert();
        hook.beforeInitialize(STRANGER, key, 1);
        vm.expectRevert();
        hook.afterInitialize(STRANGER, key, 1, 0);
        vm.expectRevert(abi.encodeWithSignature("NotPoolManager()"));
        vaults.unlockCallback("");
        vm.stopPrank();
        BallastStandby sb = BallastStandby(address(vaults.standby()));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSignature("NotPoolManager()"));
        sb.unlockCallback("");
    }

    function test_VaultsOnly_EnterVaultOp_Accrue_ShareMintBurnMove() public {
        BallastShares st = vaults.shareToken();
        BallastStandby sb = BallastStandby(address(vaults.standby()));
        vm.startPrank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.NotVaults.selector, STRANGER));
        hook.enterVaultOp();
        vm.expectRevert(abi.encodeWithSelector(BallastStandby.NotVaultsContract.selector, STRANGER));
        sb.accrue(1, 1);
        vm.expectRevert(abi.encodeWithSelector(BallastShares.NotVaultsContract.selector, STRANGER));
        st.mint(STRANGER, v, 1);
        vm.expectRevert(abi.encodeWithSelector(BallastShares.NotVaultsContract.selector, STRANGER));
        st.burn(address(this), v, 1);
        vm.expectRevert(abi.encodeWithSelector(BallastShares.NotVaultsContract.selector, STRANGER));
        st.move(address(this), STRANGER, v, 1);
        vm.stopPrank();
    }

    function test_SponsorOnly_FundAndRate() public {
        BallastStandby sb = BallastStandby(address(vaults.standby()));
        vm.startPrank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.NotSponsor.selector, STRANGER));
        sb.fundStandby(1);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.NotSponsor.selector, STRANGER));
        sb.setStandbyRate(1);
        vm.stopPrank();
    }

    function test_CuratorOnly_Operations() public {
        Range[] memory r = new Range[](1);
        r[0] = Range(-60, 60);
        uint128[] memory l = new uint128[](1);
        l[0] = 1e18;
        vm.startPrank(STRANGER);
        bytes memory err = abi.encodeWithSelector(IBallastErrors.NotCurator.selector, STRANGER);
        vm.expectRevert(err);
        vaults.seed(v, l, 1, 1, STRANGER);
        vm.expectRevert(err);
        vaults.rerange(v, r, l);
        vm.expectRevert(err);
        vaults.deployIdle(v, r[0], 1);
        vm.expectRevert(err);
        vaults.setCommitment(v, 1);
        vm.expectRevert(err);
        vaults.claimCuratorFees(v, STRANGER);
        vm.stopPrank();
    }

    function test_TicketOwnerOnly_CancelAndClaim() public {
        uint256 t = vaults.requestRedeem(v, 1e16);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.startPrank(STRANGER);
        vm.expectRevert(IBallastErrors.NotTicketOwnerOrOperator.selector);
        vaults.cancelRedeem(t);
        vm.expectRevert(IBallastErrors.NotTicketOwnerOrOperator.selector);
        vaults.claimRedeem(t, STRANGER);
        vm.stopPrank();
    }

    function test_Permissionless_Operations_NeedNoRole() public {
        vm.startPrank(STRANGER);
        vaults.checkpoint(v);
        hook.pokeStress();
        hook.evaluateStress();
        Range[] memory r = new Range[](1);
        r[0] = Range(-60, 60);
        vaults.createVault(r, 0, 0);
        vm.stopPrank();
    }
}
