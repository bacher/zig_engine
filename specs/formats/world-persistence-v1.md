# World persistence v1 format contract

This is the normative format reference for the
[world-persistence feature spec](../features/world-persistence.md). It contains the existing
binary layouts, encoding rules, compatibility policy, checksums, and metadata bounds,
extracted without changing the format. All R/Q identifiers refer to that feature spec;
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

For example, adding a material in format 2 can leave the minimum at 1: the updated engine
reads versions 1 and 2 but writes version 2. An engine supporting only version 1 rejects
version 2 before interpreting any chunk bytes. An incompatible change in version 3 without
legacy decoding sets the minimum to 3. A version bump alone does not implement compatibility:
when layout/defaults change, retain the required old decoding logic or raise the minimum.

Initially perform no material-enum membership checks, either per raw cell or per RLE run.
Retain file/record checksums and structural bounds, and reject unsupported codec IDs at the
per-record dispatch point. Once version/integrity checks succeed and decoding yields exactly
32,768 bytes, reinterpret the owned buffer directly as `[32][32][32]BlockType` in x-fast order.
For standard RLE, expand material bytes and initialize omitted trailing air without first
converting each run's material to an enum. Validate custom metadata using byte-level custom
markers before publishing the typed chunk. Temporary decoding buffers do not change the
enum-based runtime representation.

Verify the assumed one-byte `BlockType` layout and array size at compile time, and preserve
required alignment and buffer ownership/lifetime. A cast must not leave the live chunk pointing
into recycled I/O scratch storage. The accepted trust assumption is that a compatible writer
emitted valid values and verified bytes retain them. Version/checksum checks do not logically
establish membership in the exhaustive enum. Invalid values from a writer bug, an incorrect
compatibility declaration, or a file with matching recomputed checksums can still produce
undefined behavior; safe handling of that case is explicitly not guaranteed in v1.

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
are required semantic data and must be recognized; the material-enum trust policy does not
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
metadata in both modes; no separate full-block material-ID scan is required.

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

The initial save-format version is 1, with engine current-write/minimum-readable versions
both initially 1. All integer fields are explicitly sized and little-endian; f32/f64 use
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
| Generator ID | u16; 0 flat, 1 terrain |
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
Do not substitute runtime defaults for saved values. Changes to generator behavior that
alter generated terrain require advancing the generator implementation version and retaining
compatible generation or an explicit migration under Q1.

Terrain generator version 1 settings are exactly 39 bytes, in this order:

| Field | Encoding |
| --- | --- |
| noise_scale | f64 |
| octaves | u8 |
| lacunarity | f64 |
| persistence | f64 |
| base_height_present | u8; 0 automatic, 1 explicit |
| base_height | u32; zero when automatic |
| height_amplitude | f64 |
| dirt_depth | u8 |

Preserve the automatic-height choice rather than substituting today's explicit default.
Validate settings with the supported generator's parameter/layout rules. Flat generation
uses seed zero and an empty settings payload. Terrain descriptors therefore occupy 80 bytes,
and flat descriptors 41 bytes, for these initial schemas.

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

Empty-inventory records occupy 52 bytes. Initially inventory schema and length are both
zero; inventory contents await a future supported schema. Reject unsupported schemas and
nonfinite coordinates/angles. Restore feet position/view under R17's motion-reset and
authoritative collision-validation rules. The record has no individual checksum: its
container's physical checksum or transaction digest covers it.

Persist all known players, including offline players, sorted by unique player ID. A
simultaneous-player target does not limit historical records. Each WAL transaction
contains complete global state and the complete player array, plus only changed chunks.
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

Each transaction consists of header, complete global state, complete player array, changed
chunk records, and commit footer. The transaction header is exactly 84 bytes:

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
Parse the declared global/player sections and exactly the declared number of length-framed
chunk records before expecting a footer; never search payload bytes for magic markers.
Reject duplicate chunk IDs within a transaction. Chunk records use the identical base/WAL
representation already defined; WAL chunk ordering need not match the sorted base order.

The footer's size must equal bytes consumed from the transaction start through its digest,
and its repeated sequence must match the header. Validate all framing, predecessor links,
checksums, and payload semantics before accepting a recoverable snapshot. A marker alone
does not establish a commit. Writer success still requires synchronization before
acknowledgment; partial writes and failure repair remain governed by R23/R30/R55.

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

Transaction coverage includes its header, global state, full player records, chunk records
with their checksums, and the commit footer's marker, total length, and repeated sequence.
Only its final digest is excluded. The included segment header binds world, segment, format,
and segment predecessor; the transaction header binds the immediately previous committed
sequence/digest. Verify the segment header independently before using it in this input.
The base physical checksum includes the finalized header, incorporated logical digest,
descriptor, global state, index, and all player/chunk records with their record checksums.

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
| Pending transformations | Cell index u16, transformation kind u8, deadline tick u64 | 11 bytes |
| Custom blocks: unformed adaptive road | Custom type u8, road state u8 | 2 bytes |
| Custom blocks: formed adaptive road | Custom type u8, road state u8, high endpoint [3]u32, downhill direction u8, formation length u32, section index u32 | 23 bytes |

Construction and timer payloads contain no additional entry count: divide the section length
by 2 or 11 respectively, rejecting a remainder or count above 32,768 before allocation.
Cell indices use x-fast order and must be below 32,768 despite their u16 storage width.
Transformation kinds are explicitly 0 compact_dirt and 1 grow_grass; reject unknown kinds.

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

