# World persistence format contract

This is the normative format reference for the
[world-persistence feature spec](../features/world-persistence.md). It contains the existing
binary layouts, encoding rules, compatibility policy, checksums, and metadata bounds
for current format 7. Formats 1–6 are rejected as incompatible development worlds.
Version 7 persists construction ownership transfers, retained materializing instances,
and durable grass-initialization obligations; it adds no migration or historical ruleset.
All R/Q identifiers refer to that feature spec;
requirement and acceptance-criterion IDs remain there. Runtime ownership, cancellation,
recovery procedures, and platform durability remain in the feature spec.

## Large-File Format and Arithmetic

The initial format uses the following widths; no 4-GiB save-size preflight is required.

| Field | Serialized width |
| --- | --- |
| Chunk ID | u32, unchanged from the world layout |
| Absolute file offset, including chunk index and WAL positions | u64 |
| Declared base-file size; aggregate section/index/transaction byte length | u64 |
| Aggregate counts, including chunk-index entries, WAL records, and players | u64 |
| Bounded individual chunk-record, block-payload, and metadata-section byte lengths | u32 |
| Block type and literal RLE count | u8, unchanged |

Each on-disk chunk index entry is exactly 12 bytes: a u32 chunk ID followed by a u64
absolute offset from the beginning of the base file, with no native alignment padding.
Bounded per-chunk lengths do not limit the combined file size. Their totals must fit the
individual record framing; enforce codec-specific bounds before allocation. Other bounded
record fields retain explicitly specified widths when the exact section layouts are frozen.

The current world layout permits 2^32 distinct chunks. IDs fit u32, but their count needs
u64. Widen operands before computing dimension products, count * entry_size, or accumulated
output lengths. Use checked u64 arithmetic for file extents, WAL commit boundaries, read/
write cursors, and compaction accounting. Validate a range using offset <= file_size and
length <= file_size - offset (or an equivalent checked addition), including nested sections.
Do not increment a u32 chunk ID as a loop counter past its maximum value.

Keep file positions separate from in-buffer indices. Check conversions to usize and any
signed or narrower platform file-offset type; neither truncation nor floating-point size
accounting is valid. Stream payloads/checksums in bounded buffers, and check index/cache
allocation arithmetic and resource limits separately from on-disk sizes. Large-file support
does not require loading the entire file into memory. Report platform/filesystem limits and
I/O failures through the existing save/load failure paths without discarding durable files.

## Enum IDs and Reader Compatibility

Use explicit material enum values rather than relying on declaration order, and numeric u8
codec IDs as assigned below.
Keep air at 0 and custom-cell storage at 255. The current application also has a placement-only
adaptive-road material; existing behavior stores those cells as custom plus metadata, not as
the placement selector. Preserve that distinction in the encoder.

Each base/WAL file records the version it was written with. Engine constants define
`current_write_version` and `minimum_readable_version`. Accept only the supported inclusive
range, with actual decoding support for every accepted version. These are distinct from
snapshot sequences, world ticks, and generator versions. The minimum is an engine support
policy; a second per-file version field is not required for this initial design.

The current writer and minimum reader version are both 7. Development formats 1–6
are rejected before their gameplay records are interpreted. A version bump alone does
not implement compatibility: incompatible changes must also raise the minimum unless
the engine supplies every required older decoding path. Pre-release development saves
have no migration or backward-compatibility commitment.

All accepted file encodings map to the same current gameplay logic. The reader does not
select a historical ruleset from a save or an individual blueprint. A sufficiently incompatible
gameplay change also advances the write version and raises the minimum to exclude old worlds,
even when record layouts are unchanged. This world-level gate covers saved blueprint definitions
and unfinished instances without independent rule-version fields or migration.

Validate material membership before publishing a typed chunk, including chunks with no
metadata. Accepted raw IDs are 0–6, 8–20, and 255. Legacy packed dirt ID 7 is reserved
and rejected, as are all other IDs. Raw and RLE decoding must yield exactly 32,768 bytes
including implicit trailing air, then metadata validation scans every material byte.
Checksums and version compatibility do not replace material membership validation.

Verify the one-byte `BlockType` layout and array size at compile time and preserve required
alignment and ownership. The live chunk must own its decoded buffer rather than referring
to recycled I/O scratch storage. Custom metadata must match byte-255 cells exactly before
the owned buffer is reinterpreted in x-fast `[z][y][x]` order.

