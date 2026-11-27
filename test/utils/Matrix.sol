// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BruteForce} from "./BruteForce.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Config} from "../../src/types/Types.sol";

/// @notice Runs one test body over the whole collateral-ordering x lens-construction-order matrix (ADR-058): the
/// collateral is currency0 or currency1, and the lens is built before or after the pool is initialised. A test
/// contract inherits `Matrix`, sets up with `_setUpMatrix`, and is instantiated four times by inheriting one mixin
/// (`C0Before`, `C0After`, `C1Before`, `C1After`) per leaf contract. Ordering-dependent reads go through the helpers
/// below so a test body never hard-codes which currency is the quote.
abstract contract Matrix is BruteForce {
    function _c0() internal pure virtual returns (bool);

    function _lensAfter() internal pure virtual returns (bool);

    /// @dev The variant a leaf claims to be is the variant that was built.
    function _assertVariant() internal view {
        assertEq(collateralIs0, _c0(), "ordering flag");
        assertEq(
            Currency.unwrap(cfg.collateral) < Currency.unwrap(cfg.quote),
            _c0(),
            "collateral sorts as currency0 iff the variant says so"
        );
        assertEq(lensAfterInit, _lensAfter(), "lens construction order");
    }

    /// @dev Every leaf runs this against its `setUp` fixture. A suite that builds its fixture inside each test (the
    /// fixture does not exist yet here) calls `_assertVariant` itself from a test of its own.
    function test_Matrix_VariantIsWhatItClaims() public view {
        if (address(pm) == address(0)) return;
        _assertVariant();
    }

    function _setUpMatrix(Config memory c, int24 startTick) internal {
        lensAfterInit = _lensAfter();
        _setUpDefault(_c0(), c, startTick);
    }

    /// @dev Idle balance of the quote (the standby reward currency) of vault `v`.
    function _idleQuote(uint256 v) internal view returns (uint256) {
        return _c0() ? lens.vault(v).idle1 : lens.vault(v).idle0;
    }

    /// @dev Idle balance of the collateral of vault `v`.
    function _idleCollateral(uint256 v) internal view returns (uint256) {
        return _c0() ? lens.vault(v).idle0 : lens.vault(v).idle1;
    }

    /// @dev Curator-owed balance of the quote of vault `v`.
    function _owedQuote(uint256 v) internal view returns (uint256) {
        return _c0() ? lens.vault(v).curatorOwed1 : lens.vault(v).curatorOwed0;
    }

    /// @dev Signed direction of a collateral sale on the tick: -1 if ticks fall (collateral is currency0), else +1.
    function _liquidationSign() internal pure returns (int24) {
        return _c0() ? int24(-1) : int24(1);
    }
}

abstract contract C0Before is Matrix {
    function _c0() internal pure override returns (bool) {
        return true;
    }

    function _lensAfter() internal pure override returns (bool) {
        return false;
    }
}

abstract contract C0After is Matrix {
    function _c0() internal pure override returns (bool) {
        return true;
    }

    function _lensAfter() internal pure override returns (bool) {
        return true;
    }
}

abstract contract C1Before is Matrix {
    function _c0() internal pure override returns (bool) {
        return false;
    }

    function _lensAfter() internal pure override returns (bool) {
        return false;
    }
}

abstract contract C1After is Matrix {
    function _c0() internal pure override returns (bool) {
        return false;
    }

    function _lensAfter() internal pure override returns (bool) {
        return true;
    }
}
