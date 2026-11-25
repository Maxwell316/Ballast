// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {VaultMath} from "../../../src/libraries/VaultMath.sol";

contract VaultMathHarness {
    function ceilShare(uint256 a, uint256 s, uint256 t) external pure returns (uint256) {
        return VaultMath.ceilShare(a, s, t);
    }

    function floorShare(uint256 a, uint256 s, uint256 t) external pure returns (uint256) {
        return VaultMath.floorShare(a, s, t);
    }
}

/// @notice Unit, fuzz and differential tests for VaultMath. The maths is independent of token decimals and of the
/// collateral ordering (it scales amounts by a share ratio), so the decimals/ordering matrix does not apply here.
contract VaultMathTest is Test {
    VaultMathHarness internal h = new VaultMathHarness();

    /// @custom:requirement R-VLT-3 R-VLT-8
    function test_Examples() public pure {
        assertEq(VaultMath.ceilShare(10, 1, 3), 4); // 3.33 -> 4
        assertEq(VaultMath.floorShare(10, 1, 3), 3);
        assertEq(VaultMath.ceilShare(9, 1, 3), 3); // exact
        assertEq(VaultMath.floorShare(9, 1, 3), 3);
        assertEq(VaultMath.ceilShare(0, 5, 7), 0);
        assertEq(VaultMath.ceilShare(5, 0, 7), 0);
        assertEq(VaultMath.floorShare(5, 0, 7), 0);
        assertEq(VaultMath.ceilShare(123, 7, 7), 123);
        assertEq(VaultMath.floorShare(123, 7, 7), 123);
    }

    /// @custom:requirement R-VLT-3 R-VLT-8
    function test_RevertWhen_SupplyIsZero() public {
        vm.expectRevert(VaultMath.ZeroSupply.selector);
        h.ceilShare(1, 1, 0);
        vm.expectRevert(VaultMath.ZeroSupply.selector);
        h.floorShare(1, 1, 0);
    }

    /// @custom:requirement R-VLT-3 R-VLT-8
    function test_RevertWhen_ResultOverflows() public {
        vm.expectRevert();
        h.ceilShare(type(uint256).max, 2, 1);
        vm.expectRevert();
        h.floorShare(type(uint256).max, 2, 1);
    }

    /// @notice Differential: agrees with Uniswap's independent `FullMath` implementation, and the two roundings
    /// bracket the exact rational value by at most one unit.
    /// @custom:requirement R-VLT-3 R-VLT-8
    function testFuzz_MatchesFullMath_AndBracketsExactValue(
        uint128 amount,
        uint128 shares,
        uint128 supply
    ) public pure {
        supply = uint128(bound(supply, 1, type(uint128).max));
        uint256 up = VaultMath.ceilShare(amount, shares, supply);
        uint256 down = VaultMath.floorShare(amount, shares, supply);
        assertEq(up, FullMath.mulDivRoundingUp(amount, shares, supply));
        assertEq(down, FullMath.mulDiv(amount, shares, supply));
        assertLe(down, up);
        assertLe(up - down, 1);
        // Exactness: up == down iff the division is exact.
        bool exact = mulmod(uint256(amount), uint256(shares), uint256(supply)) == 0;
        assertEq(up == down, exact);
    }

    /// @notice Rounding favours the vault: entering never pays less, leaving never receives more, than the exact
    /// proportional amount.
    /// @custom:requirement R-VLT-3 R-VLT-8
    /// @custom:invariant INV-5
    function testFuzz_RoundingFavoursVault(uint112 amount, uint112 shares, uint112 supply)
        public
        pure
    {
        supply = uint112(bound(supply, 1, type(uint112).max));
        uint256 up = VaultMath.ceilShare(amount, shares, supply);
        uint256 down = VaultMath.floorShare(amount, shares, supply);
        uint256 product = uint256(amount) * shares; // < 2^224, no overflow
        // Cross-multiplied: up * supply >= amount * shares >= down * supply (products stay below 2^226).
        assertGe(up * supply, product, "entering never pays less than exact");
        assertLe(down * supply, product, "leaving never receives more than exact");
    }

    /// @notice INV-5 (maths form): depositing `shares` then immediately redeeming the same shares never returns
    /// more than was paid, for any vault total, share count and prior supply.
    /// @custom:requirement R-VLT-3 R-VLT-8
    /// @custom:invariant INV-5
    function testFuzz_DepositThenRedeem_NeverReturnsMoreThanPaid(
        uint128 total,
        uint128 shares,
        uint128 supply
    ) public pure {
        supply = uint128(bound(supply, 1_000, type(uint120).max));
        shares = uint128(bound(shares, 0, type(uint120).max));
        total = uint128(bound(total, 0, type(uint120).max));
        uint256 paid = VaultMath.ceilShare(total, shares, supply);
        // After the deposit the vault holds total + paid and the supply is supply + shares.
        uint256 back = VaultMath.floorShare(uint256(total) + paid, shares, uint256(supply) + shares);
        assertLe(back, paid, "round trip must not profit");
    }

    /// @notice Same round-trip property over small numbers, where rounding differences are frequent and any
    /// wrong rounding direction shows up quickly.
    /// @custom:requirement R-VLT-3 R-VLT-8
    /// @custom:invariant INV-5
    function testFuzz_DepositThenRedeem_SmallNumbers(uint16 total, uint16 shares, uint16 supply)
        public
        pure
    {
        uint256 sup = bound(supply, 1, 5_000);
        uint256 paid = VaultMath.ceilShare(total, shares, sup);
        uint256 back = VaultMath.floorShare(uint256(total) + paid, shares, sup + shares);
        assertLe(back, paid, "round trip must not profit");
    }

    /// @custom:requirement R-VLT-3 R-VLT-8
    function testFuzz_MonotonicInShares(uint128 amount, uint128 s1, uint128 s2, uint128 supply)
        public
        pure
    {
        supply = uint128(bound(supply, 1, type(uint128).max));
        (s1, s2) = s1 <= s2 ? (s1, s2) : (s2, s1);
        assertLe(VaultMath.ceilShare(amount, s1, supply), VaultMath.ceilShare(amount, s2, supply));
        assertLe(VaultMath.floorShare(amount, s1, supply), VaultMath.floorShare(amount, s2, supply));
    }

    /// @notice Splitting a redeem into two halves never pays more than redeeming at once (no gain from slicing).
    /// @custom:requirement R-VLT-8
    /// @custom:invariant INV-5
    function testFuzz_SplitRedeem_NeverBeatsSingleRedeem(
        uint128 amount,
        uint128 s1,
        uint128 s2,
        uint128 supply
    ) public pure {
        supply = uint128(bound(supply, 1, type(uint128).max));
        s1 = uint128(bound(s1, 0, type(uint128).max / 2));
        s2 = uint128(bound(s2, 0, type(uint128).max / 2));
        uint256 split =
            VaultMath.floorShare(amount, s1, supply) + VaultMath.floorShare(amount, s2, supply);
        assertLe(split, VaultMath.floorShare(amount, uint256(s1) + s2, supply));
    }
}