## Section Compatibility and Extensions

All serialized integers use little-endian encoding and explicit widths. Section layouts are
wire contracts, not native Zig structs: omit compiler padding and serialize each field in
the defined order. Each metadata section has this confirmed layout:

| Field, in order | Encoding |
|---|---|
| Section type | u16 |
| Section schema version | u16 |
| Section flags | u8 |
| Payload length, excluding header | u32 |
| Payload | Declared number of bytes |

The header is exactly 9 bytes. Flag bit 0 means required; other bits are reserved and
initially zero. Initial section schema versions are 1, with these stable type assignments:

| Section type | Meaning |
|---|---|
| 0 | Invalid/reserved |
| 1 | Custom-block records |
| 2 | Construction markers |
| 3 | Pending transformations |

All three initial section types are required to understand when present. Emit only nonempty
sections, once each, in ascending type order; reject duplicates or out-of-order sections.
An absent section denotes an empty collection. Custom records must still match custom cells
exactly, so their section cannot be absent when custom cells exist. The enclosing metadata
payload length determines the end; there is no terminator or section count. Payload schemas
and their derived byte limits are defined under Metadata Semantics and Size Bounds.

Each metadata section identifies its type and schema version, declares whether it is required
or optional, and gives its payload byte length. Parse known supported sections with their
declared schema and require exact payload consumption. Unknown types or unsupported schema
versions fail when required. Only sections explicitly defined as optional and safe to ignore
may be skipped; length framing alone is not permission to discard unknown state. A section's
schema defines whether absence is allowed and the resulting defaults; do not invent defaults
for missing required gameplay data.

Even skipped payloads remain within validated section/record bounds and enclosing checksum
coverage. Check their lengths before seeking/advancing. Optionality is a format compatibility
promise that gameplay remains valid without interpreting that extension; it is not a general
guarantee of lossless preservation of unknown data when rewriting saves. Custom-block types
are required semantic data and must be recognized; material validation does not
permit skipping unknown custom payloads or guessing their sizes.

The file-version gate runs before section interpretation. An older engine still rejects a
newer overall save version even if that file's new sections happen to be optional. An updated
engine may read supported older schemas or skip permitted optional extensions, but must never
apply a new interpretation to old bytes without explicit version-aware decoding. Incompatible
changes follow R49's minimum-readable-version policy.

## Initial Block Encoding

Use standard byte-pair RLE or raw bytes only, with numeric u8 codec IDs:

| Codec ID | Meaning |
|---|---|
| 0 | Raw: exactly 32,768 block bytes |
| 1 | Standard RLE: `(u8 material, u8 count)` pairs |
| 2-255 | Reserved; reject at per-record dispatch |

Flatten blocks in x-fast `[z][y][x]` order;
there are exactly 32,768 cells. Standard emits a material byte and a literal count in 1-255
for each run fragment. Adjacent fragments may have the same material when splitting a long
run. Zero is never a count/sentinel. The explicit payload length delimits the pairs.

Standard may omit trailing air; the decoder initializes the remainder to air. A zero-byte
standard payload denotes an all-air chunk, still an explicit override when indexed. Validate
that payload length is even and the sum of counts does not exceed 32,768; explicit cells plus
implicit trailing air must fill the chunk exactly. Raw requires all 32,768 material bytes,
including trailing air. Apply R49/R50's version and enum policy and validate custom-cell
metadata and every material ID in both modes.

Select standard if its encoded block payload is <=32,768 bytes; select raw otherwise. Codec
selection does not need a separate histogram pass or persistent per-chunk statistics. Encode
with bounded scratch storage, stopping the RLE attempt once committed output would exceed
the raw size. When omitting trailing air, defer a pending air run until a subsequent non-air
cell proves it is internal; omitted final air must not incorrectly trigger the raw fallback.
On fallback, use the original immutable block array for raw output. Metadata/framing/checksum
remain the same in either case; release snapshot ownership only after all required reads finish.

## Chunk Record Layout

The initial chunk-record checksum layout is confirmed: a 32-byte BLAKE3-256 footer inside
the length-framed chunk record, using the same record representation in base and WAL.
The exact hash input is `domain_prefix || world_uuid || record_bytes_before_checksum`.
Use `ZGW-CHUNK-1\0` including its trailing zero and the fixed 16-byte world UUID representation
from the validated container, never a textual UUID or native struct representation. Include
all record lengths; exclude the checksum itself. The record layout is:

