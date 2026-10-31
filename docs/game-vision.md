# Game vision

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

“People,” “minions,” “NPCs,” and “workers” generally mean the same thing here: NPC creatures represented by the simulation that can carry out player-directed work. A **courier** is an NPC performing a transport task.

This does not imply that every person visible in a settlement needs an individually simulated domestic life. Houses support the settlement and improve nearby NPC efficiency. People shown inside houses can be a visual effect only; those decorative inhabitants are not additional simulation agents. Active workers and couriers do have the state needed to perform their jobs.

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

Progression connects settlement growth, production, research, and transport. NPCs need housing, production buildings, food, and potentially clothing; their needs grow as technology advances. The current clothing idea applies to cold biomes rather than requiring it everywhere. Houses enable population growth and improve the efficiency of NPCs nearby, without requiring simulated household routines.

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

Support eligibility and occupancy are distinct. A block directly below which cannot provide the required support should contribute no support, while still permitting another legal support route. For example, planks with valid lateral plank support may sit above dirt without requiring the dirt to be a stable platform. This does not let unsupported dirt become a foundation or grant lateral support to materials which lack it. The blueprint iteration includes correcting the current validator to follow this rule while preserving material-specific limits.

Rebar and reinforced concrete keep their existing direct-support rules: crushed stone alone is not an eligible foundation, while qualifying platforms and legal lateral support remain available. The earlier proposal to add reinforced-on-crushed direct support has been withdrawn. Blueprint capture may instead change the conflicting support material under the narrow normalization rule below; ordinary construction uses the same rules as before.

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

Players can save a building they have already constructed as a blueprint, create one interactively block by block, or obtain one through research/progression. Capture and interactive planning produce private blueprints by default, owned by the receiving player and stored per player in that world's save. Progression rewards are intended to be shared by default, accessible to every player on the multiplayer server. Converting a private blueprint to shared is a future capability. The first planned iteration covers capture and application; planning, rewards, sharing, and multiplayer are deferred.

