# Multiblock structures

A multiblock structure (сооружение) gives a set of world cells a shared gameplay identity.
It can own state, protect members, reserve surrounding air, and replace member presentation.
[Warehouses](../specs/features/warehouses.md) specify explicit registration, with implementation pending;
[adaptive road slopes](country-roads.md) already demonstrate automatic pattern recognition.
This vocabulary does not imply an existing general registry or require rewriting roads.

## Registration

| Policy | Trigger | Examples |
| --- | --- | --- |
| Automatic | A valid block pattern is recognized | Existing road slope; future workbench |
| Explicit | Player confirms a dialog after assembling valid blocks | Warehouse (specified) |

Each type defines its pattern and registration checks. Successful registration establishes
identity, members, type-specific metadata, and any claims coherently. Client previews can be
stale and cannot publish authoritative claims. A later registration at the same coordinates
must be distinguishable from the old one when delayed commands or responses arrive.

For warehouses, opening creation performs an advisory check without reserving space or
locking pallets. Confirmation repeats the current validity/compatibility checks and publishes
registration with its reservation together; failure reports its cause without partial state.
Canceling an unsubmitted preview has no spatial claim to release. The
[registration decision](../specs/features/warehouses.md#q14--registration-checks-and-consistency)
allows otherwise legal world changes during material selection rather than introducing
temporary preview claims. Other structure types define their own preview policies.

Canonical storage is type-specific. The warehouse
[authority decision](../specs/features/warehouses.md#q16--simulation-owned-warehouse-state-versus-pallet-owned-metadata)
uses a persistent simulation object addressed by WarehouseId for inventory, incoming
promises, capacity settings, geometry, and lifecycle. World-data owns terrain members and
derived spatial/claim indexes. A fixed central cell coordinate serves as the layout origin
for relative bounds and hashing; no pallet holds authoritative stock. Its
[recognition rules](../specs/features/warehouses.md#q6--discovering-the-rectangle-and-choosing-the-layout-origin)
use the entire face-connected coplanar component. Even axes choose the lower central
coordinate, while hash bits independently choose the first cargo column among central cells.

The current [warehouse size-change workflow](../specs/features/warehouses.md#q11--expansion)
requires stopped, empty, obligation-free unregister, ordinary rebuilding, and new registration.
The new object has a new identity and central origin even when it reuses the same coordinates.
Future in-place expansion preserving the origin is deferred. A road keeps its existing section
metadata; these concepts do not force all structure types into one storage format or scheduler.

## Members and reserved space

A structure may lock member edits and reserve additional air. Reserved terrain can remain
air while derived packed goods occupy it for movement collision. Query member ownership,
reservation, collision, support, and presentation separately.

Claims must apply to all relevant mutation paths, including observer/debug operations,
simulation, indirect changes, and new blueprint targets. Registration must also consider
existing planned targets. Type-specific rules decide whether empty clearance can be shared
or overlap another structure's bounding box.

[Warehouse Q8](../specs/features/warehouses.md#q8--reservation-overlap-and-blueprint-composition)
allows a shared one-cell aisle, including diagonal clearance overlap. Only the air-clearance
regions may overlap: each warehouse's members and full potential cargo volume remain outside
the other's reserved envelope, even with zero stock or disabled columns. Shared cells stay
protected while any owner remains registered; unregister releases only that owner's claim.
Spatial lookup/recovery must retain the other owners across object/terrain unloading and save/load.
This permits compact layouts without merging warehouse inventories or lifecycles.

Warehouse [courier access](../specs/features/warehouses.md#q15--courier-loading-and-unloading-points-wh-02)
uses side-adjacent cells of the base-level halo as potential endpoints, excluding its
diagonal-only corners. Ordinary traversability decides whether a candidate is usable:
reserved air alone proves neither footing nor a route. These endpoints add no exclusive
dock claim or congestion rule to a shared aisle. Registration does not require a route,
and stock/active-column changes do not change the footprint-derived candidate set.

The same [warehouse Q8](../specs/features/warehouses.md#q8--reservation-overlap-and-blueprint-composition)
allows a warehouse within an unfinished blueprint's empty cavity in either admission order.
Only the boxes may overlap: no nonempty blueprint target may intersect the warehouse's full
member/cargo/clearance envelope, including disabled columns and currently empty cargo slots.
Pallets need an already-real floor. Simulation inventory transfers remain available under warehouse
rules, while ordinary terrain extraction inside the active blueprint box remains forbidden
even after warehouse unregister. Blueprint completion and warehouse unregister each release
only their own restrictions. This does not permit overlapping boxes of two active blueprints
or establish compatibility between other unreviewed structure pairs.

Member material rules also survive unregister. For example,
[pallets require direct support below](../specs/features/warehouses.md#q7--pallet-support-and-the-floor)
both before and after warehouse registration, supply no construction support themselves,
and prevent loss of their necessary floor for as long as they remain. Releasing a structure's
spatial claims does not erase these ordinary material dependencies.

Locate structures from members, claimed space, and derived-content hits through bounded
spatial lookup. Member/chunk references and indexes can point to canonical state without
duplicating writable inventories. Authority must discover claims after reload even when
the authoritative owner state is not currently resident. Missing data is unknown rather than unclaimed air.

For warehouses, [Q12](../specs/features/warehouses.md#q12--missing-warehouse-state-discovery-and-streaming-ownership)
selects a WarehouseId/registration/bounds entry in every chunk intersecting the full reserved
envelope, including chunks with only halo or upper potential cargo cells. One warehouse
needs at most eight entries. These references contain no stock or active-count copies, change with
register/unregister, and remain unchanged on ordinary stock or settings updates. Restore
sufficient discovery state before dependent edits after load; removing one registration
must preserve other owners of shared clearance. Exact encoding and persistence/rebuild
mechanics remain implementation choices. This warehouse index does not prescribe every
structure type's discovery representation.

## Deconstruction and busy state

| Policy | Member edit behavior |
| --- | --- |
| Explicit unregister first | Reject changes until management releases the structure under its lifecycle rules |
| Pattern-breaking removal | Allow a legal edit; revoke registration if the remaining pattern is invalid |

Warehouses require explicit unregister; road slopes revert to surviving ordinary road
sections after a member/endpoint removal. Neither policy replaces ordinary material/support
checks. A type may temporarily reject deconstruction while busy even if it normally permits
pattern-breaking removal, as proposed for an operating workbench.

Busy state, stopping, unregistering, and deleting blocks are separate concerns. Existing
[simulation lifecycle rules](simulation-notes.md#stopping-is-separate-from-dismantling) close
a stopped object to new work, preserve accepted obligations, and leave it inactive afterward.
The confirmed [warehouse lifecycle](../specs/features/warehouses.md#q4--empty-is-not-obligation-free-wh-04)
provides Stop/Enable separately from unregister. Stop blocks new automatic work involving
the warehouse while accepted incoming/outgoing deliveries finish; manual take remains
available. Unregister and material change require stopped, empty, obligation-free storage.
Material change retains registration and stopped status. Completion never automatically
enables or unregisters it. Zero visible stock alone does not prove an object has no incoming
delivery or accepted work. Other structure types define their own stock/deconstruction rules.

## Presentation

Registration may replace the members' appearance: a plank pattern becomes a workbench model,
or road cells become a slope. Unregistering restores the surviving members' ordinary view.
Prevent replacement geometry and suppressed member geometry from rendering twice. Collision
and support follow separate explicit policies; appearance alone grants neither.

Warehouse members remain pallets and its contents use [packed blocks](packed-blocks.md).
Both full-block and mesh subscriptions expose discovery references, and object snapshots
provide the required warehouse state. Object-only changes matter even when ordinary terrain faces are unchanged. One owner and
subscription lifetime must control derived geometry through handoffs, eviction, and late replies.

The warehouse's accepted distant omission when its object snapshot is absent is a type-specific
visual allowance. It does not establish a general omission policy for other structures,
authoritative claims, stock accounting, or nearby movement collision.
Nearby warehouse queries request current warehouse object state; until it arrives, possible cargo
cells are unknown and cannot be crossed or edited as empty terrain. Known halo clearance
remains traversable subject to ordinary collision checks, while its placement claim stays
active. Several chunk references still resolve to one cargo presentation owner through
handoffs and eviction; references alone do not supply stock or duplicate geometry. The
terrain chunk containing the layout origin need not be loaded to resolve the object.

## Persistence and bounded work

Capture registered state coherently with members, inventory, and relevant accepted obligations.
Restore sufficient discovery state before allowing conflicting edits; rebuild disposable
render/collision indexes from canonical records. Use the existing development save-version
policy instead of adding historical gameplay modes or per-operation disk flushes.

Work should follow changes that can affect the structure. Ordinary local edits must not scan
every structure; unchanged warehouses need no per-tick footprint validation. Automatic
recognition can have its own bounded/deferred processing, as roads already do. Persist deferred
authoritative obligations when necessary; client-only render dirtiness is reconstructible.

Start with the shared identity, lookup, guards, and rendering boundaries concrete types need.
More general frameworks require a demonstrated benefit, not only the existence of two examples.
