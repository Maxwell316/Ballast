// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BallastHook} from "../src/BallastHook.sol";
import {Config} from "../src/types/Types.sol";
import {HookPermissions} from "../src/libraries/HookPermissions.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {DemoConfig} from "./config/DemoConfig.sol";

/// @title DeployBallast
/// @notice M2 deployment: demo mock tokens, the hook at a CREATE2 address mined for its five permission flags, and the
/// pool initialisation, all in ONE broadcast from the configured initializer (ADR-014, T15). Addresses of the
/// PoolManager and the CREATE2 deployer are read from `config/addresses.json`; nothing is hard-coded.
/// @dev Sender = initializer = sponsor (override the sponsor with `SPONSOR`). Run without `--broadcast` for a dry run.
/// This script writes no manifest: addresses depend on the sender's nonce, so the manifest
/// (`deployments/<chainId>.json`) is recorded from the actual transactions (docs/DEPLOYMENT.md §8).
contract DeployBallast is Script {
    uint8 internal constant COLLATERAL_DECIMALS = 18;
    uint8 internal constant QUOTE_DECIMALS = 6;

    struct Deployed {
        address collateral;
        address quote;
        address hook;
        bytes32 salt;
        bytes32 poolId;
        int24 startTick;
    }

    function run() external returns (Deployed memory d) {
        string memory addresses = vm.readFile("config/addresses.json");
        string memory chainKey = string.concat(".", vm.toString(block.chainid));
        IPoolManager pm =
            IPoolManager(vm.parseJsonAddress(addresses, string.concat(chainKey, ".poolManager")));
        address create2Deployer =
            vm.parseJsonAddress(addresses, string.concat(chainKey, ".create2Deployer"));
        require(address(pm).code.length > 0, "no PoolManager code on this chain");
        require(create2Deployer == CREATE2_FACTORY, "unexpected CREATE2 deployer");
        require(create2Deployer.code.length > 0, "no CREATE2 deployer code on this chain");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address sponsor = vm.envOr("SPONSOR", deployer);

        (MockToken collateral, MockToken quote) = _deployTokens(deployer);
        Config memory cfg = DemoConfig.make(
            Currency.wrap(address(collateral)), Currency.wrap(address(quote)), sponsor, deployer
        );
        (BallastHook hook, bytes32 salt) = _deployHook(pm, create2Deployer, cfg);
        d.startTick = _initPool(pm, hook, cfg);
        vm.stopBroadcast();

        d.collateral = address(collateral);
        d.quote = address(quote);
        d.hook = address(hook);
        d.salt = salt;
        d.poolId = PoolId.unwrap(hook.poolId());
        console2.log("chainId             ", block.chainid);
        console2.log("deployer/initializer", deployer);
        console2.log("sponsor             ", sponsor);
        console2.log("collateral (bCOL)   ", d.collateral);
        console2.log("quote (bQTE)        ", d.quote);
        console2.log("hook                ", d.hook);
        console2.log("salt                ", vm.toString(d.salt));
        console2.log("poolId              ", vm.toString(d.poolId));
        console2.log("start tick          ", d.startTick);
    }

    /// @dev Orders the deployments so the collateral sorts as currency0 without spending a transaction on a retry.
    function _deployTokens(address deployer)
        internal
        returns (MockToken collateral, MockToken quote)
    {
        uint64 nonce = vm.getNonce(deployer);
        bool collateralFirst =
            vm.computeCreateAddress(deployer, nonce) < vm.computeCreateAddress(deployer, nonce + 1);
        if (collateralFirst) {
            collateral = new MockToken("Ballast Demo Collateral", "bCOL", COLLATERAL_DECIMALS);
            quote = new MockToken("Ballast Demo Quote", "bQTE", QUOTE_DECIMALS);
        } else {
            quote = new MockToken("Ballast Demo Quote", "bQTE", QUOTE_DECIMALS);
            collateral = new MockToken("Ballast Demo Collateral", "bCOL", COLLATERAL_DECIMALS);
        }
        require(address(collateral) < address(quote), "collateral must be currency0");
    }

    /// @dev Mines a salt for the flags of `getHookPermissions()` and deploys through the CREATE2 deployer with an
    /// explicit call (`salt ++ initcode`), not with `new C{salt: s}()`: Foundry's implicit routing of `new{salt}`
    /// through the deployer differs between a dry run and a broadcast, which would silently change the address
    /// (observed during M2: the dry run created the hook from the sender and failed the flag check). The address is
    /// asserted against the mined one and against `getHookPermissions()` (T15).
    function _deployHook(IPoolManager pm, address create2Deployer, Config memory cfg)
        internal
        returns (BallastHook hook, bytes32 salt)
    {
        uint160 flags = HookPermissions.flags(HookPermissions.permissions());
        bytes memory initCode =
            abi.encodePacked(type(BallastHook).creationCode, abi.encode(address(pm), cfg));
        address predicted;
        (predicted, salt) = HookMiner.find(
            create2Deployer, flags, type(BallastHook).creationCode, abi.encode(address(pm), cfg)
        );
        require(predicted.code.length == 0, "hook address already occupied");
        (bool ok,) = create2Deployer.call(abi.encodePacked(salt, initCode));
        require(ok && predicted.code.length > 0, "CREATE2 deployment failed");
        hook = BallastHook(predicted);
        require(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK
                == HookPermissions.flags(hook.getHookPermissions()),
            "hook address flags differ from getHookPermissions()"
        );
    }

    function _initPool(IPoolManager pm, BallastHook hook, Config memory cfg)
        internal
        returns (int24 tick)
    {
        PoolKey memory key = PoolKey(
            cfg.collateral, cfg.quote, cfg.fee, cfg.tickSpacing, IHooks(address(hook))
        );
        tick = DemoConfig.startTick(true, COLLATERAL_DECIMALS, QUOTE_DECIMALS, cfg.tickSpacing);
        pm.initialize(key, TickMath.getSqrtPriceAtTick(tick));
    }
}