| Field, in order | Encoding |
|---|---|
| Total record size, including checksum | u32 |
| Chunk ID | u32 |
| Persistent chunk revision | u64 |
| Persistent flags | u8 |
| Block codec | u8 |
| Block payload length | u32 |
| Block payload | Declared number of bytes |
| Metadata payload length | u32 |
| Metadata sections | Declared number of bytes |
| Chunk checksum | 32-byte BLAKE3-256 |

Fixed overhead is exactly 58 bytes, with no padding. Persistent flag bit 0 stores historical
`is_unreachable`; remaining bits are reserved and initially zero. Base and WAL use identical
records. Index entries remain `(u32 ChunkId, u64 offset)`, exactly 12 bytes, and are not part
of the chunk hash input. The container supplies world identity; offsets and segment/snapshot
identities are excluded so compatible records can retain their checksum when copied.
Source checksum verification remains required during copying.

A footer permits streaming without backpatching the checksum. Preserve this algorithm and
layout as part of the format-version contract, not a runtime setting. Hash-cost measurements and
alternative algorithms are follow-up improvements, not prerequisites for this initial choice.

## Binary Container Layouts

The initial save-format version was 1; version 2 added inventory schema 1 below.
Version 3 added the world's private blueprint library and unfinished-instance progress.
The current writer and minimum readable version are both 7. Version 4 added unfinished
world-work keys with each base and WAL snapshot. Version 5 gated platform-only direct stone
support and portable blueprint certification. Version 6 excluded loose-soil support and
placement-triggered compaction. Version 7 changes blueprint progress and transformation-marker
semantics.
The base and every WAL segment must pass this
whole-world version gate before their gameplay data is published. No migration or
historical ruleset dispatch is provided. Fixed base/WAL header sizes remain unchanged.
All integer fields are explicitly sized and little-endian; f32/f64 use
their IEEE-754 little-endian bit representation. Serialize fields individually without
native struct padding. UUIDs are fixed 16-byte sequences carried unchanged between records
and hash inputs, not text or platform-native UUID structs. Header sizes must match the
supported version's layout; a length alone does not authorize unknown fields or schemas.

### Base file

The physical order is:

```text
Base header
World descriptor
Global state
Chunk index
Player records
Blueprint-state byte length (u64), followed by blueprint checkpoint bytes
Pending-work byte length (u64), followed by canonical pending-work keys
Chunk records
Base physical checksum (32 bytes)
```

| Header field, in order | Encoding |
| --- | --- |
| Magic: `ZGWORLD\0` | 8 bytes |
| Save-format version | u32 |
| Header size | u32, initially 120 |
| Total file size, including checksum | u64 |
| World UUID | 16 bytes |
| Incorporated snapshot sequence | u64 |
| Incorporated snapshot digest | 32 bytes |
| World descriptor byte length | u32 |
| Global-state byte length | u32 |
| Chunk count | u64 |
| Player count | u64 |
| Player-record section byte length | u64 |
| Chunk-record section byte length | u64 |

The header is exactly 120 bytes. Section positions follow from these lengths and the
`chunk_count * 12` index length, using checked arithmetic; no separate section directory
is stored. The total must equal the actual file size, including the final 32-byte checksum.
Sections and records must consume their extents exactly, without overlaps, gaps, or trailing
unaccounted bytes. The index and base chunk records are sorted by chunk ID with no duplicates;
each index identity and absolute offset must select the matching complete chunk record.
Player records are sorted by player ID with no duplicates.
The blueprint and pending-work length prefixes are present even when zero; their bytes
are not part of the player-record or chunk-record section lengths. Chunk-index absolute
offsets account for both sections. Their declared lengths are bounded before allocation
and must fit the base's exact total extent.

Compaction writes a seekable temporary file: reserve the index, stream records, and finalize
index offsets and header lengths before computing the base physical checksum. Initially use
a final bounded streaming read of finalized bytes for that checksum. This adds a read but
avoids retaining the whole base in memory. Source verification under R45 remains required;
hashing the output does not replace it. Validate/synchronize the finished candidate before
installation, and preserve the incorporated logical snapshot digest independently of this
new physical checksum.

### Immutable world descriptor

