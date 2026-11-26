// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StressMachine} from "../../src/libraries/StressMachine.sol";
import {LockState} from "../../src/types/Types.sol";

/// @notice Second, independently derived reference for `StressMachine`: 300 event-driven timelines (10,410 evaluation
/// points) generated from the SPEC text only by `tools/gen_stress_vectors.py` (see the header of that file and
/// `test/vectors/stress_machine.json` for the date and seed). The first reference (`StressMachine.fuzz.t.sol`) was
/// written alongside the implementation; this one was not. Any disagreement is a finding to report, not to patch.
/// @custom:requirement R-STR-1 R-STR-2 R-STR-3 R-STR-4 R-STR-5 R-STR-6 R-STR-9
/// @custom:invariant INV-12
contract StressMachineVectorsTest is Test {
    uint256 internal mismatches;
    uint256 internal events;
    uint256 internal toCalmFromRecovering;
    uint256 internal expiries;
    uint256 internal relapses;

    struct Timeline {
        uint32 enter;
        uint32 exit_;
        uint32 calm;
        uint32 maxLock;
        uint256[] t;
        int256[] dev;
        bool[] warm;
        uint256[] state;
        bool[] expired;
        bool[] active;
        uint256[] started;
        uint256[] until;
    }

    function _key(uint256 i, string memory f) internal pure returns (string memory) {
        return string.concat(".timelines[", vm.toString(i), "].", f);
    }

    function _load(string memory json, uint256 i) internal pure returns (Timeline memory tl) {
        tl.enter = uint32(vm.parseJsonUint(json, _key(i, "cfg.enter")));
        tl.exit_ = uint32(vm.parseJsonUint(json, _key(i, "cfg.exit")));
        tl.calm = uint32(vm.parseJsonUint(json, _key(i, "cfg.calm")));
        tl.maxLock = uint32(vm.parseJsonUint(json, _key(i, "cfg.maxLock")));
        tl.t = vm.parseJsonUintArray(json, _key(i, "t"));
        tl.dev = vm.parseJsonIntArray(json, _key(i, "dev"));
        tl.warm = vm.parseJsonBoolArray(json, _key(i, "warm"));
        tl.state = vm.parseJsonUintArray(json, _key(i, "state"));
        tl.expired = vm.parseJsonBoolArray(json, _key(i, "expired"));
        tl.active = vm.parseJsonBoolArray(json, _key(i, "active"));
        tl.started = vm.parseJsonUintArray(json, _key(i, "started"));
        tl.until = vm.parseJsonUintArray(json, _key(i, "until"));
    }

    function _report(uint256 i, uint256 e, string memory what) internal {
        ++mismatches;
        if (mismatches <= 10) {
            emit log_named_string(
                string.concat("MISMATCH timeline ", vm.toString(i), " event ", vm.toString(e)), what
            );
        }
    }

    function _replay(Timeline memory tl, uint256 i) internal {
        LockState s = LockState.CALM;
        StressMachine.Ctx memory c = StressMachine.Ctx({
            nowTs: 0,
            stressStartedAt: 0,
            belowExitSince: 0,
            enterTicks: tl.enter,
            exitTicks: tl.exit_,
            calmDuration: tl.calm,
            maxStressLock: tl.maxLock,
            lockExpiryRecorded: false
        });
        for (uint256 e; e < tl.t.length; ++e) {
            ++events;
            c.nowTs = uint40(tl.t[e]);
            LockState prev = s;
            bool expired;
            (s, c, expired) = StressMachine.next(s, tl.dev[e], tl.warm[e], c);
            if (uint256(s) != tl.state[e]) _report(i, e, "state");
            if (expired != tl.expired[e]) _report(i, e, "LockExpired emission");
            if (StressMachine.lockActive(s, c) != tl.active[e]) _report(i, e, "lockActive");
            if (c.stressStartedAt != tl.started[e]) _report(i, e, "stressStartedAt");
            if (StressMachine.lockedUntil(s, c) != tl.until[e]) _report(i, e, "lockedUntil");
            if (prev == LockState.RECOVERING && s == LockState.CALM) ++toCalmFromRecovering;
            if (prev == LockState.RECOVERING && s == LockState.STRESS) ++relapses;
            if (expired) ++expiries;
        }
    }

    function test_AllVectorsAgree() public {
        string memory json = vm.readFile("test/vectors/stress_machine.json");
        uint256 n = vm.parseJsonUint(json, ".count");
        assertEq(n, 300, "vector file has the expected number of timelines");
        for (uint256 i; i < n; ++i) {
            _replay(_load(json, i), i);
        }
        emit log_named_uint("events compared", events);
        emit log_named_uint("RECOVERING -> CALM transitions covered", toCalmFromRecovering);
        emit log_named_uint("RECOVERING -> STRESS relapses covered", relapses);
        emit log_named_uint("LockExpired emissions covered", expiries);
        assertEq(mismatches, 0, "the two references disagree (see MISMATCH logs)");
        // Coverage of the interesting transitions, so the agreement is not vacuous.
        assertGt(toCalmFromRecovering, 50);
        assertGt(relapses, 50);
        assertGt(expiries, 50);
    }
}
