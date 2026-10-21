# World persistence acceptance evidence

This is a review map for AC1–AC137 in [the feature spec](../specs/features/world-persistence.md), not a claim that all acceptance criteria passed. **Tested** means the listed deterministic test directly exercises the stated contract within its stated scope. **Partial** means implementation and some evidence exist, but the remaining validation listed in that row has not been demonstrated. **Review** means code inspection only. **Skipped** identifies an evaluation not performed or an extension not defined for schema 1. No row implies hardware power-cut, interactive UI, or exhaustive fault coverage.

Commands used by the implementation work are `zig build test-persistence`, `zig build test-capture`, `zig build test-world`, and `zig build test`; the accompanying [validation report](persistence-validation.md) records final run results. Tests imported through the application root include public service and shutdown tests. The capture target imports the real coordinator and actual storage adapter. Performance artifacts are in [benchmarks/persistence-2026-10-19](benchmarks/persistence-2026-10-19/); they measure a persistence pipeline on one machine, without frame-latency evidence.

## Evidence keys

The following keys name concrete tests or implementation sites; test titles are searchable verbatim. A source link is not by itself a test result.

| Key | Concrete evidence |
| --- | --- |
| S-native | [storage.zig](../src/voxel_app/persistence/storage.zig): `native durable creation, WAL commit, repair, recovery, and indexed base reads`. |
| S-repair | Same file: `torn append and failed truncation/fullflush require successful repair before retry`; `failed commit synchronization is unacknowledged and repaired to memory boundary`; `restart may recover complete unacknowledged commit after sync error`. |
| S-corrupt | Same file: `incomplete final transaction is excluded but complete digest corruption is fatal`; `missing committed predecessor fails without deleting surviving evidence`; `checksummed invalid descriptors fail before recovery or source retirement`. |
| S-compact | Same file: `compaction primitive failures preserve committed state across restart`; `detached cancellation preserves inputs and newer WAL commits`; `old indexed read handles survive replacement while latest catalog tracks exact revisions`. |
| S-model | Same file: `modeled power loss distinguishes unacknowledged sync survival and validates logical snapshot contents`; `modeled rename before directory barrier and reappearing retired segments retain committed state`; `modeled unsynced partial appends and repaired lengths obey power-loss boundaries`; `modeled failed fullflush at publication and retirement has both uncertain outcomes`. These use [io_model.zig](../src/voxel_app/persistence/io_model.zig) below actual Store operations. |
| S-atomic | Same file: `modeled crash never publishes half a multi-chunk snapshot or its global/player state`, including custom metadata, global tick, and players. |
| S-zero | Same file: `snapshot zero includes initial overrides and canonical players and survives reopen`; `rotation establishes complete headers before admission and retries uncertain barriers`; `creation preserves orphaned persistence artifacts and accepts an empty precreated directory`. |
| S-path | Same file: `fresh nested save path creates parents and preserves the installed world's identity`; `nested creation propagates mkdir namespace and fullflush failures without overwriting evidence`. Native adapter checks cover missing parents, barrier ordering, failure propagation and preserved creation evidence; the crash model does not model ancestor namespaces. |
| S-offset | Same file: `checked file arithmetic never wraps`; `native file offsets and durable sparse lengths exceed four GiB`. The latter tests the adapter, not a 4 GiB base/WAL container. |
| S-lock | Same file: native second Store-open rejection in S-native; `modeled crash releases stable ownership while live compaction references retain it`. No separate native process fixture. |
| S-code | [storage.zig](../src/voxel_app/persistence/storage.zig): `create/open/scan/compact/prepareCompaction/installCompaction`; [io.zig](../src/voxel_app/persistence/io.zig): pread/pwrite, full flush, atomic rename, directory/parent barriers. |
| F-codec | [format.zig](../src/voxel_app/persistence/format.zig): `chunk codecs roundtrip air, deferred trailing air, raw fallback and corruption`; `structurally invalid RLE is rejected even with matching checksum`; `exact air record framing and hash domain binds world identity`. |
| F-meta | Same file: `metadata validates custom correspondence and independent section identities`; `metadata sections reject unknown flags schemas duplicates and truncation`; `all metadata sections may reach independent bounds and full wire record cap`. |
| F-state | Same file: `descriptor global and player strict wire roundtrips`; `terrain settings retain automatic height and reject invalid layout parameters`; `all codec allocation failures release owned buffers`. |
| C-gates | [lifecycle_tests.zig](../src/voxel_app/persistence/lifecycle_tests.zig): `cancellation releases all sources while real writer remains stalled and queue bounded`; `source release precedes independent durable sync gate and acknowledgement`; `actual write and durability failures release sources without acknowledgement`. |
| C-queue | Same file: `failed queued write frees only unconsumed output and retains writer byte charge`. Head-index dequeue retains the writer-owned charge and frees only remaining queued records on failure. |
| C-race | Same file: `footer transition wins cancellation without holding cancellation lock over IO`; `cancellation before footer transition prevents commit footer`. Storage also tests `controlled commit rejects before hash mutation and durable footer I/O`. |
| C-order | Same file: `all48 prioritized sources beyond27 encode first with exactly one release` exercises 80 sources, released-buffer mutation, real base compaction/readback, output accounting, and priority order. |
| C-limits | Same file: `tiny output working and manifest admission fail before workers borrow sources`; [coordinator.zig](../src/voxel_app/persistence/coordinator.zig): pre-encode output reservations, working reservation, Source descriptors. |
| B | [budget.zig](../src/voxel_app/persistence/budget.zig): `capacity accounts spare allocation, rejects growth and recovers after free`; `reservation transfers consumed bytes and returns only unused capacity`; `backing allocation failure restores charged capacity`. |
| P-service | [world_data_service.zig](../src/voxel_app/world_data_service.zig): `public service commits ordered players and reloads exact base revisions with lazy timers`; `public service live budget rejection preserves terrain and final save remains usable`; `public service bounds unread terminal operations and reopens admission when consumed`; `public service restore reports failed persisted dependency instead of hanging`. |
| P-drain | Same file: `final save restarts an edit dependency that failed before the save request`; `final dependency drain has one automatic retry and explicit retry resumes the same edit`; `final dependency drain reports permanent corruption without automatic retry`. The first test decodes the durable chunk and checks the retried edit and revision. Additional tests cover waiting-query-only corruption, queued final intent takeover for mutations and queries, and synchronous preparation OOM with bounded retry. |
| P-lifecycle | [save_lifecycle.zig](../src/voxel_app/persistence/save_lifecycle.zig): eleven deterministic transition tests for fenced commands, queued takeover/read readiness, bounded retries and retirement, earliest deadlines, final/overdue policy, exact cancellation outcomes, and stale epochs. The component performs no I/O; P-drain/P-policy/A-shutdown retain integration evidence. |
| P-edits | Same file: `service publishes road formation and reversion atomically and retains custom meshes after eviction`; `concurrent clients cannot both put into the same empty block`; `seeded client reconciliation converges to the authoritative worker after interleaved road edits`; `reveals notify all neighbor subscribers and survive eviction and reload`. The seeded reconciliation test does not inject storage crashes. |
| P-timers | Same file: `soil compacts at thirty minutes, grows grass later, and resets exposure after covering`; `covering loose earth across a chunk boundary compacts it and cancels its old deadline`; `evicting a subscription preserves timers and a large time step catches up both stages`; `public service restores a dense timer chunk in deadline and cell order` (32,768 unique events); plus P-service. |
| T-kernel | [timer_kernel.zig](../src/voxel_app/timer_kernel.zig): `fixed cutoff finite chain is idempotent and incremental equivalent`; `intervening edits win and invalid events are persistent metadata-only consumption`; `timer preparation releases all allocations and never partially edits source`; `deadline saturation stays finite and future events keep stable deadline-cell order`. |
| M-alloc | [chunk_metadata.zig](../src/voxel_app/chunk_metadata.zig): `fallible metadata preparation and cloning clean up all allocation failures`; [block_transformations.zig](../src/voxel_app/block_transformations.zig): `fallible queue cloning rescheduling and extraction release every failed allocation`; `failed event insertion preserves existing deadlines`. |
| W-client | [world.zig](../src/voxel_app/world.zig): `optimistic admission prepares every allocation before changing client state`; `full optimistic count or byte budget rejects before mutation or validation`; `snapshot rollback allocates before mutating optimistic state`; `rejected optimistic command survives resource pressure then retires on safe rebase`; `older authoritative snapshots cannot undo a newer revision`; boundary-cache/reconciliation tests. |
| A-shutdown | [main.zig](../src/voxel_app/main.zig): `shutdown cannot save ahead of optimistic edits that have not been admitted`; `persistent service initialization releases partial ownership at every allocation failure`; `Game.updatePersistence/beginExit/cancelExit/drawPersistence`. Service tests `service shutdown drains edits and frees unconsumed replies`, `shutdown skips generation requests but still commits commands`, and standing-space shutdown. [simulation_worker.zig](../src/voxel_app/simulation_worker.zig): `exit pause fences a simulation dispatch preempted before submission and resume admits it later` gates the real dispatch helper and verifies saved revisions before and after resume. |
| L | [launch.zig](../src/voxel_app/persistence/launch.zig): `opening never implies creation and world modes cannot be combined`; [world_layout.zig](../src/engine/world_layout.zig): `world dimensions validate storage bounds and the chunk ID budget`. |
| P-restart | [persistence_service_tests.zig](../src/voxel_app/persistence_service_tests.zig): `seeded public service saves recover exact acknowledged prefixes and discard unsaved suffixes`; three seeds, four save/restart rounds each, independent full block arrays, revisions, tick and player oracle, async reload, and continued edits. This is a software restart test, without injected mid-operation power loss. |
| P-policy | Public service tests: `public service releases stalled capture at capture deadline`; `public service prioritizes player and cancels stalled capture at player deadline`; `public service final capture ignores gameplay deadline and cancel intent resumes edits`; `public service overdue capture ignores gameplay cancellation deadlines`. |
| PERF | Fourteen original schema-2 plus four explicit capture-working-budget, seed-1, ten-cycle production-coordinator reports in the benchmark directory, raw/terrain/metadata-heavy and independent transaction write/full-sync stalls, plus baseline update time, stage timing, queue peak, RSS, and full reopen oracle. No gameplay/UI measurements or repeated long-run overload experiment. |

