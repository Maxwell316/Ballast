// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @dev Test hook with exactly Ballast's five permissions. It records invocations, blocks external
/// liquidity changes when `allowExternal` is false (as Ballast will), and performs its own liquidity
/// operations inside an unlock, settled with the OpenZeppelin `CurrencySettler` (tokens and claims).
contract FlagsHook is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    error ExternalLiquidityForbidden();

    enum Op {
        ADD_PAY_TOKENS,
        REMOVE_TAKE_TOKENS,
        REMOVE_TAKE_CLAIMS,
        ADD_PAY_CLAIMS
    }

    uint256 public beforeInitCalls;
    uint256 public afterInitCalls;
    uint256 public beforeAddCalls;
    uint256 public beforeRemoveCalls;
    uint256 public beforeSwapCalls;
    int24 public lastPreSwapTick;
    address public lastInitSender;
    bool public allowExternal;
    PoolKey public poolKey;

    constructor(IPoolManager pm) BaseHook(pm) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.beforeSwap = true;
    }

    function setAllowExternal(bool allow) external {
        allowExternal = allow;
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160)
        internal
        override
        returns (bytes4)
    {
        beforeInitCalls++;
        lastInitSender = sender;
        poolKey = key;
        return this.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        afterInitCalls++;
        return this.afterInitialize.selector;
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        if (!allowExternal) revert ExternalLiquidityForbidden();
        beforeAddCalls++;
        return this.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        if (!allowExternal) revert ExternalLiquidityForbidden();
        beforeRemoveCalls++;
        return this.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        beforeSwapCalls++;
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, key.toId());
        lastPreSwapTick = tick;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Hook-initiated liquidity change; `Op` selects how it is settled.
    function modify(Op op, ModifyLiquidityParams calldata params) external {
        poolManager.unlock(abi.encode(op, params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Op op, ModifyLiquidityParams memory params) = abi.decode(data, (Op, ModifyLiquidityParams));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(poolKey, params, "");
        bool claims = op == Op.REMOVE_TAKE_CLAIMS;
        bool burn = op == Op.ADD_PAY_CLAIMS;
        _settleOne(poolKey.currency0, delta.amount0(), burn, claims);
        _settleOne(poolKey.currency1, delta.amount1(), burn, claims);
        return "";
    }

    function _settleOne(Currency c, int128 amt, bool burn, bool claims) private {
        if (amt < 0) c.settle(poolManager, address(this), uint256(uint128(-amt)), burn);
        else if (amt > 0) c.take(poolManager, address(this), uint256(uint128(amt)), claims);
    }
}

