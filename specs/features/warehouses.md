---
service: zig_engine
created: 2026-11-11
status: approved
---

# Add pallet warehouses

## Intent

Let players assemble a rectangular pallet base, register it for one material, and quickly
transfer packed blocks into and out of shared storage. Keep stock in a
persistent simulation object; derive presentation and collision without filling terrain
with cargo voxels.

Define warehouse capacity, delivery promises, lifecycle, spatial protection, and courier
access while keeping packed-block rendering and multiblock-structure concepts reusable.
Q1–Q18 record the agreed behavior, inventory authorities, and live-commit/save baseline.
Q19 selects target-only construction ownership for further design in a separate spec.
Q22 selects separate state domains on the existing service executor for the first warehouse
implementation. Q23 fixes live-session command retries and resynchronization after a session
change. Q24 selects independent object subscriptions with complete snapshots. Q20–Q21
discuss accounting tradeoffs and soil transformations; Q25 records incremental publication
as a deferred follow-up for evaluation. Q26 selects reserved-halo displacement recovery.
Concrete implementation and performance measurements remain separate work.

Q16 makes the warehouse a persistent simulation object addressed by WarehouseId. The
central layout origin remains a coordinate for bounds and hashing; no pallet owns stock.
Chunk discovery entries reference the object, and terrain residency does not determine
its lifetime. Q17 retains player inventory in world-data service; Q18 accepts coordinated
live transfers and shared save capture without per-item disk synchronization.

## Context

This specification records decisions agreed on 2026-11-11/12. The implementation context
below was checked against `main` at `d5d95d9`; runtime implementation is separate work.

- [Design principles](../../DESIGN_PRINCIPLES.md) prioritize whole-world simulation
  throughput, coherent resource ownership, simulation precedence over conflicting player
  edits, bounded local work, and explicit discussion of gameplay simplifications.
- [Voxel world](../../docs/voxel-world.md) separates authoritative world data, predicted
  client state, and GPU geometry. Block and mesh subscriptions already support custom draws.
- [Country roads](../../docs/country-roads.md) demonstrate pattern recognition, saved
  metadata, shape-aware collision, and instanced geometry outside ordinary terrain meshes.
  They do not yet supply a general structure registry or warehouse stock protocol.
- [Construction rules](../../docs/block-placement.md), [blueprints](blueprints.md), and
  [monotone additions](monotone-block-additions.md) distinguish physical terrain and planned
  blocks. Warehouse reservations add occupancy constraints; packed stock must supply no
  support, including the cheap five-neighbor blueprint fulfillment predicate.
- [Rendering](../../docs/rendering.md) and [construction visuals](incremental-construction-visuals.md)
  favor reusable sources and batched drawing. Logical state and delayed GPU geometry have
  separate responsibilities; presentation cannot authorize resource changes.
