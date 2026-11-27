// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookFixture} from "./HookFixture.sol";
import {Position} from "../../src/types/Types.sol";

/// @notice Independent expected values for depth (INV-9): a plain v4 pool with no hook holds the same positions, and
/// a real swap in the liquidation direction measures how much collateral the pool absorbs between two ticks. Nothing
/// here calls `DepthMath`, `BandMath`, the lens or the vaults, so a bug in them cannot cancel against itself.
/// @dev The plain pool shares the fixture's `PoolManager`. It differs from the Ballast pool only in the hook (none),
/// so each plain pool in one test needs a distinct `PoolKey`: successive pools take successive divisors of 60 as tick
/// spacing (every range in the tests is a multiple of 60, hence valid for each).
///
/// Net-of-fee measurement: the swapper pays gross input = net input + fees. The fees are read back from the
/// PoolManager's own accounting: LP fees through each position's fee-growth-inside delta, protocol fees through
/// `protocolFeesAccrued`. Both round down, so the measured net can exceed the exact net by less than one wei per
/// position (documented tolerance, `tolerance`).
abstract contract BruteForce is HookFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint24[12] internal _bfSpacings = [60, 30, 20, 15, 12, 10, 6, 5, 4, 3, 2, 1];
    uint256 internal _bfNext;
    bool internal _bfApproved;
    string internal _bfRef;

    /// @notice A plain pool and the positions placed in it.
    struct Plain {
        PoolKey key;
        Position[] positions;
        uint256 protocolPaid; // protocol fees accrued by swaps into this pool (the counter is per currency)
        uint256 grossPaid; // cumulative collateral paid by swaps into this pool
    }

    /// @dev Rounding allowance between the exact net-of-fee input and what is measured or reported, per call: each
    /// swap step rounds its input up by at most one wei, each position's reported amount rounds down by at most one
    /// wei, each position's measured fee rounds down by at most one wei, so three wei per position, plus a constant
    /// for the extra boundary steps and the two-stage swap.
    function tolerance(uint256 positions) internal pure returns (uint256) {
        return 3 * positions + 6;
    }

    /// @dev Creates a plain pool (fee `fee` pips, protocol fee `protocolFee` packed as in v4) initialised at
    /// `sqrtStart`, with every position of `ps` added once under its own salt.
    function _plainPool(Position[] memory ps, uint160 sqrtStart, uint24 fee, uint24 protocolFee)
        internal
        returns (Plain memory p)
    {
        require(_bfNext < _bfSpacings.length, "BruteForce: out of tick spacings");
        if (!_bfApproved) {
            collateral.approve(address(liqRouter), type(uint256).max);
            quote.approve(address(liqRouter), type(uint256).max);
            _bfApproved = true;
        }
        (Currency c0, Currency c1) = collateralIs0
            ? (Currency.wrap(address(collateral)), Currency.wrap(address(quote)))
            : (Currency.wrap(address(quote)), Currency.wrap(address(collateral)));
        // SAFETY: the divisors of 60 in `_bfSpacings` fit int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        p.key = PoolKey(c0, c1, fee, int24(uint24(_bfSpacings[_bfNext++])), IHooks(address(0)));
        pm.initialize(p.key, sqrtStart);
        if (protocolFee != 0) pm.setProtocolFee(p.key, protocolFee);
        p.positions = ps;
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].liquidity == 0) continue;
            liqRouter.modifyLiquidity(
                p.key,
                ModifyLiquidityParams(
                    ps[i].tickLower, ps[i].tickUpper, int256(uint256(ps[i].liquidity)), bytes32(i)
                ),
                ""
            );
        }
    }

    /// @dev Sells collateral into `p` until the price reaches `limitTick` (or liquidity runs out). Returns the
    /// cumulative gross collateral paid into `p` and, from the PoolManager's fee accounting, the cumulative
    /// net-of-fee input.
    function _sellTo(Plain memory p, int24 limitTick)
        internal
        returns (uint256 gross, uint256 net)
    {
        uint256 before_ = collateral.balanceOf(address(this));
        uint256 protocolBefore = pm.protocolFeesAccrued(Currency.wrap(address(collateral)));
        swapRouter.swap(
            p.key,
            SwapParams({
                zeroForOne: collateralIs0,
                amountSpecified: -int256(1e29),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limitTick)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        p.grossPaid += before_ - collateral.balanceOf(address(this));
        p.protocolPaid += pm.protocolFeesAccrued(Currency.wrap(address(collateral)))
        - protocolBefore;
        gross = p.grossPaid;
        net = gross - _feesPaid(p);
    }

    /// @dev Cumulative fees paid in the collateral since the pool was created: LP fees owed to every position plus
    /// the protocol's share.
    function _feesPaid(Plain memory p) internal view returns (uint256 fees) {
        PoolId id = p.key.toId();
        IPoolManager m = IPoolManager(address(pm));
        for (uint256 i; i < p.positions.length; ++i) {
            Position memory q = p.positions[i];
            if (q.liquidity == 0) continue;
            (, uint256 last0, uint256 last1) =
                m.getPositionInfo(id, address(liqRouter), q.tickLower, q.tickUpper, bytes32(i));
            (uint256 in0, uint256 in1) = m.getFeeGrowthInside(id, q.tickLower, q.tickUpper);
            uint256 delta;
            // The accumulators wrap by design in v4.
            unchecked {
                delta = collateralIs0 ? in0 - last0 : in1 - last1;
            }
            fees += FullMath.mulDiv(delta, q.liquidity, FixedPoint128.Q128);
        }
        fees += p.protocolPaid;
    }

    /// @dev Two-stage measurement of the collateral a pool absorbs from its current price to `farTick`: stage one stops
    /// one tick short of `farTick` (toward the near side), stage two continues to `farTick`. `narrow` and `wide` are
    /// net-of-fee inputs; `gross` is the total paid. The lens may use either edge (BandMath is at most one tick narrower
    /// than the exact band, docs/MATH.md §2), so its figure must lie in `[narrow - tolerance, wide]`.
    function _absorbTwoStage(Plain memory p, int24 farTick)
        internal
        returns (uint256 narrow, uint256 wide, uint256 gross)
    {
        (, narrow) = _sellTo(p, collateralIs0 ? farTick + 1 : farTick - 1);
        (gross, wide) = _sellTo(p, farTick);
    }

    /// @dev Tick distance of `bps` of price impact from the committed 80-digit reference table
    /// (`test/data/band_ticks_ref.json`, `.floor`, index `bps - 1`): the exact value rounded down. `BandMath` returns
    /// this value or one less (docs/MATH.md §2).
    function _tableTicks(uint16 bps) internal returns (int24) {
        if (bytes(_bfRef).length == 0) _bfRef = vm.readFile("test/data/band_ticks_ref.json");
        // SAFETY: the table holds at most ~92,000 ticks, well inside int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(uint24(vm.parseUint(vm.parseJsonStringArray(_bfRef, ".floor")[bps - 1])));
    }

    /// @dev The far edge of a band of `bps` impact starting at `nearTick`, in the liquidation direction.
    function _farEdge(int24 nearTick, uint16 bps) internal returns (int24) {
        int24 t = _tableTicks(bps);
        return collateralIs0 ? nearTick - t : nearTick + t;
    }
}
