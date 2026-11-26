// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {HookFixture} from "../../utils/HookFixture.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {BallastHook} from "../../../src/BallastHook.sol";
import {HookMiner} from "../../../script/utils/HookMiner.sol";
import {IBallastErrors} from "../../../src/interfaces/IBallastErrors.sol";
import {Config, LockState, StressInfo} from "../../../src/types/Types.sol";

/// @notice Pool binding, permissions, hook-only liquidity and deployment on a real local PoolManager.
/// @custom:requirement R-POOL-1 R-POOL-2 R-POOL-3 R-POOL-4 R-POOL-6 R-LIQ-1 R-LIQ-2 R-LIQ-3 R-LIQ-4
contract HookCallbacksTest is HookFixture {
    using StateLibrary for IPoolManager;

    function _preInit(bool c0) internal {
        _deployInfra();
        _tokens(c0, 18, 6);
        _deployHook(ConfigFixture.prodLike());
    }

    function _fullSetUp(bool c0) internal {
        _setUpDefault(c0, ConfigFixture.prodLike(), 0);
    }

    function _revertInit(PoolKey memory k, bytes memory reason, address sender) internal {
        vm.prank(sender);
        vm.expectRevert(_wrapped(IHooks.beforeInitialize.selector, reason));
        pm.initialize(k, 1 << 96);
    }

    // ─── permissions and deployment ───

    function _mask(Hooks.Permissions memory p) internal pure returns (uint160 m) {
        if (p.beforeInitialize) m |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) m |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) m |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.afterAddLiquidity) m |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) m |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.afterRemoveLiquidity) m |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) m |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) m |= Hooks.AFTER_SWAP_FLAG;
        if (p.beforeDonate) m |= Hooks.BEFORE_DONATE_FLAG;
        if (p.afterDonate) m |= Hooks.AFTER_DONATE_FLAG;
        if (p.beforeSwapReturnDelta) m |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterSwapReturnDelta) m |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterAddLiquidityReturnDelta) m |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (p.afterRemoveLiquidityReturnDelta) {
            m |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
        }
    }

    /// @custom:requirement R-LIQ-4
    function test_Permissions_AreExactlyTheFiveFlags_NoReturnDeltas() public {
        _preInit(true);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertEq(_mask(p), FLAGS, "mask");
        assertFalse(
            p.beforeSwapReturnDelta || p.afterSwapReturnDelta || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta,
            "return-delta flags must stay off"
        );
    }

    /// @notice The mined CREATE2 deployment carries exactly the flags of `getHookPermissions()` (T15).
    function test_MinedCreate2Deployment_AddressFlagsEqualPermissions() public {
        _deployInfra();
        _tokens(true, 18, 6);
        Config memory c = ConfigFixture.prodLike();
        c.collateral = Currency.wrap(address(collateral));
        c.quote = Currency.wrap(address(quote));
        bytes memory args = abi.encode(address(pm), c);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(BallastHook).creationCode, args);
        BallastHook h = new BallastHook{salt: salt}(pm, c);
        assertEq(address(h), predicted, "predicted address");
        assertEq(uint160(address(h)) & Hooks.ALL_HOOK_MASK, _mask(h.getHookPermissions()), "flags");
    }

    function test_RevertWhen_DeployedAtAddressWithoutFlags() public {
        _deployInfra();
        _tokens(true, 18, 6);
        Config memory c = ConfigFixture.prodLike();
        c.collateral = Currency.wrap(address(collateral));
        c.quote = Currency.wrap(address(quote));
        vm.expectRevert();
        new BallastHook(pm, c); // an ordinary CREATE address has (almost surely) the wrong low bits
    }

    // ─── pool binding ───

    function _checkBound(bool c0) internal {
        _fullSetUp(c0);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(pid), "poolId");
        assertEq(hook.collateralIsCurrency0(), c0, "collateral side");
        (int24 twap, bool warm) = hook.twapTick(300);
        assertEq(twap, 0, "seed tick");
        assertFalse(warm, "cold at start");
    }

    function test_BeforeInitialize_BindsPool_CollateralIsCurrency0() public {
        _checkBound(true);
    }

    function test_BeforeInitialize_BindsPool_CollateralIsCurrency1() public {
        _checkBound(false);
    }

    function test_AfterInitialize_SeedsObservationZeroAtInitialTick() public {
        _preInit(true);
        _initPool(-1200);
        vm.warp(block.timestamp + 100);
        // Pool tick is -1200 for the whole 100 s since initialisation.
        (int24 twap,) = hook.twapTick(100);
        assertEq(twap, -1200);
    }

    function test_RevertWhen_InitializerIsNotConfigured() public {
        _preInit(true);
        _revertInit(
            key,
            abi.encodeWithSelector(IBallastErrors.PoolInitializerOnly.selector, address(0xBAD)),
            address(0xBAD)
        );
        assertEq(PoolId.unwrap(hook.poolId()), bytes32(0), "not bound after failed init");
    }

    function test_RevertWhen_FeeDiffers() public {
        _preInit(true);
        PoolKey memory k = key;
        k.fee = 500;
        _revertInit(
            k, abi.encodeWithSelector(IBallastErrors.InvalidPoolKey.selector), cfg.initializer
        );
    }

    function test_RevertWhen_TickSpacingDiffers() public {
        _preInit(true);
        PoolKey memory k = key;
        k.tickSpacing = 10;
        _revertInit(
            k, abi.encodeWithSelector(IBallastErrors.InvalidPoolKey.selector), cfg.initializer
        );
    }

    function test_RevertWhen_FeeIsDynamic() public {
        _preInit(true);
        PoolKey memory k = key;
        k.fee = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG
        _revertInit(
            k,
            abi.encodeWithSelector(IBallastErrors.DynamicFeeUnsupported.selector),
            cfg.initializer
        );
    }

    function test_RevertWhen_CurrencyIsNative() public {
        _preInit(true);
        PoolKey memory k = key;
        k.currency0 = Currency.wrap(address(0));
        _revertInit(
            k,
            abi.encodeWithSelector(IBallastErrors.NativeCurrencyUnsupported.selector),
            cfg.initializer
        );
    }

    function test_RevertWhen_CurrencyPairIsNotCollateralAndQuote() public {
        _preInit(true);
        MockERC20 other = new MockERC20("O", "O", 18);
        PoolKey memory k = key;
        // Replace the quote with an unrelated token, keeping the sort order valid.
        (k.currency0, k.currency1) = address(other) < address(collateral)
            ? (Currency.wrap(address(other)), Currency.wrap(address(collateral)))
            : (Currency.wrap(address(collateral)), Currency.wrap(address(other)));
        _revertInit(
            k, abi.encodeWithSelector(IBallastErrors.InvalidPoolKey.selector), cfg.initializer
        );
    }

    function test_RevertWhen_HooksFieldIsNotThisHook() public {
        _preInit(true);
        PoolKey memory k = key;
        k.hooks = IHooks(address(0x1234));
        // Unreachable through the PoolManager (it calls `k.hooks`); exercised by a direct call from it.
        vm.prank(address(pm));
        vm.expectRevert(IBallastErrors.InvalidPoolKey.selector);
        hook.beforeInitialize(cfg.initializer, k, 1 << 96);
    }

    function test_RevertWhen_SecondInitialize_PoolAlreadyBound() public {
        _fullSetUp(true);
        // The only key the hook accepts is the one already initialised; the PoolManager calls the hook first.
        _revertInit(
            key, abi.encodeWithSelector(IBallastErrors.PoolAlreadyBound.selector), cfg.initializer
        );
    }

    function test_RevertWhen_CallbacksCalledByNonPoolManager() public {
        _fullSetUp(true);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(cfg.initializer, key, 0);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(cfg.initializer, key, 0, 0);
    }

    function test_Views_BeforeBinding() public {
        _preInit(true);
        assertEq(PoolId.unwrap(hook.poolId()), bytes32(0));
        StressInfo memory si = hook.stressInfo();
        assertEq(uint8(si.state), uint8(LockState.CALM));
        (LockState st, uint40 until) = hook.lockState();
        assertEq(uint8(st), 0);
        assertEq(until, 0);
        vm.expectRevert(IBallastErrors.PoolNotBound.selector);
        hook.twapTick(60);
        vm.expectRevert(IBallastErrors.PoolNotBound.selector);
        hook.pokeStress();
    }

    function test_Config_RoundTrips() public {
        _fullSetUp(true);
        Config memory c = hook.config();
        assertEq(Currency.unwrap(c.collateral), address(collateral));
        assertEq(Currency.unwrap(c.quote), address(quote));
        assertEq(c.initializer, cfg.initializer);
        assertEq(c.fee, cfg.fee);
        assertEq(c.maxStandbyRate, cfg.maxStandbyRate);
        assertEq(c.observationCardinality, cfg.observationCardinality);
    }

    // ─── G-1: hook-only liquidity ───

    /// @notice A plain router cannot add liquidity. Test of G-1 / R-LIQ-1.
    /// @custom:guarantee G-1
    function test_RevertWhen_ExternalAddLiquidity_PlainRouter() public {
        _fullSetUp(true);
        collateral.approve(address(liqRouter), type(uint256).max);
        quote.approve(address(liqRouter), type(uint256).max);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IBallastErrors.ExternalLiquidityForbidden.selector)
            )
        );
        liqRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 1e18, 0), "");
    }

    /// @notice A plain router cannot remove liquidity (including a zero-delta poke, which v4 routes to the
    /// remove callback). Test of G-1 / R-LIQ-2.
    /// @custom:guarantee G-1
    function test_RevertWhen_ExternalRemoveLiquidity_PlainRouter() public {
        _fullSetUp(true);
        hook.modifyForTest(-600, 600, 1e18, bytes32(uint256(1)));
        bytes memory expected = _wrapped(
            IHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(IBallastErrors.ExternalLiquidityForbidden.selector)
        );
        vm.expectRevert(expected);
        liqRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, -1e18, 0), "");
        vm.expectRevert(expected);
        liqRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 0, 0), "");
    }

    /// @notice The hook's own liquidity changes bypass its callbacks (R-LIQ-4) and the position is owned by it
    /// (R-LIQ-3, INV-1).
    /// @custom:guarantee G-1
    function test_HookSelfCall_AddsAndRemovesLiquidity_BypassingCallbacks() public {
        _fullSetUp(true);
        bytes32 salt = bytes32(uint256(1 << 8 | 0));
        hook.modifyForTest(-600, 600, 5e17, salt);
        bytes32 posKey = Position.calculatePositionKey(address(hook), -600, 600, salt);
        assertEq(IPoolManager(address(pm)).getPositionLiquidity(pid, posKey), 5e17, "owned by hook");
        // The router's own key for the same range holds nothing.
        bytes32 routerKey = Position.calculatePositionKey(address(liqRouter), -600, 600, salt);
        assertEq(IPoolManager(address(pm)).getPositionLiquidity(pid, routerKey), 0);
        hook.modifyForTest(-600, 600, -2e17, salt);
        assertEq(IPoolManager(address(pm)).getPositionLiquidity(pid, posKey), 3e17);
    }

    /// @notice Donations are not restricted (R-LIQ-5): the hook has no donate flag.
    function test_Donate_IsNotRestricted() public {
        _fullSetUp(true);
        hook.modifyForTest(-600, 600, 1e18, bytes32(uint256(1)));
        PoolDonateTest donor = new PoolDonateTest(pm);
        collateral.approve(address(donor), type(uint256).max);
        quote.approve(address(donor), type(uint256).max);
        donor.donate(key, 1e6, 1e6, "");
    }
}