| Field, in order | Encoding |
| --- | --- |
| Descriptor schema version | u16, initially 1 |
| Coordinate/chunk-ID layout version | u16, initially 1 |
| Chunk edge length | u16, initially 32 |
| World dimensions in chunks, X/Y/Z | [3]u32 |
| Topology flags | u8; bit 0 = wrap X, other bits initially zero |
| Generator ID | u16; 2 current natural/flat profile generator |
| Generator implementation version | u32, initially 1 |
| Seed | u64 |
| Generator-settings byte length | u32 |
| Generator settings | Declared bytes |
| Logical ticks per second | u32, initially 60 |

The descriptor occupies 41 bytes plus settings. Layout version 1 defines the existing
centered coordinate convention and chunk-ID packing; reconstruct derived masks/shifts from
validated dimensions rather than serializing them. Reject unsupported layout, chunk size,
topology, tick rate, generator identity/version, or settings. In particular, a saved topology
must match what the running engine supports. Settings are immutable for the world's lifetime.
Do not substitute runtime defaults for saved values. Incompatible generator behavior changes
advance the generator implementation identity/version and the world-save write/minimum-readable
versions so unsupported older worlds are rejected under Q1. Keep one current generator logic
with its supported settings profiles rather than historical implementations or required migration.

Generator ID 2, implementation version 1, is the only accepted generator. Settings start
with a profile byte: 0 natural, 1 flat. Flat settings are exactly one byte `{1}`. Natural
settings are exactly nine bytes, in this order:

| Field | Encoding |
| --- | --- |
| profile | u8 = 0 |
| beaches | u8 boolean, 0 or 1 |
| climate_displacement | u16 |
| island_count | u8 |
| large_deposits_per_resource | u8 |
| small_deposits_per_resource | u8 |
| feature_index_capacity | u16 |

Validate all settings against the current generator's parameter and layout rules. The
descriptor occupies 42 bytes for flat and 50 bytes for natural; its fixed part remains
41 bytes. Saved settings determine generation for absent chunks throughout the world's
lifetime.

### Global and player records

Global schema 1 contains `u16 schema_version = 1` followed by `u64 world_tick`, exactly
10 bytes. Future persistent globals require an explicit schema/format change. Resume this
tick without adding offline time; the tick rate is in the immutable descriptor.

Each player record has this layout:

| Field, in order | Encoding |
| --- | --- |
| Total player-record size, including its size field | u32 |
| Player schema version | u16, initially 1 |
| Player ID | u64 |
| Feet position, X/Y/Z | [3]f64 |
| Yaw and pitch, radians | [2]f32 |
| Inventory schema version | u16 |
| Inventory payload length | u32 |
| Inventory payload | Declared bytes |

Legacy inventory schema 0 has a zero payload length and occupies 52 bytes in total;
reading it initializes an empty slot. Current inventory schema 1 has a one-byte payload,
so every newly encoded player record occupies 53 bytes. Payload byte 0 denotes an empty
slot; bytes 2, 4, 5, 6, and 8 through 14 are the placeable carried materials. Reject other
values, unsupported inventory schemas, incorrect payload lengths, and nonfinite
coordinates/angles. Player schema remains 1. Read each player using its declared record
length, then validate exactly the declared player count in ascending ID order.

Restore feet position/view under R17's motion-reset and authoritative collision-validation
rules, and restore the inventory slot for that player ID. Partial holds and optimistic
predictions have no persistent representation. Accepted terrain/inventory transfers are
captured together; rejected edits cannot alter the saved slot. The record has no individual
checksum: its container's physical checksum or transaction digest covers it.

Persist all known players, including offline players, sorted by unique player ID. A
simultaneous-player target does not limit historical records. Each WAL transaction
contains complete global state, the complete player array, and the complete pending-work
set, plus only changed chunks and ordered blueprint operations.
Player eligibility still follows R42; client/session command dependency watermarks are
resolved before capture and are not serialized as persistent session counters. Validate
record counts and exact section consumption before publishing recovered state.

### WAL segment and transaction framing

Each segment begins with this immutable header:

| Field, in order | Encoding |
| --- | --- |
| Magic: `ZGWAL\0\0\0` | 8 bytes |
| Save-format version | u32 |
| Header size | u32, initially 120 |
| World UUID | 16 bytes |
| Segment UUID | 16 bytes |
| Predecessor snapshot sequence | u64 |
| Predecessor snapshot digest | 32 bytes |
| Header checksum | 32 bytes |

