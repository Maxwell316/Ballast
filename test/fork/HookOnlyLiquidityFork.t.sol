// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {ConfigFixture} from "../utils/ConfigFixture.sol";
import {BallastHookHarness} from "../utils/BallastHookHarness.sol";
import {IBallastErrors} from "../../src/interfaces/IBallastErrors.sol";
import {Config} from "../../src/types/Types.sol";

interface IPositionManagerLike {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IPermit2Like {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice G-1 on the real Unichain Sepolia deployment: the real PositionManager and the deployed test routers
/// cannot add or remove liquidity in a Ballast pool, while the hook's own liquidity operations succeed (R-LIQ-1,
/// R-LIQ-2, R-LIQ-4). Addresses come from `config/addresses.json` (never hard-coded). Skips without `RPC_URL`.
/// @custom:guarantee G-1
/// @custom:requirement R-LIQ-1 R-LIQ-2 R-LIQ-4 R-POOL-6
contract HookOnlyLiquidityForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant FORK_BLOCK = 68_788_256;
    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG;
    address internal constant HOOK_ADDR = address(FLAGS | (uint160(0xBA11A57) << 20));

    IPoolManager internal pm;
    IPositionManagerLike internal positionManager;
    IPermit2Like internal permit2;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liqRouter;
    BallastHookHarness internal hook;
    MockERC20 internal collateral;
    MockERC20 internal quote;
    PoolKey internal key;
    PoolId internal pid;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "RPC_URL not set");
        vm.createSelectFork(rpc, FORK_BLOCK);

        string memory a = vm.readFile("config/addresses.json");
        pm = IPoolManager(vm.parseJsonAddress(a, ".1301.poolManager"));
        positionManager = IPositionManagerLike(vm.parseJsonAddress(a, ".1301.positionManager"));
        permit2 = IPermit2Like(vm.parseJsonAddress(a, ".1301.permit2"));
        swapRouter = PoolSwapTest(vm.parseJsonAddress(a, ".1301.poolSwapTest"));
        liqRouter = PoolModifyLiquidityTest(vm.parseJsonAddress(a, ".1301.poolModifyLiquidityTest"));
        assertGt(address(positionManager).code.length, 0, "no PositionManager code");

        MockERC20 x = new MockERC20("COL", "COL", 18);
        MockERC20 y = new MockERC20("QTE", "QTE", 6);
        while (address(x) > address(y)) y = new MockERC20("QTE", "QTE", 6); // collateral = currency0
        collateral = x;
        quote = y;

        Config memory c = ConfigFixture.compressed();
        c.collateral = Currency.wrap(address(collateral));
        c.quote = Currency.wrap(address(quote));
        deployCodeTo(
            "BallastHookHarness.sol:BallastHookHarness", abi.encode(address(pm), c), HOOK_ADDR
        );
        hook = BallastHookHarness(HOOK_ADDR);
        key = PoolKey(c.collateral, c.quote, c.fee, c.tickSpacing, IHooks(HOOK_ADDR));
        pid = key.toId();

        vm.prank(c.initializer);
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));

        collateral.mint(address(hook), 1e30);
        quote.mint(address(hook), 1e30);
        collateral.mint(address(this), 1e30);
        quote.mint(address(this), 1e30);
        collateral.approve(address(swapRouter), type(uint256).max);
        quote.approve(address(swapRouter), type(uint256).max);
        collateral.approve(address(liqRouter), type(uint256).max);
        quote.approve(address(liqRouter), type(uint256).max);
        hook.modifyForTest(-6000, 6000, 1e19, bytes32(uint256(1)));
    }

    function _forbidden(bytes4 callback) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            HOOK_ADDR,
            callback,
            abi.encodeWithSelector(IBallastErrors.ExternalLiquidityForbidden.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @notice The real PositionManager cannot mint a position into the Ballast pool.
    function test_RevertWhen_PositionManagerMintsPosition() public {
        collateral.approve(address(permit2), type(uint256).max);
        quote.approve(address(permit2), type(uint256).max);
        permit2.approve(
            address(collateral), address(positionManager), type(uint160).max, type(uint48).max
        );
        permit2.approve(
            address(quote), address(positionManager), type(uint160).max, type(uint48).max
        );

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            int24(-600),
            int24(600),
            uint256(1e18),
            type(uint128).max,
            type(uint128).max,
            address(this),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.expectRevert(_forbidden(IHooks.beforeAddLiquidity.selector));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
    }

    /// @notice The same PositionManager also cannot add into a range the hook already occupies.
    function test_RevertWhen_PositionManagerMintsIntoOccupiedRange() public {
        collateral.approve(address(permit2), type(uint256).max);
        quote.approve(address(permit2), type(uint256).max);
        permit2.approve(
            address(collateral), address(positionManager), type(uint160).max, type(uint48).max
        );
        permit2.approve(
            address(quote), address(positionManager), type(uint160).max, type(uint48).max
        );
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            int24(-6000),
            int24(6000),
            uint256(1e15),
            type(uint128).max,
            type(uint128).max,
            address(this),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.expectRevert(_forbidden(IHooks.beforeAddLiquidity.selector));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
    }

    /// @notice The deployed liquidity router cannot add, remove, or poke.
    function test_RevertWhen_DeployedRouterAddsRemovesOrPokes() public {
        vm.expectRevert(_forbidden(IHooks.beforeAddLiquidity.selector));
        liqRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 1e18, 0), "");
        vm.expectRevert(_forbidden(IHooks.beforeRemoveLiquidity.selector));
        liqRouter.modifyLiquidity(
            key, ModifyLiquidityParams(-6000, 6000, -1e15, bytes32(uint256(1))), ""
        );
        vm.expectRevert(_forbidden(IHooks.beforeRemoveLiquidity.selector));
        liqRouter.modifyLiquidity(
            key, ModifyLiquidityParams(-6000, 6000, 0, bytes32(uint256(1))), ""
        );
    }

    /// @notice The hook's own operations succeed on the same PoolManager, and the position is the hook's.
    function test_HookSelfCall_Succeeds_OnDeployedPoolManager() public {
        bytes32 salt = bytes32(uint256(2));
        hook.modifyForTest(-1200, 1200, 3e17, salt);
        bytes32 posKey = Position.calculatePositionKey(address(hook), -1200, 1200, salt);
        assertEq(pm.getPositionLiquidity(pid, posKey), 3e17);
        hook.modifyForTest(-1200, 1200, -3e17, salt);
        assertEq(pm.getPositionLiquidity(pid, posKey), 0);
    }

    /// @notice A swap through the deployed router passes the hook and writes the oracle on the deployed chain.
    function test_Swap_ThroughDeployedRouter_WritesOracle() public {
        vm.warp(block.timestamp + 120);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(hook.obsState().lastSwapTs, uint40(block.timestamp));
        assertEq(hook.obsLength(), 2, "seed + one snapshot");
    }
}
