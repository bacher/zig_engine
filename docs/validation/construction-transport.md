# Construction transport validation

Construction publications use a random, nonzero service session plus object kind,
site ID, and lifetime. A site snapshot establishes a revision; each batched delta
names its exact base and resulting revision. The service retains at most
`max(pending_commands, 1)` history entries. If those entries cannot bridge a
client's revision, the next publication contains a current snapshot.

Chunk subscriptions discover active sites throughout their full boxes, including
chunks containing only cavities. Discovery accompanies blocks, surfaces, boundary
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

The publication cap excludes terrain/surface payloads, allocator overhead and temporary
reallocation overlap, client subscription/cache maps, and the separately bounded
history ring. Status reports publication used/peak bytes, rejected reservations,
history bytes, and permanently oversized publication payloads. An indivisible
discovery payload larger than the configured cap leaves its terrain package pending
and reports the blocked condition.

Run the focused server checks with:

```sh
zig build test-world-service -Dtest-filter='construction transport' --summary all
```

These checks cover surface/cavity discovery, relevant-site filtering, shared-definition
caching, exact batched revisions and transfers, retirement composition watermarks,
history overwrite and snapshot recovery, explicit interest and stale identities,
multiple unknown-site retirements, shared capacity with unread packages, release
wakeups, definition prefixes, packages surviving service ownership, flattened
discovery ownership, snapshot/delta allocation denial, bounded control admission,
and delayed discovery after lost retirement and source cleanup. They do not establish
end-to-end frame latency or throughput.

## Snapshot payload boundary

`construction_stream.Snapshot` is an explicit descriptor/progress/lifecycle payload
with read-only views of four arrays: fulfillment bits, box chunks, target groups
(including transfer state), and target indices. It retains the existing counters
and metadata so the same full snapshot validation applies. It has no runtime
instance or executor-local cleanup cursor. Publication clones its arrays once;
installation creates one owned runtime copy with local retirement progress starting
at zero. Validation, atomic replacement, monotone progress checks and bounded
retirement are unchanged. Generic runtime cloning still preserves local state.

The array representation is retained deliberately. This boundary change does not
claim a throughput improvement or remove grouping from retained runtime state.
The following benchmark compares its cost with a compact descriptor, bitmap and
transfer-record prototype before selecting a broader representation change:

```sh
zig build test-construction-client -Doptimize=ReleaseFast -Dtest-filter='snapshot payload benchmark' --summary all
```

The fixture uses Zig 0.16 on native arm64, `std.heap.smp_allocator` wrapped in the
requested-byte accounting allocator, and a dense 100×100×32 plank definition at
origin `(31,31,12)`, rotation zero. Its 320,000 targets occupy 50 chunks/groups.
The building case is half fulfilled; the materializing case has 25 transferred
groups. Setup is outside the timed regions; definition certification is not measured. Copy
phases repeat 200 times, reconstruction 20, validation 50 and copy plus validation
100; the initial pending-index preparation is one separate sample. Timed copy and
reconstruction phases include release. The benchmark verifies reconstructed
progress, grouping and transfer state against the current representation.

Native publication-owned bytes, including one update slot, are:

| Payload component | Bytes |
| --- | ---: |
| Fulfillment bitmap | 40,000 |
| Box chunks | 200 |
| Target groups, including transfer state | 1,200 |
| Target indices | 1,280,000 |
| Current update slot | 168 |
| Current full snapshot | 1,321,568 |
| Compact prototype, building | 40,112 |
| Compact prototype, 25 transfer records | 40,712 |

These are native allocation/payload sizes, not wire bytes. The compact prototype
uses the existing 24-byte transfer record and a 112-byte update slot. The previous
embedded-instance update slot was 176 bytes; separating the payload leaves all
1,321,400 array bytes unchanged. Both actual `Snapshot.clone` and `toInstance`
perform four allocations and retain those same array bytes. The compact clone
uses one allocation for a building site and two with transfer records.

Two quiet ReleaseFast runs produced the following ranges of phase means; CPU
times followed wall times and are also printed by the benchmark. These are
warm-process measurements of this fixture, not first-load latency guarantees.

| Phase | Wall µs/operation | Allocations/operation |
| --- | ---: | ---: |
| Generic runtime clone and release | 63.9–64.7 | 4 |
| Actual snapshot publication clone and release | 61.9–63.6 | 4 |
| Actual runtime installation copy and release | 61.2–61.8 | 4 |
| Compact building payload clone and release | 2.9–3.1 | 1 |
| Compact payload with 25 transfers, clone and release | 3.0–4.1 | 2 |
| Initial compact reconstruction and release, excluding validation | 4,467–4,508 | 11 |
| Full current snapshot validation | 786–788 | 0 |
| Current owned copy plus validation | 856–870 | 4 |
| Initial pending-index preparation plus validation, one sample/run | 9,075–9,288 | 822 |

The initial pending-index preparation retained an additional 11,202,092 requested
bytes, excluding the already-owned 1,321,400-byte runtime array copy. Its extra
allocation peak was 11,300,160 bytes. Those pending lists/lookups are separate from
the snapshot publication payload and remain necessary after a representation change.

Full validation scans the bitmap and every supplied target index. Pending-index
preparation then scans definition cells again and builds per-chunk pending lists
and lookups. Reconstruction uses the existing two-pass grouping builder before
that validation and index work. A compact payload therefore saves about 97% of
publication-owned bytes in this fixture while adding first-load reconstruction
work. The service and client still need their runtime grouping arrays for grouped
reads, geometry and materialization; compact publication would not remove them.

A follow-up could reconstruct on first sight and reuse the immutable membership
of an existing client's grouping on a same-lifetime resync. An owned deep copy
would preserve current ownership and allocation counts without shared buffers;
it would need an exact identity/descriptor match, fresh transfer state and the
existing progress/lifecycle checks before replacement. The copy-plus-validation
measurement is the current baseline, not an implemented reuse path. Choosing
compact publication remains a separate tradeoff between retained publication
memory and first-load work. No end-to-end bandwidth, latency or throughput gain
is established by this benchmark.
