# Packed blocks

A packed block is one material unit represented as cargo. Warehouses, workstation input and
output buffers, and other storage owners can reuse its appearance and interaction semantics.
This document defines the shared concept; implementation is pending. The
[warehouse specification](../specs/features/warehouses.md) owns warehouse-specific rules.

## Ownership

Cargo belongs to its owner's authoritative state. Displayed cubes are derived views, not
additional terrain blocks or independently writable items. Taking or putting transfers the
material coherently; packaging adds no resource and ordinary terrain-mining conversions do
not apply to taking a stored item.

An owner supplies its layout, cargo eligibility, capacity, lifecycle, and interaction policy.
The shared concept does not mandate one inventory format for every owner. Rendering accepts
material and placement without depending on warehouse bounds, ordering, or dialogs. Warehouse
[Q16](../specs/features/warehouses.md#q16--simulation-owned-warehouse-state-versus-pallet-owned-metadata)
selects a persistent simulation object; [Q1/Q2](../specs/features/warehouses.md#q1--one-count-versus-priority-draining)
define its count-only inventory and repacking policy.

Capture and serialization consumers must distinguish cargo from terrain: movement collision
alone does not make a packed item a capturable building block. The warehouse
[capture boundary](../specs/features/warehouses.md#blueprint-capture-boundary) preserves the
blueprint material view and excludes derived cargo and inventory.

## Appearance

Render a material cube with pallet artwork along the bottom of all side faces and on the
bottom face, plus binding straps on each side. Keep the resource recognizable between those
marks. Transparent gaps in the packaging reveal the opaque material, not the world behind
it; a generic opaque crate hiding its contents does not satisfy this contract.

A coverage-mask blend in an opaque shader is a suitable approach without requiring a
particular shader API or transparent-object sorting. Keep the geometry in its original unit
cell for unit-spaced stacking. Packaging is distinct from a loose terrain pallet: it creates
no separate item, structure membership, or support dependency. Warehouse
[pallet rules](../specs/features/warehouses.md#q7--pallet-support-and-the-floor) and
[empty-base markers](../specs/features/warehouses.md#q13--markers-packaging-and-visual-freshness)
belong to that feature.

Use scene depth, materials, lighting, directional shadows, and post-processing. Share geometry
or shader functions across cargo owners, batch visible instances, and preserve chunk-relative
coordinate precision. Drawing after terrain is a world-geometry path, not the held-item/GUI
overlay. One ordinary scene object per item is not required.

## Collision, support, and interaction

| Property | Shared contract |
| --- | --- |
| Terrain contents | Cargo need not exist in the terrain material array |
| Movement collision | Occupied full unit cell regardless of the material's ordinary shape |
| Structural support | None, including road/platform and cheap blueprint support |
| Stacking | Permitted by the owner's layout independently of ordinary support rules |
| Target identity | Inventory/structure owner plus local hit information needed for UX |
| Put/take | Fast and material-independent; exact controls/timing belong to the owner |
| Resource effect | One coherent transfer; no packaging item, mining conversion, or duplicate stock |

Standing on goods is compatible with their lack of construction support: movement and
structural validation are separate consumers. Placement still respects occupied cargo and
owner reservations. An empty clearance halo is an owner's policy, not an intrinsic property
of every packed cube.

A ray can hit one cube while the operation addresses its owner and removes another slot.
The owner decides that order. The reusable renderer must not implement warehouse admission,
removal order, observer behavior, or input bindings; those are defined in warehouse
[Q9](../specs/features/warehouses.md#q9--targeting-reach-dialogs-and-actor-overlap).

## Updates and performance

Authoritative inventory, client prediction/collision, and GPU sources have different lifetimes.
Publish coherent logical state and derive geometry only for relevant observed owners. Reuse
unchanged sources; an analytic slot query may avoid constructing render geometry for collision.
Compare compact owner records with cached instances through measurements before choosing a
renderer. Do not expand unobserved storage into per-item scene objects by default.

Player transfer duration adds no corresponding delay to simulation processing. Batched
mutations/publication must retain every accepted resource effect. Logical collision and actor
recovery cannot wait for GPU uploads, and delayed work needs revision/lifetime checks. Owners
must define how rearrangement affects overlapping actors. Warehouse
[Q13](../specs/features/warehouses.md#q13--markers-packaging-and-visual-freshness) fixes its
change-driven presentation contract and
[Q26](../specs/features/warehouses.md#q26--reserved-halo-displacement-fallback) fixes its
bounded recovery fallback. Other owners, partial/perishable cargo, transport visuals, and
unpacking into construction still require their own policies.