## Criterion map

| Criterion | Status | Evidence | Remaining validation or precise scope |
| --- | --- | --- | --- |
| AC1 | Partial | S-atomic; P-edits; P-restart | Multi-chunk storage atomicity is modeled; P-restart adds repeated public-service edits/save/reopen and unsaved suffix loss; injected mid-capture crash scheduling remains separate. |
| AC2 | Partial | S-atomic; F-meta; P-service; P-timers | Metadata and timer state round-trip; no single end-to-end persisted custom-road/timer gameplay reference sequence. |
| AC3 | Partial | C-gates; C-order; service admissible | Released output remains independent; full cross-chunk mutation admission under an active capture lacks a dedicated service race fixture. |
| AC4 | Partial | S-compact; service wal_revisions/source revisions | Detached compaction preserves newer WAL state; live newer-edit versus old-ack sequence needs a service fixture. |
| AC5 | Partial | S-corrupt; S-model; S-atomic | Representative cut points covered; no every-byte truncation sweep over a complete history. |
| AC6 | Partial | S-model; S-compact | Explicit modeled barriers and primitive faults; not every boundary of every operation or hardware power cuts. |
| AC7 | Tested | S-native; S-compact; S-model | Validated lineage, incorporated segments, interrupted installation and reappearing retired names. |
| AC8 | Partial | F-codec; F-meta; F-state; S-corrupt; S-offset | Malformed cases covered; no exhaustive size/offset/checksum mutation corpus or fuzz run. |
| AC9 | Partial | F-codec; F-meta | Air, raw, standard, metadata, long runs and corruption covered; no arbitrary seeded valid-chunk property generator. |
| AC10 | Partial | P-service; S-zero; S-code | Base reload before generator and retained mismatch implemented; explicit persisted all-air override service fixture missing. |
| AC11 | Partial | F-state; S-corrupt; startup descriptor reconstruction | Invalid descriptors rejected and settings round-trip; cross-release generator/default migration fixture absent. |
| AC12 | Partial | F-state; P-service; startup player restoration | Saved tick/player values verified; offline time and movement reset/collision behavior not tested as one restart scenario. |
| AC13 | Partial | C-gates; C-limits; B; P-service | Bounded stall/failure/pressure tests; sustained gameplay with concurrent compactor/full-disk error not evaluated. |
| AC14 | Partial | PERF; C-limits | Encoder/I/O and pipeline timings measured; authoritative edit contention, frame latency and full R66 workload matrix missing. |
| AC15 | Review | service beginCapture filters wal_revisions; coordinator writeAll | No dedicated second unchanged-checkpoint test asserting zero chunk bytes and updated tick/player state. |
| AC16 | Partial | P-service; P-restart; S-native; A-shutdown | Final save/compaction and reopening tested separately; no complete normal application shutdown/restart automation. |
| AC17 | Partial | S-corrupt; F-codec; S-code scan | Digest and missing-dependency failures tested; complete field-by-field transaction mutation suite absent. |
| AC18 | Tested | S-repair; S-native | Failed append repairs to remembered durable end before a later linked commit/reopen. |
| AC19 | Partial | S-compact; P-service; service evictEligible | Newer WAL/base revisions preserved; full live edit plus stale base acknowledgment plus pin-release eviction race fixture missing. |
| AC20 | Partial | S-compact; W-client; loaded_chunk revision/catalog checks | Old descriptors survive replacement; simultaneous public load/edit/install interleaving not directly gated. |
| AC21 | Partial | S-lock; S-native; io.Directory.open | Stable lock behavior tested in-process/model; native concurrent-process ownership and process-exit fixture missing. |
| AC22 | Partial | P-service; P-edits; F-meta | Lazy timers and road gameplay tested; persisted-road reload through service plus dependency validation needs a combined fixture. |
| AC23 | Partial | service admissible/run-write/dependency gates; C-gates; P-timers | No path-by-path active-capture test for every player/simulation/timer/historical mutation route. |
| AC24 | Review | service requestSave/requestCompaction coalescing; budget pressure paths | Early pressure trigger/coalescing under live concurrent writer/compactor lacks a targeted test. |
| AC25 | Partial | S-compact; S-model; Game.updatePersistence | Durable WAL survival verified; application exit-on-finalization-failure branch not driven by fault-injected UI test. |
| AC26 | Partial | A-shutdown; drawPersistence | Retry/cancel/explicit quit implemented; interactive failure choices not exercised automatically or manually here. |
| AC27 | Partial | P-service; service evictEligible; lazy classification | Exact base lazy eviction exercised; mixed non-lazy set and overdue due-index removal need explicit cases. |
| AC28 | Review | S-code recovery/compaction has no WorldChunk API; service startup catalog | No targeted nonresident timer-count assertion across opening/recovery/compaction. |
| AC29 | Partial | P-service; P-timers | Restored deadlines, readiness and later catch-up covered; repeated load registration and revision identity not exhaustively asserted. |
| AC30 | Partial | S-offset | Sparse native adapter exceeds 4 GiB; complete base/WAL transaction/recovery/compaction/index container boundary cases missing. |
| AC31 | Partial | L; S-offset arithmetic | Maximum 32-bit ID tested; explicit 2^32 count and 12*2^32 index-extent assertion missing. |
| AC32 | Partial | S-offset; F-state; S-corrupt | Overflow/range arithmetic and invalid descriptors tested; native API boundary matrix and prior-save preservation for every malformed extent missing. |
| AC33 | Tested | S-repair | Sync failure repairs remembered boundary before retry; no reread-based durability inference. |
| AC34 | Partial | S-repair; C-gates | Truncate/fullflush retries and source handoff covered; gameplay error visibility during repeated repair stalls not a full service fixture. |
| AC35 | Tested | C-race; S-repair | Gated real footer IO tests both authorization orderings and successful post-transition acknowledgment. |
| AC36 | Partial | S-model; S-repair | Lost/surviving failed sync and durable repair modeled; no complete before/during/after-repair cut-point sweep. |
| AC37 | Partial | C-gates; coordinator encodeAll | Cancellation while output-blocked releases all; active metadata encoding safe-stop latency not independently gated/measured. |
| AC38 | Partial | M-alloc; T-kernel; W-client; P-edits | Preparation and atomic successful publication covered; every authoritative multi-chunk publication allocation failure not exhaustively injected. |
| AC39 | Tested | C-gates; C-race | Encoder releases every source while writer remains blocked; cancellation before authorization prevents footer. |
| AC40 | Tested | C-gates; C-race | Sources release before gated fullsync and before authorized footer IO; cancel remains prompt during footer write. |
| AC41 | Partial | M-alloc; metadata empty-list initialization; Source.freeze | No backing allocation for empty lists by construction; explicit independent-array capacity assertion missing. |
| AC42 | Partial | C-order; W-client | Released source mutation preserves encoded old record and unrelated held data; concurrent authoritative mutation/caches need combined fixture. |
| AC43 | Partial | Source.freeze; world/chunk derived flags paths; W-client | Historical scalar copied; targeted derived-flag mutation during active encoding not exercised. |
| AC44 | Partial | P-service; W-client boundary/reconciliation tests; chunk decode reconstruction | Persistence loaded caches and optimistic caches covered separately; all historical/derived combinations not directly compared. |
| AC45 | Partial | B; M-alloc; service source gate | Growth failure ownership/accounting tested separately; borrowed-array resize attempt while active source remains gated lacks direct fixture. |
| AC46 | Partial | F-meta; B; M-alloc | Maximum wire metadata and allocator failure tested; service admission of every valid maximum-size collection not exercised. |
| AC47 | Partial | M-alloc; F-state; B | Codec/metadata/queue allocation failure sweeps; not every complete authoritative multi-chunk edit preparation path. |
| AC48 | Review | service prepared in-place mutation path; C-order Source pointers | No capture COW path; copied-byte/allocation instrumentation comparing admitted edits missing. |
| AC49 | Review | service dependency discovery/admission and worker prepared operation | No targeted traversal-count assertion across unchanged admission and deferred revalidation. |
| AC50 | Skipped | PERF covers persistence only | No baseline-versus-new simple edit/road/timer CPU, allocation, copied-byte and tail latency experiment. |
| AC51 | Partial | P-service; W-client; service processAdmitted retry accounting | Resource exhaustion/optimistic rejection tested; useful-handoff retry count under active capture not explicitly exercised. |
| AC52 | Partial | T-kernel; P-timers; simulation pauseDispatch/resumeDispatch | Deferred timer atomicity tested; paced service simulation backlog across repeated capture/resource waits lacks reference workload. |
| AC53 | Partial | P-service; B; block_diagnostics tests | Reserved bounded operation result exercised; all semantic/budget/backing-allocator failure classifications not end-to-end asserted. |
| AC54 | Partial | W-client; P-service | Rejection retires optimistic work and admission reopens; old-rejection/no-replay after live budget recovery needs direct service scenario. |
| AC55 | Partial | A-shutdown; service pending FIFO/save_fence_remaining; P-service | Unadmitted intent, producer preemption/resume, and ordered player save tests; all dependency completion/later-command races are not fully gated. |
| AC56 | Partial | P-service; S-compact; dependency/revision checks | Read errors and immutable generations covered; newly discovered second dependency and concurrent live edit race not directly tested. |
| AC57 | Partial | P-service; A-shutdown; applyEligibleCheckpoint | Ordered player records tested; unresolved gaps, rejected N, cross-session command identity require dedicated cases. |
| AC58 | Partial | A-shutdown; P-drain; service drain/read loop | A failed pre-save edit dependency is restarted and its edit reaches the durable snapshot; complete producer/read/client shutdown interleavings remain outside these focused fixtures. |
| AC59 | Partial | S-zero; S-native; S-code create | Correct creation ordering verified through Store/model; all initial-base failure steps not enumerated. |
| AC60 | Partial | S-zero; S-model | Snapshot-zero reopening and established headers covered; initial write/sync/rename/first-segment crash matrix missing. |
| AC61 | Tested | S-native; S-model; S-atomic | Snapshot-zero plus acknowledged WAL recovers complete logical state before periodic compaction. |
| AC62 | Tested | S-zero creation-artifact regression; L; S-corrupt | Missing/invalid opening rejects; orphan WAL and known temporary artifacts preserved before new anchor creation. |
| AC63 | Partial | S-corrupt; S-compact; compact input verification | Input hash and lineage checked; no targeted corrupt superseded-record/index fixture for every compaction path. |
| AC64 | Partial | compact pre/post whole-source verification and per-consumed-record check | No IO hook that substitutes corrupt bytes specifically during copying after initial validation, including superseded records. |
| AC65 | Tested | S-native; S-compact; compact/writeBase | Encoded bytes copied and validated with protected physical header/index, sync and install ordering. |
| AC66 | Tested | S-compact indexed-handle test | Guaranteed checksum-byte flip causes indexed read rejection; unexpected-success buffer explicitly freed. |
| AC67 | Tested | S-native; S-compact; F-codec | Exact encoded records survive WAL-to-base and base replacement without re-encoding. |
| AC68 | Review | service fixed timer pass selection; T-kernel | No gated ordinary B load during fixed resident pass A assertion. |
| AC69 | Tested | T-kernel; P-timers; P-service | Fixed cutoff processes eligible compaction/grass chain; future deadline retains original relationship. |
| AC70 | Partial | T-kernel; P-timers; M-alloc | Stale/replaced event and preparation failures covered; selected-work delay across service capture wait not explicitly gated. |
| AC71 | Partial | P-service; service evictEligible | Exact base revision/lazy eviction tested; redundant-WAL/stale-bookkeeping eligibility matrix absent. |
| AC72 | Partial | P-service; S-compact; revision increments | Revision advancement and base mismatch observed; return-to-earlier-bytes plus stale ack case not explicitly tested. |
| AC73 | Partial | P-service; historical/revision restoration paths | Base reload restores revision; metadata-only/historical-only mutation and pin-race matrix missing. |
| AC74 | Partial | F-codec; format encodeChunk payload comparison | Below/above boundary covered; exact 32768-byte standard payload tie fixture missing. |
| AC75 | Partial | F-codec | Air/trailing-air/long-run behavior and zero-count rejection covered; explicit odd-length, decoded-overflow and wrong-raw-length boundary fixtures missing. |
| AC76 | Skipped | format version constants and explicit material IDs | No second writer/reader version fixture or simulated material-addition migration. |
| AC77 | Partial | S-corrupt; version gates/material explicit IDs | Unsupported current format rejected; synthetic minimum-readable-version upgrade and declaration-reorder fixture absent. |
| AC78 | Review | format decodeChunk; gameplay block-buffer interpretation | No per-material membership validation; direct cast/layout/lifetime reviewed, not a compatibility release matrix. |
| AC79 | Partial | F-codec; S-corrupt; service loaded validation | Integrity/bounds validation precedes publication; no public-service fixture for every version/codec/payload rejection. |
| AC80 | Partial | F-meta | Independent maximum construction/timer sets and construction duplicate/index validation exercised; explicit timer duplicate, mixed-kind same-cell and excessive-count negative fixtures missing. |
| AC81 | Tested | F-meta | Custom-cell correspondence and all-custom maximum metadata fixture exercised. |
| AC82 | Partial | F-meta; F-state arithmetic; C-limits | Maximum wire bounds tested; malformed count/length overflow corpus not exhaustive. |
| AC83 | Partial | F-codec exact framing; F-state; format integer helpers | Little-endian integer helpers and exact air fixture covered; independent known-byte fixtures for every base/WAL/metadata integer missing. |
| AC84 | Tested | F-meta | Unknown required types/schema/flags and custom correspondence rejected. |
| AC85 | Skipped | F-meta reserved-flag rejection; schema-1 metadata definition | Schema1 defines only required types1–3; no explicitly registered safe optional extension exists. Unknown optional payload cannot be accepted solely because it is framed. |
| AC86 | Tested | F-codec | Raw0/standard1 dispatch,58-byte framing and unknown/invalid codec validation. |
| AC87 | Partial | F-meta; exact air fixture | Empty and known required section framing/order implemented; comprehensive out-of-order permutation fixture missing. |
| AC88 | Partial | F-codec exact domain/UUID fixture; S-compact | UUID/revision mutations and relocation covered; individual flag/length/block/metadata reseal mutation matrix missing. |
| AC89 | Partial | F-meta | 2/11-byte strides and independent full counts exercised; explicit malformed divisibility and excessive-count fixtures for both sections missing. |
| AC90 | Partial | F-meta; S-atomic; P-edits | Formed/unformed fields round-trip; each invalid direction/state/zero length/section boundary needs explicit fixture. |
| AC91 | Tested | F-meta full wire record cap | Independent maximum payload caps and combined metadata limit exercised without mandatory maximum preallocation. |
| AC92 | Tested | S-corrupt; S-model; S-atomic | Incomplete terminal append excluded while complete prior commit remains recoverable. |
| AC93 | Partial | S-corrupt; application startup error propagation | Fatal Store errors preserve artifacts; no subprocess stderr/path/nonzero-exit/no-final-cleanup assertion. |
| AC94 | Partial | S-corrupt; scan partial-field checks | Digest corruption and missing predecessor reject; full ambiguous-tail/interior-dependent-suffix mutation matrix absent. |
| AC95 | Partial | S-model; S-atomic; P-edits; P-restart | Seeded service edits/save/restart have an independent logical oracle; storage fault injection and client reconciliation remain separate from that trace. |
| AC96 | Partial | Explicit deterministic model cases; PERF seed provenance | Fault choices reproducible in fixed cases; no combined harness seed/operation log and scheduler replay covering all critical choices. |
| AC97 | Partial | S-corrupt | Corruption/dependency preservation asserted at Store API; subprocess stderr/fatal-exit contract not exercised by harness. |
| AC98 | Partial | S-zero; S-native; S-corrupt | Header/index/canonical records validated; independent golden base bytes and malformed index extent matrix missing. |
| AC99 | Partial | F-state; S-corrupt; startup descriptor reconstruction | Saved settings and tick round-trip; runtime-default-change replay fixture absent. |
| AC100 | Partial | F-state; P-service; S-atomic | 52-byte players, float fields, canonical multiple identities and NaN rejection covered; >16 offline players and full collision/reset restart test absent. |
| AC101 | Partial | S-native; S-code beginSnapshot/scan; S-atomic | Streaming framing and exact lengths implemented/tested in round-trips; independent known-byte84/120/56 framing and duplicate-ID fixture missing. |
| AC102 | Partial | F-codec; S-corrupt; S-model | Domain/identity integrity covered; explicit transaction relocation across segments and each checksum-domain golden vector missing. |
| AC103 | Tested | S-zero; S-native; S-model | Canonical snapshot-zero anchor and retained logical digest through physically checksummed compaction validated. |
| AC104 | Partial | A-shutdown; service drain and final save fence | CPU ordering/drain tests; dependency-waiting shutdown UI responsiveness not measured. |
| AC105 | Tested | P-lifecycle; P-drain; `public service final save retries transient persisted dependency once through watchdog` | The coordinator performs one automatic one-second retry for transient final-save dependency failures. Explicit retry remains available; permanent corruption is not retried automatically. |
| AC106 | Partial | Game.updatePersistence/drawPersistence | Five-second delayed choice and Keep waiting branch present; no fake-clock/UI test ensuring no duplicate request. |
| AC107 | Partial | A-shutdown cancel branch; C-race | Pending intent retained and cancel resumes controls; active commit plus stale shutdown completion/overdue state matrix missing. |
| AC108 | Partial | drawPersistence std.process.exit; S-model; updatePersistence durable-final branch | Explicit nonjoining exit and durable-finalization failure handling reviewed; no subprocess/UI stalled-quit restart scenario. |
| AC109 | Tested | C-gates; S-repair; native adapter | ACK withheld until real F_FULLFSYNC; injected sync failure cannot acknowledge. |
| AC110 | Partial | S-model; S-compact; io.Directory.sync | Publication and retirement barriers modeled including uncertain failed fullflush; hardware/APFS power-loss behavior not proven. |
| AC111 | Partial | S-zero; S-path; S-repair; io.CreationPath.sync | Nested parent/WAL/repair barriers and native injected failures covered; complete creation crash-boundary sweep missing. |
| AC112 | Partial | S-model; S-atomic; S-corrupt | Modeled working/durable bytes and namespace outcomes tested; bounded explicit cases, not exhaustive combined histories. |
| AC113 | Partial | S-lock; S-compact; C-gates | Native old-reader replacement and primitive failures covered; native multi-process/exit fixture missing; no power-loss claim. |
| AC114 | Partial | PERF | Pipeline baseline/stages/output/RSS measured; frame/operation p95/p99, gameplay contention, copy accounting and cancellation latency matrix missing. |
| AC115 | Partial | B; C-limits; P-service; PERF | Capacity/reservation/queue counters covered; metadata transient accounting integrated stress and allocator fragmentation envelope unmeasured. |
| AC116 | Partial | B; C-limits; M-alloc; T-kernel; P-service | Tiny budgets/injected allocation failures used without physical RAM exhaustion; UI behavior during pressure not validated. |
| AC117 | Partial | C-order; service whole-write-set gate | Released A old bytes retained; single cross-chunk operation requiring released A plus held B lacks deterministic service fixture. |
| AC118 | Review | service authoritative admission and dependency rediscovery | No advisory-writable/epoch-race fixture across road/revelation/timer dependency expansion. |
| AC119 | Partial | C-gates; C-race; P-policy | Actual service watchdog cancels/relinquishes sources while writes remain gated; interactive completion/frame latency unmeasured. |
| AC120 | Partial | service epoch/revision matching; W-client; S-compact | Stale identities guarded; delayed old release crossing a newer capture epoch not directly injected. |
| AC121 | Partial | C-gates; simulation pause state; service capture retry policy | Sources clear before IO; paced useful simulation progress between captures and no immediate repause not directly measured. |
| AC122 | Partial | P-service bounded terminal results; W-client; service pending FIFO | Unique logical intents/optimistic rejection bounded; retransmission/status coalescing and checkpoint-gap interleavings need a fixture. |
| AC123 | Partial | T-kernel; P-timers; simulation dispatch | Local timer catch-up idempotence covered; future NPC-style paced workload and bounded long capture backlog not evaluated. |
| AC124 | Partial | C-limits; C-gates; F-meta; PERF | Raw and near-limit metadata output/working reservations tested; save-priority service overload continuation lacks full workload test. |
| AC125 | Partial | C-order; Source.freeze descriptor layout | Sources borrow backing arrays and copied scalars; forced authoritative-map rehash/relocation during active encoding not directly tested. |
| AC126 | Partial | Source.freeze; C-limits | No full header/cache copy and no all-air source allocation by code; dedicated all-air manifest allocation-count fixture missing. |
| AC127 | Partial | P-policy; service last_success/overdue watchdog | Overdue capture survives gameplay deadlines and completes after finite stalled IO; repeated-cancellation age across multiple epochs still needs a trace. |
| AC128 | Partial | service admissible/overdue status; C-gates | Source release before sync verified; complete competing player/simulation priority, bounded backpressure and exceptional UI pause workload missing. |
| AC129 | Partial | C-gates; C-limits; service status/drawPersistence | No fake ACK under stalls/failures and bounded capacity verified; interactive exit/status serviceability under save priority unmeasured. |
| AC130 | Partial | PERF | 10k active/4k dirty and smaller/heavy pipeline cases measured;16GB/8GB physical-machine envelopes, frame confirmation latency and long successful-save age/rate not established. |
| AC131 | Partial | P-lifecycle; P-policy; A-shutdown | Gated final capture outlasts normal deadline; cancelling intent resumes mutation, and later retry saves successfully. Interactive cancel-exit/commit race matrix remains. |
| AC132 | Partial | P-lifecycle; P-policy; scheduleWatchdog/pending.since/retryPending | Actual capture/player/final/overdue policies exercised; earliest player selection and retained timestamps reviewed. Full multi-epoch dependency scheduling matrix remains. |
| AC133 | Partial | C-gates; C-limits; PERF independent stalls | Oversized bounded output cancellation and sync separation tested; fitting-output delayed-write correctness shown by benchmark128/256MiB, not a tiny deterministic fixture. |
| AC134 | Partial | PERF schema2 ten-cycle reports | Known stalls correctly scoped to transaction phase; no gameplay/frame metrics, failed/cancelled trend reports or sustained overload experiment. |
| AC135 | Partial | service scoped pins/residency; P-service; T-kernel | Revision/lazy path covered; mixed unknown non-lazy kinds and timer-pass/dependency eviction-reload race matrix missing. |
| AC136 | Partial | P-service; P-timers; T-kernel | Readiness with pending timers and two-stage catch-up covered; fair bounded service progress under capture/backlog/resource pressure not fully exercised. |
| AC137 | Partial | T-kernel; P-timers; loaded revision checks | Fixed-cutoff equivalence/idempotence and cross-boundary edits covered; concurrent stale-load/catch-up ordering reference fixture absent. |

## Outstanding validation versus implementation gaps

The largest validation gap is the full combined seeded reference harness requested by AC95–AC97. The seeded public-service restart test checks edits, acknowledged snapshots, unsaved suffix loss, base/WAL recovery, and reload against independent logical state. Deterministic storage crash tests exercise actual Store operations, while the seeded client test exercises reconciliation. Fault injection, capture cancellation, and client retransmission are still separate suites; they do not collectively constitute the full combined harness. The other broad missing evaluations are interactive shutdown/status behavior, full native process ownership/fatal-startup tests, all-container 4 GiB boundary fixtures, and gameplay/performance measurements on the specified memory envelopes.

AC105's automatic delayed dependency-read retry was implemented and verified after the initial audit. Creation over orphan persistence artifacts (AC62) was corrected with a guard and a native preservation regression while writing this map. Schema1 currently has no explicitly defined safe optional metadata extension (AC85); rejecting arbitrary unknown flags/types preserves the required-state contract rather than guessing that unknown data is optional. Consult the final validation report for follow-up changes made after this audit.