/// @notice Proves, against the real Unichain Sepolia PoolManager, that the five hook flags Ballast uses
/// behave as the pinned v4-core defines them, that a hook can block external liquidity changes while
/// its own succeed (G-1 basis, R-LIQ-4), and that claims-based settlement works on the deployed chain.
/// @custom:requirement R-LIQ-1 R-LIQ-2 R-LIQ-4 R-POOL-4
contract HooksOnChainTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 internal constant FORK_BLOCK = 68_788_256;
    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;

    IPoolManager internal pm;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liqRouter;
    FlagsHook internal hook;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "RPC_URL not set");
        vm.createSelectFork(rpc, FORK_BLOCK);

        string memory cfg = vm.readFile("config/addresses.json");
        pm = IPoolManager(vm.parseJsonAddress(cfg, ".1301.poolManager"));
        swapRouter = PoolSwapTest(vm.parseJsonAddress(cfg, ".1301.poolSwapTest"));
        liqRouter =
            PoolModifyLiquidityTest(vm.parseJsonAddress(cfg, ".1301.poolModifyLiquidityTest"));
        assertGt(address(pm).code.length, 0, "no PoolManager code");
        assertGt(address(swapRouter).code.length, 0, "no swap router");
        assertGt(address(liqRouter).code.length, 0, "no liquidity router");

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG;
        address hookAddr = address(flags | (uint160(0xBA11A57) << 20));
        deployCodeTo("HooksOnChain.t.sol:FlagsHook", abi.encode(pm), hookAddr);
        hook = FlagsHook(hookAddr);
        assertEq(uint160(hookAddr) & Hooks.ALL_HOOK_MASK, flags, "address flags");

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            FEE,
            SPACING,
            IHooks(hookAddr)
        );

        token0.mint(address(this), 1e24);
        token1.mint(address(this), 1e24);
        token0.mint(address(hook), 1e24);
        token1.mint(address(hook), 1e24);
        token0.approve(address(liqRouter), type(uint256).max);
        token1.approve(address(liqRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function _params(int256 liquidity) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600, liquidityDelta: liquidity, salt: bytes32(0)
        });
    }

    function test_Initialize_CallsBeforeAndAfterInitialize() public view {
        assertEq(hook.beforeInitCalls(), 1);
        assertEq(hook.afterInitCalls(), 1);
        assertEq(hook.lastInitSender(), address(this), "sender is the initialize caller");
    }

    function test_RevertWhen_ExternalRouterAddsLiquidity() public {
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        liqRouter.modifyLiquidity(key, _params(1e18), "");
    }

    function test_RevertWhen_ExternalRouterRemovesLiquidity() public {
        // Build a router-owned position while external liquidity is allowed, then forbid it.
        hook.setAllowExternal(true);
        liqRouter.modifyLiquidity(key, _params(1e18), "");
        hook.setAllowExternal(false);
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        liqRouter.modifyLiquidity(key, _params(-1e18), "");
    }

    function test_BeforeAddAndRemoveLiquidity_AreInvokedForExternalCallers() public {
        hook.setAllowExternal(true);
        liqRouter.modifyLiquidity(key, _params(1e18), "");
        assertEq(hook.beforeAddCalls(), 1, "beforeAddLiquidity invoked");
        liqRouter.modifyLiquidity(key, _params(-1e18), "");
        assertEq(hook.beforeRemoveCalls(), 1, "beforeRemoveLiquidity invoked");
    }

    function test_HookOwnLiquidity_SkipsItsOwnCallbacks_WhileExternalIsBlocked() public {
        assertFalse(hook.allowExternal());
        hook.modify(FlagsHook.Op.ADD_PAY_TOKENS, _params(1e18));
        assertEq(hook.beforeAddCalls(), 0, "self-call must not trigger beforeAddLiquidity");
        assertEq(pm.getLiquidity(key.toId()), 1e18, "hook liquidity is in the pool");
        hook.modify(FlagsHook.Op.REMOVE_TAKE_TOKENS, _params(-1e18));
        assertEq(hook.beforeRemoveCalls(), 0, "self-call must not trigger beforeRemoveLiquidity");
        assertEq(pm.getLiquidity(key.toId()), 0);
    }

    function test_ClaimsSettlement_MintOnRemoveBurnOnAdd() public {
        hook.modify(FlagsHook.Op.ADD_PAY_TOKENS, _params(1e18));
        uint256 id0 = Currency.wrap(address(token0)).toId();
        uint256 id1 = Currency.wrap(address(token1)).toId();
        hook.modify(FlagsHook.Op.REMOVE_TAKE_CLAIMS, _params(-1e18));
        uint256 c0 = pm.balanceOf(address(hook), id0);
        uint256 c1 = pm.balanceOf(address(hook), id1);
        assertGt(c0, 0, "claims minted for currency0");
        assertGt(c1, 0, "claims minted for currency1");
        // Remove rounds amounts down and add rounds up, so re-adding the full liquidity from the claims
        // just received would be short by dust. Re-add slightly less.
        hook.modify(FlagsHook.Op.ADD_PAY_CLAIMS, _params(0.9e18));
        assertLt(pm.balanceOf(address(hook), id0), c0, "claims burned for currency0");
        assertLt(pm.balanceOf(address(hook), id1), c1, "claims burned for currency1");
    }

    function test_BeforeSwap_IsInvoked_AndSeesPreSwapTick() public {
        hook.modify(FlagsHook.Op.ADD_PAY_TOKENS, _params(1e18));
        (, int24 tickBefore,,) = pm.getSlot0(key.toId());
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e16,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(hook.beforeSwapCalls(), 1, "beforeSwap invoked");
        assertEq(hook.lastPreSwapTick(), tickBefore, "tick read in beforeSwap is the pre-swap tick");
        (, int24 tickAfter,,) = pm.getSlot0(key.toId());
        assertLt(tickAfter, tickBefore, "swap moved the price");
    }
}
