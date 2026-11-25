// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ConfigLib} from "./libraries/ConfigLib.sol";
import {Config} from "./types/Types.sol";

/// @title BallastHook (M0 stub)
/// @notice Committed-liquidation-depth hook. This stub carries the validated immutable configuration and the
/// five-flag permission set; hook callbacks, vaults and accounting arrive in later milestones.
/// @dev Inherits OpenZeppelin `BaseHook` (ADR-030), which validates the deployed address against
/// `getHookPermissions()` in its constructor. Configuration lives in immutables so the swap path never reads
/// configuration from storage.
contract BallastHook is BaseHook {
    Currency private immutable _collateral;
    Currency private immutable _quote;
    address private immutable _sponsor;
    address private immutable _initializer;
    uint24 private immutable _fee;
    int24 private immutable _tickSpacing;
    uint16 private immutable _bandBps;
    uint16 private immutable _stressEnterBps;
    uint16 private immutable _stressExitBps;
    uint32 private immutable _anchorWindow;
    uint32 private immutable _shortWindow;
    uint32 private immutable _calmDuration;
    uint32 private immutable _maxStressLock;
    uint32 private immutable _exitNotice;
    uint32 private immutable _rerangeGrace;
    uint32 private immutable _maxAccrualInterval;
    uint16 private immutable _maxCuratorFeeBps;
    uint32 private immutable _observationInterval;
    uint16 private immutable _observationCardinality;
    uint128 private immutable _maxStandbyRate;

    /// @param poolManager_ The v4 PoolManager.
    /// @param cfg Immutable configuration; validated by `ConfigLib.validate` (R-CFG-1).
    constructor(IPoolManager poolManager_, Config memory cfg) BaseHook(poolManager_) {
        ConfigLib.validate(cfg);
        _collateral = cfg.collateral;
        _quote = cfg.quote;
        _sponsor = cfg.sponsor;
        _initializer = cfg.initializer;
        _fee = cfg.fee;
        _tickSpacing = cfg.tickSpacing;
        _bandBps = cfg.bandBps;
        _stressEnterBps = cfg.stressEnterBps;
        _stressExitBps = cfg.stressExitBps;
        _anchorWindow = cfg.anchorWindow;
        _shortWindow = cfg.shortWindow;
        _calmDuration = cfg.calmDuration;
        _maxStressLock = cfg.maxStressLock;
        _exitNotice = cfg.exitNotice;
        _rerangeGrace = cfg.rerangeGrace;
        _maxAccrualInterval = cfg.maxAccrualInterval;
        _maxCuratorFeeBps = cfg.maxCuratorFeeBps;
        _observationInterval = cfg.observationInterval;
        _observationCardinality = cfg.observationCardinality;
        _maxStandbyRate = cfg.maxStandbyRate;
    }

    /// @notice The five permissions Ballast needs and nothing else (D-5). No return-delta flags.
    /// @inheritdoc BaseHook
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory permissions)
    {
        permissions.beforeInitialize = true;
        permissions.afterInitialize = true;
        permissions.beforeAddLiquidity = true;
        permissions.beforeRemoveLiquidity = true;
        permissions.beforeSwap = true;
    }

    /// @notice The immutable configuration this hook was deployed with.
    function config() external view returns (Config memory) {
        return Config({
            collateral: _collateral,
            quote: _quote,
            sponsor: _sponsor,
            initializer: _initializer,
            fee: _fee,
            tickSpacing: _tickSpacing,
            bandBps: _bandBps,
            stressEnterBps: _stressEnterBps,
            stressExitBps: _stressExitBps,
            anchorWindow: _anchorWindow,
            shortWindow: _shortWindow,
            calmDuration: _calmDuration,
            maxStressLock: _maxStressLock,
            exitNotice: _exitNotice,
            rerangeGrace: _rerangeGrace,
            maxAccrualInterval: _maxAccrualInterval,
            maxCuratorFeeBps: _maxCuratorFeeBps,
            observationInterval: _observationInterval,
            observationCardinality: _observationCardinality,
            maxStandbyRate: _maxStandbyRate
        });
    }
}
