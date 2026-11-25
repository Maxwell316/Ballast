# Verification log (Phase 1)

**Date:** 2026-11-25 · **Method:** read pinned dependency source under `lib/`, queried the official docs and the live chain. Nothing here is from memory. "Evidence" gives file and line in the pinned sources, a URL, or the command that produced the result.

## Pins

| Dependency | Commit | Role |
|---|---|---|
| v4-core | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (v4.0.0 + 12 commits) | Core. `PoolManager` differs from tag v4.0.0 only by moving `ModifyLiquidityParams`/`SwapParams` into `types/PoolOperation.sol` (`git diff e50237c..59d3ecf5 -- src/PoolManager.sol src/libraries/Hooks.sol`). |
| OpenZeppelin `uniswap-hooks` | `acbd604c409a827f7f98c9517236da860c4fca1a` (v1.2.1, 2025-11-27) | `BaseHook`, `CurrencySettler` (ADR-030) |
| ↳ nested `openzeppelin-contracts` | `fcbae5394ae8ad52d8e580a3477db99814b9d565` (v5.5.0) | `SafeERC20` for the settler; remapped from `lib/uniswap-hooks/lib/` |
| v4-periphery | `c6e4754dab11bd38c6f08ac51c3c868569e93d64` | Tests only (PositionManager, Permit2). Its pinned core is `59d3ecf5`, the same as ours. |
| solady | `acd959aa4bd04720d640bf4e6a5c71037510cc4b` (v0.1.26) | `lnWad`, `ReentrancyGuardTransient` |
| forge-std | `f3dae6e6ee381f25eb6a246f7da9b85c91a68219` (v1.17.0) | Tests and scripts |
| Foundry | forge 1.8.4 (`50af4efe`) | |
| solc | 0.8.26, `evm_version = cancun` | `forge build` succeeds with the pinned set. |

`lib/uniswap-hooks` also vendors its own v4-core, v4-periphery and forge-std submodules; they are unused because `remappings.txt` points `@uniswap/v4-core/` at our pin.

## Findings

### F-1 `BaseHook` source — v4-periphery master no longer ships it; evaluation of OpenZeppelin `uniswap-hooks` (ADR-030)
**Finding:** v4-periphery commit `5da22e60` ("remove hooks and move to hook repo (#510)", 2026-02-06) deleted `src/utils/BaseHook.sol` and `src/utils/HookMiner.sol` (`git show 5da22e60 --stat`); at periphery master `src/utils/` does not exist. A copy lives in `github.com/Uniswap/v4-hooks-public` (`src/base/BaseHook.sol`), a large repository of unrelated hooks.

**Evaluation of OpenZeppelin `uniswap-hooks`** (cloned to a scratch directory and read; tag v1.2.1 and `main` at `b5f10574`):

