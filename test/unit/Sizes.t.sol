// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BallastHook} from "../../src/BallastHook.sol";
import {BallastVaults} from "../../src/BallastVaults.sol";
import {BallastStandby} from "../../src/BallastStandby.sol";
import {BallastShares} from "../../src/BallastShares.sol";
import {BallastDepth} from "../../src/BallastDepth.sol";
import {BallastLens} from "../../src/periphery/BallastLens.sol";
import {SupplyCapAdvisor} from "../../src/periphery/SupplyCapAdvisor.sol";
import {ConfigFixture} from "../utils/ConfigFixture.sol";

/// @notice Size bounds (ADR-046, ADR-050): every runtime below the target, every initcode (creation code plus the
/// largest constructor arguments) at least 3,000 bytes under EIP-3860's 49,152. `BallastVaults` is the one runtime
/// allowed above the 23,800 target, up to 24,300, so that a margin of at least 250 bytes to EIP-170 remains.
contract SizesTest is Test {
    uint256 internal constant EIP_170 = 24_576;
    uint256 internal constant EIP_3860 = 49_152;
    uint256 internal constant RUNTIME_TARGET = 23_800;
    uint256 internal constant VAULTS_RUNTIME_MAX = 24_300;
    uint256 internal constant MIN_RUNTIME_MARGIN = 250;
    uint256 internal constant MIN_INITCODE_MARGIN = 3_000;

    function _runtime(string memory artifact) internal view returns (uint256) {
        return vm.getDeployedCode(artifact).length;
    }

    function _initcode(bytes memory creation, bytes memory args) internal pure returns (uint256) {
        return creation.length + args.length;
    }

    function test_Runtime_HookIsUnderTarget() public view {
        assertLe(_runtime("BallastHook.sol:BallastHook"), RUNTIME_TARGET);
    }

    function test_Runtime_VaultsKeepAnEip170Margin() public view {
        uint256 size = _runtime("BallastVaults.sol:BallastVaults");
        assertLe(size, VAULTS_RUNTIME_MAX, "vaults runtime above the ADR-050 ceiling");
        assertGe(EIP_170 - size, MIN_RUNTIME_MARGIN, "margin to EIP-170");
    }

    function test_Runtime_OthersAreUnderTarget() public view {
        assertLe(_runtime("BallastStandby.sol:BallastStandby"), RUNTIME_TARGET);
        assertLe(_runtime("BallastShares.sol:BallastShares"), RUNTIME_TARGET);
        assertLe(_runtime("BallastDepth.sol:BallastDepth"), RUNTIME_TARGET);
        assertLe(_runtime("BallastLens.sol:BallastLens"), RUNTIME_TARGET);
        assertLe(_runtime("SupplyCapAdvisor.sol:SupplyCapAdvisor"), RUNTIME_TARGET);
    }

    function test_Initcode_EveryContractKeepsAMargin() public pure {
        bytes memory cfgArgs = abi.encode(address(1), ConfigFixture.prodLike(), address(2));
        uint256 limit = EIP_3860 - MIN_INITCODE_MARGIN;
        assertLe(_initcode(type(BallastHook).creationCode, cfgArgs), limit, "hook initcode");
        assertLe(_initcode(type(BallastVaults).creationCode, cfgArgs), limit, "vaults initcode");
        assertLe(_initcode(type(BallastStandby).creationCode, cfgArgs), limit, "standby initcode");
        assertLe(_initcode(type(BallastShares).creationCode, ""), limit, "shares initcode");
        assertLe(_initcode(type(BallastDepth).creationCode, ""), limit, "depth initcode");
        assertLe(_initcode(type(BallastLens).creationCode, cfgArgs), limit, "lens initcode");
        assertLe(_initcode(type(SupplyCapAdvisor).creationCode, cfgArgs), limit, "advisor initcode");
    }
}
