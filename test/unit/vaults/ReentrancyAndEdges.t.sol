// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "../../utils/HookFixture.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {BallastStandby} from "../../../src/BallastStandby.sol";
import {IBallastErrors} from "../../../src/interfaces/IBallastErrors.sol";
import {Config, Range, VaultView} from "../../../src/types/Types.sol";

/// @dev A token that, once armed, calls `target` with `data` in the middle of the next `transferFrom` (the point
/// where the vaults and the standby hand control to the token) and bubbles up the callee's revert.
contract ReentrantToken is MockERC20 {
    address public target;
    bytes public data;

    constructor() MockERC20("RE", "RE", 18) {}

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        override
        returns (bool)
    {
        if (target != address(0)) {
            address t = target;
            target = address(0);
            (bool ok, bytes memory ret) = t.call(data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev A sponsor that is a contract, so that a malicious token can re-enter `fundStandby` as the sponsor.
contract SponsorProxy {
    function fund(BallastStandby s, uint128 amount) external {
        s.fundStandby(amount);
    }
}

/// @notice Reentrancy through a hostile token, and the guards that only a hostile or odd setup reaches (T7; R-TX-3).
/// @custom:requirement R-TX-3
contract ReentrancyTest is HookFixture {
    ReentrantToken internal re;
    ReentrantToken internal reQuote;
    SponsorProxy internal sponsor;
    BallastStandby internal standby;
    uint256 internal v;

    function setUp() public {
        _deployInfra();
        sponsor = new SponsorProxy();
        // Both tokens are hostile. Collateral must sort first (currency0).
        ReentrantToken a = new ReentrantToken();
        ReentrantToken b = new ReentrantToken();
        while (address(a) > address(b)) b = new ReentrantToken();
        re = a;
        reQuote = b;
        collateral = a;
        quote = b;
        collateralIs0 = true;
        Config memory c = ConfigFixture.compressed();
        c.sponsor = address(sponsor);
        _deployHook(c);
        _initPool(0);
        collateral.mint(address(this), 1e30);
        quote.mint(address(this), 1e30);
        collateral.approve(address(vaults), type(uint256).max);
        quote.approve(address(vaults), type(uint256).max);
        v = _provide(-6000, 6000, 1e19);
        standby = BallastStandby(address(vaults.standby()));
    }

    function test_RevertWhen_TokenReentersDeposit() public {
        re.arm(
            address(vaults),
            abi.encodeCall(
                vaults.deposit, (v, 1e15, type(uint128).max, type(uint128).max, address(this))
            )
        );
        vm.expectRevert(IBallastErrors.Reentrancy.selector);
        vaults.deposit(v, 1e15, type(uint128).max, type(uint128).max, address(this));
    }

    function test_RevertWhen_TokenReentersRequestRedeemDuringADeposit() public {
        re.arm(address(vaults), abi.encodeCall(vaults.requestRedeem, (v, 1)));
        vm.expectRevert(IBallastErrors.Reentrancy.selector);
        vaults.deposit(v, 1e15, type(uint128).max, type(uint128).max, address(this));
    }

    function test_RevertWhen_TokenReentersCheckpointDuringASeed() public {
        Range[] memory r = new Range[](1);
        r[0] = Range(-600, 600);
        uint256 v2 = vaults.createVault(r, 0, 0);
        uint128[] memory l = new uint128[](1);
        l[0] = 1e18;
        re.arm(address(vaults), abi.encodeCall(vaults.checkpoint, (v)));
        vm.expectRevert(IBallastErrors.Reentrancy.selector);
        vaults.seed(v2, l, type(uint128).max, type(uint128).max, address(this));
    }

    function test_RevertWhen_SponsorReentersFundStandby() public {
        quote.mint(address(sponsor), 1e18);
        vm.prank(address(sponsor));
        quote.approve(address(standby), type(uint256).max);
        // The sponsor is a contract; while the standby pulls its quote, the token calls the sponsor, which calls
        // `fundStandby` again. The second call passes the sponsor check and meets the lock.
        reQuote.arm(address(sponsor), abi.encodeCall(sponsor.fund, (standby, 1)));
        vm.expectRevert(IBallastErrors.Reentrancy.selector);
        sponsor.fund(standby, 100);
        // The failed call rolled back the token's own disarming, so disarm it. Without the hostile callback the same
        // funding works, so the revert above was the guard.
        reQuote.arm(address(0), "");
        sponsor.fund(standby, 100);
        assertEq(standby.standbyInfo().fundBalance, 100);
    }
}
