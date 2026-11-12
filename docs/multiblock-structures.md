# Multiblock structures

A multiblock structure (сооружение) gives a set of world cells a shared gameplay identity.
It can own state, protect members, reserve surrounding air, and replace member presentation.
[Warehouses](../specs/features/warehouses.md) specify explicit registration, with implementation
pending; [adaptive road slopes](country-roads.md) already demonstrate automatic recognition.
This vocabulary does not imply an existing general registry or require rewriting roads.

## Registration

| Policy | Trigger | Examples |
| --- | --- | --- |
| Automatic | A valid block pattern is recognized | Existing road slope; future workbench |
| Explicit | Player confirms a dialog after assembling valid blocks | Warehouse (specified) |

Each type defines its pattern and validation. Successful registration establishes identity,
members, type-specific state, and claims coherently. A later registration at the same location
must be distinguishable from the old one when delayed commands or responses arrive. Client
previews cannot publish authoritative claims; each type defines any temporary-preview policy.

Canonical storage is type-specific. Members, chunk references, and spatial indexes may point
to an object's state without duplicating writable inventory. A geometric origin need not be
a metadata owner. Warehouses specify [recognition](../specs/features/warehouses.md#q6--discovering-the-rectangle-and-choosing-the-layout-origin),
[simulation ownership](../specs/features/warehouses.md#q16--simulation-owned-warehouse-state-versus-pallet-owned-metadata),
and [confirmation](../specs/features/warehouses.md#q14--registration-checks-and-consistency).
Roads retain their section metadata; these concepts do not force all structures into one
storage format or scheduler.

## Members and reserved space

Query member ownership, reservations, movement collision, structural support, and presentation
separately. Reserved terrain can remain air while derived packed goods occupy it for movement.
Claims apply to every relevant mutation path, including observer/debug actions, simulation,
indirect changes, and planned construction. Registration must consider existing plans too.

Each pair of types needs an explicit overlap rule. A shared clearance cell may have several
owners; releasing one claim must preserve the others. A structure's bounding box may cover
ordinary terrain or another structure without its members/targets overlapping. Neither kind
of overlap can be decided from bounding-box intersection alone.

Warehouse [Q8](../specs/features/warehouses.md#q8--reservation-overlap-and-blueprint-composition)
settles shared aisles and composition with blueprint-empty cavities. It preserves independent
warehouse and active-site restrictions. Unregister releases only structure claims; ordinary
material dependencies, such as the pallet's required floor, still apply to surviving members.

Use bounded spatial lookup from members, claimed space, and derived-content hits. Claims must
remain discoverable after reload even if canonical owner state is not resident. Missing owner
data is unknown, not unclaimed air. Warehouse
[Q12](../specs/features/warehouses.md#q12--missing-warehouse-state-discovery-and-streaming-ownership)
selects chunk references for its envelope; that index does not prescribe every type's discovery
representation. Access points and routing are also type policies, defined for warehouses in
[Q15](../specs/features/warehouses.md#q15--courier-loading-and-unloading-points-wh-02).

## Deconstruction and busy state

| Policy | Member edit behavior |
| --- | --- |
| Explicit unregister first | Reject changes until management releases the structure under its lifecycle rules |
| Pattern-breaking removal | Allow a legal edit; revoke registration if the remaining pattern is invalid |

Warehouses require explicit unregister; road slopes revert to surviving ordinary sections
after member/endpoint removal. Neither policy replaces ordinary material/support checks.
A type may reject deconstruction while busy even if it normally permits pattern-breaking
removal, as proposed for an operating workbench.

Busy state, stopping, unregistering, and deleting blocks are separate concerns. The
[simulation lifecycle](simulation-notes.md#stopping-is-separate-from-dismantling) closes stopped
objects to new work while preserving accepted obligations. Each type defines its inventory
and dismantling conditions; zero visible stock alone does not prove no work is outstanding.
Warehouse [Q4](../specs/features/warehouses.md#q4--empty-is-not-obligation-free-wh-04) is its
normative lifecycle, and [Q11](../specs/features/warehouses.md#q11--expansion) defines the
current unregister/rebuild workflow for footprint changes.

## Presentation

Registration may replace members' appearance: a plank pattern becomes a workbench model,
or road cells become a slope. Unregister restores surviving members' ordinary view. Avoid
rendering both replacement geometry and suppressed members. Appearance alone grants neither
collision nor support. Warehouse contents use reusable [packed blocks](packed-blocks.md).

Block and mesh consumers need relevant discovery/object state independently of terrain faces.
Derived geometry needs a clear owner and lifetime through handoffs, eviction, and late replies.
Visual omission, logical unknown-data handling, and functional retention are separate policies;
warehouse [Q12](../specs/features/warehouses.md#q12--missing-warehouse-state-discovery-and-streaming-ownership)
and [Q24](../specs/features/warehouses.md#q24--warehouse-object-subscriptions-and-client-retention)
specify them for storage. A distant visual allowance cannot silently weaken nearby collision,
authoritative claims, or resource accounting.

## Persistence and bounded work

Capture registered state coherently with members, inventory, and accepted obligations. Restore
sufficient discovery before conflicting edits; rebuild disposable render/collision indexes
from canonical records. Use the development save-version policy without requiring historical
gameplay modes or per-operation disk flushes.

Work should follow relevant changes. Local edits must not scan every structure, and unchanged
warehouses need no per-tick footprint validation. Automatic recognition may use bounded/deferred
processing, as roads already do. Persist deferred authoritative obligations when needed;
client-only render dirtiness is reconstructible.

Start with the shared identity, lookup, guards, and rendering boundaries concrete types need.
A general framework requires demonstrated benefit, not merely two examples.
