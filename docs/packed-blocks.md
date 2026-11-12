# Packed blocks

A packed block is one material unit represented as cargo. Its appearance and interaction
semantics can be reused by [warehouses](../specs/features/warehouses.md), workstation input
buffers, output buffers, and other storage owners. This note defines the shared concept,
not an implemented feature. Warehouses have selected count-only inventory with repacking
and an explicit active-column capacity/layout policy in the specification.

## Ownership

Cargo belongs to its owning structure's authoritative state. Warehouse Q16 places that
state in a persistent simulation object rather than a pallet's metadata. Displayed cubes
are derived views of that inventory, not additional terrain blocks or independently writable items. Taking or
putting transfers the material between owners coherently; packaging adds no resource and
ordinary terrain-mining conversions do not apply to taking the stored material.

An owner supplies its layout and interaction policy. The renderer should accept material and
placement without depending on warehouse bounds, rank order, active capacity, or dialogs.
The shared concept does not mandate any particular inventory format for all owners.
Warehouse Q1 selects one aggregate count, owned by simulation under
[Q16](../specs/features/warehouses.md#q16--simulation-owned-warehouse-state-versus-pallet-owned-metadata).
It derives placement from bounds, count, active-column configuration, and Q5's central-column selectors and direction hashed from
the fixed layout origin's chunk-local coordinates, without authoritative column heights or
item-position history. The first filling column may differ from the layout origin on
even-sized bases. Warehouse order fills inner layers before outer ones and leaves remaining
corners last; for 4×4, the inner 2×2 fills to height four before any perimeter column.
These choices belong to the warehouse's layout policy, not the shared packed-block renderer.
Other owners may choose their own compact state while reusing packed-block presentation.

Warehouse [Q2](../specs/features/warehouses.md#q2--what-does-active-capacity-restrict)
allows 0..N active columns. Fill active columns first using four levels per column, then
the fifth/sixth levels; apply the same pattern to disabled columns for remaining stock.
Taking from the end drains disabled stock first. Reconfiguration can relocate goods without
changing quantity; earlier accepted deliveries retain room in the full physical footprint.
New incoming work and unreserved additions must fit within active capacity, including
outstanding promises. These rules belong to the warehouse, not the reusable packed renderer.

The initial warehouse cargo list is explicitly limited to eleven materials, including pallets, in
[Q10](../specs/features/warehouses.md#q10--allowed-materials-and-pallet-selection).
Water is excluded while liquid mechanics remain undecided; this concept does not define
liquid containers or assume that all resources can be packed as solid cubes. Cargo eligibility
is separate from terrain placeability and from the pallet's floor-support requirements.
Future cargo-only resources can receive explicit eligibility when their item rules are defined.

## Appearance

Render a material cube with pallet texture along the bottom of all side faces and on the
bottom face, plus binding straps on each side. Preserve the recognizable resource texture
between these marks: packaging covers limited surface regions, with transparent gaps revealing
the material below it. The resource remains opaque; those gaps do not reveal the world behind
the cube. A generic opaque crate that hides the material would not satisfy this appearance.
The same material-plus-packaging appearance is reusable across owners. A coverage-mask blend
within an opaque shader is a suitable implementation approach, without prescribing a shader
API or requiring transparent-object sorting. Keep geometry in its original unit cell so
stacked items have unit spacing. A packed block's packaging is distinct from a loose pallet,
which is a low plank model with no movement collision. Under the confirmed
[pallet support rule](../specs/features/warehouses.md#q7--pallet-support-and-the-floor),
each loose/member pallet needs an eligible real block immediately below, but supplies no
construction support itself. Its required floor cannot be removed while the pallet remains,
even after unregistering the warehouse; a 3×3×3 platform is not required. The confirmed floor
allowlist includes existing structural materials and solid country road; sand, water, snow,
leaves, adaptive roads in either shape, other pallets, and packed goods do not qualify.
The exact terrain IDs are listed in Q7. These floor rules apply to the terrain pallet,
not to the packaging artwork on each stacked cargo item.

Warehouse material icons and disabled crosses belong only to empty base pallets. A column
containing cargo emits no such marker; after it empties, the appropriate base marker returns.
Do not repeat markers on packed goods or upper layers. This warehouse-specific marker policy
uses the same presentation snapshot as its cargo and is separate from shared packaging.

An unregistered terrain pallet can be recovered as one carried item in three seconds and
reinstalled in one second, under ordinary placement/support rules. Registered member pallets
require explicit warehouse unregister first. These terrain actions use ordinary timings;
the fast packed-cargo transfer duration does not apply to them. Pallet crafting remains
unavailable. Pallet items can themselves be warehouse cargo: each uses one unit of stock
and a full packed-cube slot with movement collision and no construction support. Put/take
takes about 100 ms and returns/transfers one ordinary pallet item; packaging artwork does
not create another pallet. Stored pallets are derived cargo, not terrain or structure members.

Use scene depth, materials, lighting, directional shadows, and post-processing. Share geometry
or shader functions with other cargo owners, batch visible instances, and preserve chunk-relative
coordinate precision. No requirement calls for one ordinary scene object per item. A draw after
terrain remains part of world rendering; the camera-space held-item/GUI overlay is unsuitable.

## Collision, support, and interaction

| Property | Contract |
| --- | --- |
| Terrain contents | Cargo need not exist in the terrain material array |
| Movement collision | Occupied full unit cell regardless of the packed material's usual shape |
| Structural support | None, including road/platform and cheap blueprint support |
| Stacking | Permitted by the owner's layout, independently of ordinary support rules |
| Target identity | Inventory/structure owner plus any local hit information needed for UX |
| Put/take | Fast and material-independent; warehouse player interaction takes about 100 ms |
| Resource effect | One coherent transfer; no packaging item, mining conversion, or duplicate stock |

No construction support does not mean no collision. Placement must also respect occupied
cargo and any owner reservations. Reserved empty space is an owner's policy, not an intrinsic
clearance halo around every packed cube. Standing on goods is compatible with their lack of
construction support: movement and structural validation are different consumers.

A ray can hit a particular packed cube while the operation addresses only its owner. Whether
that cube disappears or another item is removed follows the owner's policy. The generic
renderer must not implement warehouse removal order or capacity admission.

For the confirmed warehouse player controls, Mouse2 on cargo opens its owner's management
dialog; Mouse1/E takes with empty hands or puts the matching carried item. A different held
material is rejected without consuming it. Each transfer takes about 100 ms and requires
a fresh press; no automatic take/put loop follows an inventory change. Reach is measured
to the nearest vertex of the aimed pallet/item's full unit cell, not the layout origin or changed
layout slot. Pallets use one low 1×1×0.2 target box; packed cargo uses the full unit cube.
Rays above an empty pallet continue, and decorative gaps between its planks do not split
its target box. Targeting does not change the pallet's lack of movement collision. These
are warehouse interaction rules, not mandatory bindings for every packed-block owner.

Warehouse observer controls perform instant one-unit creative stock additions/removals
without touching player inventory. An addition uses the observer's selected material and
must match the warehouse material; mismatches share the player-mode error. The warehouse
does not choose a material on the observer's behalf. These edits retain stock/admission
guards and member protection; creative source/sink semantics do not change cargo ownership.

## Updates and performance

The authoritative inventory, client prediction/collision, and GPU sources have different
lifetimes. Publish coherent logical state; derive geometry only for relevant observed owners
and reuse unchanged sources. An analytic column/slot query may avoid constructing render
geometry for collision. Compare compact GPU owner records with cached item instances using
measurements; do not expand unobserved storage into per-item scene objects by default.

The warehouse player duration does not add a 100 ms delay to simulation processing. Allow
batched stock mutations and publication while preserving each transfer's resource meaning.
The confirmed warehouse policy prepares visuals on change without an intentional refresh
interval or quiet-period delay. Several changes before preparation may produce one latest
coherent image; all accepted transfers still retain their accounting effects. Normally the
updated appearance reaches the next available frame; under load preparation may span frames
without blocking simulation. There is no hard one-frame freshness guarantee. Stock, current
client collision/targeting, and recovery do not wait for GPU work, and markers agree with the
same visual snapshot as cargo. Reuse unchanged sources and retain revision/lifetime checks
for delayed work. Per-frame budgets and renderer representation require implementation
measurement; the 100 ms player action duration is not a visual refresh rate.

For warehouses, repacking, valid manual puts, and accepted delivery arrivals displace the
player into known free full-body space if their resulting goods overlap the player. Overlap
alone does not reject the manual put or delay delivery. Apply the resource transfer normally;
recovery adds no resource changes and does not alter the deterministic layout. It queries
current terrain and derived cargo occupancy without waiting for visual uploads, and simulation
does not wait for client recovery. Search only on actual intersection, without global actor
scans. [Warehouse Q26](../specs/features/warehouses.md#q26--reserved-halo-displacement-fallback)
selects the reserved base-level halo as fallback when ordinary recovery fails. Prefer a known
clear full-body position in loaded data; otherwise acquire bounded nearby dependencies while
movement remains blocked and simulation continues. The clearance guarantee is not a supporting
floor requirement: ordinary gravity resumes after recovery. Missing data cannot establish a
free destination. Rare column-disable changes need no specialized optimization.
Other packed-block owners, partial/perishable cargo, transport visuals, and unpacking into
construction still require their own policies.
