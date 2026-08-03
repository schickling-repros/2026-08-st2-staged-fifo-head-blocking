# st2 staged FIFO head blocking

This repository reproduces a staged-delivery state-machine defect in st2. A startup backlog is
coalesced into one Recovery notice. When its transport receives no adapter-recognized receipt and
the owned payload disappears, the current retry maps the resulting `Unproven` screen to `Staged`.
That FIFO head then prevents a later message from receiving a fresh transport.

The reproduction uses synthetic messages, an isolated bus, a real PTY session, and the production
st2 DING sidecar. Experiment-owned PTY instrumentation records transport and retry boundaries.
Inbox state, pane appearance alone, PTY command success, and elapsed time are not delivery oracles.

## Reproduction

On Linux with Nix and flakes enabled:

```bash
nix run
```

The command runs three checks:

1. The pinned current behavior transports exactly one startup Recovery, observes zero provider
   acceptances and two healthy `Unproven` staged retries, then proves that a uniquely nonced later
   message received zero transports while both the provider session and sidecar remained alive.
2. A positive control changes only the synthetic screen to an adapter-accepted Recovery. The
   staged head resolves and the later message receives exactly one transport.
3. A candidate binary changes only the production `retry_staged` mapping from `Unproven -> Staged`
   to `Unproven -> Deferred`. With the same healthy unproven screen, the vanished archived head is
   relinquished and the later message receives exactly one accepted transport.

The 15-second production retry backoff is unchanged. The shim marks the first production receipt
observation that sees the exact unproven fixture frame, returns a fixed nonzero status once so the
sidecar deterministically owns the payload as staged, and lets later peeks pass through normally.
Bounded waits collect that receipt boundary and instrumented retry and transport events;
classification comes from exact counts at those boundaries.

## Expected

Once an archived staged payload is absent from a healthy, adapter-unproven screen, its FIFO
ownership is relinquished so a later message can receive a fresh guarded transport.

## Actual

The pinned baseline keeps returning `Staged`: after exactly two observed production retry cycles,
the later message still has zero transports. The executable reports `BASELINE_RESULT=RED` for this
state-machine property. Both the accepted-screen control and the one-line candidate mapping report
`GREEN` after exactly one later-message transport.

If the experiment-owned attempt capture or a required health boundary is missing, the run fails
closed and reports `RUN_RESULT=INCONCLUSIVE`. The reproduction does not claim a general delivery
regression.

## Versions

- st2 baseline: `509ffb4cdcc1805a1ccd566e87b5d373bb4c47d4`
- pty: `504ac7332895fe1fa3767b530dcd99f091f56cda` (`0.12.0`)
- Platform: Linux (`x86_64` or `aarch64`)

The candidate disables the pinned package's unit-test phase because those tests encode the current
`Unproven -> Staged` behavior. It still compiles the exact pinned source with one fail-closed
replacement and is verified by the same real-binary end-to-end scenario. No upstream source tree
is modified, and no upstream issue is filed by this reproduction.