| Question | Result |
|---|---|
| License | MIT (`LICENSE`, "Copyright (c) 2016-2026 Zeppelin Group Ltd"); SPDX MIT in the files. |
| Audits | Reports in `audits/`: v1.0.0 RC 1, v1.1.0 RC 1, v1.1.0 RC 2. From OpenZeppelin's published pages (found by web search, not read in full): the milestone-1 audit listed `BaseHook.sol` in scope; the v1.1.0 RC 2 audit (commit `3e9fa22`) lists `CurrencySettler.sol`. **The repository README also states the code "has not been audited"** (README line 43, generic disclaimer). I could not machine-read the PDFs here, so the audited scope is taken from the web pages and not independently confirmed. |
| Release and activity | Last stable tag v1.2.1 (2025-11-27). `main` is version 1.3.0 (tag `v1.3.0-rc.0`, 2026-10-07). 231 commits since 2026-05-01. |
| Post-audit changes to the two files we use | Between v1.1.0 and v1.2.1 `BaseHook`: pragma 0.8.26, `@uniswap/v4-core` import paths, `validateHookAddress` renamed `_validateHookAddress` (non-virtual), `virtual` removed from external callbacks, `onlySelf`/`onlyValidPools` removed. `CurrencySettler` shows no functional change in that range. After v1.2.1, `main` adds docs, re-adds `onlyValidPools`, and adds a native-currency payer check to the settler (irrelevant to us). We pin v1.2.1. **No audit report covers v1.2.1.** The diff is structural, but it has not been reviewed by anyone but us. |
| Compatibility | Compiles with our pins: v4-core `59d3ecf5`, solc 0.8.26, `evm_version = cancun`, no `via_ir` (scratch project and the repo's own `forge build`). Pragma `^0.8.26`. |
| `BaseHook` API (v1.2.1, `lib/uniswap-hooks/src/base/BaseHook.sol`) | `abstract contract BaseHook is IHooks`. `IPoolManager public immutable poolManager`, set in `constructor(IPoolManager)`, which then calls `_validateHookAddress(this)` → `Hooks.validateHookPermissions(hook, getHookPermissions())`. `getHookPermissions()` is `public pure virtual`. Modifier `onlyPoolManager` (reverts `NotPoolManager`). External callbacks dispatch to `internal virtual` `_beforeInitialize(address, PoolKey calldata, uint160)`, `_afterInitialize`, `_beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)`, `_beforeRemoveLiquidity`, `_beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) returns (bytes4, BeforeSwapDelta, uint24)`, etc., which default to `revert HookNotImplemented()`. `_validateHookAddress` is not overridable, so tests deploy to a flagged address with `deployCodeTo`. The base does not implement `IUnlockCallback`; we implement it. Self-calls are not handled in the hook at all: the PoolManager never invokes the callbacks on a self-call (F-2). |
| `CurrencySettler` | `settle(currency, poolManager, payer, amount, burn)`: zero amount returns early; `burn == true` calls `poolManager.burn(payer, id, amount)` (claims); otherwise `sync`, `safeTransfer`/`safeTransferFrom` to the PoolManager, `settle()`. `take(currency, poolManager, recipient, amount, claims)`: `claims == true` calls `poolManager.mint(recipient, id, amount)`, else `poolManager.take`. **Covers claims-based settlement.** Amounts are nominal (fee-on-transfer unsupported, consistent with our non-goals). Uses OZ `SafeERC20`. Proven on the real chain by `test_ClaimsSettlement_MintOnRemoveBurnOnAdd` (F-3). |
| OpenZeppelin contracts version | Needs `@openzeppelin/contracts` for `SafeERC20` (pragma `^0.8.20`); its pinned submodule is v5.5.0 (`fcbae539`). We use no other OpenZeppelin code, so there is no version conflict; we remap to the nested copy. |
| `HookMiner` | Not provided. We write our own minimal miner in `script/utils` with unit tests (ADR-030). |

**Decision rule check (human's rule):** compiles with our pins ✓; maintained ✓; `BaseHook` and `CurrencySettler` were in audited scopes, but the exact pinned version (v1.2.1) is not itself audited and the README disclaims audit — **met with this caveat**; settler covers claims ✓. **Result: adopt.** The caveat is mitigated by the small, structural nature of the diff, by our own fork tests against the real PoolManager, and by the fact that the `_before*` surface is the same as the old periphery `BaseHook`, so switching sources later is cheap. See ADR-030.

### F-2 Self-call callback skip (basis of G-1) — **confirmed in source**
- `Hooks.noSelfCall`: `if (msg.sender != address(self)) { _; }` (`lib/v4-core/src/libraries/Hooks.sol:170-174`). It guards `beforeInitialize` (178), `afterInitialize` (185-187), `beforeModifyLiquidity` (195-200), `beforeDonate`/`afterDonate` (318-330). `msg.sender` inside this internal library call is the caller of `PoolManager.modifyLiquidity`.
- `beforeModifyLiquidity` calls `beforeAddLiquidity` when `liquidityDelta > 0` and `beforeRemoveLiquidity` when `< 0` (line 202-206 region; flags at `Hooks.sol:31,34`).
- **Not guarded:** `beforeSwap` (line 248), `afterSwap` (285) and `afterModifyLiquidity` (209) have no `noSelfCall`; irrelevant to Ballast, which never swaps itself, but note that `afterModifyLiquidity` is not skipped (not enabled).
- **Impact:** none on the design. G-1 holds: hook-initiated `modifyLiquidity` skips `beforeAdd/RemoveLiquidity`; any other caller (router, PositionManager) triggers the revert. Position ownership is keyed by `msg.sender`, so an external caller cannot touch hook-owned positions either. **Behavioural test still required (R-LIQ-4, M2).**

### F-3 Hook permission flags and address bit order — **confirmed**
- Flags are `1 << 13` (beforeInitialize) down to `1 << 0` (afterRemoveLiquidityReturnsDelta) (`Hooks.sol:26-46`); `ALL_HOOK_MASK = (1 << 14) - 1`. Use `Hooks.*_FLAG` names, never literals. Ballast's five: `BEFORE_INITIALIZE_FLAG | AFTER_INITIALIZE_FLAG | BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_REMOVE_LIQUIDITY_FLAG | BEFORE_SWAP_FLAG`.
- `PoolManager.initialize` requires a valid hook address (`isValidHookAddress`, `Hooks.sol:108-125`): a hook with no flags and a static fee is rejected, return-delta flags require their action flag.
- **Unichain Sepolia (chain 1301) PoolManager `0x00b036b58a818b1bc34d502d3fe730db729e62ac`:**
  1. Runtime bytecode is 24,009 bytes and identical to the Ethereum mainnet PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90` after masking the embedded self-address (the `NoDelegateCall` immutable; one occurrence at byte 13618 in both). Method: `cast code` on both, byte comparison. So the deployed contract is the final v4 PoolManager and its flag bit order is the one in the pinned `Hooks.sol`.
  2. `test/fork/HooksOnChain.t.sol` (fork of the real PoolManager at block 68,788,256, with `RPC_URL` set; skipped otherwise) places a test hook carrying exactly Ballast's five flags at a flagged address using `deployCodeTo` (the address bits are asserted equal to the flags) and shows, on the real PoolManager:
     - `beforeInitialize` and `afterInitialize` are invoked on `initialize`, and `beforeInitialize`'s `sender` is the caller of `initialize` (basis of ADR-014);
     - `beforeAddLiquidity` and `beforeRemoveLiquidity` are invoked for an external router (the official deployed `PoolModifyLiquidityTest`), with counters incrementing when the hook allows it;
     - a revert in `beforeAddLiquidity` / `beforeRemoveLiquidity` blocks the external router's `modifyLiquidity` (the PoolManager wraps it in `WrappedError`);
     - the hook's own `modifyLiquidity` succeeds while external liquidity is blocked, and its own `beforeAdd/RemoveLiquidity` counters stay at zero (self-call skip, R-LIQ-4);
     - `beforeSwap` is invoked through the official deployed `PoolSwapTest`, and the tick read inside it equals the pre-swap tick;
     - claims-based settlement works with `CurrencySettler` (remove with `claims = true` mints claims; add with `burn = true` burns them). Incidental finding: removing rounds down and adding rounds up, so re-adding the same liquidity from the claims just received is short by dust; the test re-adds 90%.
     All 7 tests pass. This covers all five flags Ballast uses.
- **Still due:** a funded testnet deployment of the real hook in M2 and M9.

### F-4 ERC-6909 base for shares
- `lib/v4-core/src/ERC6909.sol` is an abstract solmate-derived implementation: public `isOperator`, `balanceOf`, `allowance` mappings, `transfer`, `transferFrom`, `approve`, `setOperator`, and `internal virtual` `_mint`/`_burn` (lines 79-90). It has **no `totalSupply`**. `ERC6909Claims.sol` (PoolManager's claims) adds `_burnFrom` only.
- **Decision proposed (ADR-024 item 5 applies):** inherit `ERC6909` (not `ERC6909Claims`), override `_mint`/`_burn` to maintain `totalSupply[id]`. Names `shares` (hook ledger) vs `claims` (PoolManager) stay distinct. `isOperator(owner, caller)` supplies the operator check for `claimRedeem` (ADR-016).
- **Caveat:** `_mint`/`_burn` emit `Transfer(msg.sender, ...)` with the caller as first argument; indexers see the hook-call sender. Acceptable; document in CONTRACTS.

### F-5 Transient storage
- v4-core itself uses `tstore`/`tload` in assembly (`lib/v4-core/src/libraries/Lock.sol:8-19`) and Solidity 0.8.26 has no `transient` keyword for state variables, so Ballast's guards use assembly helpers or Solady's `ReentrancyGuardTransient` (`lib/solady/src/utils/ReentrancyGuardTransient.sol`, pragma `^0.8.24`; compiles with the pin).
- Compiler: `solc = 0.8.26`, `evm_version = cancun` builds all pinned dependencies (`forge build`, 115 files).
- Chain: `cast call <PoolManager> "exttload(bytes32)(bytes32)"` (executes `TLOAD`) succeeds on Unichain Sepolia. The deployed PoolManager also uses transient storage for its unlock lock. **Supported.**
- Note: transient flags persist for the whole transaction, which is what D-9 relies on (`SWAPPED`, `VAULT_OP`).

### F-6 Position key and `StateLibrary`
- `Position.calculatePositionKey(owner, tickLower, tickUpper, salt)` = `keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))` (`lib/v4-core/src/libraries/Position.sol:48-60`).
- `StateLibrary` (`lib/v4-core/src/libraries/StateLibrary.sol`): `getSlot0` (40), `getTickInfo` (76), `getTickLiquidity` (108), `getFeeGrowthGlobals` (157), `getLiquidity` (183), `getPositionInfo(manager, poolId, owner, tickLower, tickUpper, salt)` (230), `getPositionInfo(manager, poolId, positionId)` (254), `getPositionLiquidity(manager, poolId, positionId)` (279). All are `internal view` reading via `extsload`, so no external dependency beyond the PoolManager.
- **Impact:** matches CLAUDE.md §7.4. Salt `bytes32(vaultId << 8 | slot)` is compatible.

### F-7 `modifyLiquidity` deltas and zero-liquidity pokes
- `callerDelta = principalDelta + feesAccrued` (`PoolManager.sol:158-171`), confirming fees are included in `callerDelta`; fee separation must use the returned `feesAccrued`.
- `Position.update` with `liquidityDelta == 0` and recorded liquidity zero reverts `CannotUpdateEmptyPosition` (`Position.sol:84-87`, comment "disallow pokes for 0 liquidity positions"). **Confirms the user's belief; R-LIQ-6 stands.** The hook must track per-position liquidity itself and never poke a zero-liquidity position.

### F-8 Unlock, settlement and initialize
- `unlock` reverts `AlreadyUnlocked` if nested, calls `IUnlockCallback(msg.sender).unlockCallback`, then reverts `CurrencyNotSettled` if `NonzeroDeltaCount != 0` (`PoolManager.sol:103-113`). Consequence: Ballast's public entrypoints cannot be called from inside another contract's open unlock.
- Settlement primitives: `sync`, `settle`, `take`, `clear`, `mint`, `burn` (`PoolManager.sol:277-330`).
- `initialize` (`PoolManager.sol:116-140`): enforces tick spacing in `[1, 32767]` (`TickMath.sol:26-28`), `currency0 < currency1`, valid hook address, then `beforeInitialize(msg.sender, ...)` (`Hooks.sol:178-183`). So the `sender` argument is the caller of `initialize`, which makes ADR-014 (`sender == initializer`) effective. Static fee must be `≤ MAX_LP_FEE = 1_000_000`; `DYNAMIC_FEE_FLAG = 0x800000` (`LPFeeLibrary.sol:14-25`). SPEC §14 constants are therefore confirmed.
- **Settlement helper:** resolved by F-1 (OpenZeppelin `CurrencySettler`, ADR-030). v4-core's own `test/utils/CurrencySettler.sol` was the model for it.

### F-9 Solady and toolchain names
- `ReentrancyGuardTransient` exists (F-5); `FixedPointMathLib.lnWad(int256)` exists (`lib/solady/src/utils/FixedPointMathLib.sol:277`); `SafeTransferLib`, `SafeCastLib` exist. The settler uses OpenZeppelin `SafeERC20`, so `SafeTransferLib` is not needed for settlement.
- `PoolManager.sol` pragma is exactly `0.8.26`; `Hooks.sol` is `^0.8.0`; `BaseHook` is `^0.8.0`. v4-core's own profile uses `evm_version = "cancun"` (`lib/v4-core/foundry.toml:6-7`); periphery too (`lib/v4-periphery/foundry.toml:3,8`). `via_ir` is not needed so far.

### F-10 Network facts (Unichain Sepolia)
- Chain ID **1301**, RPC `https://sepolia.unichain.org`, explorer `https://sepolia.uniscan.xyz` (Unichain docs, https://docs.unichain.org/docs/technical-information/network-information). `cast chain-id --rpc-url https://sepolia.unichain.org` returns `1301`.
- Official v4 addresses for chain 1301 from https://docs.uniswap.org/contracts/v4/deployments (fetched 2026-11-25): PoolManager `0x00b036b58a818b1bc34d502d3fe730db729e62ac`, PositionManager `0xf969aee60879c54baaed9f3ed26147db216fd664`, Universal Router `0xf70536b3bcc1bd1a972dc186a2cf84cc6da6be5d`, StateView `0xc199f1072a74d4e905aba1a84d9a45e2546b6222`, PoolSwapTest `0x9140a78c1a137c7ff1c151ec8231272af78a99a4`, PoolModifyLiquidityTest `0x5fa728c0a5cfd51bee4b060773f50554c0c8a7ab`, Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`. Recorded with source links in `config/addresses.json`. The page warns that addresses differ per chain and must be confirmed per chain.
- The PoolManager on 1301 has `owner() = 0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519` and `protocolFeeController() = 0x0` (`cast call`). The owner controls protocol fees, which is a **dependency-level trust assumption**, not a Ballast privilege (SECURITY, THREAT_MODEL).
- **Protocol fee formula (ADR-031).** `slot0` packs `lpFee` and a 24-bit `protocolFee` as two 12-bit halves (`zeroForOne` = low 12 bits, `oneForZero` = high 12 bits; `ProtocolFeeLibrary.getZeroForOneFee/getOneForZeroFee`, `ProtocolFeeLibrary.sol:17-23`). Each half is at most `MAX_PROTOCOL_FEE = 1000` pips (0.1%) (`ProtocolFeeLibrary.sol:8`). Swap fee = `p + l − floor(p·l / 1_000_000)` (`calculateSwapFee`, `ProtocolFeeLibrary.sol:38-46`), used in `Pool.swap` as `protocolFee == 0 ? lpFee : calculateSwapFee(protocolFee, lpFee)` (`Pool.sol:286-307`). MATH §3 now defines the gross-up with this formula; depth reported to consumers stays net.

## Not verified / deferred
- Behavioural proof of G-1 with the real `BallastHook` and with the PositionManager (as opposed to the test hook and the official test router): M2.
- A funded testnet deployment of the real hook: M2 and M9.
- Whether the locally built v4-core PoolManager bytecode equals the deployed one (not compared; optimizer settings differ).
- Audit coverage of OpenZeppelin `uniswap-hooks` v1.2.1 (taken from web pages, README disclaims; not independently confirmed).
- The v4 template repository and its fixtures: not evaluated.

## Design impact summary
| Item | Result |
|---|---|
| F-1 BaseHook source | D-4 replaced: OpenZeppelin `BaseHook` + `CurrencySettler` (ADR-030); own `HookMiner` |
| F-2, F-3, F-4, F-5, F-6, F-7, F-8 | Confirm the design; all five flags exercised on the real PoolManager |
| F-10 protocol fee | Gross-up uses the effective fee (ADR-031); owner control documented as a dependency assumption |
