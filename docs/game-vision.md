# Game vision

Use the [design principles](../DESIGN_PRINCIPLES.md) alongside this vision when designing or integrating features. They prioritize throughput in world simulation and the world-data service, allow client responsiveness where overall performance is preserved, and define the tradeoffs for consistency and deliberate simplification.

This is the long-term creative and technical direction for the game, based on the author's ideas as of 2026-10-21. It describes the experience we want to work toward and gives context for decisions made along the way. It is a living document, not a final requirements specification, a release commitment, or a description of everything currently implemented.

Reaching this vision will take many iterations and milestones. Early versions can explore a small part of it. Use the vision to keep that groundwork focused, while allowing experiments to change the details. Numerical values below are starting points for design and balancing unless a feature specification explicitly adopts them.

## The experience we are building toward

The player starts by shaping a voxel world and doing work by hand. Over time, they build settlements, production chains, transport networks, and the infrastructure that lets NPCs do that work at scale. Towns and technology develop through this infrastructure.

The central challenge is making a place productive: materials must reach construction sites, workers need supplies, terrain affects transport, and distant regions offer different opportunities. Technology expands what can be built and how far a network can reach. Its value comes partly from reducing the effort of operating that network.

Players can pursue technological progress through their own labor, but doing everything personally should be slow, repetitive, and difficult to scale. The rewarding path is to organize infrastructure and let the simulation carry out the work. Late in the game, players mostly plan and orchestrate; the simulation performs almost all world changes. An illustrative expectation is that it might initiate 99.9% of changes at that stage, rather than players placing or moving each block themselves.

Several ideas guide the experience:

- **Logistics is physical.** Goods occupy the world and need transport. Carrying capacity, roads, terrain, food, and eventually fuel or electricity make location matter.
- **Automation grows from local infrastructure.** Production depends on buildings, supplies, and services in the area. Building a machine alone does not establish a functioning industry.
- **Geography creates useful differences.** Climate, fertility, minerals, and oceans encourage specialization and transport between regions and hemispheres.
- **Construction has material limits.** Foundations, weight, and unsupported spans shape buildings. Better materials enable more ambitious structures.
- **The world continues independently of observation.** Watching an NPC, looking away, or viewing it from another player must not change its travel time or the outcome of its work.
- **Technology changes the player's reach.** Progress moves from hands-on labor to transport, remote supervision, and eventually remote physical action through machines.

## Vocabulary and simulation scope

“People,” “minions,” “NPCs,” and “workers” describe the characters used to visualize work. A **courier** represents a transport task. The simulation uses a local workforce model: work may begin automatically when its prerequisites, including resources and food, are satisfied, without allocating a persistent individual NPC or simulating their approach and return.

