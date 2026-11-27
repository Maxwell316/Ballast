// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {RewardMath} from "./libraries/RewardMath.sol";
import {Transient} from "./libraries/Transient.sol";
import {IBallastStandby} from "./interfaces/IBallastStandby.sol";
import {Config, StandbyInfo} from "./types/Types.sol";

/// @title BallastStandby
/// @notice Holds the sponsor's standby fund as PoolManager claims and pays accrued rewards to `BallastVaults`
/// (ADR-046, R-SBY-1..6). The vaults contract passes in the eligible depth and the interval and applies the result.
/// @dev Created by `BallastVaults` in its constructor. It has no way to touch vault principal or positions: its only
/// outward calls are PoolManager `unlock`, `settle`/`take` of the sponsor's own funding, and ERC-6909 `transfer` of
/// quote claims to the vaults contract. Acyclic: vaults call standby, standby calls only the PoolManager. No owner,
/// admin, proxy or `delegatecall`.
contract BallastStandby is IUnlockCallback, IBallastStandby {
    using CurrencySettler for Currency;

    /// @notice The caller of `unlockCallback` was not the PoolManager.
    error NotPoolManager();
    /// @notice Only the vaults contract may call this function.
    error NotVaultsContract(address caller);

    IPoolManager public immutable poolManager;
    address public immutable vaults;
    Currency private immutable _quote;
    address private immutable _sponsor;
    uint128 private immutable _maxStandbyRate;

    uint128 private _fund;
    uint128 private _rate;
    uint256 private _credited;
    bool private _depleted;

    constructor(IPoolManager poolManager_, address vaults_, Config memory cfg) {
        poolManager = poolManager_;
        // Only `BallastVaults` constructs this contract, passing `address(this)`; zero is unreachable.
        // slither-disable-next-line missing-zero-check
        vaults = vaults_;
        _quote = cfg.quote;
        _sponsor = cfg.sponsor;
        _maxStandbyRate = cfg.maxStandbyRate;
    }

    /// @inheritdoc IBallastStandby
    /// @custom:requirement R-SBY-2
    function fundStandby(uint128 amount) external {
        if (msg.sender != _sponsor) revert NotSponsor(msg.sender);
        if (amount == 0) revert ZeroShares();
        if (Transient.get(Transient.LOCK)) revert Reentrancy();
        // Effects first (checks-effects-interactions): a failing unlock reverts all of it, and the callback does not
        // read the fund. The transient lock blocks re-entry through a hostile quote token during the unlock.
        _fund += amount;
        _depleted = false;
        emit StandbyFunded(msg.sender, amount);
        Transient.set(Transient.LOCK, true);
        // slither-disable-next-line unused-return
        poolManager.unlock(abi.encode(msg.sender, amount));
        Transient.set(Transient.LOCK, false);
    }

    /// @inheritdoc IBallastStandby
    /// @custom:requirement R-SBY-2
    function setStandbyRate(uint128 rate) external {
        if (msg.sender != _sponsor) revert NotSponsor(msg.sender);
        if (rate > _maxStandbyRate) revert StandbyRateTooHigh();
        _rate = rate;
        emit StandbyRateSet(rate);
    }

    /// @notice PoolManager callback for funding: settles the sponsor's tokens and mints claims to this contract.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address payer, uint128 amount) = abi.decode(data, (address, uint128));
        Currency q = _quote;
        q.settle(poolManager, payer, amount, false);
        q.take(poolManager, address(this), amount, true);
        return "";
    }

    /// @inheritdoc IBallastStandby
    /// @custom:requirement R-SBY-3 R-SBY-6
    /// @custom:invariant INV-8
    function accrue(uint128 eligibleDepth, uint32 dt) external returns (uint256 reward) {
        if (msg.sender != vaults) revert NotVaultsContract(msg.sender);
        uint128 rate = _rate;
        if (rate == 0 || eligibleDepth == 0 || dt == 0) return 0;
        uint128 fund = _fund;
        reward = RewardMath.capToFund(RewardMath.accrue(eligibleDepth, rate, dt), fund);
        if (reward == 0) return 0;
        // SAFETY: reward <= fund <= 2^128 - 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 r = uint128(reward);
        _fund = fund - r;
        _credited += reward;
        if (fund == r && !_depleted) {
            _depleted = true;
            emit StandbyDepleted();
        }
        // The reward is quote claims already held here; handing them to the vaults moves the claims in step with
        // the vaults' ledger credit (INV-3). Last, after every state change (checks-effects-interactions).
        // slither-disable-next-line unused-return
        poolManager.transfer(vaults, uint256(uint160(Currency.unwrap(_quote))), reward);
    }

    /// @inheritdoc IBallastStandby
    function standbyInfo() external view returns (StandbyInfo memory) {
        return StandbyInfo(_fund, _rate, _credited);
    }
}