A blueprint records block types and their 3D arrangement. Its normalized completed design must satisfy structural rules without depending on source blocks outside the capture box, assuming a **stable platform beneath every occupied block in its globally lowest layer**. Each platform is a filled 3×3×3 cube centered immediately below that block, using the [current qualifying materials](block-placement.md#stable-platforms). Platforms reset construction-height counters, so the source terrain's elevation does not reduce the blueprint's remaining allowance. Internal height/span limits still apply. Remove empty outer layers when saving; retain internal cavities. Capture can include an unfinished blueprint, interpreting its miniatures as completed logical blocks.

Capture starts with ordinary placement-cell targeting for the anchor, selects an XY rectangle using the camera ray's intersection with a fixed horizontal plane through that cell, then selects height using a fixed vertical plane through the rectangle. Both extents can be selected in open air without a terrain hit. The client obtains all selected chunks in full block form through ordinary world-service subscriptions, then freezes the player's current view, including effective pending edits and miniature types, into an owned main-thread snapshot. A bounded helper validates its detached contents in isolation; success must arrive before name entry is enabled. Confirming the name transfers exactly that checked definition to WorldDataService for saving, without its source location. Later source changes or rejection of a captured pending edit do not alter the design. If data must load first, capture records the view when loading completes. Source retention is released after copying, and no authoritative source-state synchronization is required. Temporary unconfirmed preparation is never part of autosave and is discarded on cancellation/exit; an already submitted Save follows normal save/exit handling. The previous service-owned capture workflow is retained in the feature spec as a rejected alternative.

Blueprint selection and name entry block gameplay controls while the world continues running, including player gravity/collision, NPC/service changes, block timers, streaming, and saving. A large first-iteration workload is approximately 100×100×32 cells, with most designs smaller. That is a supported scenario rather than a fixed maximum. Large application checks also need bounded preparation and atomic final publication, so the world remains responsive while a site is admitted.

Placement starts with a full-size, noncolliding preview, rotatable in 90-degree clockwise steps. Applying it requires actual bottom platforms and free cells at every nonempty blueprint target, even if an existing block has the correct type. Existing blocks in blueprint-empty cells stay in place. The active site has a thin black/yellow box frame and a quarter-size floating block miniature at every pending cell. Miniatures do not block walking. A target accepts only its required material; placing the real block removes the miniature. Extraction is forbidden throughout the active box, including preexisting nontarget blocks, until all targets are fulfilled; then the frame and blueprint restrictions disappear. A site cannot overlap another unfinished site's box. Future NPCs deliver materials and assemble these sites; their logistics/scheduling are separate features.

Cheap structural approval during assembly is an explicit requirement: examine at most the real block directly below and four immediate XY neighbors. A real block below, or an eligible real XY neighbor beside a cell with air below, allows placement without repeating full height/span validation. XY support accepts matching logical material, the rebar/reinforced-concrete pair, and real natural rock for crushed-stone targets, matching the ordinary bridge-side family (stone, metal_ore, limestone, coal, deeprock). These are support relations; the required target material stays specific. Miniatures never count as real support for this check. Full design validity is established at creation. Temporary unsupported intermediate states, such as completing a beam from one endpoint before its other endpoint is built, are intentional. Future cancellation will leave already placed real blocks, even if this preserves a temporarily invalid arrangement; that cooperative/single-player compromise is accepted. Cancellation itself is deferred.

The game must not admit a world modification that invalidates affected real or planned constructions in the resulting logical world where all miniatures are filled. This applies to every gameplay actor and mutation path, including player/NPC actions, application, simulation/timers, debug/service commands, batch edits, and indirect effects. Preserve the ordinary exemptions for generated terrain. This is a restriction on world-mutation admission; operations which preserve that logical arrangement by construction, such as blueprint fulfillment, need no repeated full validation.

The current progress guarantee is that all active sites can be completed in some shared order of block placements, potentially interleaving sites. One site may wait for a neighboring site's target to become real; for example, a plank target can lose its lower support through a legal edit and then need the adjacent site's plank built first. Independent completion of each site is a potential future improvement. The per-instance-reader and support-component alternatives remain deferred, with readers the preferred future direction. The global completion argument uses the valid completed world and cheap support covering ordinary routes, without a runtime graph/search or additional completion checks. It concerns structural feasibility; material delivery, access, and scheduling are separate.

Temporary ordinary physical invalidity may extend both inside and outside an unfinished site, affecting other partial or already completed buildings. Eventual physical validity follows from the admission invariant: completed structures satisfy ordinary rules once no unfinished construction affects their support windows. With the current validator, absence of pending targets within ±28 cells on each axis around every constructed cell is a sufficient condition; X uses its wrapped distance. The completed and physical worlds then agree in those windows. This needs no final building scan, repair operation, or additional searches on the five-neighbor fulfillment path. Future cancellation and its effects on remaining or surrounding structures are excluded from this contract and will be discussed separately.

Outside an active box, extraction uses ordinary structural validation against the world as if all pending miniatures were already completed blocks. There are no additional foundation locks: an original platform cell may be removed if the completed logical building still satisfies ordinary rules. This requires including planned cells among affected constructions, even before their first real block is installed. A blueprint fill leaves that completed logical world unchanged, which avoids repeating dependent validation for each fill.

Applying a blueprint also checks its completed composition with the destination once. Correcting lateral-support eligibility does not eliminate every conflict: a six-cell crushed-stone column joining an existing crushed-stone bridge above creates an illegal seven-cell run. Ordinary placements must validate the new block in both physical terrain and the completed logical world, then protect completed logical dependents. This also rejects the reverse order: adding a physically supported bridge above six pending column cells would make the new bridge the seventh crushed cell after completion. Physical target validation still prevents miniatures from providing real support. These checks run at application or ordinary edits, never on each blueprint-directed fill.

The initial material set is ordinary construction cubes: dirt, sand, crushed stone, tree trunk, planks, rebar, reinforced concrete, and solid country road. Capture first converts every included stone to crushed stone and grass/packed dirt to dirt, then validates. A valid result is unchanged. Only when reinforced blocks lack a legal support route because of crushed stone below may that support become reinforced concrete, continuing down the necessary support chain to a legal foundation or lateral route. The original logical snapshot, including miniatures, must already contain rebar or reinforced concrete; an unrelated reinforced block does not permit repairing other crushed columns. Thus seven stone under original rebar may become concrete, while a seven-cell stone-only column without a reset still rejects capture. Fully validate the final arrangement without changing ordinary material rules, removing cells, adding supports, or relaxing limits. A converted reinforced path reaching mineral height 21 without a reset or another valid route produces an explicit height-limit error and highlights its lower source support cells. This remains a path-height limit, not a limit on the total reinforced blocks in a blueprint. Dirt aging preserves blueprint fulfillment. Leaves, geological resources, clay, deeprock, water, snow, and adaptive/custom roads are excluded from this iteration.

The [blueprint specification](../specs/features/blueprints.md) records confirmed behavior, adopted UI defaults, the validation/performance contract, and the implementation measurement plan. Blueprints and unfinished sites use the game's single current logic and follow the general [save compatibility policy](persistence.md#save-compatibility). Before the first release, development saves carry no compatibility or migration commitment; future migration between released versions will be designed separately. Technical memory/work limits must be measured against the supported workload. This section records intended behavior, not an implemented feature.

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

A proposed warehouse is any room containing a **warehouse accounting** block, with a roof and at least one entrance/exit. Exact room detection and access rules are open.

The initial material-flow idea is demand-driven:

1. A workstation requests the inputs needed for one unit of work from a warehouse within its local radius.
2. The warehouse aggregates requests from the workstations it serves.
3. Couriers deliver inputs to the workstation.
4. Once the workstation produces an item, it places an order to transport that output to a warehouse.

This combines pull requests for inputs with an explicit delivery request for outputs. The overall choice between push, pull, or a hybrid economy is still open; this sequence captures the current idea rather than prescribing a complete scheduling system.

### Food as the cost of labor and delivery

Food spoils over time. It also pays for work and transport: for example, producing one unit at a workstation consumes food, and a courier consumes food to move goods. Food deliveries have higher priority than ordinary goods.

A delivery starts only when enough food is available from the configured supply source. Longer deliveries require more food, including the cost of transporting that food itself. This can impose a practical delivery radius: roads permit longer journeys by reducing travel time and food cost, while off-road travel supports shorter ones. Better preservation technologies extend reach by keeping food usable for longer.

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

### Persistent work independent of observation

Couriers are stateful agents moving goods through the world. Saving and loading must preserve enough state to resume their work, including active tasks, cargo, paid or reserved food, and travel progress. A saved world must represent the ongoing economy, not just its terrain and buildings.

Travel time must not depend on whether a player sees the courier. Observation must have no effects that modify authoritative world state. Rendering may adapt the visual movement to be plausible, but cannot change production, delivery outcomes, or the underlying schedule. The same principle applies when several players observe the same activity.

We do not need to update a precise rendered pose for every unseen courier. We do need efficient queries for couriers present in selected chunks at the current simulation time, so nearby activity can be displayed without scanning the whole population.

### Accepting a delivery and paying for it

A courier plans a route when accepting a task from A to B. The simplest payment model takes the required food from a dispenser in A; if it is unavailable, the task does not start.

A more flexible route configuration could choose one of four policies:

- Always pay from A.
- Always pay from B.
- Prefer A, falling back to B.
- Prefer B, falling back to A.

Payment from the destination raises an open choice: reserve food there, ensuring it remains usable until arrival, or deduct it immediately as part of accepting the task. Expiry and reservations must be accounted for consistently. Once food is successfully secured under the selected model, the delivery becomes active.

### Planned journeys and visual reconstruction

The initial idea is to calculate a journey in advance, including when the courier reaches each part of it. A candidate representation records chunk entries:

```text
[{ timestamp, chunk_id }, ...]
```

This schedule allows the current chunk to be found from elapsed time, including by a simple scan initially. It is a per-courier representation idea; an efficient query for all couriers in selected chunks may need an additional index.

Two ways of representing finer movement are under consideration:

| Approach | Idea and tradeoff |
| --- | --- |
| Compressed full route | Store intervals of movement in the same direction, splitting them at chunk boundaries so each chunk's entry point is easy to locate. Avoid storing every individual step. |
| Chunk itinerary with local reconstruction | Store the chunk sequence, timing, and enough entry/exit information to recreate visible movement within a chunk using its current geometry. This reduces stored detail but may produce movement different from the originally planned path. |

In the reconstruction approach, geometry may have changed since the journey was planned. A simplified visual path could permit movements normally disallowed during route planning, so the courier still reaches its scheduled exit or destination on time. The intent is to fit the animation to the journey's authoritative data while making it as plausible as possible to the observer. How to handle severe changes, blocked destinations, or deliberate route disruption still needs a gameplay policy; these cases must not acquire different outcomes merely because someone is watching.

Reconstructing the exact original route from historical chunk snapshots was considered, but retaining arbitrary-time snapshots appears impractical. Planning all couriers against a retained common snapshot is another possibility, with its own costs. Even an exact historical path could conflict with today's geometry, so snapshots would not remove the need to adapt visible movement. No snapshot-based solution is selected here.

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

| Area | Decision still needed |
| --- | --- |
| Economy and power | Food-only energy versus separate fuel/electricity; which progression stages earn their complexity. |
| Logistics | Push/pull balance, supply radii, food payment and reservation, priorities, and replenishment controls. |
| Routing | Mixed terrain versus road-centered travel; route representation; behavior when the world changes during a journey. |
| Settlements | Building recognition, service coverage, population growth, and needs at each technology level. |
| Construction | Long-term weight/span rules and large-scale concrete workflows. The blueprint specification fixes its first-iteration gameplay; technical resource limits need implementation measurements. |
| Storage | Spoilage, preservation, permafrost, and food-crate stack behavior. |
| Geography | Biome overlap, a separate fertile-soil category, and eventual rivers/lakes. |

For current implementation behavior, consult [architecture](architecture.md), [voxel world](voxel-world.md), [coordinates](coordinates.md), [world configuration](world-configuration.md), [block placement](block-placement.md), and [country roads](country-roads.md). Feature specifications under [`specs/features/`](../specs/features/) define concrete feature scope and acceptance criteria. This vision supplies intent and tradeoff context; it does not silently replace those documents or turn every exploratory idea into a requirement.