The simulation retains active operations, cargo, schedules, and progress. Client-side NPC models illustrate that activity and need not persist between jobs. Houses support the settlement and improve nearby work efficiency; inhabitants shown inside them may also be purely visual. Neither domestic routines nor a separate finite pool of available individual workers is required by this model. See the [local workforce notes](simulation-notes.md#local-workforce-and-client-side-npcs).

## World and geography

### Scale, coordinates, and topology

The world consists of a very large number of voxels, each occupying a 1 × 1 × 1 metre cell.

| Axis | Negative direction | Positive direction |
| --- | --- | --- |
| x | West | East |
| y | South | North |
| z | Down | Up |

The world wraps along x. Walking continuously east or west eventually returns to the same place. Impassable barriers bound the north and south. The horizontal world therefore has the topology of a cylinder, rather than a torus.

The northern and southern extremes are very cold, while the equatorial belt is predominantly desert. Roughly half the surface is ocean. Effective resource extraction should create a reason to transport goods between the hemispheres, with climate and oceans shaping those networks.

### Biomes and regional conditions

The following values express the initial balance idea, not fixed tuning:

| Region | Intended effect |
| --- | --- |
| Meadows | Baseline conditions; all ordinary multipliers are 1×. |
| Jungle | Fertility 2×. Dangerous wildlife attacks workers unless a local hunter controls it. The hunter needs weapons. |
| Desert | Water consumption 2×; fertility ¼ of baseline. |
| Cold regions | Fertility 0. Workers need access to clothing. |
| Mountains | Movement is difficult; mineral resources 4×; fertility ½ of baseline. |

A separate fertile-soil region is a possibility, but may add more complexity than useful decisions. Whether terrain categories such as mountains can overlap climate biomes remains to be defined.

### Resource deposits and extraction

Unlike Minecraft, mineral resources should occur in huge, finite deposits. Establishing extraction at a new deposit should supply resources for a meaningful period of play, making the effort of building access, equipment, and transport worthwhile. Eventually the deposit is exhausted, and the player must find and develop another one. This applies to ordinary bulk materials such as limestone, clay, sand, and gravel as well as valuable metal ores.

Resource placement should broadly reflect where materials occur on Earth. Metal ores should be found predominantly in mountainous terrain; other resources should favor their own plausible geological settings. These concentrations should give regions distinct industrial opportunities and create sustained demand for freight transport.

Extraction methods can include open-pit mining, quarrying, and underground workings reached through tunnels or shafts. Other methods may be added where appropriate to the resource and its setting; the full set remains open.

### Generation direction

A candidate generation process is:

1. Use large-scale masks to separate land and ocean.
2. Partition land into regions using a Voronoi-based process.
3. Merge neighboring regions and expand assigned regions into unassigned areas.
4. Weight region assignment by latitude, with cold regions near the poles and mostly desert or mountains near the equator.

The intended outcome is coherent geography with meaningful regional differences. The exact generation algorithm can change as we test that outcome.

Rivers and lakes would support fishing, scenery, and water-powered industry. Simulating them plausibly and efficiently in an editable world is unresolved, so dynamic rivers and lakes are deferred. Features that depend on them remain part of the longer-term vision.

## Players and progression

The eventual multiplayer target is up to 32 simultaneous players. Early versions will be single-player, but the player model and interaction with the world should remain compatible with a later move to a client-server architecture. This is a reason to preserve useful boundaries now, not a requirement to implement the full networking stack immediately.

Progression connects settlement growth, production, research, and transport. Housing, production buildings, food, and potentially clothing support local work; requirements grow as technology advances. The current clothing idea applies to cold biomes rather than requiring it everywhere. Houses support settlement growth and improve nearby work efficiency. Exact settlement progression remains open; it does not require tracking individual residents or finding a free NPC before a task can start.

Better materials enable more efficient buildings and larger structures. Research provides blueprints and new capabilities, while operating a larger economy creates the need for better transport and power sources.

## Construction and physical materials

### Building by hand

Construction should feel broadly like Minecraft or Valheim: players shape buildings block by block in the world. A building qualifies for residential or production use only when its arrangement meets relevant conditions, such as the correct workstations, enough interior height, and a roof. Exact recognition rules are still to be designed.

Location matters to production. Fishing piers belong on rivers or lakes, mills serve fields, and mines belong near mineral-rich mountains. More advanced construction materials enable more effective facilities.

Materials must be delivered to the construction site. There is no conventional inventory large enough to carry an entire building's supplies. The initial idea is that the player carries one block at a time, increasing to at most three later in progression through backpack upgrades that each add one block of personal carrying capacity.

A cart increases transport capacity, but slows the player and needs a sufficiently even surface with limited gradients. This creates a reason to build a usable road from extraction to construction before attempting a large project. The proposed capacity progression is described under freight transport below; allowed slopes and movement costs remain open balance choices.

### Structural limits

Blocks have weight, and lower parts of a structure must be strong enough to support what is above them. Materials differ in their ability to carry loads and extend horizontally without direct support. More advanced materials generally allow larger spans.

The intended interaction is to reject an invalid placement, including one that overloads its support. Removing a supporting block should also be rejected when doing so would leave an invalid structure. This favors understandable construction rules; the vision does not require a general physics-based collapse simulation.

Support eligibility and occupancy are distinct. A block directly below which cannot provide the required support should contribute no support, while still permitting another legal support route. For example, planks with valid lateral plank support may sit above dirt without requiring the dirt to be a stable platform. This does not let unsupported dirt become a foundation or grant lateral support to materials which lack it. The validator follows this rule while preserving material-specific limits.

Rebar and reinforced concrete keep their existing direct-support rules: crushed stone alone is not an eligible foundation, while qualifying platforms and legal lateral support remain available. Blueprint capture may instead change the conflicting support material under the [conditional normalization rule](../specs/features/blueprints.md#conditional-concrete-support-conversion); ordinary construction uses the same support rules.

Initial material examples:

| Material | Proposed construction behavior |
| --- | --- |
| Loose soil | Requires a filled 3 × 3 support layer immediately beneath the placed cell. Successive layers therefore need wider foundations, producing pyramid-like forms rather than thin soil overhangs. |
| Planks | Can rest on a supporting block and extend horizontally through other planks for up to two unsupported steps, including diagonals. The intended examples are a 5 × 5 platform on a central support, or a six-block beam including its two supported endpoints. |
| Rebar and reinforced concrete | Can extend horizontally in a similar way, with a larger reach X still to be decided for the long-term design. |

The plank examples should allow a 6 × 6 room with a 4 × 4 interior and a flat wooden ceiling. Exact diagonal propagation, load accounting, and support rules belong in feature specifications. The [current placement document](block-placement.md) describes today's implemented rules and values, which may be more specific than this vision.

Concrete production follows the material chain described below. Large-scale delivery and placement of concrete and reinforced concrete still need further design, including how reinforcement and concrete are combined at a construction site.

### Major structures

Long-term construction projects include:

- Dams.
- Reactors.
- Offshore oil platforms.
- Oil refineries.
- Steelworks.
- Spaceports.
- Airfields.

Research unlocks blueprints for these structures. A player may also build the corresponding structure without an unlocked blueprint, although doing so by hand should take considerable effort. A blueprint helps organize construction; its absence is not intended to be an absolute ban on a valid structure.

### Blueprints and automated construction

Players can save a building they have already constructed as a blueprint, create one interactively block by block, or obtain one through research/progression. Capture and interactive planning produce private blueprints by default, owned by the receiving player and stored per player in that world's save. Progression rewards are intended to be shared by default, accessible to every player on the multiplayer server. Converting a private blueprint to shared is a future capability. The first iteration implements capture and application; planning, rewards, sharing, and multiplayer are deferred.

A blueprint records block types and their 3D arrangement. Its completed design must satisfy structural rules without relying on source blocks outside the capture box, assuming a [stable platform](block-placement.md#stable-platforms) beneath every occupied block in its globally lowest layer. The same foundations are required when applying it elsewhere; internal height/span limits still apply. Capture can include an unfinished blueprint, treating its miniatures as completed blocks. Captured materials must have supported construction equivalents, and the resulting design is validated before saving.

Capture uses three stages: choose an anchor cell, extend an XY rectangle, then choose its height. The extents can be selected in open air, and the player can move while marking out a large building. Capture records the player's visible design, including pending edits; later source changes do not alter the checked candidate. Only successful validation enables naming and saving. Temporary preparation is discarded on cancellation or exit. The [capture rules](../specs/features/blueprints.md#capture-and-input) and Q12 define targeting geometry and range; [R54/Q25](../specs/features/blueprints.md#horizontal-size-and-wrapped-target-uniqueness) define world-dependent size limits.

Blueprint selection and name entry block gameplay controls while the world continues running. The first iteration should support buildings of approximately 100×100×32 cells where world dimensions permit, with most designs smaller. This is a supported workload rather than a size cap; preparation and application must keep the world responsive.

Placement starts with a full-size, noncolliding preview, rotatable in 90-degree clockwise steps. Applying it requires actual bottom platforms and free cells at every nonempty blueprint target, even if an existing block has the correct type. Existing blocks in blueprint-empty cells stay in place. The active site has a thin black/yellow box frame and a quarter-size floating block miniature at every pending cell. Miniatures do not block walking. A target accepts only its required material; placing the real block removes the miniature. Extraction is forbidden throughout the active box, including preexisting nontarget blocks, until all targets are fulfilled; then the frame and blueprint restrictions disappear. A site cannot overlap another unfinished site's box. Future NPCs deliver materials and assemble these sites; their logistics/scheduling are separate features.

Assembly must stay cheap enough for many concurrent NPC building projects. Full design validation happens during creation, while each blueprint-directed placement needs only local structural approval. The [placement contract](block-placement.md#blueprint-fulfillment) limits that approval to five real neighbors and requires no final building scan.

World modifications must preserve valid affected constructions in the logical world where every miniature is filled. Actual partial or completed buildings may temporarily violate ordinary rules while nearby construction is unfinished; they become valid once unfinished work no longer affects their support windows. All active sites remain structurally completable in some shared order, potentially interleaving placements across sites. Independent completion of each site is deferred. Outside active boxes, ordinary extraction protects the completed logical arrangement without extra foundation locks. The [world-mutation rules](block-placement.md#blueprint-world-mutation-invariant) describe these guarantees. Future cancellation will remove miniatures while retaining real blocks; its consequences require a separate design and are excluded from these guarantees.

The [blueprint specification](../specs/features/blueprints.md) is the detailed source for capture geometry, material normalization, UI transitions, preparation/save protocols, validation, and performance measurements. Blueprints and unfinished sites use the game's single current logic and follow the general [save compatibility policy](persistence.md#save-compatibility). The [implementation validation report](blueprints-validation.md) records the checks and measurements for capture and application; future acquisition paths remain separate.

The selected [construction storage direction](../specs/features/construction-state-ownership.md)
places active blueprint target cells in simulation state until their contents return to ordinary
terrain chunks. Other terrain, including blueprint-empty cavities, keeps its existing owner.
Built targets remain real, colliding, supporting blocks throughout construction. This changes
storage responsibility rather than the gameplay meaning of a partially built structure; marker
encoding and the handback mechanism still need technical design.


## Production, services, and logistics

### Work and local infrastructure

Crafting grows into factory production, with goods transported from where they are made to where they are used. Local services enable work and improve its efficiency:

| Service | Role |
| --- | --- |
| Food dispenser | Supplies NPCs within a surrounding service area and enables local work. |
| Clothing dispenser | Enables workers to operate in cold regions under the current clothing model. |
| Tool dispenser | Improves worker efficiency and enables operations unavailable without tools. |
| Vehicle dispenser | Makes previously manufactured vehicles available for couriers to rent or use for transport. |

Housing improves local efficiency, but delivery itself does not require houses. A supply network should be able to establish and serve an outpost before a residential settlement exists there.

### Cement and concrete production

Concrete is a particularly appealing production chain because it connects bulk resource extraction, high-temperature processing, and construction. Making concrete requires **cement, gravel, sand, and water**.

Cement production starts with **limestone and clay**, potentially with other mineral additives. The raw materials are fired in a kiln at approximately **1,450 °C** to produce clinker, which is then ground to make cement. Cement is subsequently mixed with gravel, sand, and water to produce concrete.

This chain should make quarries, processing facilities, and transport links useful parts of the construction economy. Exact recipes, process equipment, energy requirements, and the handling of water and concrete remain to be designed; water-dependent details must account for the deferred river and lake features.

### Freight transport progression

Transport technology increases the number of blocks moved in one trip. The proposed stages and starting capacities are:

| Stage | Carrying capacity |
| --- | --- |
| Backpack | +1 block of personal carrying capacity. |
| Handcart | 4 blocks. |
| Pedal-powered vehicle | 8 blocks. |
| Horse-drawn wagon or carriage | 16 blocks; this stage may be deferred. |
| Self-propelled cart or car | 32 blocks. |
| Truck | Up to 81 blocks, arranged as a 3 × 3 × 9 load. |

Each stage should improve transport throughput and efficiency per block by carrying more cargo at once. Movement speed also varies between vehicles, so capacity alone does not determine delivery time. Terrain, road quality, gradients, and operating supplies should make the choice of transport meaningful. Exact speeds and costs remain balance choices.

### Warehouses and material orders

The [pallet warehouse specification](../specs/features/warehouses.md) defines explicit registration
of a 1–5 by 1–5 pallet base for one material, with derived packed goods. The selected
[authority model](../specs/features/warehouses.md#q16--simulation-owned-warehouse-state-versus-pallet-owned-metadata)
keeps count, incoming promises, active capacity, geometry, and lifecycle in a persistent
simulation object addressed by WarehouseId. Pallets remain ordinary terrain members;
world-data keeps their physical state and derived spatial claims. These are design decisions,
not implemented behavior. Separate notes define [packed blocks](packed-blocks.md) and
[multiblock structures](multiblock-structures.md).

Registration recognizes the entire connected rectangular base. Its central cell coordinate,
with the lower-coordinate choice on even axes, becomes a fixed layout origin for bounds and
hashing. No pallet at that coordinate owns stock or needs to be loaded to obtain the object.
Separate hash bits choose the first column among equally central candidates and a preferred
filling direction. Inner layers precede outer ones and remaining corners fill last; a fully
active 4×4 fills its inner 2×2 to height four before the perimeter. Future expansion retains
the origin/hash while recomputing the filling center. Repacking may displace an intersecting
player into free space. Incoming deliveries reserve aggregate capacity at departure and
consume their own promise at handover. Stop/Enable is separate from unregister/material
change, which require stopped, empty, obligation-free storage.

Warehouse capacity can be reduced to A active columns, including zero, without rebuilding
its N-pallet base. Normal replenishment targets 4A and subtracts both present and already
incoming goods; new deliveries and manual/observer additions must fit within 6A after
accounting for promised incoming space. Earlier accepted deliveries and existing stock
retain the full 6N physical capacity. Goods pack into active columns first, including their
buffer levels, then into disabled columns; takes clear the disabled part first. Re-enabling
columns recalculates layout without unregister or changing stock. Setting A=0 prevents new
additions but allows manual draining and eligible outgoing work while enabled; it is
separate from Stop. The [capacity policy](../specs/features/warehouses.md#q2--what-does-active-capacity-restrict)
preserves accepted work and existing enabled/stopped intent through either capacity change.

Couriers can load or unload from any reachable side-adjacent cell of the base-level
clearance halo, excluding diagonal-only corners. There are at most twenty potential
endpoints for a 5×5 warehouse; ordinary routing rules decide which have usable footing
and routes. These candidates depend on the footprint, not current stock or active columns.
Couriers interact with the whole warehouse inventory rather than a particular visible item.
Registration and manual use do not require a courier route, while new automatic deliveries
do. After departure, route or endpoint loss does not alter the accepted journey or handover.
The [access decision](../specs/features/warehouses.md#q15--courier-loading-and-unloading-points-wh-02)
adds no designated entrance, exclusive dock, or NPC-congestion queue.

Material icons and disabled-column crosses appear only on free base pallets. Occupied columns
emit no marker, while empty columns of the same warehouse retain theirs. Packed cargo leaves
the resource texture visible between pallet and strap artwork, so the contents are recognizable
from outside; transparent parts of the packaging show the resource, not the background.

Warehouse visuals update on change without a fixed refresh delay. Multiple changes before
preparation may be combined into the latest coherent image, usually shown in the next
available frame. Under load, preparation can span frames without blocking simulation;
inventory and collision follow current logical state independently. Goods and base markers
stay consistent within each visual snapshot, and unchanged sources are reused.

Each chunk touched by the warehouse's full reserved envelope keeps a small reference to
its WarehouseId, registration, and bounds, without copying stock or active capacity. Claims
remain discoverable across chunk boundaries even when the object snapshot is unavailable.
A distant warehouse may look empty until that snapshot arrives, independently of central-pallet
chunk residency. Nearby movement and interaction load required object state and treat unresolved
possible cargo cells as unknown, while known shared clearance
remains traversable under ordinary collision rules. The
[discovery decision](../specs/features/warehouses.md#q12--missing-warehouse-state-discovery-and-streaming-ownership)
limits this index to at most eight chunk entries per warehouse; ordinary stock changes do
not rewrite those entries.

In player mode, Mouse2 opens warehouse management through any reachable pallet or packed
item, including when cargo hides all pallets. Mouse1/E takes with empty hands or puts the
matching held material; another material is rejected. Transfers take about 100 ms and each
requires a fresh press. Reach refers to the aimed pallet/item, not the layout origin or
the slot changed by the layout algorithm. Repacking, manual puts, and accepted delivery
arrivals displace an intersecting player into known free space; overlap alone does not reject
a valid warehouse put or make deliveries wait. Recovery preserves the resource transfer and
layout, and runs only on actual intersection. Warehouse dialogs release the cursor and
block movement/look/tool input while simulation and player physics continue. Displayed
values and action availability update as state changes; confirmation rechecks authoritative
conditions. Escape closes the dialog first, without opening the pause menu on that press.
Pallet targeting uses a low 1×1×0.2 box and cargo targeting a full unit cube. Rays above
empty pallets continue; decorative plank gaps do not require precise aiming. Reach uses
the ordinary inclusive four-metre distance to the nearest vertex of the targeted full
unit cell. [Q9](../specs/features/warehouses.md#q9--targeting-reach-dialogs-and-actor-overlap)
records these interaction rules. In observer mode, key 9 selects pallets and keys 1–8
retain their assignments. Tab switches putting/removing; Mouse1/E adds one unit of the
selected material in putting mode, and Mouse1/X discards one unit in removing mode.
Edits are instant and leave player inventory unchanged, while preserving warehouse
admission and member-protection rules. A selected-material mismatch reports the same
error as player mode; the warehouse material is never substituted automatically. A general
observer material-selection menu is planned separately.

Initial warehouse cargo comprises dirt, sand, snow, crushed stone, logs, planks, rebar,
reinforced concrete, both road item types, and pallets. Water is excluded until liquid mechanics
are designed. This is an explicit storage capability, separate from terrain placeability;
future cargo-only resources can be added when their item rules are defined. The
[material decision](../specs/features/warehouses.md#q10--allowed-materials-and-pallet-selection)
treats one stored pallet as one packed cargo unit, with roughly 100 ms put/take and no extra
resource from packaging. Players can recover an unregistered
pallet as one carried item in three seconds and reinstall it in one second under ordinary
support rules. Warehouse members require explicit unregister before removal. There is no
pallet crafting yet; initial pallets come from observer mode and can then be moved and reused.

For this iteration, changing a warehouse footprint requires stopping it, completing accepted
obligations, emptying it, and explicitly unregistering before rebuilding the pallet base and
registering anew. The new registration selects its central layout origin again. In-place expansion
preserving the existing registration/origin is deferred; changing the active-column count
remains a separate capacity setting within unchanged physical bounds. See the
[size-change decision](../specs/features/warehouses.md#q11--expansion).

Opening warehouse creation only checks the candidate; it does not temporarily reserve or
protect its pallets/clearance while material selection is open. Confirmation checks current
blocks, supports, planned targets, and claims again, then publishes registration and its
reservation together. Failure reports the reason without partial registration; canceling
an unsubmitted preview leaves no claim to release. See the
[confirmation rule](../specs/features/warehouses.md#q14--registration-checks-and-consistency).

Neighboring warehouses may share one empty block of aisle width, including overlapping
diagonal clearance. Their pallet/cargo volumes remain separate; shared space stays protected
while either warehouse is registered. The [warehouse clearance rule](../specs/features/warehouses.md#q8--reservation-overlap-and-blueprint-composition)
defines this independently of stored quantities or materials.

A warehouse can occupy the empty interior of an unfinished blueprint, and construction can
start around an existing warehouse. Every nonempty blueprint target must avoid the full
warehouse envelope, including reserved clearance and unused cargo cells; supporting floor
blocks must already exist. Stock transfers remain available, but real pallets inside the
active construction box cannot be removed even after warehouse unregister. Completing the
building releases its extraction ban while preserving a registered warehouse's restrictions.
The [composition rule](../specs/features/warehouses.md#q8--reservation-overlap-and-blueprint-composition)
keeps these independent from the prohibition on overlapping two unfinished blueprint boxes.

Each pallet requires an eligible solid block directly below, without a 3×3×3 platform.
The pallet supplies no construction support of its own. Its necessary floor remains
protected while the pallet exists, including after warehouse unregister; see the
[pallet foundation decision](../specs/features/warehouses.md#q7--pallet-support-and-the-floor).
Eligible floors are existing structural materials (earth/clay, natural rock, crushed stone,
rebar/concrete, and wood) plus solid country road. Sand, water, snow, leaves, adaptive roads
in either shape, other pallets, and packed goods do not qualify; the spec lists exact types.

The initial material-flow idea is demand-driven:

1. A workstation requests the inputs needed for one unit of work from a warehouse within its local radius.
2. The warehouse aggregates requests from the workstations it serves.
3. Couriers deliver inputs to the workstation.
4. Once the workstation produces an item, it places an order to transport that output to a warehouse.

This combines pull requests for inputs with an explicit delivery request for outputs. The overall choice between push, pull, or a hybrid economy is still open; this sequence captures the current idea rather than prescribing a complete scheduling system.

### Stopping, reactivating, and dismantling objects

Stopping and dismantling are separate actions. A player can stop a simulation object without destroying it. It then accepts no new work, but already accepted operations and deliveries complete normally. A workstation finishes its current operation; a warehouse continues receiving deliveries already committed to it. These completions do not automatically enable new work on the stopped object.

After its outstanding obligations finish, the object remains intact and inactive until the player explicitly enables it again. The player may instead dismantle it once it has stopped and all outstanding operations and deliveries are complete. Stopping does not request or trigger automatic deletion.

This lets players take even a continuously busy object out of service while preserving accepted work. The [warehouse lifecycle](../specs/features/warehouses.md#q4--empty-is-not-obligation-free-wh-04) keeps manual extraction available while stopped and requires all accepted deliveries to finish and stored goods to be removed before unregister or material change. General production follow-up obligations remain separately specified. The [simulation notes](simulation-notes.md#stopping-is-separate-from-dismantling) preserve these boundaries without selecting an implementation.

### Food as the cost of labor and delivery

Food spoils over time. It also pays for work and transport: for example, producing one unit at a workstation consumes food, and a courier consumes food to move goods. Food deliveries have higher priority than ordinary goods.

A delivery starts only when enough food is available from the configured supply source. Longer deliveries require more food, including the cost of transporting that food itself. This can impose a practical delivery radius: roads permit longer journeys by reducing travel time and food cost, while off-road travel supports shorter ones. Better preservation technologies extend reach by keeping food usable for longer.

All required inputs and operating resources are consumed in full when an operation or delivery starts. Production consumes its recipe ingredients and full food cost at launch; a delivery pays its full operating cost at departure. There is no progressive consumption or additional charge at completion. Later food shortages cannot interrupt work already paid for, and food consumed as payment no longer has a spoilage lifecycle. Goods being transported remain cargo, separate from the resources consumed to transport them. See the [resource consumption rule](simulation-notes.md#consume-resources-at-start).

The player can set a food-consumption rate limit for a dispenser. The proposed operating loop is:

1. If work exists within its service area, the dispenser requests food from its assigned source.
2. A courier transports it, consuming part of the supply as the delivery cost.
3. Once food is available, local NPC work can proceed.
4. If food accumulates because consumption is lower than supply, the dispenser reduces subsequent orders.

The precise meaning of the rate limit, replenishment thresholds, and allocation between competing jobs still needs design. The goal is a controllable flow of labor and supplies that avoids unnecessary stockpiling and spoilage.

### Food preservation and storage

| Food/storage approach | Intended preservation behavior |
| --- | --- |
| Primitive food | Shortest shelf life. |
| Packaged food | Around 2–3× the shelf life of primitive food. |
| Refrigerated food | Longer shelf life while stored in a refrigerator, which consumes energy except in sufficiently cold biomes. |
| Frozen food | Almost indefinite storage while kept in a freezer, with energy consumption except in the coldest biomes. |
| Permafrost storage | Possible use of permanently cold ground at depth to preserve food; the details are exploratory. |

Food is stored in special **crate** blocks, rather than ordinary uniform solid blocks. A crate has a quantity ranging from empty to full, and its appearance shows its fill level. When fully emptied, it disappears; crates above it in the same stack move down by one cell.

How this stack behavior interacts with general support and removal rules needs an explicit design. The visual and storage behavior is the intent; it does not yet define the structural privileges of crate blocks.

## Power and technological reach

### From labor to machinery

A simple lift illustrates the desired progression. A worker turns its drum, so using it costs food. A later steam-powered version reduces reliance on human labor but requires coal, and possibly an engineer for maintenance. Animal power could form an intermediate stage.

The broad progression being considered is:

**Human labor → animal labor → wind towers / water wheels → steam (coal) → gasoline or diesel → electricity.**

This is an illustrative progression, with useful local alternatives rather than a finalized mandatory research sequence. Windy areas favor wind power; fertile areas can favor growing feed for working animals. Water wheels depend on resolving the deferred water features.

### Energy model remains open

There are three broad options:

| Option | Consequence |
| --- | --- |
| Food as the only energy resource | Every process consumes food, including vehicles and computers. This gives the economy one common operating resource. |
| Food plus liquid fuel | Separates biological work from machine power and creates fuel production and distribution. |
| Food plus electricity, with or without liquid fuel | Adds electrical generation and supply, potentially alongside fuel-based transport. |

The richer progression above expresses an ambition, while these alternatives leave room to simplify the actual economy. A working decision is still needed before power-dependent systems become concrete requirements.

The intended storage contrast is that food is difficult to stockpile because it spoils, electricity is difficult to store for later use, and gasoline can be accumulated without spoilage or a comparable time limit. This does not imply physically infinite fuel-storage capacity. Cold storage and permafrost would create useful exceptions to food's usual limitations.

### Remote supervision and travel

Large antennas provide visibility into activity within their coverage area and allow limited remote orders. A player can configure production or turn it on and off, but cannot construct new buildings through antenna access alone.

Airfields enable fast travel between equipped sites in exchange for food and fuel. The aircraft should take off, fly, and land so the journey is perceived as travel through the world. It should not appear as an instantaneous teleport.

Near the end of progression, internet connectivity and drone or robot stations enable a stronger form of remote presence. The player can take control of an avatar at an equipped location and perform local actions without the earlier antenna restrictions. This should feel like operating a remote machine. The player's carried materials do not transfer to the remote avatar; supplies remain local to the place where they physically exist.

## Simulation direction and technical implications

This section preserves technical ideas that help explain the vision. It does not choose a final scheduler, route representation, cache, threading model, or persistence format.

The main performance goal is to let simulation threads sustain whole-world activity in the late game with minimal waiting and coordination. Throughput takes priority primarily in the simulation and the world-data service it relies on. Client threads may favor low latency where it does not degrade overall performance or simulation throughput, but their demand on the world-data service must be controlled to avoid indirectly slowing the simulation.

The [simulation notes](simulation-notes.md) preserve the author's 2026-11-05 clarification of the automated-world goal, boundaries between players, the world-data service, and the simulation, startup without a full-world scan, workstation prerequisites, and separate production and delivery jobs. They also retain architecture alternatives for later consideration without selecting one.

The [ownership principles](simulation-notes.md#state-ownership-and-publication) assign blocks, chunks, loading, and publication to the world-data service; task state, obligations, and work/dependency/routing indexes to simulation; and visual presentation to clients. Each mutable fact has one authoritative source. Exclusive mutation access and client publication may operate in batches, while resource accounting remains consistent. Warehouse stock, incoming promises, capacity configuration, geometry, and lifecycle belong to persistent simulation objects; world-data retains terrain and derived spatial claims, while accepted deliveries own cargo in transit. Warehouse Q17 retains player inventory in world-data service; manual warehouse transfers update both owners as one logical resource transition, with the concrete commit/capture protocol under Q18. Other storage contracts and the wider economy's ownership units, threads, and access/publication mechanisms remain open. Warehouse Q22 selects distinct state domains on the existing service executor; Q24 selects independent object subscriptions with full snapshots.

The [condition-check policy](simulation-notes.md#consistency-of-condition-checks) permits recent mixed observations only for individually discussed checks. Room recognition requires stronger consistency; blueprint-surroundings checks may be simplified with explicit accepted deviations. Resource consumption and transfers remain consistent. These permissions do not select a synchronization mechanism or change existing feature implementations.

The initial performance target is 100,000 simultaneous work and delivery tasks, represented in gameplay by active NPCs, on a mid-range gaming PC with 4–8 CPU cores and 32 GB of system RAM, ideally also supporting a 16 GB machine. This measures simulated activity, not persistent characters or simultaneously rendered models. It is a target for the upcoming simulation, not an implemented or measured capacity. The [design principles](../DESIGN_PRINCIPLES.md#make-scale-measurable-from-the-first-simulation-prototype) define the remaining workload and resource budget choices.

### Persistent work independent of observation

Simulation time advances while the world is running and not paused. Closed worlds and stopped servers have no offline progress; loading resumes saved time and task progress without catching up to real time. A running dedicated server may continue with no connected players. The [world-time rules](simulation-notes.md#world-time-and-no-offline-progress) distinguish server downtime from a player's absence.

At normal load, simulation seconds advance at the same rate as real seconds; task times use millisecond resolution without requiring a millisecond update loop. In-game day length is a separate balance choice. Independent events need no global ordering or deterministic replay, while causality, resource consistency, and gameplay priorities remain enforced. Single-player pause stops the world; multiplayer menus do not, but the owner or an administrator may pause it explicitly. System sleep or a whole-process debugger stop adds no simulation time and does not trigger catch-up when execution resumes. Scheduled events remain intact; ordinary event-processing delays are a separate policy.

New work normally starts when processing accepts it. For a simple dependency on a late-produced or late-delivered good alone, apart from food, use an earlier start derived cheaply from the predecessor's scheduled completion. Food need only exist when processing accepts and pays for the task; its historical availability is not reconstructed. If processing finds insufficient food, a later start after waiting for food receives no compensation. Resource accounting remains consistent, and complex resource dependencies use the default start-at-processing rule. Compensation cannot exceed the actual delay, 5 simulation seconds, or half the operation's duration. It leaves at least half the duration after acceptance and cannot cause immediate completion. The [late-processing rules](simulation-notes.md#late-processing-and-dependent-work) define the calculation and remaining questions.

Brief processing delays retain normal clock speed. Sustained capacity shortages slow a common simulation clock throughout the world while camera, input, and UI remain responsive. Accepted schedules and costs stay fixed in simulation-time units. Recovery returns to 1x without accelerated clock catch-up or debt for time not advanced; pending tasks and events remain intact. Prototype measurements will establish acceptable production-rate deviations for short operations, long operations, and complete chains. The [overload rules](simulation-notes.md#coordinated-slowdown-and-recovery) distinguish this behavior from the thresholds and implementation still to be designed.

Global overload feedback consists of an averaged indicator of measured simulation-clock speed, separate from FPS, and an unobtrusive warning for sustained overload. Avoid repeated notifications and unstable warning/recovery transitions, using inexpensive aggregate measurements. This does not require per-object explanations of delayed automatic starts or select any object-panel design. Future panels may show missing gameplay resources; their scope remains for later UI design. The [feedback rules](simulation-notes.md#global-overload-feedback) leave numeric thresholds and concrete presentation open.

Task state retains both the assigned start and actual acceptance/start time, including across save/load. Clients use this distinction to show a newly accepted compensated operation from its beginning, accelerated by no more than 2x due to compensation. A courier must start with the pickup rather than appear already carrying cargo along the route because of a backdated start. Late notifications and observing already-running work require their own presentation policy under **SIM-19**; visuals never change the authoritative schedule.

When capacity is insufficient, new operations wait for acceptance without consuming resources or advancing their progress, and must remain eligible for later reconsideration. Accepted operations and deliveries retain their obligations and receive processing preference, while new eligible work and every active region must continue to receive processing opportunities. Player presence must not accelerate nearby production. Client demand is budgeted, and combined recheck notifications must preserve resource accounting, completions, and compensation timing. The [work-budget rules](simulation-notes.md#bounded-work-and-fairness) define these guarantees while leaving concrete limits and scheduling mechanisms open.

Deliveries have persistent task state that moves goods through the world; they do not require persistent individual couriers between jobs. Saving and loading must preserve enough state to resume work, including active tasks, cargo, the fact that required resources were already consumed at departure, and travel progress. Resuming started work must not charge those resources again. A saved world must represent the ongoing economy, not just its terrain and buildings.

Planning creates no accepted obligation. In the first version, acceptance and actual start combine payment, cargo ownership where applicable, task creation, and obligations into one coherent transition; failed starts leave no partial spending or transfer. Applying completion coherently accounts for the result, completed status, and fulfilled obligations. Retrying either transition must not duplicate its effects. The [task-transition rules](simulation-notes.md#consistent-task-start-and-completion) preserve these guarantees without selecting coordination or persistence mechanisms or requiring a disk write for every operation. For warehouse destinations, the [selected capacity policy](../specs/features/warehouses.md#q3--destination-capacity-and-overflow-wh-01) adds aggregate reservation to departure and consumes it coherently during cargo handover.

Travel time must not depend on whether a player sees the courier. Observation must have no effects that modify authoritative world state. Rendering may adapt the visual movement to be plausible, but cannot change production, delivery outcomes, or the underlying schedule. The same principle applies when several players observe the same activity.

We do not need to update a precise rendered pose for every unseen courier. We do need efficient queries for active deliveries and work in selected chunks at the current simulation time, so nearby activity can be displayed without scanning all tasks.

A client may keep one visible worker at a continuously operating workstation across multiple jobs. A delivery's model may appear and visually approach the pickup point; after arrival it may walk away and disappear or be reused for another nearby delivery. These animations and reuse choices must not delay task starts or completion, add resource costs, or create simulated approach and return journeys. Work does not wait for a model to appear or become available, and clients may choose different visuals for the same authoritative task.

### NPC movement and visual separation

In the first version, NPCs do not collide with or block each other and do not generate traffic congestion in the simulation. Two couriers can use a narrow passage in opposite directions without waiting for each other. Other NPCs do not change a delivery's route, duration, or food cost; terrain and roads still determine traversability and travel costs.

Visualization will likely separate displayed movement to reduce overlap between NPCs. This is purely a presentation effect: it cannot change authoritative positions or progress, schedules, resource costs, or production and delivery outcomes. The simulation behaves the same whether this visual effect is present or absent, and regardless of who observes the NPCs. No visual separation algorithm is chosen here.

### Accepting a delivery and paying for it

A delivery from A to B requires a planned route and its start prerequisites. No existing courier has to be found or brought to A. The simplest payment model takes the required food from a dispenser in A; if it is unavailable, the task does not start.

A more flexible route configuration could choose one of four policies:

- Always pay from A.
- Always pay from B.
- Prefer A, falling back to B.
- Prefer B, falling back to A.

Whichever supply source is selected, including payment from the destination, consume the full food cost when the delivery starts. The food must be available and usable at that point; it is not reserved for consumption on arrival. The choice of source policy remains open, but the time of consumption is fixed at departure.

Calculate travel duration when transport starts. Its accepted food cost and travel duration remain fixed in simulation time despite subsequent changes along the route. The first version does not recheck or replan active routes. Stopping a destination preserves accepted deliveries, and dismantling must wait until its outstanding obligations finish, as described in the [object lifecycle](#stopping-reactivating-and-dismantling-objects).

### Planned journeys and visual reconstruction

The initial idea is to calculate a journey in advance, including when the courier reaches each part of it. A candidate representation records chunk entries:

```text
[{ timestamp, chunk_id }, ...]
```

This schedule allows the current chunk to be found from elapsed time, including by a simple scan initially. It is a per-delivery representation idea; an efficient query for all active deliveries in selected chunks may need an additional index.

Two ways of representing finer movement are under consideration:

| Approach | Idea and tradeoff |
| --- | --- |
| Compressed full route | Store intervals of movement in the same direction, splitting them at chunk boundaries so each chunk's entry point is easy to locate. Avoid storing every individual step. |
| Chunk itinerary with local reconstruction | Store the chunk sequence, timing, and enough entry/exit information to recreate visible movement within a chunk using its current geometry. This reduces stored detail but may produce movement different from the originally planned path. |

In the reconstruction approach, geometry may have changed since the journey was planned. A simplified visual path could permit movements normally disallowed during route planning, so the courier still reaches its scheduled exit or destination on time. The intent is to fit the animation to the journey's authoritative data while making it as plausible as possible to the observer. The policy below governs whether a world change affects an active journey; these cases must not acquire different outcomes merely because someone is watching.

Reconstructing the exact original route from historical chunk snapshots was considered, but retaining arbitrary-time snapshots appears impractical. Planning all couriers against a retained common snapshot is another possibility, with its own costs. Even an exact historical path could conflict with today's geometry, so snapshots would not remove the need to adapt visible movement. No snapshot-based solution is selected here.

### Responding to world changes during travel

In the first version, an active delivery's route is not rechecked or replanned after departure. Its duration is calculated when the delivery starts and remains fixed in simulation time. Changes along the route, including removal of a bridge or creation of a better path, do not change that schedule or the accepted food cost. Updated routing data affects new deliveries.

Visualization may adapt the displayed motion to current terrain, for example to keep an NPC from walking through the air where a bridge used to be. These adjustments are purely visual: they must not change authoritative world state, travel progress, arrival time, food costs, or delivery outcomes. They must not make the simulation depend on whether, or by how many players, the courier is observed.

Completing an accepted journey despite route changes is an intended gameplay rule; its acceptability does not depend on those changes being rare. Stopping a destination does not cancel its accepted deliveries, and ordinary player dismantling cannot remove it while they remain outstanding. Explicit order cancellation and exceptional failures still need cargo and task policies; they do not introduce route revalidation in the first version. These choices guide the upcoming simulation and do not describe implemented courier behavior.

### Routing across roads and terrain

Roads increase movement speed and reduce food consumption, so couriers should usually prefer them. Route quality should be reasonable from the player's perspective; mathematically optimal routes are not required.

Precomputed connectivity maps and/or route graphs may help plan across many chunks. A useful system must consider that a courier may benefit from entering or leaving a road partway along it, rather than only at endpoints.

The main routing alternatives are:

- Allow mixed road and off-road travel throughout a journey, including shortcuts and transfers between nearby roads.
- Restrict the main journey to roads, with off-road legs for reaching a road from the origin and leaving it for the destination. Entry/exit selection, and transfers between roads that pass close without intersecting, remain unresolved in this model.

The second approach simplifies the travel model but still has routing choices to solve. Neither is selected yet. Both need to account for terrain, travel time, food cost, and the world's wrapped x boundary.

### Asynchronous connectivity and caching

Connectivity and route-related data should update asynchronously on a separate worker, without blocking gameplay or the main thread. Ideally this work also avoids blocking the world-data service; how far that can go without excessive coordination complexity is an open architecture question.

A route using connectivity information roughly 100–500 ms out of date is acceptable as an initial tolerance, in conjunction with the separation between the journey schedule and its animation. This is an intended tolerance, not a measured performance guarantee or a complete policy for stale data.

Reuse as much connectivity work as practical. One candidate is to mark changed cells as dirty and inspect whether they actually affect cached connectivity or routes, instead of discarding all related caches whenever a chunk changes. A building growing upward will often leave the road network below it unchanged. Any selective invalidation scheme still needs to detect edits that do affect traversal; specific cache dependencies and publication rules belong in an implementation design.

## Using this vision for decisions

When comparing technical approaches, ask whether they support the direction above:

- Can the simulation initiate and sustain most world activity as settlements grow?
- Do materials and operating supplies retain meaningful locations and transport costs?
- Can work continue and resume after loading, independently of rendering and player proximity?
- Can the same world/player boundary later support multiple clients and authoritative world updates?
- Do routing and connectivity scale without making ordinary world edits stall gameplay?
- Does construction remain understandable while allowing stronger materials and automated building to matter?

These questions favor preserving useful foundations, not implementing every end-game feature early. A smaller experiment can deliberately simplify a mechanic. Record the reason and what the experiment is intended to teach, then revise the vision when experience changes the desired direction.

Before committing to related features, the main open design choices are:

The [simulation open questions](simulation-open-questions.md) turn the simulation-related choices into a decision list with stable IDs. The [warehouse specification](../specs/features/warehouses.md) settles first-version storage behavior, including count-only repacking, reduced active capacity, guaranteed destination capacity at departure, and explicit Stop/Enable with stopped, empty, obligation-free unregister/material change. Full logistics allocation and perishability remain separate follow-ups.

| Area | Decision still needed |
| --- | --- |
| Economy and power | Food-only energy versus separate fuel/electricity; which progression stages earn their complexity. |
| Logistics | Push/pull balance, supply radii, food payment source, allocation between competing jobs, priorities, replenishment controls, and non-warehouse production obligations when stopping or dismantling. All required resources are consumed at the start of an operation or delivery. |
| Routing | Mixed terrain versus road-centered travel; route representation; visual adaptation to changed terrain; cargo/task outcomes for explicit order cancellation and exceptional failures. Active routes are not rechecked in the first version; destinations cannot be dismantled while deliveries remain outstanding. |
| Settlements | Building recognition, service coverage, settlement growth, and needs at each technology level, using local workforce rather than persistent individual NPCs. |
| Construction | Long-term weight/span rules and large-scale concrete workflows. The blueprint specification fixes its first-iteration gameplay; technical resource limits need implementation measurements. |
| Storage | Spoilage, preservation, permafrost, and food-crate stack behavior. |
| Geography | Biome overlap, a separate fertile-soil category, and eventual rivers/lakes. |

For current implementation behavior, consult [architecture](architecture.md), [voxel world](voxel-world.md), [coordinates](coordinates.md), [world configuration](world-configuration.md), [block placement](block-placement.md), and [country roads](country-roads.md). Feature specifications under [`specs/features/`](../specs/features/) define concrete feature scope and acceptance criteria. This vision supplies intent and tradeoff context; it does not silently replace those documents or turn every exploratory idea into a requirement.
