// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC6909} from "@uniswap/v4-core/src/ERC6909.sol";

/// @title BallastShares
/// @notice The vault share token (ERC-6909, id = vaultId) of a Ballast pool (ADR-050). Only the vaults contract that
/// created it can mint, burn or escrow shares; holders transfer them with the standard ERC-6909 functions.
/// @dev Created by `BallastVaults` in its constructor (`vaults = msg.sender`). Escrow for pending redeem tickets is
/// the vaults contract's own balance here. It holds no tokens and calls nothing. No owner, admin, proxy or
/// `delegatecall`.
/// @custom:invariant INV-4
contract BallastShares is ERC6909 {
    /// @notice The caller was not the vaults contract.
    error NotVaultsContract(address caller);

    /// @notice The custody contract that created this token and is its only minter, burner and escrow agent.
    address public immutable vaults;

    /// @notice Total supply of a vault's shares: holders, escrow and the burned minimum.
    mapping(uint256 id => uint256 supply) public totalSupply;

    constructor() {
        vaults = msg.sender;
    }

    modifier onlyVaults() {
        if (msg.sender != vaults) revert NotVaultsContract(msg.sender);
        _;
    }

    /// @notice Mints `amount` shares of `id` to `to`. Vaults only.
    function mint(address to, uint256 id, uint256 amount) external onlyVaults {
        totalSupply[id] += amount;
        _mint(to, id, amount);
    }

    /// @notice Burns `amount` shares of `id` held by `from`. Vaults only.
    function burn(address from, uint256 id, uint256 amount) external onlyVaults {
        totalSupply[id] -= amount;
        _burn(from, id, amount);
    }

    /// @notice Moves shares between two holders without allowance, for the escrow and release of redeem tickets.
    /// Vaults only; supply is unchanged.
    function move(address from, address to, uint256 id, uint256 amount) external onlyVaults {
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
        emit Transfer(msg.sender, from, to, id, amount);
    }
}
