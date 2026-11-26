#!/usr/bin/env python3
"""Independent reference for the stress machine: test vectors generated from the SPEC text only.

Source of truth: docs/SPEC.md R-STR-1 .. R-STR-9 (state machine) and R-STR-4/5 (lock window, expiry). The Solidity
implementation (src/libraries/StressMachine.sol) was NOT consulted while writing this file, and the structure is
deliberately different from it: instead of carrying timers between steps, every decision is recomputed from the
recorded history of evaluation points (event-driven timeline).

Semantics used, quoted from the SPEC:
  R-STR-1  CALM -> STRESS when dev >= enter and the oracle is warm; stressStartedAt = now, on this transition only.
  R-STR-2  STRESS -> RECOVERING when dev < exit. RECOVERING -> STRESS when dev >= enter; stressStartedAt unchanged.
  R-STR-3  RECOVERING -> CALM when dev < exit has held continuously for calmDuration.
  R-STR-4  lock active while state != CALM and now < stressStartedAt + maxStressLock.
  R-STR-5  LockExpired is emitted once per episode, the first time now >= stressStartedAt + maxStressLock is
           evaluated in a non-CALM state; the record is cleared when the machine returns to CALM.
  R-STR-6  not warm -> CALM with cleared timers (also releases any non-CALM state).
  R-STR-9  continuity of the below-exit period is checked at evaluation points only.
Between the thresholds (exit <= dev < enter) the state is unchanged and an in-progress calm period is interrupted
(a calm period needs dev < exit at every evaluation point it spans).

Output: test/vectors/stress_machine.json. Deterministic: fixed seed. Run: python3 tools/gen_stress_vectors.py
"""
import json
import random

GENERATED = "2026-11-26"
SEED = 20261126
CALM, STRESS, RECOVERING = 0, 1, 2


def run_timeline(cfg, events):
    """events: list of (t, dev, warm). Returns per-event expectations."""
    enter, exit_, calm, max_lock = cfg["enter"], cfg["exit"], cfg["calm"], cfg["maxLock"]
    state = CALM
    started = 0
    history = []  # evaluation points since the episode began: (t, dev)
    expiry_emitted = False
    out = []
    for (t, dev, warm) in events:
        expired_now = False
        if not warm:
            state, started, history, expiry_emitted = CALM, 0, [], False
        else:
            if state == CALM:
                if dev >= enter:
                    state, started, history, expiry_emitted = STRESS, t, [], False
                    history.append((t, dev))
            else:
                history.append((t, dev))
                if dev >= enter:
                    state = STRESS  # from STRESS: stays; from RECOVERING: relapse (started untouched)
                elif dev < exit_:
                    # length of the trailing run of evaluation points with dev < exit
                    i = len(history)
                    while i > 0 and history[i - 1][1] < exit_:
                        i -= 1
                    run_start_t = history[i][0]
                    if state == STRESS:
                        state = RECOVERING  # the run starts at this very point
                    elif t - run_start_t >= calm:
                        state = CALM
                # else: between thresholds: unchanged
                if state == CALM:
                    started, history, expiry_emitted = 0, [], False
                elif (not expiry_emitted) and t >= started + max_lock:
                    expiry_emitted = True
                    expired_now = True
        active = state != CALM and t < started + max_lock
        out.append({
            "state": state,
            "expired": expired_now,
            "active": active,
            "started": started,
            "until": (started + max_lock) if active else 0,
        })
    return out


def gen_events(rng, cfg, n):
    t = rng.randrange(1_000_000_000, 1_900_000_000)  # realistic epoch, well above small-number artefacts
    events = []
    enter, exit_ = cfg["enter"], cfg["exit"]
    for _ in range(n):
        r = rng.random()
        if r < 0.10:
            dt = 0
        elif r < 0.55:
            dt = rng.randrange(1, 120)
        elif r < 0.85:
            dt = rng.randrange(120, cfg["calm"] + 1)
        else:
            dt = rng.randrange(cfg["calm"], max(cfg["calm"], cfg["maxLock"] * 2) + 2)
        t += dt
        k = rng.random()
        if k < 0.30:
            dev = rng.randrange(enter, enter * 4 + 10)
        elif k < 0.55:
            dev = rng.randrange(-50, exit_)  # below exit (may be negative: price moved against liquidation)
        elif k < 0.80:
            dev = rng.randrange(exit_, enter)  # between thresholds
        elif k < 0.85:
            dev = enter  # exact boundaries
        elif k < 0.90:
            dev = exit_
        elif k < 0.93:
            dev = enter - 1
        elif k < 0.96:
            dev = exit_ - 1
        else:
            dev = rng.choice([-1_774_544, 1_774_544, 0])
        warm = rng.random() > 0.04
        events.append((t, dev, warm))
    return events


def main():
    rng = random.Random(SEED)
    timelines = []
    for idx in range(300):
        enter = rng.choice([51, 100, 305, 305, 800, 2000])
        exit_ = rng.randrange(1, enter)
        calm = rng.choice([300, 600, 900, 3600])
        max_lock = rng.choice([1, 600, 1800, 3600, 86_400, 7 * 86_400])
        cfg = {"enter": enter, "exit": exit_, "calm": calm, "maxLock": max_lock}
        events = gen_events(rng, cfg, rng.randrange(8, 60))
        exp = run_timeline(cfg, events)
        timelines.append({
            "cfg": cfg,
            "t": [e[0] for e in events],
            "dev": [e[1] for e in events],
            "warm": [e[2] for e in events],
            "state": [x["state"] for x in exp],
            "expired": [x["expired"] for x in exp],
            "active": [x["active"] for x in exp],
            "started": [x["started"] for x in exp],
            "until": [x["until"] for x in exp],
        })
    doc = {
        "generator": "tools/gen_stress_vectors.py",
        "generated": GENERATED,
        "seed": SEED,
        "source": "docs/SPEC.md R-STR-1..9 (text only; Solidity not consulted)",
        "count": len(timelines),
        "states": {"CALM": 0, "STRESS": 1, "RECOVERING": 2},
        "timelines": timelines,
    }
    with open("test/vectors/stress_machine.json", "w") as f:
        json.dump(doc, f, separators=(",", ":"))
    n_ev = sum(len(t["t"]) for t in timelines)
    visits = [0, 0, 0]
    for t in timelines:
        for s in t["state"]:
            visits[s] += 1
    exp_n = sum(sum(t["expired"]) for t in timelines)
    print(f"{len(timelines)} timelines, {n_ev} events; state visits CALM/STRESS/RECOVERING = {visits}; expiries = {exp_n}")


if __name__ == "__main__":
    main()
