// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "./MockERC20.sol";
import {ConfigFixture} from "./ConfigFixture.sol";
import {BallastHookHarness} from "./BallastHookHarness.sol";
import {BallastVaults} from "../../src/BallastVaults.sol";
import {Config, Range} from "../../src/types/Types.sol";

/// @notice Shared fixture: a real local PoolManager, mock tokens in a chosen decimals/ordering scenario, and a
/// `BallastHookHarness` placed at an address carrying exactly Ballast's five flags (via `deployCodeTo`, because the
/// OpenZeppelin `_validateHookAddress` is non-virtual; ADR-030). The pool is initialised by the configured initializer.
abstract contract HookFixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG;
    address internal constant HOOK_ADDR = address(FLAGS | (uint160(0xBA11A57) << 20));
    uint40 internal constant T0 = 1_800_000_000;

    PoolManager internal pm;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liqRouter;
    MockERC20 internal collateral;
    MockERC20 internal quote;
    BallastHookHarness internal hook;
    BallastVaults internal vaults;
    PoolKey internal key;
    PoolId internal pid;
    Config internal cfg;
    bool internal collateralIs0;

    function _deployInfra() internal {
        vm.warp(T0);
        pm = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(pm);
        liqRouter = new PoolModifyLiquidityTest(pm);
    }

    /// @dev Creates tokens so that the collateral sorts as currency0 iff `c0`.
    function _tokens(bool c0, uint8 cd, uint8 qd) internal {
        MockERC20 a = new MockERC20("COL", "COL", cd);
        MockERC20 b = new MockERC20("QTE", "QTE", qd);
        while ((address(a) < address(b)) != c0) b = new MockERC20("QTE", "QTE", qd);
        collateral = a;
        quote = b;
        collateralIs0 = c0;
    }

    /// @dev Deploys the harness hook at `HOOK_ADDR` with `cfg` (collateral/quote filled from the tokens).
    function _deployHook(Config memory c) internal {
        c.collateral = Currency.wrap(address(collateral));
        c.quote = Currency.wrap(address(quote));
        cfg = c;
        deployCodeTo(
            "BallastHookHarness.sol:BallastHookHarness", abi.encode(address(pm), c), HOOK_ADDR
        );
        hook = BallastHookHarness(HOOK_ADDR);
        vaults = BallastVaults(hook.vaults());
        (Currency c0, Currency c1) =
            collateralIs0 ? (c.collateral, c.quote) : (c.quote, c.collateral);
        key = PoolKey(c0, c1, c.fee, c.tickSpacing, IHooks(HOOK_ADDR));
        pid = key.toId();
    }

    function _initPool(int24 tick) internal {
        vm.prank(cfg.initializer);
        pm.initialize(key, TickMath.getSqrtPriceAtTick(tick));
    }

    /// @dev Standard setup: collateral 18 decimals, quote 6, collateral = currency0 unless `c0` is false.
    function _setUpDefault(bool c0, Config memory c, int24 startTick) internal {
        _deployInfra();
        _tokens(c0, 18, 6);
        _deployHook(c);
        _initPool(startTick);
        MockERC20(address(collateral)).mint(address(hook), 1e30);
        MockERC20(address(quote)).mint(address(hook), 1e30);
        collateral.mint(address(this), 1e30);
        quote.mint(address(this), 1e30);
        collateral.approve(address(swapRouter), type(uint256).max);
        quote.approve(address(swapRouter), type(uint256).max);
        collateral.approve(address(vaults), type(uint256).max);
        quote.approve(address(vaults), type(uint256).max);
    }

    /// @dev Provides liquidity through the real custody path: a one-position vault seeded by this contract.
    function _provide(int24 lo, int24 hi, uint128 liq) internal returns (uint256 vaultId) {
        Range[] memory r = new Range[](1);
        r[0] = Range(lo, hi);
        vaultId = vaults.createVault(r, 0, 0);
        uint128[] memory l = new uint128[](1);
        l[0] = liq;
        vaults.seed(vaultId, l, type(uint128).max, type(uint128).max, address(this));
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = IPoolManager(address(pm)).getSlot0(pid);
    }

    /// @dev Swap exact input of `amountIn` of the collateral (`sellCollateral`) or the quote, stopping at no limit.
    function _swap(bool sellCollateral, uint256 amountIn) internal {
        bool zeroForOne = sellCollateral == collateralIs0;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev The error PoolManager emits when a hook reverts with `reason` in callback `selector`.
    function _wrapped(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            HOOK_ADDR,
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
