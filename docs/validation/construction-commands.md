# Common live-session command boundary

The approved Q8/Q23 command boundary is implemented in
`construction_commands.zig` and `world_data_service.zig`. It is an in-memory
live-session ledger; accepted world effects keep their existing persistence path.
There is no durable per-click command journal.

## Identity and intent

`{ world_session, client_session, sequence }` identifies an external intent.
`request_id` remains transport correlation. One monotonically ordered sequence
spans Save, Apply, player resource operations, and ordinary external terrain edits
on an endpoint. Automatic simulation work keeps its local lifecycle and bypasses
the ledger.

The service compares the whole typed intent exactly. Fulfillment binds object kind,
world session, construction ID, registration lifetime, definition-cell index, and
the complete block operation. Apply binds owner, definition ID, origin, and rotation.
Save binds owner, canonical trimmed name, and immutable definition dimensions, cells,
and target count. Ordinary player edits bind the cell, action/material, player ID,
and existing sequence precondition. A future warehouse intent must use its own
typed target. A stale lifetime cannot act on another registration.

`nextExternalCommand` supplies the next identity without advancing admission.
`trySubmitOperationCommand`, `tryApplyBlueprintCommand`, and
`trySaveBlueprintCommand` return `Submission` directly:

- `queued` admits one effect and advances the sequence.
- `pending` identifies an already accepted matching intent.
- `replayed` includes the original scalar terminal outcome.

Retries do not add waiters, mailbox replies, or world effects. Reusing an identity
with a changed intent fails. Admission failures preserve the sequence, request ID,
and caller-owned Save candidate. Every successful Save disposition consumes the
candidate, including pending/replayed duplicates.

## Bounds and acknowledgment

The service shares at most `pending_commands` ledger records across all endpoints
(256 by default). `persistence.Limits.command_intent_bytes` adds a 32 MiB allocation
cap for record/result capacity, canonical retry payloads, queued Save payloads, and
legacy retry-key map capacity. Save conservatively reserves twice its canonical
name/cell bytes until acknowledgment, including after the queued copy moves into
the separately bounded definition library. Legacy maps also retain their existing
`max_definitions` entry limit. These are memory bounds, not measured throughput or
latency targets.

Admission reserves the record and payload before enqueue. Completed unacknowledged
records keep consuming the shared window. An acknowledgment marks a completed
record; only an acknowledged contiguous prefix retires. The endpoint keeps
`retired_through`, so a retired command returns stale/resync and cannot execute again.
There is no time expiry. A slow consumer can backpressure the shared window.

`acknowledgeExternalCommand` provides the explicit wire-facing acknowledgment.
Local `takePackages`, `waitPackages`, and `takeBlueprintResults` acknowledge after
ownership transfers into the caller's retained array. A future network adapter must
acknowledge client acceptance; server network-buffer receipt is insufficient.

Replay returns status, diagnostics, mined material, or immutable result IDs. It
does not replay old inventory, terrain, or construction snapshots. Current state is
resynchronized separately. An Apply replay still names its original instance after
that instance completes. A terminal failed command remains failed; an intentional
new command is required for another attempt.

Successful Save and Apply reserve their notification slot before effects. Rejected
results also remain in the bounded ledger outbox when mailbox allocation fails.
Retry publishes the stored outcome without repeating the intent.

## Session fences and legacy keys

World restart changes the world session. Live `rotateExternalSession` requires all
accepted old-session work to be completed and acknowledged; it releases the legacy
key map and resets the sequence. New admissions remain fenced until
`acknowledgeExternalResync` confirms the new client session's state boundary. Old
sessions fail validation. An uncertain old intent is never renamed automatically.

`trySaveBlueprintWithKey` remains a bounded compatibility adapter. An arbitrary key
maps to one command sequence during its client session. Matching retries share the
original request ID and effects. Changed contents fail; after collection/acknowledgment
the key is stale, even though its command record has retired. An acknowledged session
rotation creates a fresh namespace for an intentionally reused legacy key.

## Validation

```sh
zig build test-world-service -Dtest-filter='command ledger' --summary all
zig build test-world-service -Dtest-filter='external command rejection' --summary all
```

Tests cover exact whole-intent equality, typed target kind/lifetime conflicts,
pending duplicate suppression, scalar replay after newer player inventory changes,
contiguous acknowledgment holes, stale retries, session rotation/resync fences,
shared record/byte bounds, simulation bypass, legacy Save key ownership and session
scope, Save and batch admission allocation-denial sweeps, and rejected-result outbox
recovery. These checks do not measure network latency or establish a durable retry
contract across process restarts.