The header is exactly 120 bytes. Generate a new unique segment UUID at rotation. There is
no mutable total-WAL-size field. The predecessor is the committed snapshot immediately
before this segment; its first transaction must name that predecessor, and each subsequent
transaction must name the preceding commit. Recovery follows validated links rather than
filenames, modification times, or numerical adjacency of attempted snapshot sequences.
Verify the header checksum even when no transactions follow. Establish and synchronize the
header and directory entry under the existing creation/rotation durability contract.

Each transaction consists of header, complete global state, complete player array,
blueprint-operation byte length (u64), blueprint operations, pending-work byte length
(u64), canonical pending-work keys, changed chunk records, and commit footer. Both length
prefixes are present even when zero. The transaction header is exactly 84 bytes:

| Field, in order | Encoding |
| --- | --- |
| Begin marker: `ZGTXBEG1` | 8 bytes |
| Snapshot sequence | u64 |
| Previous committed sequence | u64 |
| Previous committed digest | 32 bytes |
| Global-state byte length | u32 |
| Player count | u64 |
| Player-record section byte length | u64 |
| Changed-chunk count | u64 |

The commit footer is exactly 56 bytes:

| Field, in order | Encoding |
| --- | --- |
| Commit marker: `ZGTXEND1` | 8 bytes |
| Total transaction size, including header and footer | u64 |
| Snapshot sequence, repeated | u64 |
| Transaction digest | 32 bytes |

The changed-chunk count is known at capture, while compressed sizes become known during
encoding. Put the total transaction size only in the footer, allowing streaming without
WAL backpatching or retaining all encoded chunks. Release snapshot references under R29.
Parse the declared global/player/blueprint/pending-work sections and exactly the declared number of length-framed
chunk records before expecting a footer; never search payload bytes for magic markers.
Reject duplicate chunk IDs within a transaction. Chunk records use the identical base/WAL
representation already defined; WAL chunk ordering need not match the sorted base order.

The footer's size must equal bytes consumed from the transaction start through its digest,
and its repeated sequence must match the header. Validate all framing, predecessor links,
checksums, and payload semantics before accepting a recoverable snapshot. A marker alone
does not establish a commit. Writer success still requires synchronization before
acknowledgment; partial writes and failure repair remain governed by R23/R30/R55.

### Unfinished world-work keys

`deferred_world_work.zig` defines a finite typed reconciliation obligation. The enclosing
base/WAL section starts with its byte length as u64, followed by zero or more five-byte
records without a per-record header or native padding:

| Field, in order | Encoding |
| --- | --- |
| Work kind | u8; 1 = road-shape reconciliation, all other values unsupported |
| Chunk ID | u32 |

Sort strictly by numeric kind, then numeric chunk ID; duplicates and out-of-order keys
are invalid. Require the byte length to be divisible by five, at most 4,096 entries
(20,480 payload bytes), and every chunk ID to lie within the saved world's dimensions.
Bound section bytes before reading/allocating them; validate the complete set before
allocating runtime keys or publishing state. A zero-byte payload denotes an empty set.
Every committed snapshot replaces the complete prior set, including when empty;
this section is not an operation journal.

Marking an obligation accompanies accepted world effects in the same snapshot. Clearing
an obligation accompanies its completed current-world result. A snapshot may retain a key
alongside already committed partial reconciliation effects; restart repeats the whole pass.
Road shape and ownership remain ordinary chunk metadata. Runtime cursors, revision
observations, repeat flags, and dependency waits are not serialized. Restore scheduling
directly from saved keys before readiness and load dependencies on demand. Existing
source ownership and selected-command-prefix rules still apply; a nonempty work set does
not itself block any save kind. Future work kinds require explicit shared schemas/handlers
and the enclosing world-version compatibility policy.

The capture owns an immutable encoded set; storage owns the last committed encoded set.
Base compaction copies its frozen set and preserves any newer live committed membership.
See [persisted unfinished world work](../features/deferred-world-work.md).

### Blueprint definitions and active instances

`persistence/blueprints.zig` implements these records. All fields are serialized in the
listed order without padding; the enclosing base checksum or WAL digest protects them.
There is no separate blueprint rules version. Names are canonical UTF-8 with outer Unicode
whitespace removed, 1–100 Unicode scalar values and at most 400 bytes; line breaks and
control characters are forbidden. Duplicate names are permitted. Definition IDs and
instance IDs occupy independent monotonically increasing nonzero u64 spaces. Exhaustion
rejects new allocations rather than wrapping or reusing an ID.

