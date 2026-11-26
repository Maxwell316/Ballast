// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BallastHook} from "../../src/BallastHook.sol";
import {BallastVaults} from "../../src/BallastVaults.sol";
import {IBallastHook} from "../../src/interfaces/IBallastHook.sol";
import {HookPermissions} from "../../src/libraries/HookPermissions.sol";
import {Config} from "../../src/types/Types.sol";
import {HookMiner} from "../../script/utils/HookMiner.sol";

/// @notice Test helper that follows the production deployment order (ADR-050): predict the vaults address from the
/// deployer's nonce, mine the hook salt over creation code plus arguments (which include that address), deploy the
/// vaults with the mined hook address, then deploy the hook with CREATE2. The deployer is `address(this)`.
abstract contract BoundDeploy is Test {
    function _predictVaults() internal view returns (address) {
        return vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
    }

    /// @dev Mines the hook address for `cfg`, deploys the vaults bound to it and returns both plus the hook salt. The
    /// hook itself is NOT deployed; callers either `new BallastHook{salt: salt}(...)` or place a harness with
    /// `deployCodeTo`.
    function _mineAndDeployVaults(IPoolManager pm, Config memory cfg)
        internal
        returns (address hookAddr, bytes32 salt, BallastVaults vaults)
    {
        address predictedVaults = _predictVaults();
        (hookAddr, salt) = HookMiner.find(
            address(this),
            HookPermissions.flags(HookPermissions.permissions()),
            type(BallastHook).creationCode,
            abi.encode(pm, cfg, predictedVaults)
        );
        vaults = new BallastVaults(pm, IBallastHook(hookAddr), cfg);
        assertEq(address(vaults), predictedVaults, "vaults address prediction");
    }

    function _deployBound(IPoolManager pm, Config memory cfg)
        internal
        returns (BallastHook hook, BallastVaults vaults, bytes32 salt)
    {
        address hookAddr;
        (hookAddr, salt, vaults) = _mineAndDeployVaults(pm, cfg);
        hook = new BallastHook{salt: salt}(pm, cfg, address(vaults));
        assertEq(address(hook), hookAddr, "hook address prediction");
    }
}
