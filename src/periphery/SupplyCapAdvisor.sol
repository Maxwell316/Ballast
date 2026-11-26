// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IBallastDepthOracle} from "../interfaces/IBallastDepthOracle.sol";

/// @title SupplyCapAdvisor
/// @notice Reference view that turns guaranteed depth into a suggested supply cap: `multiplier * liveDepth`.
/// @dev Advisory only. It integrates with no lending protocol and holds no state beyond the depth source. The
/// multiplier is a parameter; Chaos Labs' published methodology uses 2x liquidity at the liquidation-penalty price
/// impact (docs/ECONOMICS.md cites the sources). It moves no funds and has no owner.
contract SupplyCapAdvisor {
    /// @notice The multiplier is fixed-point with 18 decimals.
    uint256 public constant WAD = 1e18;

    /// @notice Where depth is read from (the lens of a Ballast pool).
    IBallastDepthOracle public immutable depthOracle;

    constructor(IBallastDepthOracle depthOracle_) {
        depthOracle = depthOracle_;
    }

    /// @notice `floor(multiplierWad * liveDepth(impactBps, horizon) / 1e18)`, in collateral raw units.
    /// @param multiplierWad Cap multiplier, 1e18 = 1x.
    /// @param impactBps Price impact at which depth is measured (for example the liquidation penalty).
    /// @param horizon Seconds the depth must stay available; exits maturing inside it are netted.
    function suggestedCap(uint256 multiplierWad, uint16 impactBps, uint32 horizon)
        external
        view
        returns (uint256)
    {
        return FixedPointMathLib.fullMulDiv(
            multiplierWad, depthOracle.liveDepth(impactBps, horizon), WAD
        );
    }
}
