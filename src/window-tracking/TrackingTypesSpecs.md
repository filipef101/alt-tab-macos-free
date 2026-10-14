# Tracking identities — Specs

The identity types every rule in the attention pipeline keys on. There is no behaviour here. macOS assigns
window numbers uniquely for the current login session, while pids are eventually reused; the combined type
also records which process generation owned a WindowServer surface.

- **`ProcessGeneration`** — a pid plus the generation AltTab assigned it. macOS reuses pids, so a callback
  from a process that has already died would otherwise read as current. Every per-app fact, every AX observer
  entry and every attention record is keyed on this.
- **`WindowIdentity`** — a session-unique wid plus the process generation observed owning that surface. The
  process qualification rejects callbacks from a terminated app; it is not a wid-recycling workaround.
- **`IngressSequence`** — arrival order, allocated when evidence reaches the model. Compared per process and
  nowhere else (`AttentionModelSpecs`, R1).
- **`MonotonicTimestamp`** — the clock the AX observer health budgets and cooldowns run on. Monotonic so a
  wall-clock jump cannot make a retry look overdue.
- **`QueryIssueOrder`** — a monotonic issue fence for aggregate asynchronous snapshots. Completion order
  cannot make an older query replace the newest issued state.
- **`TrackingProvider`** — who told us. Telemetry only, so a disagreement is attributable to a channel.
- **`AttentionWriteSource`** — what entitles a call to move the window order. See `AttentionOrderSpecs.md`.

## Test scenarios

- **testProcessGenerationSeparatesPidReuse** — a reused pid is a different process.
- **testWindowIdentityOrdersByProcessThenWid** — ownership generation and then session-unique wid form a
  deterministic order.
- **testIngressSequenceOrders** — arrival order is a total order.
- **testSnapshotAnswersOnlyApplyForTheNewestIssue** — an older query token is rejected after a newer issue.
