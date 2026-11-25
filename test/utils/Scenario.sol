// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev A test scenario: token decimals and collateral ordering. The library tests run every scenario so each band
/// and depth test covers decimals (18/6, 6/18, equal) and both orderings (collateral as currency0 and currency1).
struct Scenario {
    bool collateralIs0;
    uint8 collateralDecimals;
    uint8 quoteDecimals;
    int24 startTick; // about a 1:1 human price, rounded toward zero to a multiple of `SPACING`
}

library Scenarios {
    int24 internal constant SPACING = 60;
    /// @dev log_{1.0001}(10) rounded: ticks per decade of raw price.
    int256 internal constant TICKS_PER_DECADE = 23_027;

    function make(bool collateralIs0, uint8 collateralDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (Scenario memory s)
    {
        s.collateralIs0 = collateralIs0;
        s.collateralDecimals = collateralDecimals;
        s.quoteDecimals = quoteDecimals;
        // Raw price is token1 per token0. Collateral = token0: quote raw per collateral raw = 10^(qd - cd).
        // Collateral = token1: collateral raw per quote raw = 10^(cd - qd).
        int256 e = collateralIs0
            ? int256(uint256(quoteDecimals)) - int256(uint256(collateralDecimals))
            : int256(uint256(collateralDecimals)) - int256(uint256(quoteDecimals));
        int256 tick = (e * TICKS_PER_DECADE / int256(SPACING)) * int256(SPACING);
        // SAFETY: |e| <= 255 would overflow, but decimals here are <= 18, so |tick| < 24 * 23_027 < 2^23.
        s.startTick = int24(tick);
    }

    /// @notice The default fixture first (collateral 18, quote 6), then (a) 6/18, (b) equal decimals, both orderings.
    function all() internal pure returns (Scenario[] memory out) {
        out = new Scenario[](6);
        out[0] = make(true, 18, 6);
        out[1] = make(false, 18, 6);
        out[2] = make(true, 6, 18);
        out[3] = make(false, 6, 18);
        out[4] = make(true, 18, 18);
        out[5] = make(false, 18, 18);
    }
}