| Record | Fields in order |
| --- | --- |
| Immutable definition | ID u64, owner/player ID u64, name byte length u16, name bytes, compact size [3]u32, occupied target count u32, dense-cell byte length u32, dense logical material bytes |
| Instance identity/transform | ID u64, definition ID u64, owner/player ID u64, normalized world origin [3]u32, clockwise quarter-turn u8 (0–3) |

Definition cells use x-fast order `index = (z * size_y + y) * size_x + x`. The byte
length must equal the checked volume. Both horizontal cell counts must be no greater than
`min(world_blocks_x / 2 - 1, world_blocks_y)`; every dimension is positive and all six
outer faces contain at least one occupied cell. Accepted logical materials are air 0,
dirt 2, sand 5, crushed stone 8, tree trunk 9, planks 10, rebar 11, reinforced concrete 12,
and solid country road 13. Target count equals the number of nonair cells and is nonzero.
An instance references an existing retained immutable definition and has the same private
owner. Its rotated box fits finite Y/Z bounds, uses normalized wrapping X, and cannot
overlap another active box. Rotation maps `(x,y,z)` to `(y,width-1-x,z)` per clockwise turn.

An empty never-used blueprint checkpoint is zero bytes. Otherwise its header is exactly
28 bytes: maximum allocated definition ID u64, maximum allocated instance ID u64,
definition count u32, active-instance count u32, and grass-initialization count u32.
Highwaters survive completed-instance retirement. Definitions follow in increasing ID
order, then active instances in increasing ID order. The identity/transform record is
exactly 37 bytes. Each active instance contains, in order:

| Field | Encoding |
| --- | --- |
| Identity/transform | 37-byte record above |
| Remaining target count | u32 |
| Phase | u8; 0 building, 1 materializing |
| Construction revision | u64 |
| Fulfillment bitmap | exactly `ceil(definition_volume / 8)` bytes |
| Target-bearing portion count | u32 |
| Portions | each chunk ID u32 followed by terrain revision u64, sorted by chunk ID |

Bit `index % 8` of byte `index / 8` marks that dense definition index fulfilled. Air-cell
and unused trailing bits must be zero. Remaining equals occupied targets minus set bits;
positive remaining requires building, and zero remaining requires materializing. The last
fill retains the materializing instance. Its portions cover exactly the canonical
nonempty target groups, including groups with no transfer. Revision zero denotes simulation
ownership; a nonzero terrain revision denotes world-data ownership. Only materializing
instances may have transfers. Construction revision equals fulfilled target count plus
transferred portion count. Complete instances have no active checkpoint record.

Grass obligations follow active instances, sorted by `(instance_id, chunk_id)`. Each is
49 bytes: identity/transform (37), chunk ID u32, and completion tick u64. It refers to a
retained definition and a soil-bearing target chunk; its completed instance ID is at most
the highwater and cannot also identify a live instance. This descriptor routes work and
supplies a deadline; cell lifetime is proved separately by per-cell markers. Definitions
remain retained; there is no deletion operation. Derived spatial/render indexes are rebuilt.

WAL operations have no native struct framing or padding. Parse to the exact section end;
reject unknown kinds, truncation, invalid references, reused IDs, duplicate fulfillment or
transfer, and progress directed at air/out-of-range cells. Ordered operations may create,
fill, transfer, complete and initialize a site in one transaction.

| Kind u8 | Following payload | Total bytes |
| --- | --- | --- |
| 1 | Immutable definition record | variable |
| 2 | Identity/transform; targets initially pending | 38 |
| 3 | Instance ID u64, dense definition index u32 | 13 |
| 4 | Instance ID u64, chunk ID u32, terrain revision u64 | 21 |
| 5 | Instance ID u64, completion tick u64, soil-group count u32 | 21 |
| 6 | Instance ID u64, initialized chunk ID u32 | 13 |

Kind 3 changes one bit, remaining count and construction revision. Kind 4 transfers an
entire canonical target group exactly once, at a nonzero terrain revision. Kind 5 requires
all targets fulfilled and all groups transferred; it retires the instance, frees active
quota, and creates exactly the declared number of soil-group obligations. Kind 6 retires
the matching grass obligation after its matching cell markers have been activated.
Normal fulfillment never rewrites immutable definitions or complete bitmaps. Checkpointing
may encode the full bitmap and portions.

