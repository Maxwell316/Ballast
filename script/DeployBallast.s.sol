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
import {BallastVaults} from "../src/BallastVaults.sol";
import {BallastLens} from "../src/periphery/BallastLens.sol";
import {SupplyCapAdvisor} from "../src/periphery/SupplyCapAdvisor.sol";
import {IBallastHook} from "../src/interfaces/IBallastHook.sol";
import {IBallastDepthOracle} from "../src/interfaces/IBallastDepthOracle.sol";
import {Config} from "../src/types/Types.sol";
import {HookPermissions} from "../src/libraries/HookPermissions.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {DemoConfig} from "./config/DemoConfig.sol";

/// @title DeployBallast
/// @notice Deployment of a Ballast pool (ADR-050): demo mock tokens, the vaults (which create shares, standby and the
/// depth calculator), the hook at a CREATE2 address mined for its five permission flags, the lens, the advisor, and the
/// pool initialisation, all in ONE broadcast from the configured initializer (ADR-014, T15, T20). Addresses of the
/// PoolManager and the CREATE2 deployer are read from `config/addresses.json`; nothing is hard-coded.
/// @dev Order: (1) tokens, (2) predict the vaults address from the deployer's nonce, (3) mine the hook salt over the
/// full creation code plus constructor arguments (which include the predicted vaults address), (4) deploy the vaults
/// with the mined hook address as an immutable, (5) deploy the hook through the CREATE2 deployer; its constructor
/// verifies the binding in one direction and `VerifyBinding` verifies both. Every prediction is asserted.
/// Sender = initializer = sponsor (override the sponsor with `SPONSOR`). Run without `--broadcast` for a dry run.
/// With `WRITE_MANIFEST=true` the addresses are also written to `deployments/<chainId>.json`.
contract DeployBallast is Script {
    uint8 internal constant COLLATERAL_DECIMALS = 18;
    uint8 internal constant QUOTE_DECIMALS = 6;

    struct Deployed {
        address collateral;
        address quote;
        address hook;
        address vaults;
        address shares;
        address standby;
        address depthCalc;
        address lens;
        address advisor;
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
        BallastHook hook;
        BallastVaults vaults;
        (hook, vaults, d.salt) = _deployBound(pm, create2Deployer, cfg, deployer);
        BallastLens lens = new BallastLens(IBallastHook(address(hook)), vaults.shareToken());
        SupplyCapAdvisor advisor = new SupplyCapAdvisor(IBallastDepthOracle(address(lens)));
        d.startTick = _initPool(pm, hook, cfg);
        vm.stopBroadcast();

        d.collateral = address(collateral);
        d.quote = address(quote);
        d.hook = address(hook);
        d.vaults = address(vaults);
        d.shares = address(vaults.shareToken());
        d.standby = address(vaults.standby());
        d.depthCalc = address(vaults.depthCalc());
        d.lens = address(lens);
        d.advisor = address(advisor);
        d.poolId = PoolId.unwrap(hook.poolId());
        console2.log("chainId             ", block.chainid);
        console2.log("deployer/initializer", deployer);
        console2.log("sponsor             ", sponsor);
        console2.log("collateral (bCOL)   ", d.collateral);
        console2.log("quote (bQTE)        ", d.quote);
        console2.log("hook                ", d.hook);
        console2.log("vaults              ", d.vaults);
        console2.log("shares              ", d.shares);
        console2.log("standby             ", d.standby);
        console2.log("depthCalc           ", d.depthCalc);
        console2.log("lens                ", d.lens);
        console2.log("advisor             ", d.advisor);
        console2.log("salt                ", vm.toString(d.salt));
        console2.log("poolId              ", vm.toString(d.poolId));
        console2.log("start tick          ", d.startTick);
        if (vm.envOr("WRITE_MANIFEST", false)) _writeManifest(d);
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

    /// @dev Predicts the vaults address, mines the hook salt, deploys the vaults then the hook (ADR-050). The hook is
    /// deployed through the CREATE2 deployer with an explicit call (`salt ++ initcode`), not `new C{salt: s}()`:
    /// Foundry's implicit routing of `new{salt}` differs between a dry run and a broadcast, which would silently change
    /// the address (observed during M2). Aborts if any predicted address or flag differs from the actual one.
    function _deployBound(
        IPoolManager pm,
        address create2Deployer,
        Config memory cfg,
        address deployer
    ) internal returns (BallastHook hook, BallastVaults vaults, bytes32 salt) {
        uint64 vaultsNonce = vm.getNonce(deployer);
        address predictedVaults = vm.computeCreateAddress(deployer, vaultsNonce);
        require(predictedVaults.code.length == 0, "vaults address already occupied");

        uint160 flags = HookPermissions.flags(HookPermissions.permissions());
        bytes memory args = abi.encode(address(pm), cfg, predictedVaults);
        address predictedHook;
        (predictedHook, salt) =
            HookMiner.find(create2Deployer, flags, type(BallastHook).creationCode, args);
        require(predictedHook.code.length == 0, "hook address already occupied");

        vaults = new BallastVaults(pm, IBallastHook(predictedHook), cfg);
        require(address(vaults) == predictedVaults, "vaults address differs from prediction");
        require(vm.getNonce(deployer) == vaultsNonce + 1, "unexpected deployer nonce");

        (bool ok,) =
            create2Deployer.call(abi.encodePacked(salt, type(BallastHook).creationCode, args));
        require(ok && predictedHook.code.length > 0, "CREATE2 deployment failed");
        hook = BallastHook(predictedHook);
        require(hook.vaults() == address(vaults), "hook does not point at the vaults");
        require(address(vaults.hook()) == address(hook), "vaults do not point at the hook");
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

    function _writeManifest(Deployed memory d) internal {
        string memory k = "manifest";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "collateral", d.collateral);
        vm.serializeAddress(k, "quote", d.quote);
        vm.serializeAddress(k, "hook", d.hook);
        vm.serializeAddress(k, "vaults", d.vaults);
        vm.serializeAddress(k, "shares", d.shares);
        vm.serializeAddress(k, "standby", d.standby);
        vm.serializeAddress(k, "depthCalc", d.depthCalc);
        vm.serializeAddress(k, "lens", d.lens);
        vm.serializeAddress(k, "advisor", d.advisor);
        vm.serializeBytes32(k, "salt", d.salt);
        string memory out = vm.serializeBytes32(k, "poolId", d.poolId);
        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
