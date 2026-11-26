// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BallastHook} from "../../../src/BallastHook.sol";
import {BallastVaults} from "../../../src/BallastVaults.sol";
import {IBallastErrors} from "../../../src/interfaces/IBallastErrors.sol";
import {IBallastHook} from "../../../src/interfaces/IBallastHook.sol";
import {HookPermissions} from "../../../src/libraries/HookPermissions.sol";
import {Config, Range} from "../../../src/types/Types.sol";
import {HookMiner} from "../../../script/utils/HookMiner.sol";
import {HookFixture} from "../../utils/HookFixture.sol";
import {BoundDeploy} from "../../utils/BoundDeploy.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";

/// @notice T20: the hook refuses a vaults contract that is missing, bound to another hook, or built with another
/// configuration; and the vaults are unusable until the pool is bound (ADR-050).
/// @custom:requirement R-SPLIT-1 R-POOL-1
contract BindingTest is HookFixture, BoundDeploy {
    function _mine(Config memory c, address vaultsAddr) internal view returns (bytes32 salt) {
        (, salt) = HookMiner.find(
            address(this),
            HookPermissions.flags(HookPermissions.permissions()),
            type(BallastHook).creationCode,
            abi.encode(address(pm), c, vaultsAddr)
        );
    }

    function setUp() public {
        _deployInfra();
        _tokens(true, 18, 6);
    }

    function _cfg() internal view returns (Config memory c) {
        c = ConfigFixture.compressed();
        c.collateral = Currency.wrap(address(collateral));
        c.quote = Currency.wrap(address(quote));
    }

    function test_RevertWhen_VaultsHaveNoCode() public {
        Config memory c = _cfg();
        address nobody = address(0xDEAD0001);
        bytes32 salt = _mine(c, nobody);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.VaultsNotDeployed.selector, nobody));
        new BallastHook{salt: salt}(pm, c, nobody);
    }

    function test_RevertWhen_VaultsAreBoundToAnotherHook() public {
        Config memory c = _cfg();
        address predicted = _predictVaults();
        bytes32 salt = _mine(c, predicted);
        BallastVaults wrong = new BallastVaults(pm, IBallastHook(address(0xBEEF)), c);
        assertEq(address(wrong), predicted);
        vm.expectRevert(IBallastErrors.VaultsBindingMismatch.selector);
        new BallastHook{salt: salt}(pm, c, address(wrong));
    }

    function test_RevertWhen_VaultsWereBuiltWithAnotherConfig() public {
        Config memory c = _cfg();
        address predicted = _predictVaults();
        bytes32 salt = _mine(c, predicted);
        // Same hook address, different configuration (a wider band): the config hash differs.
        Config memory other = _cfg();
        other.bandBps = 900;
        BallastVaults wrong =
            new BallastVaults(pm, IBallastHook(_hookAddr(salt, c, predicted)), other);
        assertEq(address(wrong), predicted);
        vm.expectRevert(IBallastErrors.VaultsBindingMismatch.selector);
        new BallastHook{salt: salt}(pm, c, address(wrong));
    }

    function _hookAddr(bytes32 salt, Config memory c, address vaultsAddr)
        internal
        view
        returns (address)
    {
        return HookMiner.computeAddress(
            address(this),
            salt,
            keccak256(
                abi.encodePacked(
                    type(BallastHook).creationCode, abi.encode(address(pm), c, vaultsAddr)
                )
            )
        );
    }

    function test_Correct_Binding_Deploys() public {
        Config memory c = _cfg();
        (BallastHook h, BallastVaults v,) = _deployBound(pm, c);
        assertEq(h.vaults(), address(v));
        assertEq(address(v.hook()), address(h));
        assertEq(v.configHash(), keccak256(abi.encode(c)));
    }

    // ─── nothing works until the pool is bound ───

    function test_BeforeBinding_VaultsAndHookRefuse() public {
        _deployHook(_cfg()); // deployed, pool not initialised
        Range[] memory r = new Range[](1);
        r[0] = Range(-60, 60);
        vm.expectRevert(IBallastErrors.PoolNotBound.selector);
        vaults.createVault(r, 0, 0);
        vm.expectRevert(IBallastErrors.PoolNotBound.selector);
        hook.evaluateStress();
    }
}
