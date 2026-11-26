// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BoundDeploy} from "../utils/BoundDeploy.sol";
import {BallastVaults} from "../../src/BallastVaults.sol";
import {IBallastHook} from "../../src/interfaces/IBallastHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "../../script/utils/HookMiner.sol";
import {IBallastErrors} from "../../src/interfaces/IBallastErrors.sol";
import {BallastHook} from "../../src/BallastHook.sol";
import {Config} from "../../src/types/Types.sol";
import {ConfigFixture} from "../utils/ConfigFixture.sol";

contract Tiny {
    uint256 public immutable x;

    constructor(uint256 x_) {
        x = x_;
    }
}

/// @custom:requirement R-DEP-1
contract HookMinerTest is BoundDeploy {
    function test_ComputeAddress_MatchesForgeCreate2() public {
        bytes memory code = type(Tiny).creationCode;
        bytes memory args = abi.encode(uint256(7));
        bytes32 salt = bytes32(uint256(1234));
        address predicted =
            HookMiner.computeAddress(address(this), salt, keccak256(abi.encodePacked(code, args)));
        assertEq(
            predicted,
            vm.computeCreate2Address(salt, keccak256(abi.encodePacked(code, args)), address(this))
        );
        Tiny t = new Tiny{salt: salt}(7);
        assertEq(address(t), predicted);
    }

    /// forge-config: default.fuzz.runs = 64
    /// forge-config: ci.fuzz.runs = 256
    function testFuzz_Find_ReturnsRequestedFlags(uint16 rawFlags) public pure {
        uint160 flags = uint160(rawFlags) & Hooks.ALL_HOOK_MASK;
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(0xBEEF), flags, type(Tiny).creationCode, abi.encode(uint256(1)));
        assertEq(uint160(hookAddress) & HookMiner.FLAG_MASK, flags);
        assertEq(
            hookAddress,
            HookMiner.computeAddress(
                address(0xBEEF),
                salt,
                keccak256(abi.encodePacked(type(Tiny).creationCode, abi.encode(uint256(1))))
            )
        );
    }

    function test_Find_MasksFlagsToLow14Bits() public pure {
        (address a,) = HookMiner.find(
            address(0xBEEF), type(uint160).max, type(Tiny).creationCode, abi.encode(1)
        );
        assertEq(uint160(a) & HookMiner.FLAG_MASK, HookMiner.FLAG_MASK);
    }

    function test_MinedBallastHook_DeploysWithFlagsEqualToPermissions() public {
        IPoolManager pm = IPoolManager(address(0xA11CE));
        Config memory cfg = ConfigFixture.prodLike();
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG;
        (address predicted, bytes32 salt, BallastVaults vaults) = _mineAndDeployVaults(pm, cfg);
        BallastHook hook = new BallastHook{salt: salt}(pm, cfg, address(vaults));
        assertEq(hook.vaults(), address(vaults));
        assertEq(address(vaults.hook()), predicted);

        assertEq(address(hook), predicted, "address matches prediction");
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK, flags, "address flags equal permissions"
        );
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.afterInitialize && p.beforeAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity && p.beforeSwap);
        assertFalse(p.afterAddLiquidity || p.afterRemoveLiquidity || p.afterSwap);
        assertFalse(p.beforeDonate || p.afterDonate);
        assertFalse(
            p.beforeSwapReturnDelta || p.afterSwapReturnDelta || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        Config memory out = hook.config();
        assertEq(out.bandBps, cfg.bandBps);
        assertEq(out.observationCardinality, cfg.observationCardinality);
        assertEq(out.initializer, cfg.initializer);
        assertEq(address(hook.poolManager()), address(pm));
    }

    function test_RevertWhen_DeployedAtAddressWithWrongFlags() public {
        IPoolManager pm = IPoolManager(address(0xA11CE));
        Config memory cfg = ConfigFixture.prodLike();
        // Salt 0 gives an unmined address; its low 14 bits almost certainly differ from the five flags.
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG;
        bytes memory code = type(BallastHook).creationCode;
        address predictedVaults = _predictVaults();
        address wrong = HookMiner.computeAddress(
            address(this),
            bytes32(0),
            keccak256(abi.encodePacked(code, abi.encode(pm, cfg, predictedVaults)))
        );
        BallastVaults vaults = new BallastVaults(pm, IBallastHook(wrong), cfg);
        assertEq(address(vaults), predictedVaults);
        assertTrue(
            uint160(wrong) & Hooks.ALL_HOOK_MASK != flags, "salt 0 must not be a mined address"
        );
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrong));
        new BallastHook{salt: bytes32(0)}(pm, cfg, address(vaults));
    }

    function test_RevertWhen_ConfigInvalid() public {
        IPoolManager pm = IPoolManager(address(0xA11CE));
        Config memory cfg = ConfigFixture.prodLike();
        cfg.bandBps = 1; // invalid
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG;
        (, bytes32 salt, BallastVaults vaults) = _mineAndDeployVaults(pm, cfg);
        vm.expectRevert(IBallastErrors.InvalidConfig.selector);
        new BallastHook{salt: salt}(pm, cfg, address(vaults));
    }
}