- [Simulation notes](../../docs/simulation-notes.md) require accepted deliveries to retain
  cargo and complete after an object stops. [WH-01 through WH-05](../../docs/simulation-open-questions.md#warehouse-contracts-and-logistics-follow-ups)
  track capacity, inventory, demand, lifecycle, and perishability. This spec resolves the
  warehouse contracts; full logistics allocation and perishable goods remain separate work.
- [Persistence](../../docs/persistence.md) requires coherent world/inventory capture and
  permits rejection of incompatible development saves without migrations.
- [Game vision](../../docs/game-vision.md#warehouses-and-material-orders) describes storage's
  role in the automated economy. This pallet-based design replaces the earlier exploratory
  room/roof/accounting-block concept.
- Separate design notes define [packed blocks](../../docs/packed-blocks.md) and
  [multiblock structures](../../docs/multiblock-structures.md). They describe specified
  contracts, not existing implementation.

## Requirements

### Pallets and creation

- R1: Add a pallet block to observer-mode material selection. Pallet crafting is not
  available in this iteration. Key 9 selects pallets while keys 1–8 retain their current
  assignments. A general observer material-selection menu is deferred under Q10.
- R2: A pallet occupies a terrain cell and renders as planks roughly one-fifth of a block
  high, at the bottom of that cell. It is targetable through R43's low box but has no
  movement collision.
  Placing a pallet directly on another pallet is forbidden. Every pallet needs an eligible
  real block directly below and supplies no construction support under R37/Q7, which
  specifies the confirmed floor-material allowlist.
- R3: A warehouse base consists of a filled, coplanar X/Y rectangle of pallets, with each
  dimension in 1..5: 1..25 cells. All rotated variants are valid. Reject holes and
  nonrectangular/oversized arrangements. Discover the whole face-connected coplanar pallet
  component containing the clicked pallet; never select a valid subrectangle from an invalid
  component. Stop discovery with failure when either dimension exceeds five or a 26th pallet
  is found. Check floor support and clearance separately after recognizing the base (Q6).
- R4: With inclusive base bounds xmin..xmax, ymin..ymax at z0, the clearance envelope is
  `[xmin-1..xmax+1] × [ymin-1..ymax+1] × [z0..z0+5]`. Only base pallets may occupy terrain
  in that envelope. This includes the bottom-level border and diagonal neighbors: a 3×3
  base requires 5×5×6, and a 5×5 base requires 7×7×6. Also check the supporting cell
  directly below each pallet under R37; it lies outside this clearance envelope.
- R5: Mouse2 on any candidate pallet within four blocks validates the arrangement and
  opens an in-game material chooser when valid. Confirming the material registers the
  warehouse. Canceling leaves ordinary pallets. R40/R41 define controls and the reach
  reference, R42 defines live modal behavior, and R43 defines hit geometry and distance.
- R6: Registration must establish current valid members, clearance, material, and absence
  of conflicting claims before publishing the warehouse and its reservation together.
  A stale dialog cannot overwrite newer world changes or create a partial registration.
  R50/Q14 require current coherent confirmation and no temporary dialog reservation.
  R62 defines the initial stock, capacity, and automatic-work state.
- R7: An unoccupied active base pallet displays a square selected-material icon centered
  on its top, approximately one-third of its width. An unoccupied disabled base pallet
  displays a red cross instead. Emit neither marker while its column contains cargo;
  other empty pallets of the same partly filled warehouse retain their markers. Markers
  appear only on real base pallets, never on packed items or upper levels. Derive marker
  occupancy and cargo geometry from the same presentation snapshot (Q13).

### Inventory and layout

- R8: A persistent simulation object identified by WarehouseId owns the warehouse's
  selected material, aggregate stock C, incoming reserved quantity I, active count A,
  enabled/stopped intent, geometry, and warehouse lifecycle bookkeeping (Q16). Identity
  distinguishes registration lifetimes even at reused coordinates. Choose the central
  cell coordinate of the original base as a fixed layout origin, independently of the
  clicked pallet; use the lower-coordinate central cell on each even-length axis in the
  locally unwrapped footprint. Store inclusive base bounds relative to this origin,
  e.g. x1=-2, x2=2, y1=-1, y2=1 for an initial 5×3 base. No member pallet stores or owns
  stock. Derived indexes and client/render state are not independently writable inventories.
  Q1 keeps one count without authoritative column heights, item positions, or layout
  history. The origin is fixed for this registration; future in-place expansion retains
  it, while this iteration changes the footprint by unregister/new registration under Q11.
- R9: Cargo does not replace terrain. Base cells remain pallets and other cells remain
  air. The warehouse object reconstructs the whole footprint even if member chunks,
  including the chunk containing the layout origin, are absent.
- R10: Client and authority share a deterministic layout contract. Choose the filling
  center from the current footprint's central candidates using the fixed origin's hash
  (R39/Q5). It may differ from the layout origin even at initial registration. Future
  expansion may move the filling center while preserving the origin and hash selectors.
  Start with four blocks in the central column, then four in each successive column.
  The lowest item occupies z0, the pallet's cell. After these four levels fill, fill level
  five across columns, then level six, using the same column order when all columns are
  active. Derive occupied cells from bounds, stock count, active-column configuration,
  and the fixed origin's coordinate-derived center selectors and direction (R38/R39),
  without previous layout state. Configuration changes may repack existing goods under Q1.
  Q5 defines the full column order; R54/Q2 defines active-before-disabled slot placement.
- R11: Prefer a center-out order with actual outer corners late, so remaining space can
  be seen from different sides. Complete inner footprint layers before outer ones; a 4×4
  base always fills all four inner 2×2 columns to height four before starting any perimeter
  column, regardless of hash selectors. Within a layer use the hashed ordering and defer
  corners under Q5. The author's 5×5 reference is:

  ```text
  24 20 19 21 22
  17 08 07 09 11
  16 05 01 02 10
  18 06 03 04 12
  23 14 13 15 25
  ```

  Here X increases rightward and Y downward, matching +X, +Y, then (+X,+Y) after the
  center. This diagram is not the north-up map convention; world Z remains vertical.
  It is the reference with an eastward second column. R38 varies the preferred direction;
  Q5 rotates this sequence around the selected filling center, adapts it to smaller
  footprints, and prioritizes inner layers. All actual corners except the first column
  follow noncorners.
- R12: With N fully active columns, normal target capacity is 4N and absolute capacity
  is 6N: 4/6 items for 1×1 and 100/150 for 5×5. Levels five and six are overflow buffers
  for excessive deliveries, not ordinary replenishment targets. No operation may make
  stock negative or exceed physical capacity. Incoming reservations also consume this
  ceiling under R31–R33; R53/Q2 defines the reduced-capacity target and admission ceiling.
- R13: Stored items use reusable packed-block rendering: the contained material cube,
  pallet texture on the bottom face and lower part of every side, and binding straps on
  every side. The material remains visually identifiable from outside: pallet/strap artwork
  covers limited regions, and its transparent gaps reveal the underlying resource texture,
  not the world behind the cube. Do not replace the material with a uniformly opaque crate
  surface or make the whole cargo cube translucent. Packaging is not another inventory
  item. Geometry remains within each unit cell; the loose pallet's height does not increase
  stack spacing. Reuse this material-plus-packaging appearance outside warehouses (Q13).
- R14: Packed items collide as full occupied cells regardless of their material's normal
  shape, but supply no construction support. This includes platform, road, and blueprint
  support checks. Their special stacking rules belong to storage, not ordinary placement.

### Interaction and resource transfers

- R15: Put/take interactions are fast and material-independent, initially about 100 ms
  for the player's action, with a fresh press for each transfer under R40. This is not a service latency deadline, simulation tick,
  required sleep per transfer, or disk-sync requirement.
- R16: Send stock intents identifying the current warehouse object/registration, such
  as `warehouse_put(warehouse_id, material)` or `warehouse_take(warehouse_id)`, without
  a desired cargo-cell coordinate or a pallet address as inventory identity. The
  simulation-owned record authorizes stock changes; exact request encoding and the
  cross-owner transfer protocol remain technical design under Q18; Q17 retains player
  inventory in world-data authority.
- R17: Client checks before prediction and authority checks before acceptance must reject
  empty takes, puts exceeding unreserved capacity, wrong materials, and invalid registrations.
  An incoming reservation is not available stock for take. Player carried stock and
  warehouse stock change coherently: rejection changes neither authoritative inventory.
  Taking goods returns their stored material without applying terrain mining conversions.
- R18: Aiming at any eligible member/packed item selects the warehouse. Put uses the next
  layout slot; take normally removes the last occupied slot in filling order, regardless
  of the aimed cell. With reduced active capacity, use the deterministic count-only layout
  selected under R23/Q1/Q2; goods need not retain their previous physical positions.
  Failed warehouse interactions cannot fall through into ordinary terrain edits in the
  same reserved space.
- R19: Prediction includes stock, derived occupancy, and carried inventory. Reconciliation
  must preserve later accepted changes, reject stale registration/subscription state, and
  prevent duplicate resource effects on retries. Simulation retains precedence over
  conflicting player actions; no client acknowledgment is required per simulated item.

### Reservation, capacity reduction, and lifecycle

- R20: Registered member pallets cannot be removed/replaced through ordinary edits.
  Reserve the R4 envelope against ordinary placement and conflicting future construction.
  Adding the selected material there is a stock transfer, not physical terrain placement.
  Apply guards to player, observer, simulation, blueprint, and indirect mutation paths.
- R21: Registration must check already planned construction and other claims, not only
  terrain air. Disabled columns retain their original reservation. Warehouse clearance
  regions may share empty cells under R36/Q8; member/potential-cargo regions may not
  intersect another warehouse's envelope. Unfinished-blueprint cavities may contain a
  warehouse under R48/Q8, provided no blueprint target intersects its full envelope;
  required floor support is protected under R37/Q7.
- R22: Management allows unregister and material change only when automatic work is
  stopped, stock is zero, and all accepted obligations involving the warehouse have
  finished, including incoming reservations. Recheck these conditions together at
  authoritative confirmation; an old dialog cannot override arrivals or reactivation.
  Unregister removes this warehouse's registration, member protection, and spatial claim
  together, leaving ordinary pallets and preserving other owners' claims on shared air.
  Material change retains the registered footprint and stopped
  status; resuming automatic work requires explicit Enable. Q4 records the confirmed lifecycle.
- R23: The management dialog also allows reducing the active column count while stock is
  present. Disable a suffix of the column order, last-filled column first. Preserve all
  goods by quantity; repacking may move them between columns. Prefer active columns and
  release disabled storage as stock drains, without tracking the identity or original
  position of individual items. New replenishment must not target disabled columns.
  R53/R54 and Q2 allow 0..N active columns, new admission within 6A including promises,
  and active-before-disabled packing. Raising A re-enables the next columns in the same
  order without unregister. Existing goods and accepted incoming reservations remain
  valid within 6N; lowering A does not delay the change or revoke any accepted delivery.
  Disabling columns is expected to be rare: use a simple bounded recomputation, without
  persistent layout history or specialized optimization for this path.

### Streaming, persistence, and performance

- R24: Both block and mesh subscriptions expose warehouse discovery references; object
  snapshots/updates provide enough state to reconstruct contents independently of terrain
  geometry. Object-only changes must reach relevant subscribers even if a chunk mesh has
  zero faces or does not change. Reservation-only updates change client admission state
  even when C is unchanged. R60/Q24 selects independent object subscriptions and complete
  snapshots; concrete transport encoding and budgets remain implementation choices.
  No independent writable stock copy belongs to a chunk or pallet.
- R25: A distant warehouse may appear empty while its object snapshot is unavailable.
  Receiving the object state enables rendering across its entire saved footprint without
  loading the terrain chunk containing the layout origin. Discover WarehouseId through
  any intersecting chunk reference; central-pallet residency is no longer a prerequisite.
  R52/Q12 requires current object state or unknown-data guards for nearby cargo
  collision/interaction. The distant visual allowance does not establish empty storage.
- R26: Packed geometry participates in scene depth, lighting, shadows, and post-processing.
  Drawing after the chunk mesh means another world-geometry path, not a GUI overlay.
  Unchanged camera frames reuse source data. Stock changes must not require terrain remeshing.
  Changes only to promised capacity I do not require rebuilding cargo geometry.
- R27: Capture simulation warehouse objects, task/cargo/reservation state, world claims
  and members, and associated player inventory changes as one coherent saved outcome.
  Restore objects/discovery indexes before accepting dependent operations; independent
  commits must not save opposite sides of a transfer from different logical outcomes.
  Once deliveries are integrated, capture/restore accepted cargo, its destination capacity
  reservations, and completion state coherently under R33 as well. Preserve the warehouse's
  automatic-work enabled/stopped intent and outstanding obligations through save/load;
  loading cannot implicitly enable it or complete its deliveries.
  Derived cargo cubes and client predictions are not authoritative save records. Integrate
  with existing capture/source ownership and whole-world version gates.
- R28: Membership, reservation, and collision lookup must be spatially bounded, with no
  scan of every warehouse per edit, movement query, or simulation tick. Changes wake only
  relevant work. Permit batched authoritative mutations and coalesced client publication.
- R29: Measure authority, index lookup, publication, client layout/collision, GPU work,
  memory, and persistence separately, with and without observers. Include many warehouses,
  buffers, disabled columns, chunk boundaries, and the wrapped-X seam. Numerical budgets
  must come from measured representative workloads, not the 100 ms player animation.
- R30: If repacking, an otherwise valid manual put, or an accepted delivery arrival places
  goods inside the player's body, move the player to a free full-body position validated
  against current terrain and derived cargo collision. Player overlap alone must not reject
  the manual put or make the delivery wait for the player to leave. Apply the ordinary
  stock/inventory/reservation transfer, then recover against the resulting occupancy;
  recovery itself neither changes resource quantities nor changes the deterministic layout.
  Repacking still preserves warehouse quantity and carried inventory. Do not inherit ordinary
  terrain placement's player-overlap rejection for warehouse stock transfers.
  Reuse the existing bounded player-recovery path where suitable, extending its collision
  reader to include packed goods. Start recovery search only on actual intersection;
  unchanged/distant warehouses must not trigger whole-world actor scans or free-space searches.
  Missing data is not a valid free destination. Apply recovery against current logical state,
  including reconciliation, independently of GPU upload timing. Simulation does not wait
  for client recovery or its acknowledgment. Q26 selects the reserved base-level halo as
  the fallback destination, preferring candidates with known full-body clearance and loading
  bounded missing dependencies if necessary. Recovery never deletes goods or selects unknown space.

### Accepted deliveries and capacity reservations

- R31: Reserve an aggregate quantity of destination capacity at successful delivery
  acceptance/departure, without assigning individual cargo cells. For an N-pallet warehouse
  with A active columns, present stock C, outstanding incoming reserved quantity I,
  and positive new cargo quantity q, require `C + I + q <= 6A`. Preserve `C + I <= 6N`
  across mutations, including reductions of A. Q2 selects the normal target 4A and
  demand `max(0, 4A - C - I)`; the hard admission ceiling remains separate from demand.
  No admission relies on forecast future consumption or chooses a full logistics scheduler.
  Preliminary planning creates no reservation. Successful departure coherently combines
  destination reservation, source-to-delivery cargo transfer, operating payment, task
  creation, and obligations. Failed acceptance leaves none of these partial effects.
  The promise belongs to the accepted delivery and current destination registration;
  time passing, stopping, or capacity reconfiguration cannot silently revoke it.
- R32: Every unreserved addition, including player puts and observer/simulation stock edits,
  must fit outside outstanding incoming reservations within the active capacity:
  `C + I + q <= 6A`; known client prediction and authoritative acceptance use the same
  rule. Successful handover of an accepted delivery's q items consumes its own matching
  reservation and changes `I -= q`, `C += q` coherently with cargo ownership and completion.
  Do not charge that arrival another q units of free capacity as an ordinary unreserved
  put would. Validate delivery/registration identity, material, and its remaining promise;
  one delivery cannot consume another's reservation. Arrivals need not wait for ordinary
  capacity because later puts cannot take their promised room. Data/service delays still
  retain both cargo and the promise until handover succeeds.
- R33: Stock C and reserved quantity I describe different facts. Render and permit taking
  only C; in-flight goods remain owned by their delivery. Keep aggregate I consistent with
  the outstanding accepted delivery reservations, without scanning all deliveries on each
  warehouse operation or storing per-cell claims. Start and handover retries cannot repeat
  reservation, payment, cargo transfer, stock increment, or reservation release effects.
  Save/load restores one coherent state of these facts before new admission, without
  adding reserved cargo to stock or reserving it a second time. The simulation owns both
  the warehouse aggregate and task reservation facts. Q22 selects initial shared execution;
  concrete task-record layout and retry/recovery encoding remain implementation choices.
  Batching remains allowed and no per-operation durable write is required. Cancellation/exceptional
  failure policies remain separate and cannot silently discard accepted cargo or promises.

### Stop, enable, and management

- R34: Management provides Stop and Enable separately from unregister. Once Stop is
  accepted, no new automatic job involving this warehouse may start, including new
  incoming and outgoing deliveries. Already accepted work/deliveries finish normally,
  retaining cargo, destination capacity, payment, timing, and obligations. A stop/start
  race must yield either a previously accepted job that finishes or a refused new start
  with no partial effects; do not revoke an accepted job. Stop preserves registration,
  selected material, stored goods, member protection, and the reserved spatial envelope.
- R35: Manual extraction remains available while automatic work is stopping or stopped,
  under ordinary stock, inventory, targeting, and quick-transfer rules. Finishing the last
  obligation leaves the warehouse intact and inactive, even when empty. Enable explicitly
  reopens automatic admission subject to current prerequisites; it does not change stock,
  discard or repeat existing obligations, or create a new registration. Completion,
  manual draining, and material change never automatically enable or unregister a warehouse.

### Shared warehouse clearance

- R36: Warehouses may share a one-cell empty aisle, including overlapping diagonal
  clearance. Let V be a warehouse's full base rectangle extruded through z0..z0+5
  (members plus every possible cargo cell), E its R4 envelope, and H = E minus V the
  side/corner clearance. Two warehouses A/B are compatible only when
  `V_A ∩ E_B = ∅` and `V_B ∩ E_A = ∅`; any intersection of their envelopes must belong
  to both H regions. Evaluate the full potential cargo volumes even when stock is zero
  or columns are disabled. All shared H cells remain terrain air and unavailable to
  ordinary construction while any owner claims them. Removing one claim preserves the
  others, including across chunk eviction, reload, and the wrapped-X seam. Registration
  order does not change geometric compatibility. Shared clearance does not merge stock,
  materials, origins, or lifecycle. This is a warehouse-to-warehouse rule; other structure
  pairs need their own policy, and R48 defines blueprint-cavity compatibility.

### Pallet foundation

- R37: Each pallet, registered or unregistered, requires one eligible solid terrain
  block directly below it. Its own support predicate reads that one neighboring cell;
  it requires no 3×3×3 platform, horizontal support path, or inherited plank height/span
  checks. The supporting block remains subject to its ordinary validity rules. Pallets
  themselves supply no construction support, including platform/road support and the
  cheap blueprint fulfillment predicate. Planned miniatures, packed goods, air, and other
  pallets cannot satisfy pallet support. Apply the same rule to placement and registration,
  and reject removal/replacement/indirect changes that would leave any remaining pallet
  without its required support. Unregister leaves these ordinary pallet rules in force:
  remove the pallet before removing its necessary support. Missing support data is unknown,
  not approval. Use Q7's explicit floor-material allowlist: existing structural materials
  plus solid country road. Sand, water, snow, leaves, adaptive roads in either shape, and
  generic custom cells are ineligible regardless of movement collision. Classify the
  material without inspecting road shape or rerunning the floor's placement validator.
  This is a local material support rule, not a lock on all ground under the air border.

### Deterministic filling variation

- R38: Derive a stable filling direction by hashing the fixed layout origin's integer
  chunk-local coordinates and taking the result modulo four: 0 North (+Y), 1 East (+X),
  2 South (-Y), 3 West (-X). This selects the preferred direction of the second column;
  Q5 skips absent neighbors and gives inner-layer and late-corner rules priority. Use the resulting
  column order for the first four levels, fifth and sixth levels, and reverse-order column
  disabling. The direction is derived, not mutable random state, and is independent of
  stock, material, active-column count, camera, registration time, and load order. Keeping
  the same origin through future expansion preserves its direction even if the filling
  center moves. Q5 specifies the hash and full ordering; client, authority, and recovery
  must share that contract.
- R39: When either footprint dimension is even, choose the first filling column by hash
  among the two central cells on that axis. An odd-length axis has a unique center and
  needs no choice. There are one, two, or four central candidates for the footprint.
  Use separate hash bits for the X choice, Y choice, and R38 direction. Hash the fixed
  layout origin, never the selected filling column; this avoids circular selection.
  The first column is always first even when it is itself a corner, as on a 2×2 base.
  Stock, material, or active-capacity changes do not choose a different center or reorder
  the full column list. The layout origin still follows R8's lower-coordinate rule.

### Player controls and access

- R40: In player mode, Mouse2 on an unregistered candidate pallet opens creation under R5;
  Mouse2 on any registered member pallet or packed item opens its warehouse's management
  dialog. Mouse1/E with empty hands takes one item; with the stored material in hand it
  puts that item; with any other material it reports rejection and retains the item.
  Each transfer requires a fresh press and uses R15's roughly 100 ms action duration.
  Holding the control cannot repeat or turn a completed take into an automatic put.
  Preserve the existing single-pending-transfer gate and rejection/reconciliation behavior;
  these player controls do not constrain simulation batching. R47 defines observer stock edits.
- R41: A hit on any reachable member pallet or packed item identifies the warehouse for
  its menu and stock operations. Check the inclusive four-block reach relative to that
  aimed pallet/item, never the layout origin or the deterministic slot that changes.
  The changed slot may lie beyond reach. This does not permit targeting through intervening
  occupied/unknown cells under R43's shape-aware targeting and distance rule. A full
  warehouse remains manageable without finding an uncovered pallet.
- R42: Warehouse creation and management dialogs do not pause the world. Continue simulation,
  delivery, stock consumption, and player physics, including falling and R30 displacement.
  Release the cursor and block movement/look/tool input while the dialog owns focus.
  Opening it cancels unfinished player/tool holds; dialog clicks and held controls must not
  execute world actions behind the UI or replay transfers after closing. Escape closes the
  warehouse dialog first and is consumed, rather than opening the pause menu on the same press.
  Display current available warehouse state and refresh action availability as updates arrive.
  Confirmations must revalidate current authoritative preconditions under R6/R22/R19;
  an earlier enabled button or snapshot cannot authorize an invalid change. UI updates
  follow relevant state changes, without global polling or repeated scans of unchanged state.
  Opening a dialog adds no pause/resume transition to the world's simulation clock.
  R63 defines confirmation reach after falling, displacement, or changes to the original hit.
- R43: Target a loose/member pallet with one axis-aligned 1×1×0.2 box at the bottom of
  its unit cell. Ignore individual plank outlines and gaps; a ray above this box continues
  to the next target instead of hitting the pallet's otherwise empty cell volume. Packed
  cargo uses a full 1×1×1 target cube, including its lowest item in the pallet cell.
  Target shape does not give the pallet movement collision or construction support.
  After finding the first shape hit, apply the ordinary inclusive four-metre reach check
  from the camera to the nearest of the targeted unit cell's eight vertices, using the
  nearest wrapped X copy. Measure the full cell, not the low box or exact ray-hit point.
  Retain the existing conservative traversal bound so an eligible cell is not lost merely
  because its hit point lies beyond four metres. Highlighting, menu opening, and transfers
  use the same hit/reach result; unknown cells still stop the ray.

### Stored materials

- R44: Initially allow only `dirt`, `sand`, `snow`, `crushed_stone`, `tree_trunk`, `planks`,
  `rebar`, `reinforced_concrete`, `country_road_solid`, `country_road_adaptive`, and the new
  `pallet` item as stored cargo. Exclude `water`: liquid storage/handling is deferred until those mechanics are
  designed. Apply the same eligibility contract to material selection, registration,
  material changes, manual transfers, and delivery admission; hiding water in the chooser
  alone is insufficient. Storage eligibility is an explicit material capability, separate
  from terrain placeability and pallet-floor support. Future materials need an explicit
  decision; adding a placeable block does not automatically make it warehouse cargo.
  Taking cargo returns its stored item identity without terrain-mining conversion (R17).
- R45: In player mode, removing an unregistered pallet with empty hands takes the ordinary
  three seconds and yields one pallet item in the single inventory slot. Installing that
  carried pallet takes the ordinary one second and consumes the item on success. Preserve
  ordinary cancellation, admission, prediction/reconciliation, and resource conservation.
  Placement still requires an eligible supporting block and forbids pallet-on-pallet stacking
  under R2/R37. Registered member pallets remain protected until explicit unregister,
  including when warehouse stock is empty. Carrying a recovered pallet does not carry a
  warehouse registration or its object state. Initial pallets are supplied through observer
  mode; no crafting recipe is introduced. The roughly 100 ms stock-transfer duration does
  not apply to ordinary terrain-pallet removal or placement.
- R46: Pallet items may be stored as warehouse cargo. One pallet contributes one stock unit
  and occupies one derived unit cell, with the shared packed appearance and full-cube
  cargo collision. It is not a terrain pallet or another warehouse member and supplies no
  construction support. Player put/take uses the same roughly 100 ms transfer as other cargo;
  taking returns exactly one ordinary carried pallet. Packaging artwork creates no additional
  pallet item. Installing/removing the recovered pallet in terrain still uses R45's ordinary
  one-second/three-second actions and the pallet's support/no-stacking rules.

### Observer controls

- R47: In observer mode, Mouse2 opens warehouse creation/management through the same target,
  reach, and modal rules. Tab keeps switching putting/removing modes. In putting mode,
  Mouse1/E attempts to add one unit of the observer's currently selected material; it
  succeeds only when that material matches the warehouse's configured material and other
  admission checks pass. On mismatch, use the same error reason and user-facing message
  as player mode, without changing selection, stock, or the player's inventory. Never
  substitute the warehouse material for the selected one. In removing mode, Mouse1/X
  removes one stock unit, not a member pallet. Observer stock edits have no hold delay and
  execute once per press; they create/discard cargo without touching the player's carried
  inventory. They remain authoritative, retry-safe stock mutations subject to empty/full,
  promised-capacity, registration/member protection, and all other applicable warehouse
  rules. An empty take cannot fall through into pallet destruction. A future selection menu
  supplies the same selected-material value; it does not change these matching semantics.

### Warehouses inside unfinished construction

- R48: Permit a warehouse envelope E to overlap an unfinished blueprint's bounding box
  if E contains no nonempty blueprint target. Let T contain all target cells of the active
  instance, including pending and fulfilled targets; require `E ∩ T = ∅`. Bounding-box
  overlap alone is not a conflict. Apply the rule symmetrically when registering a warehouse
  inside an existing site or applying a blueprint around an existing warehouse, with coherent
  admission against current claims/targets. Evaluate the full envelope, including all six
  potential cargo levels, disabled columns, and side/diagonal clearance, regardless of stock.
  Preserve every ordinary terrain, foundation, composed-world, and blueprint-instance check.
  Pallet support must already exist physically; a pending floor target cannot supply it.
  Warehouse put/take changes simulation inventory and remains available under normal warehouse rules,
  including within a site whose real-block extraction is forbidden. Unregister releases only
  warehouse restrictions; the active blueprint still forbids terrain-pallet extraction.
  Blueprint completion releases only that site's restrictions; a registered warehouse remains
  protected. Use local target/claim lookup, without global warehouse/site scans, extra per-stock
  structural validation, or widening the five-neighbor blueprint fulfillment support check.
  Blueprint capture is a separate operation and follows R64's material/ownership boundary.

### Changing the footprint

- R49: This iteration provides no in-place expansion, shrink, merge, or automatic adoption
  of neighboring pallets by a registered warehouse. To change its footprint, Stop it,
  finish all accepted obligations, empty its stock, and explicitly unregister under R22/Q4;
  then rebuild the ordinary pallet base and register it through the normal creation flow.
  The new registration performs all footprint/support/clearance/claim checks, receives a new
  registration identity, and chooses its central layout origin afresh under R8/Q5.
  The origin coordinate may change or remain the same; it does not preserve the previous
  registration's identity. No resize shortcut may bypass lifecycle or other owners' guards.
  While registered, border placement and member protection remain in force. Reducing the
  active-column count under R23 is still permitted by its own policy and does not change
  the physical footprint or origin. In-place expansion retaining the original origin is
  explicitly deferred, with its resource/claim transition design left to a later feature.

### Registration preview and confirmation

- R50: Opening the creation dialog performs a preliminary check only and creates no
  temporary reservation, member protection, or registration. While it remains open,
  otherwise legal world edits and construction admission may change the candidate area.
  On confirmation, revalidate the current base, actual floor support, clearance, selected
  material, blueprint targets, and other claims before coherently publishing the warehouse
  and its reservation together. A valid preview cannot substitute for these current checks.
  If confirmation fails, report the reason and publish no partial warehouse, membership,
  or claim. Canceling an unsubmitted dialog leaves ordinary pallets and creates no reservation
  to release or expire; no preview claim may persist merely because the window remains open.

### Visual update scheduling

- R51: Update warehouse presentation in response to relevant state changes without an
  intentional minimum-age delay or fixed refresh interval. Combine changes arriving before
  preparation into the latest coherent warehouse snapshot; intermediate images need not be
  rendered. Normally publish the updated appearance in the next available frame, but under
  load allow preparation to span frames rather than blocking simulation. Authoritative stock
  transitions and current client logical inventory, targeting, collision, and recovery do not
  wait for visual preparation/upload. Coalescing images must not discard resource operations
  or their effects. Keep goods and marker visibility coherent within each published visual
  snapshot, reuse unchanged sources, and preserve registration/revision ownership across
  deferred work. New changes must not postpone work merely to wait for a quiet period.
  Per-frame work budgets and CPU/GPU representation remain implementation choices to measure;
  this policy does not promise a hard one-frame freshness bound under overload.

### Cross-chunk warehouse discovery

- R52: Each chunk intersecting a registered warehouse's full R4 envelope carries a small
  lookup entry identifying WarehouseId/current registration and bounds. Include warehouses
  wholly inside one chunk and chunks containing only clearance or upper cargo cells.
  At most eight 32³ chunks hold an entry per warehouse; entries contain no stock or active
  count copy. Publish/retire entries coherently with registration/unregister and preserve
  other owners sharing clearance. Stock/configuration changes within unchanged bounds do
  not rewrite the index. Recover entries before dependent edits, so absent object data or
  terrain residency cannot make claims disappear. Nearby queries request current object
  state; possible cargo cells are unknown until it arrives and cannot be traversed or edited
  as empty terrain. Known halo clearance remains traversable under ordinary collision rules
  while its placement claim stays enforced. Queries use local entries and WarehouseId
  lookup without scanning all warehouses. Deduplicate presentation ownership by warehouse
  identity across chunk references and mesh/block handoffs. Reject stale object/revision/
  subscription lifetimes. Index encoding/recovery and object subscription/retention mechanics
  remain implementation review; loading one designated pallet chunk is not required.

### Reduced active capacity

- R53: Store an integer active-column count A in 0..N; the first A columns of Q5's stable
  order are active and the remaining suffix is disabled. Normal replenishment targets
  4A units with deficit `max(0, 4A - C - I)`, where C is present stock and I is accepted
  incoming quantity. Every new incoming departure and unreserved put, including player
  and observer additions, requires `C + I + q <= 6A` for positive quantity q. Manual puts
  may use levels five and six. Changing A preserves C, I, all accepted obligations,
  the full spatial reservation, and `C + I <= 6N`; it may leave C+I above 6A. Existing
  promised arrivals still complete using the full physical 6N capacity, without a second
  admission check against the reduced 6A ceiling. Setting A=0 blocks all new additions,
  but manual takes and otherwise eligible outgoing work remain available while enabled.
  It does not change Stop/Enable intent; stopped warehouses still accept no new automatic
  jobs under R34. Increasing A re-enables a longer prefix and recomputes demand/layout
  without unregister, changing stock, or implicitly enabling a stopped warehouse.
- R54: Derive a complete 6N-slot sequence by concatenating two groups: active columns
  first, disabled columns second. Within each group, use Q5's column order, fill four
  cells in each column from z0 to z0+3, then level five across that group, then level six.
  Empty groups contribute no slots. Occupied slots are exactly the first C entries;
  incoming quantity I does not render or change their placement. Thus all active capacity
  precedes disabled storage, and taking from the end clears disabled columns first.
  Lowering or raising A may repack stock, including into the active buffer levels, without
  changing quantity or remembering previous positions. A=N reproduces ordinary filling;
  A=0 uses the ordinary order across all disabled columns for surviving stock/arrivals.
  New admissions cannot refill disabled storage under R53; earlier promises remain valid.
  Preserve marker suppression and player displacement under R7/R30 on every rearrangement.

### Courier access

- R55: Offer side-adjacent cells of the base-level clearance halo as potential courier
  pickup/drop-off endpoints, excluding diagonal-only corners. A w×h base supplies
  2w+2h candidates, at most 20. Route planning selects an eligible endpoint under ordinary
  traversability rules at each participating warehouse; a candidate cell is not proof
  of a usable floor or route. Do not designate a single entrance or require one side to
  remain the only access direction. The candidate set depends only on physical bounds,
  not C, I, A, material, or the position of a derived cargo item. Resource operations
  still address the warehouse registration and use its deterministic put/take policy.
  Route availability is not a registration requirement: an otherwise valid inaccessible
  warehouse remains manually usable under ordinary player targeting/reach rules. New
  automatic deliveries require a route and all other admission prerequisites. Subsequent
  loss of a route or endpoint does not replan, delay, cancel, or change the accepted
  delivery's cost or handover under the established travel policy. Courier visuals do
  not govern resource acceptance or completion, and access points add no congestion or
  exclusive dock reservations. Concrete routing and endpoint-selection algorithms remain
  part of the separate logistics design.

### Player inventory authority

- R56: Keep the player's authoritative carried inventory in world-data service under Q17.
  Ordinary mining/placement retains its coherent terrain/inventory transition. Warehouse
  stock remains simulation-owned; one manual transfer intent must coherently update both
  owners exactly once or leave both unchanged on rejection. Movement checkpoints, client
  predictions, and simulation-side presentation copies cannot overwrite player inventory.
  Retain simulation precedence and coherent save/recovery under Q18; concrete cross-owner
  access/capture integration and bounded retry bookkeeping remain implementation work under
  the selected Q22/Q23 contracts. Ordinary automatic warehouse logistics must
  not acquire player-specific coordination solely because this manual path exists.

- R57: Use Q18's coherent live-commit and common-capture baseline across warehouse,
  player, world, and simulation state. Prepare fallible resources before the commit;
  prevent conflicting authoritative access and capture from observing partial resource
  transitions. Extend the existing coordinated save/WAL path rather than independently
  saving each owner. Ordinary item transfers and task completions need not wait for a
  durable write of their individual outcome. Recent unsaved progress may be lost coherently;
  no fixed crash-loss window is selected. Optimize coordination for frequent simulation
  work, including construction, and amortize access across batches where appropriate.
  Exact execution rights, retry lifetimes, and capture integration remain implementation
  design. Q19 selects target-only construction storage ownership for further design; Q20
  permits evaluating narrowly defined
  accounting exceptions but adopts no exception or error budget.

### Initial warehouse execution

- R58: For the first warehouse implementation, execute world-data and simulation mutations
  on the existing world-service executor while keeping canonical records, module APIs, and
  persistence responsibilities separate. Simulation-only warehouse work uses local APIs in
  bounded batches, without a world-data message or player-specific lock for each item.
  Preserve prepared coherent commits, safe snapshot/source lifetimes, simulation conflict
  precedence, and command/save fences. Validate shared-executor throughput under terrain,
  publication, and save pressure; this choice is not a capacity guarantee or a permanent
  thread topology for the full economy. Q22 retains independent/partitioned alternatives.

### External command identity and retry lifetime

- R59: Follow Q23's live-session retry contract for external warehouse commands. Identify
  intents by world/server session, client session, and monotonic command sequence; retries
  retain their identity and payload and cannot repeat a resource effect. Address the specific
  warehouse registration. Retain bounded pending/results state and recognize retired identities
  so eviction cannot make an old intent new. Reject payload conflicts and newly evaluated
  intents addressed to stale registrations; replay of a retained result does not reapply it.
  After restart/reload, use fresh sessions and resynchronize authoritative state instead of
  automatically relabeling old intents for replay; a live client-session rotation must account
  for already admitted work. Do not require a durable per-click response history. Preserve
  persistent simulation task/cargo/reservation state and its own retry guarantees independently.

### Warehouse object subscriptions

- R60: Use Q24's independent, deduplicated object subscriptions for both block and mesh clients.
  Start from chunk discovery and functional dependencies; retain needed logical state independently
  of GPU residency and release subscriptions when no reference/dependency remains. Publish compact
  complete snapshots in the first implementation, coalescing to the latest revision without a
  debounce delay or loss of required command results. Preserve registration/session/subscription
  lifetimes, retirement, and unknown-data guards. Client eviction never removes canonical stock
  or accepted work. Q25 defers evaluation of increment/decrement publication; it does not replace
  complete snapshots in this iteration or change authoritative resource operations.

### Warehouse displacement fallback

- R61: If ordinary bounded recovery cannot resolve a warehouse-goods overlap, use a cell
  in that warehouse's reserved one-cell base-level halo under Q26. Prefer a known clear
  full-body destination in already loaded logical data; center the body horizontally in
  the halo cell with feet at the pallet-base level. If none is currently usable because
  required data is missing, retain/request the bounded candidate dependencies and retry
  after data/state progress. Movement remains blocked during unresolved overlap, while
  accepted transfers and simulation continue. Revalidate the current collision and warehouse
  lifetime before relocation. No route to the destination or global free-space search is
  required; ordinary gravity resumes after recovery, and no new halo-floor requirement is added.

### Registration defaults

- R62: Successful new registration starts with the chosen material, `C=0`, `I=0`, `A=N`,
  enabled automatic-work intent, and no accepted incoming/outgoing obligations. All physical
  columns are active. Registration itself creates no delivery or cargo; automatic work may
  subsequently start only under normal admission rules. Apply these defaults to every fresh
  registration after unregister/rebuilding, even at unchanged coordinates; do not inherit
  stopped intent or disabled columns from the retired object. Restore saved registrations
  with their saved state instead, and preserve R22's stopped intent on material change.

### Confirmation reach in live dialogs

- R63: Recheck reach when evaluating a new mutating creation/management command, including
  capacity, Stop/Enable, material change, and unregister. For creation, rediscover the current
  candidate from the originally clicked pallet cell; that cell must still contain an eligible
  unregistered pallet. At least one pallet of that current candidate must be within reach.
  For management, at least one current member pallet or currently occupied cargo cell of
  the addressed registration must be within reach. Use R43's inclusive four-metre
  camera-to-nearest-full-cell-vertex metric from the current mode's viewpoint and wrapped X
  handling. Bound the query to this candidate/registration. The original hit need
  not survive, and reach is never measured to the layout origin or a formerly occupied slot.
  Once the dialog is open, confirmation needs no fresh cursor ray, camera facing, or line of
  sight; opening the dialog and ordinary stock actions retain R41/R43's targeting rules.
  If out of reach, keep the dialog available for viewing, disable/reject mutations with an
  out-of-reach reason, and leave world/inventory state unchanged. Missing required data cannot
  prove reach or identity. Recheck locally before submission and authoritatively at evaluation;
  update UI availability when the viewpoint or relevant object state changes. Moving after an
  operation is accepted does not cancel it; Q23 retries replay its result without a new reach
  test. An open subscription alone never grants remote mutation rights.

### Blueprint capture boundary

- R64: Preserve the blueprint capture allowlist and material view. A selected terrain pallet,
  registered or loose, rejects capture with an unsupported-material diagnostic; pallet
  blueprint support is deferred. Derived packed cargo is not captured terrain, even when its
  stored material is blueprint-eligible. Sample underlying terrain and existing blueprint
  logical contents under the capture rules, without substituting warehouse collision/render
  occupancy. Upper cargo cells therefore contribute air; a cargo-only selection without
  pallets or other content fails as an empty blueprint. Otherwise eligible surrounding
  construction may be captured with those cells left empty. Capture neither copies inventory,
  claims, nor registration data, and changes no warehouse state.

## Clarifications

### Q1 — One count versus priority draining

**CONFIRMED 2026-11-11: count only, with repacking.** The author selected one stock count
in one authoritative warehouse record and permits deterministic relocation of goods.
Q16 places that record in simulation state; the earlier pallet-metadata binding is superseded. Bounds,
count, active configuration, and the origin-derived center selectors and direction added by Q5 determine
occupied cells; there are no authoritative column heights, individual item positions, or
remembered prior arrangements. Any layout/collision cache
is derived and must be reconstructible from those inputs, including after save/load.

If the resulting goods intersect the player's body, displace the player into free space
under R30. Repacking changes neither warehouse quantity nor carried inventory. Exact
item positions are deliberately not preserved. Disabling columns is expected to be rare,
so prioritize a simple bounded algorithm rather than optimizing this exceptional action.
For the maximum warehouse, a complete derived rebuild considers at most 150 cargo cells;
this is an algorithmic size bound, not a measured frame-time or player-search bound.

This choice avoids persistent per-column bookkeeping and the corresponding mutation,
serialization, and synchronization work. It allows goods and colliders to jump when
configuration changes. Resource conservation and deterministic reconstruction remain strict.
Repeated deliberate toggles may repeatedly move the player, but must not create goods or
leave the body in occupied/unknown space. A specialized physical rearrangement animation
or item-by-item simulation is not required by the decision.

For comparison, stock 13 on three fully active columns produces `(5,4,4)`. Preserving a
take specifically from the third column would yield `(5,4,3)`, while the ordinary count-only
layout at 12 is `(4,4,4)`. The selected model resolves this by allowing a new arrangement,
not by remembering which item moved. The prior per-column recommendation is not selected.
Q2 completes this model with active-before-disabled slot ordering and separate limits
for new admission and existing stock/promises, keeping rare configuration changes simple.

### Q2 — What does active capacity restrict?

**CONFIRMED 2026-11-12: restrict new admission to active columns, preserve existing
stock/promises, and pack active columns first.** N is the fixed physical pallet count,
A is an integer in 0..N, C is present stock, and I is aggregate capacity reserved for
accepted incoming deliveries. Disable a suffix of Q5's stable order; re-enable by extending
its active prefix. Neither action changes the origin, footprint, hash selectors, or claims.

| Quantity or operation | Rule |
| --- | --- |
| Normal target | 4A |
| Replenishment deficit | `max(0, 4A - C - I)`; existing surplus and incoming goods reduce demand |
| New incoming departure or unreserved addition of q>0 | Require `C + I + q <= 6A` and all other admission prerequisites |
| Existing stock plus accepted promises | Preserve `C + I <= 6N`, even if a reduction leaves it above 6A |
| Handover of an accepted q-item delivery | `C += q`, `I -= q`; do not require a new 6A admission |
| Active-count change | Preserve C, I, and accepted work; apply the new A and derive layout/demand |

The deficit is the warehouse's capacity-based demand, not a chosen supplier search,
allocation policy, or full logistics scheduler. Stop/Enable still gates automatic work.
Four active levels remain the target; levels five and six are buffers, which manual puts
may use when their space is not promised. Admission checks current C/I/A coherently with
the resource transition. A competing reduction either follows an already accepted delivery
whose promise survives, or precedes a new start checked against the reduced limit.
Planning alone reserves nothing. A positive unreserved addition is refused whenever
C+I is already at or above 6A, even if disabled columns still have physical room.

Define `slots(columns)` as four slots per column in the given order, z0..z0+3, followed
by one slot at z0+4 for every column in that order, then one at z0+5. If P is Q5's full
column permutation, the complete deterministic slot sequence is:

```text
slots(P[0:A]) ++ slots(P[A:N])
```

Fill exactly its first C slots; I does not occupy displayed slots. Disabled stock is
therefore `max(0, C - 6A)`. A take removes the last occupied slot, so disabled stock drains
before any active stock. The two groups each use the existing four-level/then-buffer
pattern. Reconfiguration can put active columns into their fifth/sixth levels while
disabled columns become empty; this is intentional consolidation. No per-column inventory,
item identity, previous layout, pending reduction, or named delivery slot is introduced.
For fixed A, put/take modifies a prefix of one sequence; changing A may move many goods
and triggers the already selected overlap recovery and marker rules.

At A=N, the disabled group is empty and this is exactly ordinary filling. At A=0, the
active group is empty: no new delivery or manual/observer addition can pass admission,
but existing stock and previously accepted arrivals use the full disabled footprint.
Manual takes remain available, and an enabled warehouse may still start eligible outgoing
deliveries. Setting A=0 does not Stop it or automatically unregister it after draining.
Increasing A again re-enables columns, recalculates layout/demand, and preserves stock,
promises, and current enabled/stopped intent; no unregister is required.

For N=9, reduce A to 4 with C=20 and I=8. The new normal target is 16 and new-admission
ceiling is 24, but the existing total of 28 remains valid within 54. The twenty current
items repack as five per active column. The accepted eight-item arrival produces C=28,
I=0: six in each active column and four in the first disabled column. The next four takes
clear that disabled column; no new one-item put passes until C+I falls below 24. Normal
replenishment demand remains zero until C+I falls below 16.

This choice makes disabled storage drain without retaining item locations or assigning
slots to deliveries. Rare setting changes need only a bounded layout recomputation over
at most 150 cargo cells; quantity/reservation admission uses aggregate counters. The visible
tradeoff is immediate rearrangement and possible taller active stacks/player displacement.
Existing arrivals may temporarily refill disabled columns, but only using their preserved
promises; quantities are never discarded. The alternative soft demand-only limit with
unchanged new admission to 6N is not selected because it permits refilling disabled storage.
These are algorithmic bounds and gameplay tradeoffs, not measured runtime performance.

The [executable model verifier](../../docs/validation/warehouses.md) covers all N in 1..25,
A in 0..N, C in 0..6N, and I in 0..6N-C:
2,053,700 aggregate states. It checked unique slots, contiguous stacks, active-before-disabled
placement, disabled-first draining, admission/demand bounds, and the N=9 example above.
The check uses Q5 column ranks and validates this layout/accounting model, not runtime
implementation, concurrent code, or performance.

### Q3 — Destination capacity and overflow (WH-01)

**CONFIRMED 2026-11-11: reserve destination capacity at departure.** The author selected
aggregate quantity reservation, not named slots. For fully active storage define N pallets,
C present items, I capacity promised to accepted incoming cargo, and q items in the new
delivery. Accept departure only if `C + I + q <= 6N` and all other start prerequisites hold.
Capacity is available now; predicted future takes cannot justify an overcommitted start.
Four levels remain the normal target, six the physical ceiling. Q2 generalizes new
admission to `C + I + q <= 6A` and target demand to `max(0, 4A - C - I)` while retaining
the physical invariant `C + I <= 6N`. Demand and the hard admission guard stay separate.

| Event | Present stock C | Reserved incoming I | Other effects |
| --- | --- | --- | --- |
| Preliminary planning | Unchanged | Unchanged | No accepted task or cargo transfer |
| Successful incoming departure with q items | Unchanged | +q | Source cargo moves to the delivery; task, payment, and reservation are accepted together |
| Successful handover of that delivery | +q | -q | Its cargo ownership transfers to the warehouse and completion is recorded |
| Unreserved put of q items | +q | Unchanged | Allowed only with unreserved room and the operation's other prerequisites |
| Successful take of q items | -q | Unchanged | Only present stock is transferable; incoming cargo stays with its delivery |
| Rejected start or put | Unchanged | Unchanged | No partial payment, cargo transfer, task, or reservation |

At N=1 and C=4, two one-item departures can raise I to 2. A third is refused before it
starts. A player also cannot use those two promised spaces. Either accepted arrival changes
C/I from 4/2 to 5/1, then the other to 6/0, without requiring additional free capacity.
The reserved items do not appear in the warehouse or become available to take before arrival.

The selected tradeoff adds aggregate reservation bookkeeping and coherent start/handover
updates. It avoids routine full-destination waiting deliveries and their retries, and
requires no exact cell reservations, consumption-time predictions, or per-operation global
delivery scan. A player may be unable to add goods despite visibly empty reserved space.
These are expected work/behavior tradeoffs, not measured throughput improvements.

R31–R33 define conservation, identity, retry, and save/load invariants. Source cargo is
already in delivery custody at departure, so it is not simultaneously available source
stock. Simulation-owned task records and a warehouse's aggregate promise must describe
one coherent obligation; their physical storage/coordination is not decided here.

Stopping and reconfiguration must preserve promises. Q4 specifies management/lifecycle;
Q2 applies capacity reductions immediately while preserving promised physical room in
the unchanged 6N footprint, including disabled columns. Arrival-only checks with cargo waiting for
space are not the chosen normal policy. Delayed data/service processing and exceptional
failure/cancellation still need their own policies without losing cargo or reservations.

### Q4 — Empty is not obligation-free (WH-04)

**CONFIRMED 2026-11-11: separate stop/enable from unregister and material change.** The
following lifecycle follows that decision and the repository's object lifecycle; R62 adds
the explicit registration default:

| Action/state | Automatic work | Stock, obligations, and registration |
| --- | --- | --- |
| New registration | Enabled; normal admission prerequisites still apply | Chosen material, C=I=0, A=N, no accepted obligations; fresh identity and origin |
| Stop accepted | Refuse new jobs involving the warehouse, including new inbound/outbound deliveries | Preserve stock and claims; all accepted work/deliveries finish |
| Stopping with obligations | Process accepted work only | Manual take remains available; unregister/material change are disabled |
| Stopped, obligations complete | Remain inactive | Retain goods and registration; allow manual draining |
| Enable | Reopen admission under current prerequisites | Preserve existing stock, registration, and obligations without restarting them |
| Change material | Require stopped, empty, and obligation-free state | Change selected material; remain registered and stopped |
| Unregister | Require stopped, empty, and obligation-free state | Release this warehouse's claims and leave ordinary pallets |

R62 makes a newly created warehouse immediately usable at full capacity and eligible for
automatic supply. The creation chooser need only select the material. A player who wants to
unregister or change material must first Stop it; accepted work still has to finish. Rebuilding
creates a fresh enabled warehouse, while load/recovery restores saved settings and a material
change on an existing object keeps it stopped. These initialization defaults close the gap
identified in review; they do not add automatic delivery creation to registration.

For the warehouse delivery lifecycle, accepted incoming and outgoing deliveries involving
it finish before unregister/material change. Cargo already removed by an outgoing delivery
is not part of C, but that does not itself prove all accepted deliveries have completed.
Similarly, C=0 with I>0 is still awaiting an accepted arrival. A planned but unaccepted
request creates no obligation and cannot start while stopped; re-enabling requires current
admission checks rather than relying on its old plan.

Stopping is allowed while busy, so the player need not catch a gap between deliveries.
Manual draining does not reopen automatic work. Completion and zero stock never queue
deletion; the player chooses unregister separately. Recheck stopped status, C=0, I=0,
and absence of other accepted obligations together when applying a management action.

Keep lifecycle checks local to established task/obligation bookkeeping, without scanning
all deliveries or polling each warehouse's world footprint. An initial manual-only version
may have no delivery obligations, but must preserve the same Stop/Enable and empty-unregister
contract. Physical state representation, scheduling wake-ups, and shared SIM-15/SIM-16
production/cancellation details remain implementation or separate simulation work; no
cancel/refund feature or automatic stock disposal is introduced by this decision.

### Q5 — Exact center and ordering

**CONFIRMED 2026-11-11; storage binding revised by Q16 on 2026-11-12.** The fixed
central layout origin, variable central first column, origin-derived direction, inner-layer
priority, and late corners retain the same arithmetic. The origin is a coordinate in the
warehouse object, separate from both its identity and the filling start. At registration,
choose the layout origin at the lower-coordinate central cell of each axis in the locally unwrapped footprint:
`ax = xmin + floor((width - 1) / 2)`, `ay = ymin + floor((height - 1) / 2)`.
The origin remains fixed through future expansion (Q11).

Choose the first filling column from all equally central pallets using that origin's hash.
For odd width and height there is only one candidate. With one even dimension there are
two, and with both even there are four. For example, 4×3 keeps its initial layout origin
at offset (1,1) but can start filling at (1,1) or (2,1); 4×4 keeps its origin at (1,1) but
can start at any of (1,1), (2,1), (1,2), (2,2). These offsets are from the minimum corner.
The hash never changes the layout origin. Canonical wrapped X min/max must not replace
locally unwrapped footprint bounds.

Encode the fixed origin's chunk-local integer coordinates lx, ly, lz in 0..31 as
`key = lx + 32*ly + 1024*lz`. This retains coordinate order instead of collapsing every
location with the same x+y+z into one input. Use canonical voxel addresses, not camera-relative
positions or raw padded vector bytes. Normalize wrapped X before obtaining the origin's
chunk-local address. Equivalent wrapped addresses give the same key.

Compute a fixed u64 hash H using the SplitMix64 operations already present in the integer
[mix function](../../src/voxel_app/generation_hash.zig):

```text
v = key + 0x9e3779b97f4a7c15
v = (v xor (v >> 30)) * 0xbf58476d1ce4e5b9
v = (v xor (v >> 27)) * 0x94d049bb133111eb
H = v xor (v >> 31)
```

All additions/multiplications wrap modulo 2^64; shifts are logical. These arithmetic choices
pin the warehouse contract rather than coupling it to future generator changes. Extract:

```text
direction = H & 3              # 0 North (+Y), 1 East (+X), 2 South (-Y), 3 West (-X)
xChoice   = (H >> 2) & 1
yChoice   = (H >> 3) & 1
cx = xmin + floor((width  - 1) / 2) + (xChoice if width  is even else 0)
cy = ymin + floor((height - 1) / 2) + (yChoice if height is even else 0)
```

The center choices use different bits from the direction and from each other; choosing a
particular center does not force one direction. Odd-length axes ignore their choice bit.
The hash input is the layout origin, not the derived filling center. No PRNG sequence,
per-registration seed, or additional authoritative random fields are needed. The same local
origin coordinates in different chunks give the same selectors; for equal dimensions they
produce the same relative filling layout. Local-only input intentionally repeats across
chunks. Stock, material, active capacity, camera, and load order do not affect these choices.
Expansion keeps the selectors but evaluates cx/cy against the new bounds and dimensions.

Hash fixtures for future client/authority/recovery tests:

| Layout origin local (x,y,z) | key | H | Direction | xChoice | yChoice |
| --- | --- | --- | --- | --- | --- |
| (0,0,0) | 0 | 0xe220a8397b1dcdaf | 3 West | 1 | 1 |
| (1,0,0) | 1 | 0x910a2dec89025cc1 | 1 East | 0 | 0 |
| (31,31,31) | 32767 | 0xb73ab1ecf2c9d038 | 0 North | 0 | 1 |

Derive the complete column order as follows:

1. Start from R11's 25 ranked offsets around (0,0). Rotate the offsets about the selected
   filling center (cx,cy) so the reference's +X second-column direction becomes the selected
   direction. For an offset (dx,dy), use (-dy,dx) for North, (dx,dy) for East, (dy,-dx) for
   South, and (-dx,-dy) for West. Keep the reference's handedness; the footprint and center
   selection themselves are not rotated.
2. Filter out offsets without a member pallet. Preserve the relative order of survivors.
3. Keep the selected center first. Group the remaining columns by their distance from the
   nearest footprint edge, deepest first: `depth = min(x-xmin, xmax-x, y-ymin, ymax-y)`.
   Preserve the rotated sequence within each depth group. Thus all interior layers precede
   the perimeter, independently of which central candidate or direction the hash selected.
4. Stably move all actual footprint corners other than the selected center to the end.
   Corners have depth zero, so this preserves the inner-layer priority. A corner has both
   X and Y at their respective footprint extrema. In a 1×N footprint,
   only the endpoints are corners; every 2×2 cell is a corner. For 1×1 there is no second
   column. No column is duplicated or discarded by corner deferral.

For a 4×4 base, ranks 1–4 are exactly the inner 2×2 in a hash-dependent order; ranks 5–12
are noncorner perimeter columns, and ranks 13–16 are the four outer corners. The first
16 goods of a fully active warehouse fill the inner 2×2 to height four. Item 17 starts
the perimeter; fifth/sixth levels
still start only after the preceding level requirements in R10 are met, using this same
column order. The hash varies order within a spatial layer; it cannot move perimeter
columns ahead of unfinished inner columns. The initially selected center remains rank one.

This keeps the exact reference for an east-oriented 5×5. Rotation/filtering alone is
insufficient: for 4×4 with center (1,1) and North selected, it visits (1,1), (1,2), then
perimeter cell (0,1) before completing the inner 2×2. Depth grouping prevents that. Also,
in 3×3 reference rank 04 is a corner but ranks 05 and 07 are sides. On a 2×3 base with
selected center (0,1), its northern neighbor (0,2) is a corner while the eastern neighbor
(1,1) is not. Late-corner priority makes (1,1) second even when North was selected. The
hashed direction is a preference; absent neighbors, inner-layer priority, and corner
deferral can change the actual second column. The selected first column is the sole
exception to corner deferral.

The [executable model verifier](../../docs/validation/warehouses.md) checks all 25 dimensions
times 16 hash-selector combinations,
covering 196 distinct dimension/center/direction variants: every pallet appears once, the
selected center is first, depth never increases, remaining corners follow noncorners,
and a present noncorner in the selected direction is second if it is in the center's
depth group. All 16 variants of 4×4 fill the inner 2×2 before the perimeter, including
the 16-to-17 item boundary and the corresponding fifth/sixth-level order.
All 16 selector combinations occur among the 32³
possible local origin addresses. These checks validate the specification's combinatorics
and arithmetic, not runtime implementation or performance.

Implementation can derive at most 25 offsets on configuration changes or precompute the
196 short permutations; no repeated sorting during stock transfers is required. Hashing is
constant work and need only occur when deriving the owner/order, not per item or frame.
Active capacity selects a prefix of this stable full order and never changes the selected
center or direction; Q2 composes active and disabled slot groups from this same full order.

### Q6 — Discovering the rectangle and choosing the layout origin

**CONFIRMED 2026-11-11.** Discover the entire
face-connected coplanar pallet component containing the clicked pallet, following only
horizontal face neighbors. Stop with failure as soon as either dimension exceeds five or
a 26th unique pallet is found. Verify that the component fills its bounding rectangle:
its member count must equal width times height. Reject holes, protrusions, and oversized
components without selecting a valid subrectangle or requiring manual corner selection.
Diagonal-only pallets are not members, but any pallet in the required air border fails
clearance. Validate floor support and clearance separately from recognition. Unavailable
neighbor data cannot establish a component boundary or prove clearance; it remains unknown.

Choose the central member cell's coordinate as the layout origin at registration,
regardless of the clicked member. Odd widths/heights give a unique center; even-dimension
ties use Q5's lower-coordinate rule. Recognition, origin selection, and signed relative
bounds use locally unwrapped X across the seam, not min/max over canonical wrapped addresses.

Q16 supersedes the original metadata-pallet binding. This coordinate remains useful for
compact bounds and the unchanged hash, but the corresponding pallet has no special storage
role and its terrain chunk need not be resident to obtain the warehouse object. The previous
streaming-artifact rationale no longer governs object availability. Future expansion keeps
this fixed origin under Q11; a later footprint may have a different filling center.

### Q7 — Pallet support and the floor

**CONFIRMED 2026-11-11.** The author confirmed direct support below each pallet, no structural
support from the pallet itself, protection of the necessary supporting block for as long as
the pallet remains, and the material allowlist below. This applies equally to loose pallets
and members of registered warehouses. A complete 3×3×3 platform is not required; pallet
support does not inherit the horizontal spans or height rules of planks.

The pallet-specific proof uses the one real cell immediately below. It does not grant
validity to an otherwise invalid supporting construction or bypass occupancy, ownership,
world bounds, missing-data, or other ordinary operation checks. Registration checks each
member's support in addition to its clearance. Reject direct or indirect support loss;
unregister releases warehouse claims but does not make a surviving pallet unsupported.

Pallets are absent for construction-support purposes despite occupying a terrain cell.
Include the cheap blueprint below-neighbor check, road predicates, and stable platforms
in that rule. Other independent legal support routes remain available. Packed goods use
the same non-support principle, while their stacking is permitted by their storage owner.

The selected simplification bounds a pallet's own support check to one adjacent cell and
avoids recursive plank/bridge/platform searches. Protecting the support is still part of
ordinary authoritative dependent checks on removal; this is not a one-read bound for an
entire world mutation or a measured speedup.

The selected floor-material allowlist is:

| Family | Eligible existing terrain materials |
| --- | --- |
| Earth and clay | `dirt`, `packed_dirt`, `grass`, `clay` |
| Natural rock | `stone`, `metal_ore`, `limestone`, `coal`, `deeprock` |
| Mineral construction | `crushed_stone`, `rebar`, `reinforced_concrete` |
| Wood | `tree_trunk`, `planks` |
| Solid road | `country_road_solid` |

At the reviewed main baseline, this is exactly `isStructural()` plus solid country road.
The named materials define the selected policy; newly introduced materials/custom types
need an explicit eligibility decision. Air, `sand`, `water`, `snow`, `leaves`, adaptive roads
in both unformed and formed states, generic `custom` cells, other pallets, and derived
packed goods are ineligible. Planned material in a miniature is not real floor support.

Sand retains its existing lack of construction support. Excluding the entire adaptive-road
type avoids pallets above sloped surfaces while preserving the rule that road formation
and reversion do not change structural capabilities. No shape/geometry lookup is needed
to classify the supporting cell. Ground material states `dirt`, `packed_dirt`, and `grass`
are all eligible; this does not alter the ordinary timing/preconditions of soil transitions.
Placement, registration, and later floor changes use the same material predicate. Movement
collision alone is insufficient to establish eligibility.

### Q8 — Reservation overlap and blueprint composition

**CONFIRMED 2026-11-11: shared warehouse clearance and blueprint-empty composition.**
The author confirmed a shared one-cell aisle. Side and
corner air clearance can be owned by more than one warehouse. A pallet or potential cargo
cell of one warehouse cannot occupy any part of another's reserved envelope, including
its currently empty cargo space. R36 defines the symmetric compatibility check.

For two 1×1 bases at the same height, pallets at `(0,0)` and `(2,0)` have the common
empty column `(1,0)` between them. Their clearance overlap extends through the reserved
height z0..z0+5; each warehouse still meets its full one-cell-border requirement. Bases at
`(0,0)` and `(2,2)` can likewise share diagonal clearance at `(1,1)`. Stock and material
choices do not affect compatibility, and empty/disabled cargo columns remain exclusive.

While either owner remains registered, a shared cell cannot receive an ordinary block
or a new construction target. Unregister removes only that owner's claim. After the last
claim is removed, warehouse restrictions end; ordinary occupancy/support/other-claim rules
still apply. Claims must remain discoverable when warehouse object data is not resident or after save/load.

The selected tradeoff allows compact warehouse layouts. Lookup and removal must preserve
multiple overlapping clearance owners. Bounded spatial candidate lookup plus rectangle
intersection can implement the rule without storing a record for every reserved air cell;
Q12 selects per-chunk warehouse identity references, with concrete encoding left to implementation
review. This is an expected complexity tradeoff, not
a measured performance result. No global warehouse scan is allowed per local operation.

**CONFIRMED 2026-11-11 — blueprint composition.** Allow a warehouse inside blueprint-empty
space while the building is unfinished. A blueprint's bounding box may overlap the warehouse
envelope; none of its nonempty target cells may intersect that envelope. Apply this rule in
both orders: register within an active site or apply a building around a registered warehouse.
Empty cavities mean cells absent from the blueprint's target set, not unfulfilled targets
that are merely still air. The active instance's complete target set is considered; filled
target cells do not become cavities. This fits the existing blueprint cavity policy while
adding warehouse reservation checks.

For example, construction walls and a roof may surround the warehouse if their target cells
remain outside E. The roof must be above z0+5 over E, and walls outside its reserved cells.
Only current real terrain can support pallets: a floor miniature is insufficient, while
an already-real eligible floor can be used even if other parts of the building are unfinished.
Footprint recognition, physical air clearance, compatible claims, and ordinary construction
validity still apply. Empty stock or disabled columns do not make reserved cells buildable.
Blueprint application retains its foundation, target-emptiness, composed-world, and active
blueprint-box nonoverlap checks; this decision permits warehouse/site composition, not two
unfinished blueprint instances sharing a box.

Stock transfers remain allowed under warehouse rules because they change simulation-owned
cargo rather than extracting real terrain. Ordinary pallet removal remains forbidden inside
the active blueprint box, even after warehouse unregister. Conversely, completing the
blueprint does not unregister the warehouse or make its pallets removable. Each owner releases
only its own constraints. Unregister itself remains available under its ordinary stopped,
empty, obligation-free preconditions; it does not override the blueprint's terrain guards.

Warehouse registration checks locally indexed target cells within its bounded envelope;
blueprint application checks its target cells against spatially discoverable warehouse claims.
Coherent admission must prevent a concurrently admitted blueprint and warehouse from both
missing a conflicting claim. Missing state cannot establish compatibility. No whole-world
scan or scan of an entire large blueprint is required per warehouse registration, and stock
transfers do not rerun structural checks on the surrounding building. Fulfillment keeps its
existing five-neighbor structural bound; reservation admission adds a separate occupancy
guard. This is a bounded design, not a measured performance result.

### Q9 — Targeting, reach, dialogs, and actor overlap

**CONFIRMED 2026-11-11: player/observer controls, hit geometry/reach, transfer overlap,
and live modal behavior.** Preserve the player's existing one-slot inventory and Mouse1/E
action controls:

| Input and target | Result |
| --- | --- |
| Mouse2 on an unregistered candidate pallet | Validate the base and open creation |
| Mouse2 on any registered pallet or packed item | Open that warehouse's management dialog |
| Mouse1/E with empty hands, aiming at any member/item | Take one stored item |
| Mouse1/E with the warehouse material in hand, aiming at any member/item | Put that item |
| Mouse1/E with another material | Report rejection and retain the carried item |

Each player transfer takes about 100 ms and requires a fresh press. Preserve the current
release/repress and one-pending-transfer rules; do not queue held repeats or switch from
take to put while the control remains down. Rejection does not fall through to an ordinary
terrain edit. Stock, capacity, material, and lifecycle checks still govern each action.
These timed inventory transfers cover player mode; observer edits follow the policy below.

Observer mode retains Tab to switch putting/removing. Mouse1/E in putting mode adds one
unit of the currently selected material only if it matches the warehouse's material;
Mouse1/X in removing mode discards one stock unit. Both are instant one-per-press edits,
with no player hold timer or carried-inventory transfer. Mouse2 uses the same creation/
management dialogs as player mode. Key 9 selects pallets; existing keys 1–8 stay unchanged.

The author explicitly rejected automatically choosing the warehouse's material for observer
puts. A mismatch uses the same player-mode error reason/message, leaves the selected material
unchanged, and changes no stock or player inventory. These creative source/sink edits still
use authoritative warehouse stock accounting, empty/full and incoming-reservation checks,
retry protection, and normal target/range rules. They cannot break members or turn a failed
empty take into terrain removal. The observer material menu is deferred; its future addition
will change how a material is selected, not whether selection must match the warehouse.

Check four-block reach against the aimed pallet/item rather than the layout origin or
the layout slot that changes. A reachable hit on a full warehouse's cargo opens management
without exposing a pallet. The same warehouse is accessible from any side with an eligible
hit, even when the changed slot lies beyond four blocks. Ordinary occlusion and unknown-data
rules remain in force; nothing authorizes reaching through another obstacle.

**CONFIRMED 2026-11-11 — hit geometry and distance metric.** Both loose and registered
pallets use a single low axis-aligned target box spanning their cell in X/Y and extending
from z0 to z0+0.2. It approximates the visible planks; there are no per-board triangle or
gap tests. A ray above the low box continues through that cell to later geometry. The
visible target therefore does not occupy a full invisible cube above an empty pallet.
Packed items use the full unit cube, including the item sharing the pallet cell at z0.
These targeting shapes are separate from collision: pallets remain walk-through, while
packed goods remain solid for movement and supply no construction support.

After selecting the first intersected shape, retain the existing ordinary four-metre
nearest-vertex test against its full unit cell. This is not distance to the ray-hit point
or to a vertex of the 0.2-high box. The four-metre boundary is inclusive, and wrapped X
uses the nearest cell copy. Preserve the existing conservative ray limit of four metres
plus one cube diagonal so a reachable cell with a farther surface intersection remains
selectable. Unknown cells stop traversal. Menu opening, transfer targeting, and focus
highlighting share this result, preventing mismatched visible/usable targets.

The low box keeps selection close to the visible pallet while using one analytic shape
intersection rather than per-plank geometry. Reusing the ordinary reach test keeps the
established cell-based interaction range. This is a bounded design choice, not a measured
performance result.

**CONFIRMED 2026-11-11 — live modal behavior.** Warehouse dialogs release the cursor and
block movement, look, and tool input, while simulation and player physics continue. Couriers
can arrive, goods can be consumed, the player can fall or be displaced by newly occupied
cargo, and the dialog's displayed state/action availability updates with received changes.
Warehouse dialogs do not invoke the main pause menu's world-clock pause.

Opening a dialog cancels unfinished input holds; consume its mouse/keyboard events rather
than forwarding them to terrain edits or transfer tools. Escape closes this dialog first
without also opening the pause menu. Closing cannot replay clicks or trigger a new transfer
from an already-held control. Exact integration with map/blueprint UI transitions remains
implementation review; their controls must not operate behind the warehouse modal.

Revalidate every confirmed action against current authoritative conditions. Current stock,
incoming promises, accepted obligations, stopped state, and registration identity retain
their existing roles; live button availability is guidance, not authority. Creation still
revalidates its footprint and claims under R6/R50/Q14 without temporary preview reservations.
Update from relevant subscriptions/state changes without polling all
warehouses per frame. The live world lets the player observe and manage ongoing deliveries;
it also means inventory and action availability can change while the dialog is open.

R63 keeps confirmation local after movement: current members/cargo establish reach even if
the originally clicked item has disappeared. Creation still begins from the original pallet
cell and revalidates its current component. Out-of-range dialogs remain viewable, but cannot
mutate state until reach is restored. Confirmation uses distance instead of repeating camera
targeting while the dialog owns the cursor. Falling or displacement never pauses simulation
or cancels already accepted work.

**CONFIRMED 2026-11-11 — ordinary put/arrival overlap.** Extend the existing repacking
policy (Q1/R30) to otherwise valid manual puts and accepted delivery arrivals. Apply the
stock transfer and recover an intersecting player into known free full-body space, without
changing the layout or creating/deleting cargo. A player standing in the destination volume
cannot block the delivery or cause an otherwise valid manual put to fail. All ordinary
warehouse stock, material, reservation, and lifecycle checks remain in force.

Use the same bounded recovery semantics for both sources of goods. Recovery searches run
only on actual intersection and use current terrain plus derived cargo, independently of
GPU updates. No whole-world actor scan or per-warehouse/per-item free-space search is
required. Client recovery does not gate authoritative simulation progress. This preserves
one interaction rule while allowing displacement when a player occupies warehouse space.
Q26 selects the reserved base-level halo when ordinary bounded recovery fails. Missing terrain
or cargo data cannot prove a destination free; request bounded missing dependencies without
blocking the resource operation. The policy specifies warehouses, not all
future packed-block owners or ordinary terrain placement.

### Q10 — Allowed materials and pallet selection

**CONFIRMED 2026-11-11: eleven initial cargo materials, water exclusion, carried/stored
pallets, and observer selection.** The author accepted the current usable item materials except
water, then included the new pallet item. Liquid mechanics have not yet been designed.
The initial list is:

| Cargo group | Terrain/item IDs |
| --- | --- |
| Earth and loose materials | `dirt`, `sand`, `snow` |
| Mineral construction | `crushed_stone`, `rebar`, `reinforced_concrete` |
| Wood | `tree_trunk`, `planks` |
| Roads | `country_road_solid`, `country_road_adaptive` |
| New pallet item | `pallet` |

This consists of the ten existing placeable item types other than `water` at the reviewed
baseline, plus the new pallet. The `pallet` name denotes the new logical type; its numeric
encoding is an implementation choice. This is an explicit storage capability rather than
a permanent alias for
`isPlaceable()`. Future cargo-only resources may qualify when their item semantics are
defined. New terrain types do not qualify automatically. The separate floor allowlist in
Q7 does not restrict cargo: sand, snow, and adaptive-road items can be stored even though
they cannot support a pallet. Their packed cargo follows the same full-cube collision,
object inventory accounting, and quick-transfer rules, without loose-pile simulation.

Water is absent from warehouse material selection and rejected by authoritative registration,
material change, and stock/delivery admission. This restriction does not alter existing
terrain-water behavior or decide future tanks, containers, or other liquid logistics.
Liquid storage is outside this warehouse iteration until its mechanics receive a separate
design. No assumption that liquid can simply be represented as packed solid cargo is adopted.

Natural stone remains a terrain source for crushed stone, and grass/packed dirt for the dirt
item. Ores, coal, limestone, clay, and deeprock do not acquire new extraction/item-use rules
from this feature. Taking warehouse cargo preserves its stored identity without invoking
terrain-mining conversions. The client chooser and all mutation paths share R44's contract.

**CONFIRMED 2026-11-11 — pallets as carried items.** A player with empty hands can recover
an unregistered pallet in three seconds, receiving one pallet in the existing one-slot
inventory, and install it elsewhere in one second. These are ordinary terrain actions,
with their usual cancellation, validation, and coherent item transfer. The new location
must satisfy the pallet's support and no-stacking rules. No crafting recipe is added;
initial pallets come from observer mode, and players can subsequently move and reuse them.

A registered warehouse member cannot be removed even while empty: first complete its
unregister conditions and explicitly unregister it. An extracted pallet is an ordinary
item, not a portable warehouse with attached stock or registration. Stock transfers retain
their roughly 100 ms duration; that does not accelerate removing/installing terrain pallets.

**CONFIRMED 2026-11-11 — pallets as warehouse cargo.** Include the pallet in material
selection, raising the initial cargo list to eleven while continuing to exclude water.
One stored pallet uses one unit of stock/capacity and the shared packed-block representation,
including full-unit-cell collision. It remains object-derived cargo, not a terrain pallet
or a new structure member. Its packaging does not create an extra pallet resource.

Putting/taking a pallet through warehouse storage takes about 100 ms, with the same fresh
press and admission/conservation rules as other materials. Taking returns one ordinary
carried pallet; placing that item in terrain takes one second, and later removing that
terrain pallet takes three seconds. Cargo stacking does not invoke terrain pallet-on-pallet
placement rules, and stored pallets supply no support for construction.

**CONFIRMED 2026-11-11 — observer selection and stock edits.** Key 9 selects the pallet;
keys 1–8 retain their existing assignments. Q9/R47 retain the putting/removing controls,
instant one-unit edits, and material matching against the observer's actual selection.
Wrong-material puts use the same error as ordinary player mode. Do not auto-select or
silently substitute the warehouse's configured material as a workaround for today's
limited shortcuts. The author plans a general observer material-selection menu later;
that menu is not part of this feature and does not alter the cargo allowlist or put checks.

### Q11 — Expansion

**CONFIRMED 2026-11-11 — in-place expansion deferred; unregister required.** This iteration
changes warehouse size only through the existing lifecycle and a new registration:

1. Stop new automatic work, finish accepted obligations, and empty the stock. Manual takes
   remain available under Q4; an empty inventory alone is insufficient while obligations remain.
2. Explicitly unregister the stopped, empty, obligation-free warehouse.
3. Modify the now-ordinary pallet base under ordinary support/placement rules and any other
   remaining claims. For example, an unfinished blueprint still forbids pallet removal
   inside its box; unregister does not bypass that protection.
4. Register the resulting valid rectangle using the normal material-selection/creation flow.

This is a new warehouse registration, not migration of the old one. Select the central origin
again from the new footprint; its coordinate and hash-derived filling choices may differ.
Even if the new origin happens to occupy the old cell, registration identity and late-message
protection distinguish their lifetimes. Do not preserve old stock, obligations, or object state
as a hidden resize path. The completed unregister preconditions leave no goods/promises to
migrate; the new registration establishes its own current configuration.

Adding pallets into a registered border remains forbidden; no automatic footprint growth
or temporary edit mode is introduced. The confirmed active-column control remains a capacity
setting within an unchanged physical footprint and does not require unregister by this rule;
its stock/admission semantics are fixed by Q2.

Keep relative bounds and a fixed origin within each registration for reconstruction and
future compatibility. A later in-place expansion feature must retain that original origin
and define changes to claims, stored goods, active-column mapping, layout, and accepted
delivery capacity coherently. Those future commitments do not add an implementation task
or supported resize command to this iteration. Shrink/merge without unregister is likewise
outside this version's scope.

### Q12 — Missing warehouse state, discovery, and streaming ownership

**CONFIRMED 2026-11-12; identity and authority revised by Q16.** Each chunk intersecting
the full reserved envelope carries a small entry with WarehouseId/current registration
and bounds. Apply the same rule to wholly contained and cross-chunk warehouses, including
chunks containing only halo or upper cargo cells. The largest 7×7×6 envelope intersects
at most 2×2×2 chunks at any alignment, so one warehouse needs at most eight entries.
Authoritative material, C, I, A, lifecycle, and geometry belong to the simulation object.
Entries are derived spatial/claim projections, with no stock or active-count copy.

Create/retire entries with registration/unregister while preserving Q14/Q8's coherent
admission and shared ownership. Ordinary put/take updates the warehouse object; material,
active-column, promise, and stopped-state changes leave the fixed spatial entries unchanged.
Unregister removes only the departing registration from a shared clearance cell.

World-data authority enforces claims through its local index even when object state is
not resident. Restore enough discovery state before dependent edits after load; an empty
cache is not proof that no warehouse exists. Stock/management operations resolve the current
simulation object by identity. Choose index persistence/rebuild and lifecycle coordination
without per-operation whole-world scans or speculative searches for a metadata pallet.

Keep the distant visual allowance while the object snapshot is unavailable. Nearby
movement, targeting, and interaction request current object state; possible cargo cells
remain unknown until it arrives. Terrain air alone does not authorize traversal or edits,
even if the unknown stock might be zero or some columns disabled. Known halo clearance
contains no cargo and remains traversable under ordinary terrain/unknown-data rules, with
placement claims enforced. Current object data provides logical occupancy independently
of GPU preparation. Missing data never proves a free player-recovery destination.

Any intersecting chunk can discover WarehouseId. Its object snapshot describes the complete
footprint; the terrain chunk containing the layout origin does not need to be loaded.
Deduplicate one presentation owner per registration across references, with object revision
and subscription-lifetime guards through mesh/block handoffs, eviction, and delayed replies.
This removes the former physical-anchor dependency without requiring writable stock copies
in chunks. Q24 selects subscription/retention behavior and complete snapshots; concrete
encoding, limits, and integration remain implementation review, including teleport,
observer-to-player transitions, eviction, and resource pressure.

The index adds at most eight small discovery entries and lifecycle maintenance per warehouse.
It avoids neighboring-chunk searches for a stock owner and index rewrites per stock transfer.
Object state may remain active for simulation independently of visible terrain residency;
retention and recovery must support that lifetime. Container overhead, object retention,
publication, and capture costs require measurement; these bounds are not latency guarantees.

### Q13 — Markers, packaging, and visual freshness

**CONFIRMED — base markers/packaging on 2026-11-11; visual scheduling on 2026-11-12.**
Draw the material icon or disabled-column cross only on a free base pallet. Once that column
contains any cargo, omit its marker entirely, rather than drawing an occluded copy or moving
it onto an upper item. Empty columns of a partly filled warehouse still display their own
markers. When the last item leaves a column, its current material icon or disabled cross
reappears on the base pallet. Active-column settings remain available in the warehouse menu;
there is no duplicate cargo-top badge or through-cargo/world overlay.

The resource itself stays visible in each packed cube. Retain its ordinary material texture
and apply pallet artwork along the bottom/lower sides plus binding straps across the sides.
Those marks cover only part of the surface; gaps in their texture reveal the original resource.
The player can identify the cargo without opening the menu or relying on a material icon.
Transparent packaging texels do not make holes through the resource or alter full-cube
collision/support rules. A generic opaque crate replacing the resource texture would not
satisfy this appearance requirement. This same reusable packed appearance applies to future
workstation buffers and other owners, independently of warehouse layout and marker policies.

A suitable implementation is compositing resource and packaging samples with a coverage
mask in an opaque material shader. Outside the mask, keep the resource material; within it,
apply the pallet/strap artwork. This avoids requiring transparent-object sorting or a separate
coplanar packaging surface. It is an implementation recommendation, not a selected shader API
or measured performance result. Avoid z-fighting/double pallet geometry at the lowest item.
Use one coherent presentation snapshot for goods and marker occupancy, even when visual
publication is coalesced; a column must not show both cargo and its free-pallet marker.

**CONFIRMED 2026-11-12 — change-driven visual updates.** Prepare changed warehouse imagery
without deliberately waiting for a 100 ms interval or a quiet/debounce period. If several
updates arrive before visual preparation, derive the newest coherent snapshot once; there
is no obligation to display each intervening count. A warehouse that changed from C=10 to
11 and then 12 before preparation may render 12 directly, while both accepted transfers
retain their full resource/accounting effects.

Stock changes apply through their normal authoritative/predicted logical path. Client
collision, targeting, inventory, and player recovery follow the current applied logical
state without waiting for GPU work; remote changes become known through normal publication,
not instant cross-thread/network propagation. Normally aim for the next available frame.
Under load, preparation may be distributed across frames so rendering does not block the
simulation. The author accepts visual lag in that situation, without choosing a numeric
maximum delay or a hard frame deadline. The roughly 100 ms player transfer duration is
not a graphics-refresh timer.

Keep pending visual work eligible when more updates arrive; coalescing must not reset a
timer and postpone a busy warehouse indefinitely. Publish goods and markers together from
one visual snapshot. Unchanged warehouse sources need no rebuild/upload solely because a
new frame is drawn. Existing registration/revision/lifetime checks prevent delayed work
from resurrecting an unregistered warehouse or replacing newer presentation with older data.

Renderer representation and per-frame work budgets remain implementation review. Compare
compact per-warehouse GPU state/procedural instances with cached per-item instances built
only on change, using measurements rather than choosing a time budget from the interaction
duration. Coalescing saves repeated preparation work; it does not establish measured frame
smoothness. Marker rules do not permit assuming unloaded warehouse data proves a column
empty; streaming availability remains Q12.

### Q14 — Registration checks and consistency

**CONFIRMED 2026-11-11 — no temporary claim; current coherent confirmation.** Mouse2 checks
an initially valid candidate and opens material selection. This preliminary result grants no
member ownership or reservation. The world keeps running under Q9; a legal terrain edit or
admitted blueprint may change the candidate's validity while the player chooses a material.
Opening or leaving the dialog open does not block those changes.

Confirmation repeats the necessary current checks: full connected base/rectangle, actual
floor support, terrain clearance, eligible selected material, planned targets, and all
applicable claims. Publish the simulation object, member ownership, and spatial reservation coherently
only when those checks establish a currently valid warehouse. Do not accept a combination
of stale/mixed observations as proof of current compatibility or rely on the opening result.
Failed confirmation reports its cause and publishes no partial registration or reservation;
already-valid changes made by other actors remain intact. Concurrent admission follows
R6/R48's coherent conflict checks rather than allowing two incompatible structures to win.

Canceling before submission leaves ordinary pallets. There is no temporary spatial claim
to expire, recover, or clean up after a closed or abandoned preview, and cancellation cannot
release another registered owner's claim. A submitted confirmation and its eventual result
remain distinct from an unsubmitted preview; normal operation identity/retry rules prevent
duplicate registrations. Closing UI does not itself unregister an accepted warehouse.

The maximum valid clearance envelope has 294 cells, plus at most 25 directly-below support
cells and the already-bounded recognition/lookup work. Loading, index access, and allocation
costs are not included in that cell-count bound. Rechecking this local candidate avoids a
temporary-claim lifecycle while accepting that creation can fail after a valid preview.
This is an algorithmic tradeoff, not a measured latency or throughput claim. Concrete
snapshot/version/commit mechanics remain implementation review under the existing service
architecture; the accepted result must satisfy the coherent publication contract.

### Q15 — Courier loading and unloading points (WH-02)

**CONFIRMED 2026-11-12: courier access from any traversable side.** Use the cells directly
beside the base in its reserved halo as potential loading/unloading endpoints. For inclusive
base bounds xmin..xmax, ymin..ymax at z0, the candidate set is:

```text
{(xmin-1, y, z0), (xmax+1, y, z0) | ymin <= y <= ymax}
  union
{(x, ymin-1, z0), (x, ymax+1, z0) | xmin <= x <= xmax}
```

Exclude the four diagonal-only halo corners. A w×h base has 2w+2h candidate cells:
four for 1×1, twenty for 5×5. Use locally unwrapped X for geometry and canonical wrapped
coordinates for identity, consistent with the footprint/index rules. Endpoint availability
uses ordinary routing/traversability rules, including their support and data-availability
requirements. Reserved air does not guarantee a walkable floor or a connected path.

When planning a delivery, select a reachable endpoint at each participating warehouse.
The courier interacts with the warehouse as a whole; the resource command addresses its
registration rather than the visible item nearest the courier or a named cargo slot.
Do not require reaching the layout origin or walking into the cargo footprint.
The deterministic layout still chooses the added/removed slot. Candidate endpoints stay
unchanged when stock, incoming promises, material, active count, or layout changes; route
availability may change when relevant surrounding terrain changes.

Registration does not search for or require a usable route. A warehouse satisfying its
ordinary geometry/support/claim rules may be manually operated even if courier access is
absent. Manual access still uses the player's targeting/reach rules. New automatic
deliveries require a route as well as material, stock, capacity, lifecycle, and other
start prerequisites; an old plan alone does not create an accepted obligation.

After departure, the existing
[travel policy](../../docs/game-vision.md#responding-to-world-changes-during-travel)
applies: disappearance of the chosen endpoint's floor or another route segment does not
change accepted timing, payment, or successful handover. No routine route recheck, replanning,
waiting-for-access queue, or loss of cargo is introduced. Visual adaptation remains separate
from authoritative completion. Shared aisles also retain the established no-NPC-congestion
rule; potential endpoints do not become exclusive docks or per-courier spatial claims.

This choice avoids entrance configuration and lets a route use any suitable side. Endpoint
geometry is a bounded function of the fixed footprint and needs no rebuilding on every
stock transfer. It adds up to twenty candidate goals instead of one fixed entrance;
the routing algorithm chooses how to consider them without a prescribed series of separate
path searches. Route search, caching, supplier matching, and scheduling remain separate
logistics work. The fixed-entrance alternative is not selected. These are gameplay and
work-shape tradeoffs, not measured route-planning performance.

### Q16 — Simulation-owned warehouse state versus pallet-owned metadata

**CONFIRMED 2026-11-12: adopt persistent simulation warehouse objects.** The author chose
this basis after explaining that the original pallet-metadata design mainly reused existing
world persistence before simulation state existed. The object model supersedes that storage
binding while preserving count-only inventory, deterministic layout, capacity, and gameplay.

WarehouseId identifies a registration lifetime independently of coordinates or member blocks.
Its canonical simulation record owns material, C, aggregate incoming I, active count A,
enabled/stopped intent, geometry, and warehouse lifecycle accounting. Simulation task records
own their task facts, cargo, and individual promises; aggregate and task facts remain coherent.
No pallet or terrain-chunk record owns a second stock/configuration copy. Stopped objects
remain available to manual interaction, and object lifetime does not depend on visible
terrain residency or whether automatic work is currently enabled.

World-data authority owns terrain, member pallets, and their real supports. Every chunk
intersecting a warehouse envelope has a derived identity/bounds lookup entry, including
warehouses wholly inside one chunk. Registration/unregister coordinate object existence,
member protection, and claims before publishing success; ordinary logistics and active-count
changes update simulation state without rewriting pallet metadata or fixed spatial entries.
Coherent object snapshots support client inventory, targeting, collision, and rendering.
Publication may be coalesced without making logical transfers wait for clients or GPU work.

Retain the original central coordinate as a fixed layout origin for relative bounds and Q5's
hash. It has the same arithmetic and future-expansion stability, but no physical pallet is
privileged. Re-registration creates a new identity even if its origin and hash repeat. A chunk
reference resolves the object by identity; the chunk containing the origin need not be loaded.
Distant omission is allowed while object data is missing, with Q12's near-data guards intact.

Separate logical authority, runtime placement, spatial indexes, and durable encoding.
Existing persistence already captures players, blueprints, and unfinished work alongside
terrain; extend coherent capture/recovery to objects/tasks/cargo rather than adding an
independently committed simulation autosave. Exact representations and coordination remain
technical design. No simulation object store or full economic simulation is implemented by
this documentation decision.

The intended benefit is keeping frequent stock/reservation/task changes in the simulation
domain. This does not prescribe one thread, a global lock, per-item messages, or unrestricted
writes by all simulation workers. Safe access and cross-owner/source-destination coordination
remain necessary. The alternative world-owned model with batched exclusive access was viable;
no throughput advantage from the ownership choice alone has been measured. Compare mutation,
publication, retention, capture, and recovery costs during implementation.

Q17 retains world-data-owned player inventory. The remaining technical boundaries are
explicit: Q18 addresses atomic transfers and coherent capture; lifecycle admission must coordinate objects with terrain/claims; persistence must
capture one resource-consistent outcome; object lookup/recovery must avoid a world scan.
The updated requirements and criteria below use object authority and a geometric origin.

### Q17 — Player inventory and manual warehouse transfers

**CONFIRMED 2026-11-12: retain player inventory in world-data service.** Warehouse objects
remain simulation-owned under Q16; the player's authoritative carried item remains in the
world-data player record. Mining and ordinary terrain placement preserve their existing
local terrain/inventory transition. A stopped warehouse remains manually usable under its
ordinary rules; client predictions and movement checkpoints are not inventory authority.

Coordinate a manual warehouse transfer between these owners as one logical resource
transition, preserving simulation precedence. Acceptance updates stock and player inventory
once; rejection leaves both unchanged. Retry and save/recovery must not expose partial or
duplicate resource effects. The client submits one transfer intent, rather than independently
committing a warehouse mutation and an inventory mutation. Concrete server routing, access,
retry identity, and save coordination follow Q18's accepted baseline; concrete access
execution follows Q22 and retries follow Q23; concrete integration remains implementation review.

This confines additional player/warehouse coordination to manual interaction. Ordinary
simulation logistics need no player-specific synchronization. Moving player inventory into
simulation was considered; it would instead put ordinary mining/placement across the
terrain/inventory boundary. That alternative is not selected for this iteration.

### Q18 — Atomic transfers and coherent durable capture

**CONFIRMED BASELINE 2026-11-12; initial execution selected by Q22 and retry lifetime by Q23.** The author accepts
coherent live transitions and common save capture without disk synchronization per item,
qualified by simulation throughput: rare manual transfers must not determine the cost of
frequent automatic work. Construction is a representative cross-owner workload under Q19;
Q20 reopens narrowly measured accounting exceptions for comparison without selecting one.
Separate logical atomicity in live state, a coherent save cut, and durability of the saved
result. There is one authority per fact, with an invariant spanning those facts; warehouse
and player records are not competing writable copies of the same inventory.

For a take, the legal transition is `(warehouse C=10, hand empty)` to `(C=9, hand one item)`.
Neither `(9, empty)` nor `(10, one item)` may become an accepted resource state or a saved
outcome of that transfer. Machine stores can execute sequentially; the intermediate values
must be inaccessible to conflicting authoritative reads/writes and capture. Separate client
snapshots may lag under the existing publication rules, without authorizing partial effects.

Accepted live-state baseline:

1. Resolve records and prepare fallible resources before mutation: needed data, allocation,
   bookkeeping, retry/result storage, and publication capacity. No record is decremented
   merely because a later increment is expected to work.
2. Acquire a coordinated mutation opportunity for the affected player slot and warehouse,
   respecting their execution owners, simulation priority, and save capture. Revalidate
   material, inventory, capacity, registration, and retry identity against accepted state.
   Q22 selects sequential execution on the existing service worker for first-version warehouses;
   no cross-thread handshake between these state domains is required. Future executor/grant
   variants remain alternatives, not first-version prerequisites.
3. Commit both inventory changes and their required bookkeeping without remaining recoverable
   failure, allocation, disk/network I/O, or waiting inside the commit section. Publish the
   accepted outcome after both sides are complete. Contention/failure before commit defers
   or rejects the whole operation. A repeated intent returns its existing outcome without
   applying the transfer again while its result is retained; Q23 defines retirement and
   session resynchronization. Concrete bounded history/acknowledgment encoding remains review.

Accepted save baseline: extend the existing coordinated capture/WAL path to simulation
objects, tasks, cargo, and reservations. Establish one cut at complete operation boundaries,
with in-flight commits finished or deferred; equal timestamps alone do not establish a
consistent cut. Freeze/capture the relevant world, player, and simulation versions under
that common boundary. Reuse the existing pause/source-hold approach as the initial baseline,
then release captured sources safely so live work can resume independently of disk syncing.
Do not promise a fixed pause duration or full-world copying; measure capture, retained-source
memory, and writer backpressure at scale. Incremental records can describe a coherent cut.

Encode the participating changes in one journal transaction with the existing framing,
commit footer, integrity checks, and platform synchronization. A successful durable commit
covers the entire cut. Restore only complete valid transactions under existing recovery
rules; an incomplete final append cannot install just one inventory side. A complete record
whose acknowledgment was lost may still recover, so acknowledgment uncertainty is distinct
from an incomplete tail. Corruption is handled by the existing error policy, not silently
skipped as an ordinary partial write. Journal writing alone cannot repair a mixed snapshot;
coherent capture is required first.

This uses database principles for specific game transitions inside one server process and
one coordinated save system. It does not select a database dependency, independently
committed saves per owner, or a general distributed transaction protocol. Current persistence
already groups world/player/blueprint/unfinished-work data, but simulation capture and the
cross-owner live commit would be new integration work.

Accepted gameplay and durable-save acknowledgment remain distinct. This baseline does not
force a disk sync for each item or promise that every accepted interaction survives a crash.
Recent unsaved progress can be lost under the existing save policy, while the recovered
resource state remains coherent. A future per-operation durability guarantee would require
its own cost/acknowledgment decision; no numeric crash-loss window is selected here.

Before implementation, specify conflict ordering and deadlock avoidance, prepared-resource
ownership, retry/session lifetimes, capture gates, and behavior after uncertain commit I/O.
Validate competing player/simulation operations, failures before live commit, capture racing
transfers, repeated/lost replies, and crashes at journal boundaries. Acceptance of this
baseline does not select a per-item queue, lock, transaction object, or thread handoff.

### Q19 — Construction storage ownership and handback

**CONFIRMED 2026-11-12; refined 2026-11-13.** The dedicated
[construction state ownership spec](construction-state-ownership.md) defines actual simulation
ownership of nonempty blueprint targets, including storage, mutation, and persistence. Cavities,
foundations, and other terrain stay world-data-owned. Chunk references plus immutable definitions
identify targets; the earlier in-cell ownership-marker proposal is superseded.

Clients subscribe to construction progress separately from terrain. Targets materialize into
current chunks in bounded portions after the last fill, preserving unrelated edits. The frame
and active-site restrictions remain until the whole transfer finishes. Composed physical/logical
reads, bounded structural validation, and coherent shared saves remain required. Runtime changes
and performance validation are pending; Q21 records the ordinary-soil design assumption.

[Alternatives](construction-state-ownership.md#q2--ownership-and-execution-alternatives) retain
whole-box ownership, world-data terrain with site-defined legal actions and batched technical
access, and queued world-data operations. Source ownership and safe execution access remain
separate design dimensions.

### Q20 — Measured exceptions to resource accounting

**DEFERRED FOLLOW-UP — consideration authorized 2026-11-12, no exception selected.** The author is
open to best-effort accounting at ownership boundaries if rare loss/duplication is demonstrated
in practice and the simplification or throughput gain warrants it. Q18 remains the baseline;
the existing conservation criteria apply until a concrete exception is agreed.

Compare a safe coherent batched path against a precisely specified best-effort alternative,
separating live concurrency failures from coherent loss of recent unsaved progress. Measure
errors per relevant boundary operation and per world-hour, cumulative resource drift, and
whether a repeatable interaction or retry can amplify failures. The fraction of all NPC
actions represented by manual transfers is not an error-rate denominator. Exercise contention,
repeated/lost replies, saves racing mutations, and interrupted saves/recovery; report workload,
sample size, and uncertainty when no failures are observed. No allowed error rate or loss
budget has been chosen, and no performance benefit from relaxing accounting has been shown.

Even an adopted resource-loss exception would not permit unsafe concurrent mutation of
containers, invalid references, or use after unloading. Such memory hazards can corrupt much
more than one resource count. Data-access safety must hold in every candidate.

### Q21 — Optional soil transformations

**REFINED 2026-11-13: retain grass, remove compaction.** The
[construction soil model](construction-state-ownership.md#q6--soil-and-compact-physical-state)
uses one soil material without manual/timed compaction. World-data clears grass/cancels growth
below miniatures atomically with admission. Soil targets remain bare and timer-free throughout
building and materializing; after the whole site completes, world-data initializes ordinary
grass growth on exposed soil, preserving pending work and deadlines through saves/retries.
Simulation still needs only immutable definition materials plus progress, not grass overrides.

[PR #64](https://github.com/bacher/zig_engine/pull/64) already made direct blueprint fulfillment
writes target-local. Application covering and world-data grass machinery can be reused, with
composed exposure checks and the removal of compaction prerequisites. Existing runtime rules
remain described in [block placement](../../docs/block-placement.md#simulation-time-and-transformations)
until implementation and explicit ruleset/save gates. No measured performance gain is claimed.

### Q22 — Initial execution of simulation-owned warehouses

**CONFIRMED 2026-11-12: separate state domains on the existing service executor for the
first warehouse implementation, validated by representative load.** Selected data authority
(Q16/Q17/Q19) remains unchanged. Retain independent and partitioned execution as alternatives
for comparison if the shared executor limits the target workload.

| Choice | Execution of authoritative mutations | Benefit | Cost / limitation |
| --- | --- | --- | --- |
| Separate state domains on the existing world-service executor | World-data and simulation operations run serially on one executor | Direct local calls; manual transfer, registration/claims, and capture boundaries need no cross-thread ownership handshake | One mutation executor; terrain work, publication, and simulation compete for its time |
| Separate world-data and simulation executors | Each runs its own state; coordinated access handles cross-domain operations | Independent CPU progress; routine simulation-only stock work stays off the terrain executor | Manual transfers, lifecycle, snapshots, and capture need an explicit safe coordination protocol |
| Partitioned simulation executors | Independent simulation partitions progress concurrently | Potential use of more cores for automatic work | Partition identity, cross-partition transfers, scheduling, readers, and save barriers add design work |

The selected first warehouse baseline is the first choice, scoped to warehouse integration
and its representative tests. Introduce a distinct simulation-state module/record domain and
operation API; do not put stock back into pallet metadata or make chunks its persistence owner.
Executing both modules on one worker does not merge their data ownership. Future construction
targets likewise remain simulation records under the selected construction spec.

In this baseline, automatic operations on simulation-owned records call their local API
within bounded work batches. Do not enqueue a world-data command, acquire a player-specific
lock, or allocate a transaction object for every simulated item solely to use this topology.
External client intents still enter through the existing asynchronous boundary. Manual transfers
prepare resources, revalidate, update both domains without yielding or exposing intermediate
state, and then publish results. Registration similarly coordinates the object with terrain
validation and claims. Retry identity/retention still needs a protocol; serial execution alone
is not deduplication.

Extend shared capture to simulation records at complete operation boundaries, retaining source
holds while readers/encoding require them. A single mutation executor does not make concurrent
snapshot readers safe by itself. Existing independent read/encode/write work can remain outside
the mutation executor; disk/network waits and GPU work do not belong in its live commit section.

The current service drains request batches and prepares/publishes dirty meshes on its worker.
Reusing it unchanged does not demonstrate sustainable simulation throughput. Give competing
work bounded turns and apply simulation conflict precedence explicitly, preserving command and
save fences; ordinary FIFO order does not establish that priority. Measure throughput and
progress under streaming, many changing warehouses, publication, and save pressure. No fixed
simulation tick, target warehouse count, global CPU budget, or fairness threshold is selected.

If terrain/publication work measurably limits the chosen warehouse workload, compare independent
simulation execution or detached pure preparation before treating the implementation as ready. Independent
simulation would still need safe shared reads and Q18 coordination; it cannot simply access
mutable world-data/player arrays directly. Shared-state storage does not imply one thread per
warehouse or mandatory whole-world polling.

This selection is not a claim that one executor can meet the full future economy target.
Moving to more executors later requires real work on access, ordering, snapshot lifetimes, and
save coordination; a clean module boundary reduces coupling but does not make migration free.
The ownership/storage alternatives in the construction spec remain separate from this execution
choice. No runtime implementation has begun in this documentation change.

### Q23 — Command identity and retry lifetime

**CONFIRMED 2026-11-12: live-session deduplication, then state resynchronization after
session changes, without a durable per-click result history.** Use a stable identity for an
external warehouse intent, keyed by server/world session, client session, and a monotonic
command sequence within that client session. Retransmission carries the same identity and
payload. Current per-endpoint request IDs correlate transport replies; allocating a new transport request is not permission to
repeat a resource effect. Warehouse identity refers to a registration lifetime, not a location.
A later registration on the same pallets cannot receive an old command.

Deduplicate within the current live session. An already pending
intent remains one pending operation; a completed intent whose result is retained returns its
recorded result without rechecking it as new work. Reusing an identity with different contents
is rejected. Prepare bounded result/identity storage before committing effects. After safely
acknowledged results are retired, retain an ordered retirement frontier or equivalent bounded
recognition so an old command is rejected/resynchronized rather than executed again. Exact
window/admission bounds and acknowledgment rules remain protocol review; a blind time-based
cache expiry cannot establish that replay is safe.

Do not require a durable per-click result history across process restart or world reload in
this first version. Renew the server/world session, reject old-session requests and replies,
and resynchronize authoritative inventory and objects. Do not automatically relabel an uncertain
old intent as a new command after reconnect/reload. When rotating a client session within a
live world, resolve or fence its already admitted intents before establishing the usable
resynchronization boundary; session retirement does not silently cancel accepted commands.
Unacknowledged work may have been included in the common save; losing the reply does not establish failure. This keeps the agreed coherent
save/crash-loss policy without promising durable exactly-once clicks across sessions.

Result replay acknowledges the operation; it must not overwrite newer inventory/object state
with an old response snapshot. Closed dialogs do not cancel already submitted commands. These
transport bookkeeping costs apply to externally submitted commands; automatic simulation work
uses task identity and valid lifecycle transitions for its own exactly-once effects, not a
player-session result-cache lookup for every internal stock update. Persistent delivery cargo,
reservations, and completion still require coherent task recovery under Q3/Q18; retiring a
client session does not retire accepted simulation obligations.

This contract follows the existing persistence distinction between retained local intent and
future wire retransmission. Field widths, bounded result-window/acknowledgment mechanics, and
wire encoding remain implementation review; no durable cross-session retry service is selected.

### Q24 — Warehouse object subscriptions and client retention

**CONFIRMED 2026-11-12: independent object subscriptions and compact complete snapshots
for the first implementation.** Q12 supplies envelope-wide discovery, independent identity,
and unknown-data guards. Q25 records incremental publication as a follow-up to evaluate.

On the first reference from a subscribed terrain chunk, request/subscribe to the warehouse by
identity. Block and mesh modes use the same object channel. Multiple chunk references share
one subscription/cache entry per registration; changes between mesh and block representations
must not create duplicate owners or discard an otherwise needed snapshot. Near collision,
targeting, player recovery, open management, and pending commands can retain object state in
addition to terrain references. Requests are driven by reference/dependency changes, not a
per-frame scan of all warehouses.

Use a compact complete object snapshot initially: identity/lifetime, revision, layout
origin/bounds, material, C, I, A, enabled/stopped intent, and the lifecycle summary needed for
management. No per-item positions, column arrays, full delivery list, or writable stock copies
are required. C and A derive occupied slots; I informs admission but does not create collision.
Initial subscription installs a current snapshot and change tracking at a coherent boundary.
Later updates carry sufficient session/subscription lifetime and revision identity to reject
stale payloads. Full snapshots allow intermediate versions to be coalesced without a chain of
numeric increment/decrement messages that could be applied twice or out of order.

After accepted changes, schedule publication to interested clients. Coalesce pending state to
the latest complete snapshot without introducing a debounce delay or suppressing an operation's
required result. Resource operations still all execute; client presentation need not show each
intermediate count. Unregister publishes retirement for that registration. A late snapshot
cannot resurrect it, and late operation replies follow Q23 without regressing current state.
Stock/configuration updates do not rewrite fixed chunk discovery entries or require rebuilding
ordinary terrain meshes solely to display changed cargo.

Release a client subscription after its final chunk reference and functional retention reason
are gone. Keep logical state needed by movement/interaction independently of GPU residency.
Within bounded client budgets, prioritize near dependencies over distant presentation. Optional
distant cargo can remain undisplayed while data is unavailable; memory pressure must not turn
unknown possible-cargo cells into known empty space. Choose admission limits and near-retention
integration during implementation, using existing terrain-streaming requirements rather than
inventing a fixed warehouse distance now. Observer-to-player transitions, teleport, late replies,
and lost subscriptions must reestablish required known data before dependent actions.

If a subscription has lost freshness/continuity, resynchronize rather than using an old image
indefinitely as current authority. Logical occupancy may use accepted prediction/reconciliation
under existing contracts, but never GPU completion as proof. Ordinary known halo clearance
retains Q12's traversability and placement restrictions even when cargo state is unknown.

This is client retention, not canonical object lifetime. An unobserved warehouse and its
accepted work continue in simulation and persist through save/load. Dropping the last client
reference neither destroys stock nor cancels obligations. Canonical server residency/loading
and cold-object eviction remain a separate resource-budget decision. Concrete wire formats,
container choice, cache limits, and rendering representation remain implementation review.
The follow-up in Q25 may replace some subsequent full updates only after separate evaluation.

### Q25 — Incremental publication follow-up

**DEFERRED FOR EVALUATION 2026-11-12.** The author explicitly requests consideration of a
later transition from full object updates to increment/decrement messages. Q24 remains the
first implementation. This follow-up concerns server-to-client state publication, not the
already defined authoritative put/take operations, command retry protocol, or save authority.

Evaluate revisioned count changes (for example signed changes to C and I), together with a
policy for configuration/lifecycle changes. Keep complete snapshots for initial subscription
and resynchronization. Never apply an unqualified `+1` or `-1`: updates need registration and
subscription/session identity, a known base revision, and a resulting revision or equivalent
sequence contract. Repeats cannot apply twice, obsolete registrations cannot change new ones,
and a missing/reordered dependency must trigger the selected recovery rather than silently
leaving a wrong count. A full snapshot may reestablish the baseline without replaying old deltas.

Changes that form one object transition remain coherent on the client: delivery handover's
`C += q` and `I -= q` cannot be published/applied as unrelated accepted states. Define handling
for material, active-capacity, and lifecycle changes, including when a full replacement is
simpler than a delta. Unregister retirement, Q23 command-result reconciliation, and Q24's
logical occupancy/unknown-data rules must survive the new encoding. A late acknowledgment
must not apply an already published count change again.

Preserve coalescing: a combined delta must describe its declared revision interval completely;
intermediate events cannot merely be dropped from a dependent chain. Do not require one
message per resource operation or a permanent per-item publication history. Bound any retained
baselines, replay buffers, subscriber state, and recovery traffic.

Compare against already-coalesced full snapshots using representative warehouse churn and
subscriber counts. Measure bytes, serialization/application CPU, allocations, retained memory,
and resynchronization cost under duplicate, reordered, and missing messages. The expected
bandwidth benefit is a hypothesis; record whether it justifies the additional protocol state.
Evaluation may retain full snapshots, select deltas, or select a hybrid. No switch date,
encoding, replay-buffer size, or performance benefit is predetermined, and this follow-up
does not block initial warehouse implementation.

### Q26 — Reserved-halo displacement fallback

**CONFIRMED 2026-11-12: use the warehouse's reserved one-cell surrounding passage when
ordinary recovery fails, preferring its loaded parts.** Registration and continuing claims
protect this clearance from terrain placement, other warehouses' cargo, and construction
targets. It provides a bounded local destination set rather than requiring a distant teleport.
This applies to R30 repacking, otherwise valid manual puts, and accepted delivery arrivals.

For a w-by-h base at z0, consider the border of its expanded (w+2)-by-(h+2) rectangle at
z0, excluding the pallet rectangle. There are `2w + 2h + 4 <= 24` cells including corners.
Corners are valid recovery destinations; Q15's exclusion of corner courier endpoints does
not restrict player displacement. Choose a ready candidate with current full-body clearance,
preferably the nearest, with a stable tie order as an implementation detail. The move is a
recovery relocation, so no walkable route or swept path through the cargo is required.

Center the player's horizontal position within the chosen halo cell and put the feet at
z0. The current body is 0.6 blocks wide and 1.8 blocks tall, fitting within one horizontal
cell and two vertical cells of the reserved six-cell height. Validate the whole body against
current logical terrain/cargo, playable bounds, and wrapped coordinates; GPU mesh residency
is irrelevant. R37 protects floors under pallets only. The halo guarantees an empty volume,
not a supporting floor; this decision adds no new floor/admission rule. Existing recovery
permits clear unsupported space, and ordinary gravity applies after relocation.

Having some warehouse chunk loaded is not by itself proof that a candidate's whole body is
known: base-level cells may be in another vertical chunk, and a body starting at local z=31
crosses the vertical chunk boundary. Prefer candidates with all required logical data already
available. If none is ready because of missing data, retain/request the nearby halo/body
sources through Q24 and retry on relevant data/state progress. Bound the search to this
warehouse; do not scan or load the whole world. Temporary missing data keeps player movement
blocked under existing recovery behavior, not the simulation or delivery. Do not infer free
space from a missing cache entry or a stale registration.

Before applying the recovery, check that the player still intersects cargo and the current
registration/data still justify the destination. If the overlap disappears while waiting,
resume ordinary movement without performing the stale relocation. If relevant state changes,
reconsider using current collision/ownership. Any contradictory occupied halo or unavailable
source follows conservative existing missing/collision handling until resolved; no inventory
rollback, goods deletion, or arbitrary unknown-space fallback is introduced.

Implementation review remains for bounded candidate ordering, dependency wakeups/pinning,
and integration with the existing motion reset. The selected destination policy closes the
displacement destination choice; full-body/missing-data checks preserve existing recovery
constraints. [Model validation](../../docs/validation/warehouses.md) covers the bounded halo
and body-fit arithmetic, including the vertical chunk-boundary counterexample.

## Acceptance Criteria

These criteria cover Q1–Q18, Q22–Q24, and Q26, including inventory authorities, shared execution,
retries, subscriptions, displacement recovery, and
the save baseline, plus repository invariants. Concrete
data/API integration and implementation phases still require review; they do not claim
that runtime implementation or performance validation has been completed.

- AC1: GIVEN observer mode WHEN selecting a pallet THEN it can be placed without a crafting
  recipe, appears approximately 0.2 blocks high, and does not block player movement.
- AC2: GIVEN a pallet below a placement target WHEN placing another pallet directly on it
  THEN client and authority reject without changing terrain or inventory.
- AC3: GIVEN each complete rectangular base with X/Y lengths 1..5 and valid surroundings
  WHEN registration is confirmed THEN the footprint contains exactly X×Y member pallets.
- AC4: GIVEN a hole, L-shaped base, or oversized candidate WHEN registration is attempted
  THEN it fails rather than silently registering a different subrectangle.
- AC5: GIVEN a 3×3 base WHEN any otherwise-air cell in its 5×5×6 clearance envelope is
  obstructed, including a diagonal bottom neighbor or z0+5 cell, THEN registration fails.
- AC6: GIVEN an eligible pallet within four blocks WHEN Mouse2 opens creation and the
  player cancels THEN no warehouse object or reservation is published.
- AC7: GIVEN a valid registration preview WHEN a conflicting mutation precedes confirmation
  THEN confirmation cannot create overlapping members/claims or a partial registration.
- AC8: GIVEN a registered warehouse WHEN its object snapshot is loaded without all member chunks
  THEN saved relative bounds suffice to reconstruct the complete cargo footprint.
- AC9: GIVEN a fully active N-column warehouse WHEN stock reaches 4N, 4N+1, 5N, 5N+1, 6N
  THEN layout follows four-per-column, fifth-level, then sixth-level filling in that order.
- AC10: GIVEN equal accepted object layout state WHEN reconstructed on client, authority, or
  after save/load THEN occupied cargo cells agree, beginning at z0 rather than z0+1.
- AC11: GIVEN stored goods WHEN inspecting terrain and testing movement/support THEN terrain
  still contains only pallets/air, goods block movement, and goods supply no construction support.
- AC12: GIVEN a packed material WHEN put/take succeeds THEN its identity is preserved,
  packaging creates no extra item, and the player action duration is material-independent.
- AC13: GIVEN empty/full stock or mismatched material WHEN take/put is requested THEN both
  prediction and authority reject their locally known invalid action; authority preserves stock.
- AC14: GIVEN several targetable items of one warehouse WHEN the same legal put/take is
  aimed at different items THEN it addresses the same WarehouseId and chooses the same layout slot.
- AC15: GIVEN a competing accepted transfer or a rejected prediction WHEN replies reconcile
  THEN warehouse plus carried/delivery goods have no duplicate or lost ownership.
- AC16: GIVEN a registered warehouse WHEN ordinary edits or construction target admission
  would change protected members or fill reserved air THEN the mutation fails through every actor path.
- AC17: GIVEN nonzero stock, enabled automatic work, or an outstanding accepted obligation
  WHEN unregister or material change is requested THEN it is unavailable in management
  and rejected by authority if submitted from a stale dialog.
- AC18: GIVEN a stopped empty warehouse with no outstanding obligations WHEN unregister
  succeeds THEN ordinary pallets remain and that warehouse's claims cease together,
  without removing another warehouse's claims on shared clearance.
- AC19: GIVEN a stocked warehouse WHEN active column count decreases THEN a suffix becomes
  disabled and stock is conserved; its empty base pallets display red crosses while occupied
  columns emit no marker. Goods may repack from count/configuration alone, with detailed
  reduced-capacity policy under Q2.
- AC20: GIVEN mesh-only terrain subscriptions and a warehouse subscription WHEN stock changes
  THEN the object update reaches the client and updates derived goods independently of terrain meshes.
- AC21: GIVEN visible member chunks without the object snapshot WHEN drawing the distant warehouse
  THEN missing cargo is permitted; WHEN current object data arrives THEN contents become
  renderable even if the terrain chunk containing the layout origin is still absent.
- AC22: GIVEN an eviction, mesh/block handoff, or re-registration at the same origin WHEN a
  late old response arrives THEN it cannot duplicate contents or revive the previous registration.
- AC23: GIVEN a save during accepted warehouse/player changes WHEN reopening THEN stock,
  carried items, material, bounds, and registration describe one coherent captured state.
- AC24: GIVEN many unchanged distant warehouses WHEN simulation runs or the camera moves
  THEN no per-item terrain updates, global warehouse scans, or unchanged-source uploads are required.
- AC25: GIVEN chunk-boundary and wrapped-X footprints WHEN validating, querying, drawing,
  or restoring THEN one physical footprint/registration is used and finite Y/Z limits are respected.
- AC26: GIVEN the same origin, bounds, quantity, and active-column configuration reached through
  different histories WHEN deriving or restoring warehouse contents THEN occupied cells
  agree without persisted column heights, per-item positions, or previous layout state.
- AC27: GIVEN repacking that overlaps the player and an available known free full-body
  destination WHEN the new logical layout is applied THEN the player is displaced to a
  validated free position, warehouse quantity and carried inventory stay unchanged, and
  collision does not wait for the corresponding GPU geometry upload.
- AC28: GIVEN fully active 1×1 storage with C=4 and I=0 WHEN three otherwise eligible
  one-item incoming deliveries attempt to start THEN two are accepted, I becomes 2, C stays 4,
  and the rejected start has no payment, source-cargo, task, or reservation effects.
- AC29: GIVEN C=4 and I=2 in that warehouse WHEN a player attempts a one-item put THEN
  prediction rejects when the reservation is known, authority always rejects, and the
  carried item and stock remain unchanged despite two visibly empty cargo cells.
- AC30: GIVEN the two accepted deliveries and C=4/I=2 WHEN their handovers succeed in
  either order THEN state becomes 5/1 and then 6/0, the respective cargo transfers once,
  and neither arrival is rejected for needing extra unreserved capacity.
- AC31: GIVEN competing starts/puts for the last unreserved place WHEN admission runs
  THEN accepted effects keep C+I within 6N and no resource or promise is counted twice.
- AC32: GIVEN C=0 and I>0 WHEN taking stock or rendering contents THEN a take fails and
  no incoming item is rendered as stored cargo; reservations alone do not create stock.
- AC33: GIVEN a successfully processed delivery start or handover WHEN it is retried
  THEN payment, cargo ownership, C, I, and completion retain their single logical effect;
  a different delivery or obsolete destination identity cannot consume the promise.
- AC34: GIVEN a save boundary before or after departure/handover WHEN the world reloads
  THEN stored goods, delivery-owned cargo, reservations, and task state agree, and resumed
  processing cannot re-reserve capacity or duplicate cargo/stock.
- AC35: GIVEN an enabled warehouse with accepted deliveries WHEN Stop is accepted THEN
  subsequent new inbound/outbound automatic starts fail without partial effects, existing
  deliveries retain their accepted state, and stock, registration, and spatial claims remain.
- AC36: GIVEN a stopping warehouse WHEN its accepted incoming/outgoing deliveries complete
  THEN their normal effects occur once and the warehouse remains inactive and registered;
  pending unaccepted requests do not start automatically.
- AC37: GIVEN a stopping or stopped warehouse containing stock WHEN a legal manual take
  succeeds THEN the carried item and stock transfer coherently without enabling the
  warehouse; removing its last item does not unregister it.
- AC38: GIVEN an empty warehouse with I>0 or an unfinished accepted outgoing delivery
  WHEN unregister or material change is attempted THEN it is rejected despite zero stock.
- AC39: GIVEN a stopped, empty, obligation-free warehouse WHEN material change succeeds
  THEN the new material is selected while registration, footprint protection, and stopped
  status remain; WHEN Enable is accepted THEN automatic admission is allowed again under
  current prerequisites without recreating stock, registration, or accepted jobs.
- AC40: GIVEN a stopped warehouse or one finishing accepted obligations WHEN it is saved
  and reopened THEN automatic admission remains disabled and accepted work resumes from
  its captured state; loading neither unregisters nor implicitly enables the warehouse.
- AC41: GIVEN a concurrent Stop and automatic job acceptance WHEN authority orders them
  THEN the job either was accepted before stopping and finishes normally or is refused
  without partial payment, cargo transfer, or reservation; no accepted work is canceled.
- AC42: GIVEN otherwise valid same-height 1×1 bases at (0,0) and (2,0) WHEN they register
  in either order THEN both succeed with a shared one-cell aisle and independent identities,
  stock, materials, and lifecycle; their common clearance stays protected through z0+5.
- AC43: GIVEN otherwise valid bases at (0,0) and (2,2) WHEN they register THEN both may
  claim the diagonal clearance column (1,1), without allowing either warehouse's members
  or potential cargo volume into the other's envelope.
- AC44: GIVEN an attempted member/potential-cargo overlap with another warehouse's envelope
  WHEN placement or registration is checked THEN it rejects even if both warehouses are
  empty or the intersecting cargo column is disabled.
- AC45: GIVEN two registered owners of one clearance cell WHEN one legally unregisters
  THEN ordinary placement/construction in that cell remains forbidden by the other owner;
  WHEN the last owner unregisters THEN no warehouse claim remains on that cell.
- AC46: GIVEN overlapping warehouse clearance across a chunk boundary or wrapped-X seam
  WHEN object/terrain data unloads/reloads or the world is saved/reopened THEN applicable claims remain
  discoverable and removing one owner cannot clear another's reservation.
- AC47: GIVEN an otherwise eligible pallet target with one valid eligible real block
  directly below but no surrounding 3×3×3 platform WHEN pallet support is checked THEN
  that single below cell suffices without plank-height, span, or platform searches.
- AC48: GIVEN air, another pallet, a planned miniature, packed goods, or unavailable data
  directly below a proposed pallet WHEN placement/registration validates support THEN
  it cannot accept those contents as the required real eligible floor.
- AC49: GIVEN a loose pallet or a registered member WHEN a direct/indirect mutation would
  remove its necessary floor support THEN that mutation is rejected without partial effects;
  unregistering alone does not permit support loss while the pallet remains.
- AC50: GIVEN a loose pallet as the only proposed construction support WHEN ordinary,
  road, platform, or cheap blueprint fulfillment support is checked THEN the pallet supplies
  none, while independently valid alternate routes remain available.
- AC51: GIVEN a pallet and its necessary floor WHEN the pallet is legally removed, after
  unregister if required, THEN its floor is no longer protected by that pallet, while
  other ordinary dependencies and claims still apply.
- AC52: GIVEN each of Q7's fifteen eligible terrain materials as an otherwise valid real
  floor WHEN pallet support is classified THEN it qualifies using the material value alone,
  without shape lookup or recursive validation of that floor's construction.
- AC53: GIVEN sand, water, snow, leaves, an adaptive road in either shape, or a generic
  custom cell directly below WHEN pallet placement/registration checks support THEN it
  rejects that floor even if it has full-cube collision; forming/reverting an adaptive
  road cannot change its ineligibility.
- AC54: GIVEN the same valid pallet component WHEN creation is initiated from different
  reachable members THEN recognition produces the same complete footprint and central
  layout origin; for odd width/height the origin is the coordinate of the unique central pallet.
- AC55: GIVEN a face-connected candidate with a protrusion, a dimension over five, or more
  than 25 pallets WHEN recognition runs THEN it rejects without choosing a subrectangle;
  discovery stops on the first exceeded dimension or the 26th unique pallet.
- AC56: GIVEN a valid rectangular component and a diagonal-only neighboring pallet in its
  required air border WHEN recognition and clearance are checked THEN the diagonal pallet
  is excluded from membership and registration fails clearance.
- AC57: GIVEN a valid base spanning the periodic X seam WHEN members, center, and relative
  bounds are derived THEN locally unwrapped coordinates produce the same footprint and
  central-origin choice as an equivalent base away from the seam; missing neighbor data
  cannot be treated as an empty boundary.
- AC58: GIVEN any valid footprint with dimensions in 1..5 WHEN choosing its initial layout
  origin THEN its offsets from the locally unwrapped minimum corner are
  (floor((width-1)/2), floor((height-1)/2)), independent of the clicked pallet.
- AC59: GIVEN identical origin chunk-local coordinates WHEN client, authority, and save/load
  recovery derive the center selectors and filling direction THEN they agree without persisted
  PRNG state; origins at those same local coordinates in other chunks give the same selectors
  and, for equal dimensions, the same relative first column and full order.
- AC60: GIVEN an unchanged origin WHEN stock, material, active capacity, camera origin,
  subscription load order, or future footprint bounds change THEN its derived direction
  remains unchanged; equivalent wrapped addresses cannot change the direction either.
- AC61: GIVEN a warehouse's selected column order WHEN filling the first four levels and
  then levels five/six or disabling columns THEN all use that order, with disabling taking
  its suffix in reverse rather than using an unrotated reference or choosing a new direction.
- AC62: GIVEN even width or height WHEN deriving the first filling column THEN bits 2 and 3
  of the origin hash select the lower/upper central X and Y cells respectively, independently
  of direction bits 0–1; one even dimension permits two candidates and two permit four,
  without changing the layout origin.
- AC63: GIVEN an odd-length axis WHEN deriving the first filling column for any hash THEN
  that axis uses its unique central coordinate; a 5×5 base always starts at offset (2,2).
- AC64: GIVEN unchanged footprint bounds and origin WHEN stock, material, active capacity,
  camera origin, or subscription state changes THEN the selected first column and full
  column order stay unchanged; future bounds changes recompute the center using the same
  hash selectors while preserving the layout origin.
- AC65: GIVEN all 25 footprint dimensions and all center/direction selector combinations
  WHEN deriving the full order THEN every member appears exactly once, the selected center
  is first, depth never increases, and all remaining corners follow noncorners; the
  east-oriented 5×5 retains the exact R11 reference.
- AC66: GIVEN a fully active 4×4 warehouse with any of its 16 center/direction combinations
  WHEN stock reaches 16 THEN the inner 2×2 is filled to height four and the perimeter is
  empty; WHEN stock reaches 17 THEN the first perimeter column receives its first item.
  Ranks 1–4 are always inner columns, ranks 5–12 noncorner perimeter, and ranks 13–16 corners.
- AC67: GIVEN a registered warehouse whose cargo covers every pallet WHEN the player
  presses Mouse2 on a reachable packed item THEN its management dialog opens without
  requiring an exposed pallet, changing stock, or performing an ordinary terrain edit.
- AC68: GIVEN an eligible warehouse target WHEN the player uses Mouse1/E THEN empty hands
  select take, the matching held material selects put, and another held material produces
  a visible rejection with inventory preserved; normal stock/admission checks still apply.
- AC69: GIVEN a successful roughly 100 ms player take/put WHEN Mouse1/E remains held
  through confirmation THEN no second transfer begins, including the opposite operation
  after inventory changes; a new action requires release/repress and the existing pending gate.
- AC70: GIVEN a reachable pallet/item and an otherwise legal warehouse operation WHEN
  the layout origin or changed layout slot lies beyond four blocks THEN distance to
  those cells does not prevent the operation; an out-of-reach aimed target still fails.
- AC71: GIVEN an otherwise valid manual warehouse put whose derived cargo overlaps the
  player and a known free recovery destination WHEN the put succeeds THEN stock increases
  once, the carried item transfers once, and the player is displaced without changing the
  derived slot or rejecting solely for body overlap; recovery adds no resource effects.
- AC72: GIVEN an accepted incoming delivery whose arrival cargo overlaps the player and
  a known free recovery destination WHEN handover completes THEN the reservation converts
  into stock exactly once and the player is displaced; the delivery does not wait for the
  player to leave, client recovery to finish, or a recovery acknowledgment.
- AC73: GIVEN a successful warehouse stock/layout update that does not intersect the
  player WHEN current collision is evaluated THEN no displacement or recovery search is
  triggered, and no whole-world actor scan is introduced for that update.
- AC74: GIVEN a running world WHEN warehouse creation or management opens THEN simulation,
  deliveries, stock consumption, and the world clock continue; the cursor is available for
  the dialog while movement/look/tool input cannot affect the world behind it.
- AC75: GIVEN an open warehouse dialog WHEN support disappears or new cargo intersects
  the player with a known free recovery destination THEN normal falling or R30 displacement
  still runs; UI focus does not freeze the player body or wait for the dialog to close.
- AC76: GIVEN a warehouse dialog opened during an unfinished input hold WHEN the player
  interacts with the dialog and presses Escape THEN the old hold is canceled, only the
  dialog closes on that Escape, and no UI click/held control replays a world action.
- AC77: GIVEN an open warehouse dialog showing earlier state WHEN stock, incoming promises,
  obligations, stopped state, or registration changes THEN received updates refresh values
  and action availability; confirmation still revalidates authority and rejects any action
  whose current preconditions fail, even if its button was previously enabled.
- AC78: GIVEN an empty pallet and known geometry behind it WHEN a ray crosses only the
  cell volume above z0+0.2 THEN it continues to the later geometry; WHEN the ray intersects
  the low 1×1×0.2 box THEN that pallet is the target even through a decorative plank gap.
- AC79: GIVEN a packed item sharing its pallet's cell WHEN a ray crosses the unit cube
  above the pallet's low box THEN it targets the packed item and its warehouse; the full
  cargo cube remains solid while an empty pallet remains walk-through.
- AC80: GIVEN a pallet or packed-item shape hit WHEN the nearest vertex of its full unit
  cell is at exactly four metres THEN reach succeeds even if the ray-hit point is farther;
  WHEN that nearest vertex is beyond four metres THEN reach fails. Wrapped X uses the
  nearest copy, and neither the low-box vertex nor the layout origin changes the metric.
- AC81: GIVEN the same camera ray and current world state WHEN focus, menu opening, and
  put/take targeting evaluate a warehouse target THEN they agree on the first shape hit
  and its reach result; an intervening unknown cell prevents targeting through it.
- AC82: GIVEN the initial warehouse material chooser WHEN listing allowed cargo THEN it
  offers exactly Q10's eleven confirmed materials, including pallets, sand, snow, and adaptive-road
  items, and excludes water regardless of its existing terrain placeability.
- AC83: GIVEN a request involving water as warehouse cargo WHEN registration, material
  change, manual put, or new delivery admission validates it THEN authority rejects it
  without changing registration, stock, carried cargo, or incoming reservations, even if
  client material selection was bypassed.
- AC84: GIVEN a newly added placeable terrain type without explicit cargo eligibility WHEN
  warehouse material validation runs THEN placeability alone does not admit it; cargo
  eligibility also remains independent of the pallet-floor support predicate.
- AC85: GIVEN an unregistered pallet and a player with empty hands WHEN the player completes
  the ordinary three-second removal THEN the terrain pallet becomes one carried pallet;
  WHEN that item is legally installed with the ordinary one-second action THEN one pallet
  appears and the carried item is consumed, without transporting warehouse object state.
- AC86: GIVEN a registered member pallet, including one in an empty warehouse WHEN the
  player attempts ordinary extraction THEN it remains protected until the warehouse is
  explicitly unregistered under its lifecycle conditions; a completed hold cannot bypass it.
- AC87: GIVEN ordinary pallet recovery/reinstallation WHEN the hold is canceled or placement
  fails support, occupancy, or no-stacking checks THEN terrain and inventory preserve their
  prior ownership without duplicating/losing a pallet; these actions do not use the 100 ms
  warehouse stock-transfer duration.
- AC88: GIVEN a warehouse configured for pallets WHEN a player successfully puts/takes one
  pallet using the roughly 100 ms action THEN stock and carried inventory transfer exactly
  one pallet; it uses one cargo slot, and the packaging creates no extra item.
- AC89: GIVEN pallets stored as cargo WHEN collision, support, and targeting query them
  THEN they behave as full packed cubes with no construction support, not low terrain
  pallets or structure members; after take, ordinary terrain installation/removal still
  uses the one-second/three-second durations and the pallet's placement constraints.
- AC90: GIVEN observer mode WHEN key 9 is pressed THEN pallets become the selected material
  without changing player inventory or keys 1–8; Mouse2 on a valid pallet/item uses the
  same creation/management rules, and Tab retains putting/removing mode selection.
- AC91: GIVEN observer putting mode with the matching selected material and available
  unreserved capacity WHEN Mouse1/E is pressed THEN one stock unit is created with no
  hold timer and no player-inventory change; holding does not create additional units.
- AC92: GIVEN observer putting mode with a selected material different from the warehouse
  WHEN a put is attempted THEN it reports the same material-mismatch error as player mode,
  preserves selection/stock/player inventory, and never substitutes the warehouse material.
- AC93: GIVEN observer removing mode WHEN Mouse1/X targets a stocked warehouse THEN one
  unit is discarded per press without changing player inventory or member pallets; an
  empty take is rejected without falling through to terrain removal.
- AC94: GIVEN observer stock edits WHEN an addition would consume promised incoming room
  or exceed capacity, or an operation is retried THEN the same admission/accounting guards
  as other warehouse stock operations prevent overcommit or duplicate effects.
- AC95: GIVEN an otherwise valid warehouse and blueprint whose bounding boxes overlap but
  whose nonempty targets avoid the full warehouse envelope WHEN admitted in either order
  THEN both can coexist, retaining all ordinary foundation/terrain/claim checks.
- AC96: GIVEN a blueprint target intersecting any warehouse pallet, possible cargo cell,
  disabled column, or reserved side/diagonal clearance WHEN the warehouse or blueprint is
  admitted second THEN it is rejected without partial publication, even with zero stock.
- AC97: GIVEN a warehouse candidate within unfinished construction WHEN its necessary
  floor is only a pending miniature THEN registration fails physical support; WHEN an
  eligible floor already exists and all other conditions hold THEN unfinished construction
  elsewhere does not by itself prevent registration.
- AC98: GIVEN a registered warehouse within blueprint-empty space WHEN legal stock put/take
  operations occur THEN they remain available despite the site's real-block extraction ban;
  WHEN the warehouse is legally unregistered THEN terrain-pallet removal inside the active
  site still fails until that site's extraction restriction is released.
- AC99: GIVEN compatible overlapping warehouse and blueprint ownership WHEN the blueprint
  completes THEN only its restrictions disappear and the registered warehouse remains
  protected; unregistering the warehouse first likewise preserves the active site's guards.
- AC100: GIVEN concurrent warehouse registration and blueprint application with conflicting
  target/envelope cells WHEN admission publishes their effects THEN at most one succeeds
  and the other cannot publish from stale compatibility checks or leave partial state.
- AC101: GIVEN a registered warehouse WHEN ordinary pallet placement in its reserved border
  or removal of a member attempts to change its footprint THEN the mutation is rejected
  and bounds/origin remain unchanged; no automatic resize or temporary member-edit bypass exists.
- AC102: GIVEN a stopped, empty, obligation-free warehouse WHEN it is unregistered, its
  base is legally changed, and creation succeeds again THEN the result is a new registration
  validated against the new footprint, with a freshly selected central origin and identity;
  old delayed commands cannot affect it even if the origin coordinate is reused.

- AC103: GIVEN a valid candidate with its creation dialog open WHEN another actor performs
  an otherwise legal edit or blueprint admission affecting that area THEN the preview
  contributes no reservation or member protection that would block the operation.
- AC104: GIVEN a previously valid creation preview WHEN confirmation finds an invalid base,
  invalid floor support, obstructed clearance, or conflicting target/claim state THEN it
  reports the current failure without publishing partial object state, membership, or reservation;
  the earlier preview does not authorize registration and other actors' valid changes remain.
- AC105: GIVEN an unsubmitted creation dialog WHEN it is canceled or left open THEN no
  temporary claim is created, retained, or expired, and existing owners' claims are untouched;
  WHEN a confirmation succeeds THEN registration and its reservation become visible together.
- AC106: GIVEN a partly filled warehouse WHEN drawing its base markers THEN only columns
  without cargo emit a material icon or disabled cross, and no marker is duplicated on
  cargo, upper levels, or through geometry; occupied columns emit no hidden marker either.
- AC107: GIVEN a column whose base marker is suppressed by cargo WHEN its last item is
  removed in the rendered layout THEN the base marker reappears according to its current
  active/disabled configuration; cargo and markers use the same presentation snapshot.
- AC108: GIVEN any supported packed material WHEN viewed without a dialog or material badge
  THEN exposed portions of its resource texture remain identifiable between pallet/strap
  artwork; transparent packaging regions show the resource rather than background, and the
  cargo retains full-cube collision with no construction support.
- AC109: GIVEN several warehouse changes before visual preparation WHEN a snapshot is
  prepared THEN it may render the latest coherent state directly without intermediate
  images, while all accepted resource operations retain their accounting effects.
- AC110: GIVEN updated logical warehouse state with visual work pending WHEN inventory,
  targeting, collision, or overlap recovery is evaluated THEN it uses current logical state
  without waiting for preparation/upload; goods and markers still publish as one visual snapshot.
- AC111: GIVEN a dirty warehouse WHEN preparation can run THEN no fixed refresh interval,
  minimum age, or quiet-period timer delays it; further changes can coalesce without
  restarting a debounce delay, and unchanged sources are reused on later frames.
- AC112: GIVEN visual preparation exceeding the current frame's work allowance WHEN work
  is deferred to later frames THEN simulation and accepted stock transitions continue;
  delayed results remain subject to registration/revision checks and cannot revive stale owners.
- AC113: GIVEN a warehouse at any chunk alignment WHEN registration succeeds THEN every
  chunk intersecting its full envelope has a WarehouseId/registration/bounds lookup entry,
  including halo-only and upper-cargo-only chunks, with at most eight entries and no stock copies.
- AC114: GIVEN a registered warehouse with unchanged bounds WHEN stock, incoming promises,
  material, active capacity, or stopped state changes THEN canonical state and relevant
  subscribers update without rewriting neighboring spatial discovery entries.
- AC115: GIVEN a local warehouse claim whose object state is unavailable or whose world has reopened
  WHEN a dependent edit is considered THEN local discovery resolves/enforces the claim
  before admission without a world-wide warehouse scan; a missing cache is not unclaimed air.
- AC116: GIVEN known discovery data but unavailable current object state WHEN nearby
  movement, targeting, or editing reaches potential cargo cells THEN required object state is
  requested and those cells remain unknown until resolved; terrain air or distant visual
  omission cannot authorize passage or an ordinary edit.
- AC117: GIVEN a known warehouse clearance halo with ordinary traversable terrain WHEN its
  object state is unavailable THEN the halo reference alone does not block walking through the
  aisle, while ordinary terrain/unknown-data checks and all owners' placement claims remain.
- AC118: GIVEN overlapping clearance entries WHEN one warehouse unregisters THEN only its
  entry/claim retires coherently, other owners remain protected, and a late entry or snapshot
  from the retired registration cannot revive its contents or override a new registration.
- AC119: GIVEN several chunk references to one warehouse across a boundary or wrapped-X seam
  WHEN object data loads or terrain changes representation THEN a single owner reconstructs cargo
  for the saved footprint without duplicate instances; current logical collision need not
  wait for the corresponding visual update.
- AC120: GIVEN an N-column warehouse WHEN active capacity is configured THEN only integer
  A in 0..N is valid, the first A columns of the unchanged Q5 order are active, and the
  remaining suffix is disabled without changing bounds, origin, stock, promises, or claims.
- AC121: GIVEN active count A, present C, and promised I WHEN replenishment demand or new
  admission is evaluated THEN deficit is `max(0, 4A - C - I)`, every new q-item addition
  requires `C + I + q <= 6A`, and manual/observer puts may use unpromised buffer room;
  stopped status still forbids new automatic work regardless of a positive deficit.
- AC122: GIVEN any N, A in 0..N, and C in 0..6N WHEN layout is reconstructed THEN its C
  occupied cells are the prefix of `slots(P[0:A]) ++ slots(P[A:N])`, with unique cells
  and no gaps below goods; A=N reproduces ordinary filling and A=0 uses the same ordinary
  order entirely in disabled columns.
- AC123: GIVEN N=9, C=20, and I=8 WHEN A is reduced to 4 and the accepted cargo later
  arrives THEN no goods/promises are lost, new additions are refused, and arrival produces
  C=28/I=0 with six items per active column and four in the first disabled column.
- AC124: GIVEN stock occupying disabled columns WHEN goods are taken manually or for
  outgoing delivery THEN the last occupied slots are removed, clearing disabled stock
  before active stock; in AC123 the next four takes clear the disabled column completely.
- AC125: GIVEN A=0 with stock or incoming promises WHEN transfers are attempted THEN new
  incoming departures and all unreserved additions are refused, earlier accepted arrivals
  complete, manual takes remain available, and eligible new outgoing work remains possible
  only while enabled; draining does not automatically Stop or unregister the warehouse.
- AC126: GIVEN a warehouse with disabled columns WHEN A increases THEN the next columns
  in Q5 order become active and layout/demand recompute without unregister, new identity,
  lost stock/promises, or a change of enabled/stopped intent; overlap recovery and free-pallet
  markers follow the resulting layout.
- AC127: GIVEN competing capacity reduction and incoming departure WHEN authority applies
  them THEN a departure accepted first retains its promise after reduction, while a departure
  considered afterward uses the new A; neither ordering overcommits 6N or leaves partial effects.
- AC128: GIVEN unchanged C and A WHEN only incoming quantity I changes THEN admission/demand
  changes but cargo placement and takeable stock do not; a reserved handover transfers its
  own quantity from I to C without treating it as a new addition against 6A.
- AC129: GIVEN a reduced warehouse with `6A < C + I <= 6N` WHEN saved and reopened THEN
  its active prefix, stock, promises, and layout restore coherently without clamping goods
  to 6A, re-enabling columns, or requiring accepted deliveries to reserve capacity again.
- AC130: GIVEN any valid w×h warehouse base WHEN courier endpoints are derived THEN the
  set contains exactly the 2w+2h side-adjacent base-level halo cells, excludes diagonal-only
  corners, and has at most twenty candidates, including across a chunk or wrapped-X boundary.
- AC131: GIVEN several potential endpoints with different route availability WHEN planning
  a new delivery THEN any ordinarily traversable reachable side may be selected; neither
  access to the layout origin nor access to the particular cargo slot is required.
- AC132: GIVEN an otherwise valid warehouse base without a usable courier route WHEN it
  registers THEN route absence does not reject creation or manual use under player rules,
  but no new automatic delivery starts without the required route and other prerequisites.
- AC133: GIVEN a fixed footprint WHEN C, I, A, material, or derived layout changes THEN
  potential endpoint geometry remains unchanged and stock transfer does not rebuild it.
- AC134: GIVEN an accepted delivery WHEN its endpoint floor or another route segment
  becomes unusable THEN accepted timing/cost and cargo handover remain unchanged; route
  loss alone does not cancel cargo, revoke its promise, or make completion wait for access.
- AC135: GIVEN a courier using a selected endpoint WHEN pickup or handover is applied THEN
  the warehouse registration and aggregate inventory govern the resource transfer and Q2's
  layout determines the changed cargo slot, independently of the courier's visual position.
- AC136: GIVEN two deliveries using the same shared aisle or endpoint WHEN their work
  proceeds THEN no exclusive dock reservation or NPC-congestion queue changes acceptance,
  duration, or completion; ordinary resource/capacity admission still applies independently.
- AC137: GIVEN a registered warehouse WHEN stock, promises, active capacity, material, or
  enabled/stopped intent changes THEN its canonical simulation object authorizes the change;
  no pallet stores authoritative inventory and fixed chunk discovery entries are not rewritten.
- AC138: GIVEN unchanged geometry, layout origin, and configuration WHEN reconstructing
  cargo from the simulation object THEN the Q5 hash/order agrees with the earlier coordinate
  algorithm; removing the pallet-metadata role does not alter deterministic filling.
- AC139: GIVEN an intersecting chunk reference and a current object snapshot WHEN the
  terrain chunk containing the origin is absent THEN the full cargo footprint is available
  for rendering and logical collision without loading a privileged pallet or duplicating stock.
- AC140: GIVEN a saved boundary involving warehouse objects, delivery cargo/promises, world
  claims, or player resources WHEN recovery applies it THEN every accepted transfer describes
  one resource-consistent outcome and no independent simulation save duplicates or loses goods.
- AC141: GIVEN a stopped warehouse or a warehouse outside rendered terrain residency WHEN
  manual access or accepted simulation work needs it THEN identity lookup resolves its
  persistent object under availability rules without requiring active automatic work or
  visible member chunks; unavailable state remains unknown rather than empty or unregistered.
- AC142: GIVEN a player performing terrain and warehouse transfers WHEN accepted resource
  changes apply THEN world-data service remains the authoritative owner of carried inventory,
  the simulation warehouse remains the owner of C/I/A, and each manual transfer has one
  coherent effect across them without a second writable player inventory.
- AC143: GIVEN an accepted warehouse transfer followed by a stale movement checkpoint or
  repeated transfer intent WHEN those inputs are processed THEN the checkpoint cannot
  overwrite the carried item and the retry cannot transfer a second item; capture/recovery
  preserves one coherent resource outcome under the selected protocol.
- AC144: GIVEN a cross-owner transfer racing conflicting work or save capture WHEN its
  commit executes THEN authoritative decisions and captured state observe a complete resource
  outcome, with fallible preparation performed before mutation and retries applied once.
- AC145: GIVEN world/player and simulation changes in one captured save boundary WHEN the
  save is committed and later recovered THEN its participating records describe the same
  coherent cut; an incomplete final append cannot install only one side of a transfer.
- AC146: GIVEN ordinary warehouse or construction resource work WHEN its live outcome is
  accepted THEN acceptance does not require disk synchronization for that individual item;
  a crash may lose recent unsaved progress coherently under the shared save policy.

- AC147: GIVEN the first warehouse implementation WHEN authoritative warehouse, world-data,
  and manual inventory mutations execute THEN one service executor applies them through
  separate state-domain APIs with no observable partial commit.
- AC148: GIVEN automatic work using only simulation-owned warehouse records WHEN processed
  THEN its local mutation path does not require a world-data mailbox message or player-specific
  lock for each item solely to coordinate those domains.
- AC149: GIVEN the shared-executor implementation WHEN readiness is evaluated THEN measurements
  include changing warehouses together with terrain streaming, publication, and save pressure,
  and competing work has bounded scheduling with the selected conflict precedence.

- AC150: GIVEN the same external command identity and payload WHEN received while pending
  or after completion within retained history THEN it remains one operation and returns its
  existing status/result without repeating its resource effect.
- AC151: GIVEN a reused command identity with different contents, or a new command targeting
  a retired registration after rebuilding at the same location WHEN submitted THEN it cannot mutate the
  current warehouse and the conflicting/stale request is rejected.
- AC152: GIVEN an acknowledged result retired from bounded history WHEN its old identity is
  received again THEN retained ordering/retirement state rejects or resynchronizes the request
  instead of executing it as a new command.
- AC153: GIVEN a process restart or world reload with an uncertain old command WHEN the
  client resumes THEN fresh sessions and authoritative state replace old predictions, and old
  requests/replies cannot replay effects; a saved effect survives without needing its old reply.
- AC154: GIVEN client-session rotation while its admitted commands are unfinished WHEN a
  usable resynchronization boundary is established THEN prior admitted work is resolved/fenced,
  not silently cancelled or relabeled as new work.
- AC155: GIVEN retired client sessions or replayed old results WHEN live work continues THEN
  current inventory/object snapshots cannot regress, and persistent delivery cargo, promises,
  and task completion retain their own coherent recovery semantics.

- AC156: GIVEN several block/mesh chunk references to one registration WHEN discovered or
  switched between representations THEN one object subscription/cache entry serves them without
  requiring the layout-origin chunk or duplicating warehouse presentation.
- AC157: GIVEN multiple accepted warehouse changes before publication WHEN a client update
  is sent THEN the first implementation sends a coherent complete snapshot for the selected
  latest revision, preserves each required command result, and adds no debounce delay.
- AC158: GIVEN chunk references and functional dependencies such as movement, management, or
  a pending command WHEN some references disappear THEN logical state remains retained while
  needed; releasing the final reason may retire the client subscription without deleting stock.
- AC159: GIVEN missing object state or lost subscription continuity WHEN a nearby query needs
  possible cargo occupancy THEN it requests/resynchronizes state and preserves unknown-data
  guards independently of GPU readiness and distant visual omission.
- AC160: GIVEN unregister, subscription renewal, or a newer snapshot WHEN an old payload
  arrives THEN lifetime/revision checks prevent resurrection or state regression, while current
  fixed discovery entries are not rewritten for ordinary stock/configuration updates.
- AC161: GIVEN the last observing client unsubscribes WHEN automatic work or save/load proceeds
  THEN canonical warehouse state and accepted obligations retain their normal simulation and
  persistence lifetimes.

- AC162: GIVEN cargo overlap that ordinary bounded recovery cannot resolve WHEN a halo
  destination has known full-body clearance THEN recovery relocates the player into that
  base-level border cell without changing stock, reservations, or deterministic packing.
- AC163: GIVEN multiple halo candidates with different data availability WHEN recovery chooses
  a destination THEN ready full-body positions are preferred, including eligible corners,
  within the bounded set of at most 24 cells and without a pathfinding requirement.
- AC164: GIVEN a loaded warehouse reference but missing data intersecting a candidate's body
  WHEN no candidate is ready THEN targeted dependency loading and movement guards preserve
  unknown-space safety while the accepted transfer and simulation proceed.
- AC165: GIVEN a current clear halo position without support below WHEN recovery relocates
  the player there THEN ordinary gravity resumes and no halo-floor registration requirement
  or temporary supporting block is introduced.
- AC166: GIVEN recovery waiting for data WHEN the overlap disappears or the registration/state
  changes THEN the old relocation is not blindly applied and current collision/lifetime checks
  determine whether recovery is still needed.

- AC167: GIVEN a valid N-pallet candidate and selected eligible material WHEN registration
  succeeds THEN the new object has that material, C=I=0, A=N, enabled intent, and no accepted
  obligations; registration itself creates no cargo or delivery.
- AC168: GIVEN a stopped, reduced-capacity warehouse that was drained and unregistered WHEN
  its rebuilt base is registered again THEN the new identity uses R62's full-capacity enabled
  defaults even if coordinates are reused; loading an existing registration instead restores
  its saved settings, and changing its material preserves stopped intent.
- AC169: GIVEN an open management dialog WHEN falling or displacement moves the viewpoint
  beyond four metres from every current member/cargo cell THEN new mutations are disabled
  locally and rejected on authoritative evaluation without side effects, while viewing,
  physics, and simulation continue; returning within reach permits otherwise valid actions.
- AC170: GIVEN an open management dialog whose original cargo hit has been removed/repacked
  WHEN another current member or occupied cargo cell is within the inclusive reach limit
  THEN that cell establishes reach without requiring a new ray, camera direction, or line of
  sight; a stale slot or layout origin alone cannot authorize confirmation.
- AC171: GIVEN a creation dialog WHEN its original pallet is removed or no pallet of the
  rediscovered candidate is in reach at confirmation THEN creation rejects with no partial
  object/claims; an otherwise valid current candidate with any member in reach may register.
- AC172: GIVEN a capture selection containing a loose or registered terrain pallet WHEN
  compiling the blueprint THEN capture reports unsupported material, copies no warehouse
  identity/stock, and leaves the source unchanged.
- AC173: GIVEN a selection containing only upper packed cargo cells and underlying air WHEN
  capturing THEN cargo is omitted regardless of its material and the empty-blueprint rule
  rejects the selection, without creating targets or changing inventory.
- AC174: GIVEN otherwise eligible surrounding construction and upper cargo in one selection,
  with no pallets or other unsupported source materials WHEN capture validates THEN only
  ordinary capture materials become targets and cargo cells stay empty; no inventory,
  registration, or reservation is serialized into the definition.
- AC175: GIVEN an accepted dialog command followed by movement out of reach WHEN it completes
  or its retained result is retried THEN Q23 preserves its single outcome without cancellation
  or a new reach test; a new command still requires current reach.

## Constraints

- Keep one authoritative stock owner; lookup references, snapshots, caches, and simulation
  demand are not independently writable stock. Conservation remains the baseline; Q20 opens
  evaluation of specific exceptions without granting a general best-effort accounting policy.
- Keep collision occupancy, structural support, terrain occupancy, reservations, and draw
  geometry distinct. Do not infer packed support from its material or use GPU data for physics.
- Preserve blueprint fulfillment's existing structural bound and current monotone support
  guarantees. Reservation guards add admission checks, not recursive support work per transfer.
- Use signed local bounds across periodic X and finite Y/Z; rebase GPU coordinates before
  narrowing to f32. Respect existing source lifetime and metadata revision contracts.
- Successful registration examines at most 25 members within a 294-cell envelope plus at most 25
  directly-below support cells, still intersecting at most eight 32³ chunks. These are
  footprint bounds, not total I/O/allocation or timing bounds. Invalid-component discovery
  stops on the first exceeded dimension or the 26th unique pallet instead of traversing
  an arbitrarily large connected pallet field.
- Prefer work on relevant changes, compact state, bounded spatial lookup, batch mutation,
  and separate/coalesced visual publication. No generic engine framework or universal transaction
  system is implied. Shared renderer code must not depend on warehouse-specific game policy.
- Benchmark observed and unobserved warehouses separately. Include raw state, container capacity,
  chunk retention, indexes, queues, transient save/copy state, and GPU buffers in memory accounting.
  The simulation's 100,000-task target is not a requirement for 100,000 rendered warehouses.
- Each accepted simplification must record saved work, visible consequences, preserved
  invariants, failure/convergence behavior, and whether performance is measured or estimated.

## Out of Scope

Runtime implementation in this discussion; pallet crafting and pallet blueprint support;
full courier scheduling, route search, supplier matching, and production recipes;
perishable/partial food crates; workbench
implementation; new road behavior; a universal pattern language; released-save migrations;
multiplayer networking; liquid storage and handling pending a separate mechanics design.
The general observer material-selection menu is also deferred; this feature adds key 9
for pallets and uses the existing selected-material value.
In-place expansion, shrink, and merging are deferred under Q11; current footprint changes
require unregister, ordinary rebuilding, and new registration.
Concrete warehouse interfaces for capacity, cargo handover, and lifecycle still require
design before simulation uses them. Q2/Q3/Q4 fix reduced-capacity demand/admission/layout,
departure reservations, and stop/enable contracts. Full demand allocation and exceptional
failure/cancellation remain separate work rather than being implied by excluding the scheduler.

## Plan

### Approach

Implementation sequence under the agreed contracts:

1. Preserve confirmed Q1 count-only/repacking, Q3 departure reservations, Q4 lifecycle,
   Q5 fixed layout origin, hashed filling center/direction, and inner-layer/late-corner
   ordering, Q6 full-component discovery,
   Q7 direct pallet support and its material allowlist, and Q8 shared warehouse clearance.
   Q2 completes this with 4A target, 6A new admission, preserved promises within 6N,
   and active-before-disabled packing without persistent column heights.
2. Review integration while preserving Q10's eleven-material cargo
   list, the support allowlist, and shared-air rules. Q12 selects envelope-wide chunk references
   and unknown-data guards; Q24 selects independent object subscriptions with full snapshots.
   Finalize concrete subscription/retention mechanics during implementation.
3. Specify the compact simulation object record and Q12 chunk-reference protocol under Q22's
   shared service executor; preserve separate state domains and bounded local mutation batches.
4. Integrate authoritative operations, persistence, predictions, collision, and reusable packed
   rendering in dependency order. Reuse road/custom and miniature patterns where appropriate.
5. Validate gameplay invariants and resource conservation, then measure representative scale
   before selecting further caching, indexing, or GPU complexity.

### First-version readiness

The initial execution model (Q22), external-command retry boundary (Q23), and independent
object subscriptions with complete snapshots (Q24) are selected. They do not need another
architecture choice before starting first-version warehouse implementation.

Q26 closes the remaining displacement decision: use the registered warehouse's base-level
halo when ordinary bounded recovery fails, prefer loaded full-body destinations, and acquire
missing nearby dependencies without delaying simulation. No first-version warehouse gameplay
choice remains open. Engineering preparation and validation below still apply; this discussion
has not implemented the feature.

Engineering preparation remains: finalize records/version gates, bounded command-result
retention and acknowledgment, coherent object/claim admission and retirement, save capture/load
integration, subscription lifetimes/budgets, and staged implementation/verification. These
concretize accepted contracts; routine field/container/API choices need not become new gameplay
questions. Review choices that change observable behavior or established performance priorities.

Select representative observed/unobserved warehouse workloads and record CPU, memory,
publication, persistence, and mixed streaming costs before declaring the implementation ready.
Numeric acceptance budgets and renderer representation can be refined through implementation
measurements; they do not require settling the entire future economy upfront.

First-version warehouses do not depend on construction-target ownership implementation, Q21
soil simplification, full routing/supplier allocation/NPC scheduling, or Q25 incremental
publication. Keep strict accounting as the baseline while Q20 remains unselected. Expose and
verify reservation/handover contracts through controlled scenarios without adding the full
courier scheduler to this feature.

### Implementation review checkpoints

Q1–Q18 settle warehouse behavior, simulation authority, world-data-owned player inventory,
and the coherent live-commit/shared-capture baseline. First-version execution and retry
contracts follow Q22/Q23; concrete access/capture integration remains implementation work;
Q19 selects target-only construction ownership for further design; Q20–Q21 discuss measured
accounting tradeoffs and soil transformations. Q22 selects initial shared execution; Q23
fixes external command retry lifetimes. Q24 selects object subscriptions and complete snapshots; Q25 defers incremental publication evaluation. Review the concrete
implementation choices below against those contracts:

- Specify pallet encoding, simulation object and chunk-reference records, registration/revision
  identity, and save/recovery order. Keep stock canonical and restore claims before dependent edits.
- Specify stock/configuration operations, delivery-reservation coordination, retries, and
  optimistic rebase. Review object-state updates, unregister tombstones, mesh/block handoffs,
  near-object retention, and stale responses against resource and subscription invariants.
- Extend logical collision/targeting and the existing bounded player-recovery path. Review
  Q26 halo fallback and bounded dependency loading when no candidate is ready, without deleting
  stock, changing the deterministic layout, or treating unknown cells as a free destination.
- Compare compact owner-driven GPU geometry with cached item instances using observed and
  unobserved workloads. Measure authority/index/publication work, client derivation, GPU
  updates, and memory separately before selecting representation and per-frame budgets.

The separate logistics design owns route search and endpoint selection for Q15, supplier
allocation, and exceptional delivery outcomes. The warehouse spec provides admission,
handover, lifecycle, and endpoint contracts without selecting that scheduler.

### Affected Components

- `src/voxel_app/world_chunk_data.zig`, `chunk_metadata.zig`: pallet terrain and spatial
  discovery/claim integration; authoritative warehouse records belong to simulation state.
- `src/voxel_app/world_data_service.zig`, `world.zig`: terrain/claim guards and coordination
  with simulation commands, publication, prediction/reconciliation, and lifecycle ownership.
- `src/voxel_app/block_rules.zig`, `blueprint_admission.zig`, `blueprint_runtime.zig`:
  reservations, material support, and planned-construction interaction.
- `src/voxel_app/block_collision.zig`, `terrain_collision.zig`, `block_targeting.zig`,
  `player_interaction.zig`, `main.zig`: derived occupancy, targeting, quick actions, and UI.
- `src/engine/voxel/`, `src/engine/shaders/voxel/`: reusable pallets/packed geometry,
  instancing, markers, shadows, and independent source updates.
- Simulation object storage (new, exact module placement pending): warehouse state,
  identity lookup, stock/configuration mutations, reservations, and task coordination.
- `src/voxel_app/persistence/`: explicit object records and coherent world/simulation/player
  capture, recovery, and version gates.

### Data Model Changes

The canonical simulation warehouse record contains WarehouseId/registration identity,
fixed layout origin and relative bounds, material, C, aggregate I, A, enabled/stopped intent,
and warehouse lifecycle accounting. Q5 derives selectors/direction from the origin's
chunk-local coordinates without authoritative random state. Q1 excludes authoritative
column heights, item positions, and layout history. Simulation task records own individual
deliveries, their cargo, and promises; their relationship to aggregate I is coherent.
Q22 fixes initial execution ownership and Q23 fixes retry lifetime. Record layout, bounded
retry encoding, and capture integration remain implementation review.
Q17 retains world-data-owned player inventory; Q18 specifies the accepted commit/capture
baseline; Q19 selects simulation-owned construction targets, with mechanisms detailed
in the separate [construction spec](construction-state-ownership.md).

Q12 selects derived per-chunk WarehouseId/registration/bounds entries over the full envelope,
with at most eight entries per warehouse. They hold no independent stock or active-count
copy. Client snapshots and layout/collision/GPU caches remain derived. Spatial claims retain
multiple owners of shared clearance and retire each independently; no per-air-cell record
is prescribed. Field widths, wire tags, and save version are not chosen.

### API Changes

Required logical operations: register, put, take, configure, stop, enable, and unregister.
Q4 defines management preconditions; concrete API encoding remains unselected.
Expose stock transfers independently of ordinary terrain puts/removes, preserving batched
server access. Delivery acceptance must include aggregate capacity reservation; handover
consumes that delivery's promise instead of issuing an unreserved put. These are coherent
transition contracts, not a requirement for separate network round trips or a particular
transaction API. Clients need sufficient reserved-capacity state for put prediction.
Subscriptions need object updates/tombstones independent of ordinary meshes.
Block and mesh subscriptions also expose Q12's chunk-local discovery entries; nearby
dependent queries must be able to request current state by WarehouseId.
Registration identity, failures, retries, and prediction rebase need concrete contracts.

### Risks

Repacking, manual puts, and delivery arrivals can displace a player and require cargo-aware
recovery. Start/handover, active-count changes, and competing manual puts must update
reservation/cargo/stock facts coherently. In particular, the 6A new-admission ceiling must
not be mistaken for a limit that clamps existing stock or invalidates promises within 6N.
Empty terrain can hide cargo/reservations, and shared clearance needs ownership-aware
claim removal. One count mutation can trigger
expensive full-chunk publication if existing paths are reused indiscriminately. Missing object state,
late replies, floor changes, and restored claims require explicit ownership/availability rules.

## Tasks

### Phase 0 — Specification discussion

- [x] T1: Read repository principles and relevant subsystem/spec contracts; write a fresh
  warehouse draft and separate shared-concept notes from the current proposal.
- [x] T2: Record Q1 count-only stock/repacking/player displacement and Q2's 0..N active
  prefix, 4A target, 6A new admission, preserved 6N promises, exact slot composition,
  reverse draining, and reactivation, with reduced-capacity examples and criteria.
- [x] T3: Record Q3 aggregate departure reservation and coherent handover, Q4 explicit
  stop/enable and empty obligation-free unregister/material change, and the remaining
  WH-01/WH-02/WH-03/WH-05 scope in the simulation question list.
- [x] T4: Record Q5–Q14 decisions and review their gameplay invariants, UX, cross-document
  consistency, and simplification tradeoffs. Q5 resolves the separate layout origin and
  hashed filling center, direction, full order, inner-layer priority, and corner deferral. Q6 confirms
  full-component discovery and a central initial origin. Q7 is resolved, including floor
  materials; Q8 confirms shared warehouse clearance and warehouse/site composition in
  blueprint-empty cells, preserving each owner's independent restrictions.
  Q9 confirms player controls, fresh presses, reach relative to the aimed pallet/item, and
  displacement for manual puts and arrivals, plus live dialogs with continuing simulation
  and physics, low-box pallet/full-cube cargo targeting, and ordinary nearest-cell-vertex
  reach. Observer edits are instant one-unit operations using the selected material and
  the same mismatch error as players; Q26 resolves the recovery destination, with detailed
  input/recovery integration left to implementation review.
  Q10 confirms the eleven-material cargo allowlist including pallets, defers liquids, and
  permits ordinary three-second pallet recovery/one-second reinstallation plus fast pallet
  cargo transfers. Key 9 selects pallets; the general observer selection menu is deferred.
  Q11 defers in-place resizing and requires lifecycle-complete unregister/rebuild/new registration
  to change the physical footprint; active-column capacity settings remain separate.
  Q14 confirms advisory previews without temporary claims and current coherent confirmation.
  Q13 confirms markers only on empty base pallets, identifiable packaged resources, and
  change-driven coalesced visuals without intentional delay; renderer representation and
  preparation budgets remain implementation review.
  Q12 confirms envelope-wide chunk warehouse identity references without stock copies, local claim
  discovery, and near-data unknown guards while retaining distant visual omission.
  Index encoding/recovery and subscription/retention mechanics remain implementation review.
- [x] T11: Record Q15's access from any traversable side, bounded endpoint geometry,
  registration without a route, and preservation of accepted journeys for WH-02;
  keep the full courier scheduler and routing algorithm separate.
- [x] T12: Adopt Q16 simulation-object authority, WarehouseId discovery, and a geometric
  layout origin; revise the former pallet-owned contracts and related documentation.
- [x] T13: Record Q17 world-data-owned player inventory and a single logical manual
  warehouse transfer crossing the retained inventory boundary.
- [x] T14: Record Q18 coherent live commit and shared durable capture without per-item
  disk synchronization, qualified by frequent simulation-work throughput.
- [x] T16: Select Q22 shared execution for the first warehouses, preserving distinct state
  domains and requiring bounded scheduling and representative load validation.

- [x] T17: Adopt Q23 session-scoped external command identity, bounded repeat recognition,
  fresh-session resynchronization, and independent persistent task recovery.
- [x] T18: Adopt Q24 independent object subscriptions, complete snapshots, and functional
  client retention; preserve Q25 as a separate incremental-publication follow-up.

- [x] T20: Select Q26 reserved-halo recovery after local failure, including loaded full-body
  preference and bounded missing-data handling without delaying resource operations.

### Implementation preparation

- [ ] T5: Finalize concrete data/API changes and implementation phases against the accepted
  resource-accounting and readiness contracts; no warehouse gameplay decision remains open.
- [ ] T15: Finalize warehouse preparation/commit, bounded Q23 retry bookkeeping, failure
  handling, save integration, and Q24 subscription implementation under selected Q22 execution.
  Keep construction handback, Q20 accounting exceptions, and Q21 soil simplification in their
  separate design work; they do not block the initial warehouse implementation.

### Phase 1 — Authority and shared semantics

- [ ] T6: Add pallet capabilities, one-cell support and support-loss guards, and pure
  warehouse layout/occupancy functions; exclude pallets from all construction support paths.
- [ ] T7: Add simulation-object registration, bounded lookup/reservations, and mutation guards.
- [ ] T8: Add coherent stock/configuration/lifecycle transfers and persistent records;
  integrate delivery reservations, handover, and retry/recovery invariants with simulation.

### Phase 2 — Client and presentation

- [ ] T9: Add subscription updates, prediction/reconciliation, and near-data availability.
- [ ] T10: Add reusable packed rendering, pallet icons, collision, targeting, and dialogs.

### Follow-up — Incremental object publication (deferred)

- [ ] T19: Evaluate increment/decrement or hybrid object updates under Q25 against coalesced
  full snapshots; retain full initialization/resynchronization and verify ordering, duplicates,
  coherent multi-field transitions, bounded memory, and measured benefit before adoption.

### Validation

- [ ] T-val: Verify resolved acceptance criteria, cross-client/authority agreement,
  failure/retry/save/load conservation, bounded work, and CPU/GPU/resource measurements.