Preflight validates and allocates touched operations before the commit footer. Publication,
raw terrain, timers, player inventory and obligations share one durable transaction/capture
boundary; recovery publishes only fully verified committed sections. Before gameplay,
pending targets and fulfilled untransferred targets must be raw air. Transferred targets
must exactly match the bare definition material; grass and legacy packed dirt do not count
as transferred dirt. A portion's terrain revision cannot exceed the raw chunk revision.

Defaults permit 1,048,576 cells per definition, 4,096 definitions and active instances,
4,096 grass obligations, a 64 MiB encoded checkpoint and a 16 MiB/1,048,576-operation WAL
section. Full grass-obligation capacity defers completion without discarding accepted work.
These are configurable resource policies, independent of the service's 256 MiB native
construction-container estimate and 128 MiB source-snapshot bound. Checked arithmetic and
declared wire widths still apply. Preflight failure leaves the transaction unpublished.

## Snapshot Integrity

Use these literal ASCII checksum-domain prefixes, each including exactly one trailing zero
byte (`\0` below denotes that byte, not two printable characters):

| Checksum purpose | Domain prefix |
|---|---|
| Chunk record | `ZGW-CHUNK-1\0` |
| WAL segment header | `ZGW-WALHDR-1\0` |
| WAL transaction | `ZGW-WALTX-1\0` |
| Snapshot-zero anchor | `ZGW-INIT-1\0` |
| Base physical checksum | `ZGW-BASE-1\0` |

Prefixes are hash inputs, not repeated serialized record fields. The suffix `1` versions
the hashing contract, independently of the overall save-format version; adding a material
does not itself change these prefixes. Use BLAKE3-256 for all five checksum purposes; the
algorithm is a format contract, not a runtime setting. Exact coverage, with `||` meaning
byte concatenation, is:

| Digest | BLAKE3-256 input |
| --- | --- |
| Chunk | Chunk domain prefix `||` world UUID `||` record bytes preceding its checksum |
| WAL header | WAL-header domain prefix `||` header bytes preceding its checksum (88 bytes initially) |
| WAL transaction | Transaction domain prefix `||` complete validated WAL header (120 bytes initially, including its checksum) `||` transaction bytes preceding its digest |
| Base physical | Base domain prefix `||` every base-file byte preceding its final 32-byte checksum |
| Snapshot-zero anchor | Initial-anchor domain prefix `||` canonical initial fields listed below |

Transaction coverage includes its header, global state, full player records, blueprint
length prefix and operations, pending-work length prefix and keys, chunk records
with their checksums, and the commit footer's marker, total length, and repeated sequence.
Only its final digest is excluded. The included segment header binds world, segment, format,
and segment predecessor; the transaction header binds the immediately previous committed
sequence/digest. Verify the segment header independently before using it in this input.
The base physical checksum includes the finalized header, incorporated logical digest,
descriptor, global state, index, blueprint length/checkpoint, pending-work length/keys, and
all player/chunk records with their record checksums.

Use one chained digest per committed snapshot transaction. Validate footer identity/length
as well as the digest. Append hashing processes the fixed segment header and new transaction
bytes, without rereading prior transactions; recovery verifies each retained transaction.
The chain proves a valid linked prefix; stored predecessor digests cannot replace validation
of earlier payloads. Base compaction preserves the incorporated logical snapshot digest as
the chain anchor, while a separate physical checksum protects the rewritten base contents.

The snapshot-zero anchor hashes the following concatenation in order, with all integer
fields encoded little-endian and all variable contents using the confirmed record schemas:

```text
ZGW-INIT-1\0 (including its trailing zero byte)
World UUID (16 bytes)
Save-format version (u32)
Snapshot sequence (u64 = 0)
World descriptor length (u32), followed by descriptor bytes
Global-state length (u32), followed by global-state bytes
Player count (u64)
Player-section length (u64), followed by player records sorted by player ID
Blueprint-state length (u64), followed by canonical blueprint checkpoint bytes
Pending-work length (u64), followed by canonical pending-work keys
Initial override count (u64), followed by chunk records sorted by chunk ID
```

The domain is included once. Counts, record lengths, and canonical ordering make the input
unambiguous. Initial chunks retain their independent checksums, which do not depend on this
anchor. Exclude physical offsets/index, base total size, the anchor field itself, and the
base physical checksum to avoid self-reference and physical-placement dependencies. An
untouched generated world has zero initial overrides. Store the resulting digest in the
snapshot-zero base and reference it from the first WAL segment; install both with the
existing synchronization protocol before acknowledging journal snapshots.

