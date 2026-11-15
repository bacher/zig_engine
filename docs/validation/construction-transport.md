# Construction transport validation

Construction publications use a random, nonzero service session plus object kind,
site ID, and lifetime. A site snapshot establishes a revision; each batched delta
names its exact base and resulting revision. The service retains at most
`max(pending_commands, 1)` history entries. If those entries cannot bridge a
client's revision, the next publication contains a current snapshot.

Chunk subscriptions discover active sites throughout their full boxes, including
chunks containing only cavities. Discovery accompanies blocks, meshes, boundary
updates, unreachable chunks, and metadata acknowledgments. Explicit site interest
continues until unsubscribe, independently of terrain visibility. Resync refreshes
existing explicit or visible-chunk interest and resolves retired references;
callers subscribe first to retain a live site outside terrain visibility. A stale session or lifetime cannot
replace a current subscription. Definitions are immutable and cached per client;
multiple sites sharing a definition do not repeatedly send its contents.

Ordinary fills that leave a site building publish progress deltas without scheduling
whole-box metadata acknowledgments. The composition watermark still advances so pending
terrain responses refresh their discovery revision fences. Last-fill phase transitions,
portion transfers, admission and completion retain their discovery publications. The
transport locality regression covers repeated fills across a five-chunk box, last-fill
discovery, transfer terrain revisions, resync and completion reference removal.

Definition/subscription/resync/unsubscribe requests share a service-wide admission
counter capped by `pending_commands` (256 by default). Consumption releases a slot;
queue allocation failure or shutdown rejects submission without retaining a slot.
A reference to a cleaned-up site receives a terminal retirement and current
composition watermark, then leaves no persistent server subscription. The terminal
revision uses the maximum revision value when bounded history no longer retains
the exact final revision, so it can supersede any older cached snapshot.

`persistence.Limits.construction_publication_bytes` defaults to 32 MiB and caps
owned construction publication payloads across all clients. It covers definitions,
snapshot arrays, delta arrays, update slots, and chunk-discovery site arrays in
pending or delivered packages. Payload release returns capacity and wakes the
service for a fresh-state retry. Definition/update prefixes can be delivered in
separate packages before the remaining terrain package. Held packages retain the
budget owner after service destruction; flattened chunk responses retain their
discovery charge until response destruction.

Transient allocation failures schedule one watchdog retry after 100 ms, including
ephemeral services. The wake flag requires no queued allocation. Healthy idle
services do not poll; dependency and capacity changes also wake relevant work.

The publication cap excludes terrain/mesh payloads, allocator overhead and temporary
reallocation overlap, client subscription/cache maps, and the separately bounded
history ring. Status reports publication used/peak bytes, rejected reservations,
history bytes, and permanently oversized publication payloads. An indivisible
discovery payload larger than the configured cap leaves its terrain package pending
and reports the blocked condition.

Run the focused server checks with:

```sh
zig build test-world-service -Dtest-filter='construction transport' --summary all
```

These checks cover mesh/cavity discovery, relevant-site filtering, shared-definition
caching, exact batched revisions and transfers, retirement composition watermarks,
history overwrite and snapshot recovery, explicit interest and stale identities,
multiple unknown-site retirements, shared capacity with unread packages, release
wakeups, definition prefixes, packages surviving service ownership, flattened
discovery ownership, snapshot/delta allocation denial, bounded control admission,
and delayed discovery after lost retirement and source cleanup. They do not establish
end-to-end frame latency or throughput.