## Metadata Semantics and Size Bounds

The initial independent section limits are:

| Section | Entry limit | Identity/correspondence rule |
| --- | --- | --- |
| Construction markers | 32,768 per chunk | Unique cell index in 0-32,767 |
| Pending transformations | 32,768 per chunk | Unique cell index in 0-32,767, irrespective of event kind |
| Custom-block records | Number of custom cells, at most 32,768 | One record per byte-255 cell in x-fast block order |

Uniqueness is local to a section. A construction marker and a timer for the same cell are
valid together; do not impose a shared 32,768-entry limit across all sections. Multiple
timer records for one cell are invalid; rescheduling replaces the prior pending event
under the existing gameplay semantics. Custom record association follows block order,
rather than requiring a second stored cell-index list. Validate the schema of each custom
type and reject missing, extra, truncated, or unsupported records.

Schema version 1 uses these payload records, in the stated field order, little-endian and
without padding:

| Section | Entry fields | Serialized entry size |
| --- | --- | --- |
| Construction markers | Cell index u16 | 2 bytes |
| Pending transformations | Cell index u16, kind u8, deadline tick or lifetime token u64 | 11 bytes |
| Custom blocks: unformed adaptive road | Custom type u8, road state u8 | 2 bytes |
| Custom blocks: formed adaptive road | Custom type u8, road state u8, high endpoint [3]u32, downhill direction u8, formation length u32, section index u32 | 23 bytes |

Construction and timer payloads contain no additional entry count: divide the section length
by 2 or 11 respectively, rejecting a remainder or count above 32,768 before allocation.
Cell indices use x-fast order and must be below 32,768 despite their u16 storage width.
Transformation kind 0 is removed and rejected. Kind 1 is `grow_grass`, whose u64 is an
executable logical deadline. Kind 2 is `initialize_grass`, accepted only on raw bare dirt
(ID 2) with a nonzero construction lifetime token. Reject all other kinds. Kind 2 never
runs as an ordinary timer and has no deadline. A durable completion obligation activates
only a matching cell's token and starts its grow deadline at `completion_tick + delay`.
Cell replacement or cancellation destroys its old marker, preventing stale obligations
from initializing a later cell lifetime.

Custom type 0 denotes an adaptive road. Road state 0 is unformed/adaptive and has no further
fields; state 1 is a formed slope and has the remaining 21 bytes listed above. Reject unknown
types/states. Direction IDs are 0 positive_x, 1 negative_x, 2 positive_y, 3 negative_y;
reject other values. The high endpoint uses world block coordinates in x/y/z order and must
fit the saved world layout. A formed length must be positive and the section index must be
less than that length. Retain the formation ownership fields for correct later edits; derive
heights from length and section as in the current road model, without storing floats. Custom
cell indices remain implicit in block order. Parse exactly the expected number of custom
records and consume the section exactly, rejecting truncation or extra bytes.

The initial serialized bounds are:

| Section | Maximum entries | Maximum payload | Including its 9-byte header |
| --- | ---: | ---: | ---: |
| Construction markers | 32,768 | 65,536 bytes | 65,545 bytes |
| Pending transformations | 32,768 | 360,448 bytes | 360,457 bytes |
| Custom blocks (all formed roads) | 32,768 | 753,664 bytes | 753,673 bytes |

The conservative combined bound is `32,768 * (2 + 11 + 23) + 3 * 9 = 1,179,675` bytes,
about 1.125 MiB. It allows every section to reach its independent limit and does not assert
that every such combination is valid gameplay state. All existing semantic checks remain
required. Empty collections omit their sections, so entirely empty metadata is zero bytes.
These caps concern serialized data, not native array capacity or expected chunk usage;
never preallocate the maximum solely because it is permitted. For reference, the maximum
initial chunk-record bound is `58 + 32,768 + 1,179,675 = 1,212,501` bytes.

Use checked arithmetic and retain the u32 local-length/record framing constraints. Native
struct padding and allocated capacities do not determine serialized size. Validate
declared lengths/counts before allocating and require exact section consumption. Derive
version-specific byte bounds again when custom types or section schemas change; these
initial caps must not accidentally reject future supported schemas or optional extensions.

Existing allocators serve valid metadata within the allocation budget; allocation strategy
and budget do not change semantic limits. The trusted material-enum policy in R50 does not
waive these metadata structural checks.

