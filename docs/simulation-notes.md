# Simulation notes

These notes capture the author's gameplay intent, constraints, and architecture ideas from 2026-11-05 for the upcoming simulation. They accompany the [game vision](game-vision.md) and [design principles](../DESIGN_PRINCIPLES.md). They are not an implementation design or a description of implemented behavior. Architecture alternatives below remain unselected.

The [open questions](simulation-open-questions.md) track decisions needed before implementation. Warehouse rules will be developed in a separate specification in the next PR; their questions are explicitly deferred there.

## Primary scenario and player intervention

The long-term goal is fully automated extraction and resource processing, production of construction materials and tools, logistics, and construction of large numbers of buildings and structures worldwide, including megastructures. Players can participate directly in building and carrying resources, but this becomes of little practical value as the economy develops. Prioritize throughput over latency primarily in world simulation and the world-data service directly supporting it. World rules and execution conditions should minimize waiting and coordination for simulation threads so late-game activity across the whole world can sustain its intended pace.

Without player intervention, the simulation should not pay synchronization overhead specifically for coordinating with player actions. When a player and the simulation concurrently make conflicting edits to the same blocks, simulation edits always win. This strengthens the earlier allowance to favor the simulation into a required guarantee for these conflicts.

Simulation logic should benefit from that guarantee: it must not need rollback handling for losing an edit conflict to a player. The guarantee must be established by the future coordination model, rather than assumed while conflicts remain possible. Handling player edits, conflicts between simulation workers, and unrelated failures still needs design; this rule does not imply that every simulation action is infallible.

## Local workforce and client-side NPCs

NPCs do not need to exist persistently in the simulated world. Work can begin automatically once its prerequisites, including the necessary resources and food, are satisfied. There is no additional requirement to find an individually available worker, bring that worker to the job, or return them afterward. The local workforce model does not introduce a separate finite pool of free NPCs as a start condition.

The simulation tracks work and delivery state, including cargo, resource payment, schedules, and progress. Clients visualize these tasks with NPC models. A continuously operating workstation may keep the same visible worker across successive operations. For a delivery, a courier model may appear, visually approach the pickup point, and show the transport. After completion, it may walk away and disappear or be reused for a nearby delivery starting at that time.

Appearance, approach, departure, and model reuse are presentation choices. They must not delay authoritative task starts or completion, add food costs or empty journeys, or determine whether work can begin. Reusing a nearby model is optional; a new delivery never waits for one to become available. Separate clients may make different presentation choices without changing the shared simulation.

The 100,000-active-NPC scale target therefore refers to concurrent work and delivery tasks represented by NPCs, not persistent characters or a requirement to render them all. Local infrastructure and resource prerequisites still matter; no NPC allocation system or visualization implementation is selected here.

## Participants and process boundaries

There are three participants:

- **Players** issue actions primarily to the world-data service. Direct delivery of some events to the simulation is an option to consider, not a selected interface.
- **World-data service** accepts changes from players and the simulation and distributes up-to-date chunk data.
- **Simulation** maintains its own state, relies on world-data service data, and communicates primarily with the world-data service. Player edits may affect it, but coordinating with those edits should not dominate its processing cost.

Player action handling currently runs in the same OS process as the game and the existing simulation logic. Future multiplayer clients will interact with the server through asynchronous messages over the network. Player interaction therefore cannot depend on in-process synchronization between client and server.

The world-data service and simulation will remain together in one server process. They may use in-process synchronization, including atomics, semaphores, and mutexes. This is a process constraint, not a choice of threads or synchronization primitives.

Client threads that provide the player experience may use a more balanced throughput/latency policy and prioritize responsiveness where it does not degrade overall system performance or sustainable simulation throughput. This applies to current in-process clients as well as future network clients. Their requests and subscriptions must not overload the world-data service: client pressure on that shared layer can delay simulation work even when the simulation itself has not changed. Specific budgets and coordination mechanisms remain open; the [design principles](../DESIGN_PRINCIPLES.md#prioritize-throughput-over-latency) define the priority.

## Simulation state and startup

The simulation needs its own index and may also maintain state distinct from the data currently stored in chunks. Opening a world must resume simulation in all areas containing active event emitters without scanning the whole world. The index, stored state, and recovery mechanism have not been designed.

## World time and no offline progress

The world simulates while it is running and not paused. Closing the world or stopping its server stops simulation time. On opening a saved world, resume from its saved simulation time without adding time for the real-world interval while it was closed. There is no offline progress or offline catch-up.

Accepted work retains its saved progress and remaining simulation-time duration. If a saved delivery has one simulation minute remaining, loading that save after a day still leaves one simulation minute. Closing the world does not complete work or age resources through elapsed real time.

A future dedicated server can keep simulating without connected players while it is running and not paused. Disconnecting a client is distinct from closing or pausing the server's world. Downtime of the server itself earns no progress.

At normal load, one real second advances the simulation clock by one second. A 30-second production operation therefore takes approximately 30 real seconds. Under overload, the previously agreed coordinated slowdown may make simulation time advance more slowly. The length of an in-game day is a separate balance setting and does not redefine the seconds used by production and delivery tasks.

Task timestamps and durations use millisecond resolution. This specifies how precisely time is expressed, not how often the simulation runs: work may be processed in batches, and an event may be handled after its scheduled timestamp. The [late-processing rules](#late-processing-and-dependent-work) define dependent-work timing; numeric acceptance tolerances will be selected from prototype measurements under **SIM-03**.

Events must preserve causality and consistent resource accounting. Independent events with the same timestamp may run in any convenient order or in parallel; a dependent action cannot use an output before the preceding action has completed. If two tasks contend for the same last unit of food, only one may start. In the absence of a gameplay priority, the winner may depend on processing order. A global total ordering of independent events and identical replay of every concurrent outcome are not required. This does not remove already agreed priorities, including simulation precedence over conflicting player edits.

Single-player pause stops simulation time. Opening an individual player's menu in multiplayer does not pause the shared world; its owner or an administrator may explicitly pause it for everyone. A whole-process suspension, such as computer sleep or a debugger stop, likewise contributes no simulation time. Resume from the stopped simulation time without accelerated catch-up for the suspension interval, retaining already scheduled events and their simulation-time deadlines.

An individual worker falling behind or a task being processed late is not a suspension of the whole world. The following sections define delayed-work and coordinated-slowdown behavior; implementation mechanisms remain unselected. These gameplay rules resolve **SIM-04** without selecting a clock representation, a scheduler, or the mechanism for detecting process suspension.

## Late processing and dependent work

The default for new work is to start at the current simulation time when processing successfully accepts it and consumes the required resources. If a predecessor was scheduled to complete at second 10 but is processed at second 12, a new five-second operation normally starts at 12 and is scheduled to complete at 17. The predecessor retains its scheduled completion time and paid cost; the delay affects when dependent work is accepted. This can reduce production rates, with different effects on short and long operations. Acceptable numeric deviations will be selected from prototype measurements under **SIM-03**.

Use an earlier assigned start for a narrow, cheap-to-evaluate dependency: the produced or delivered good is the sole prerequisite for the next operation, apart from food. Derive that start from the predecessor's scheduled completion, subject to the compensation limits below and without placing it before the good's logical production or arrival. In the example above, an eligible five-second operation is assigned start 10 and completion 15 even though it is accepted at 12. This exception is not a general permission to backdate any operation whose last missing ingredient has arrived; more complex resource dependencies always use the default start-at-processing rule.

Compensate at most **5 simulation seconds** and at most **half the new operation's duration**. For an eligible operation of positive duration `D`, accepted at simulation time `A` after its predecessor's scheduled completion `P`, use:

```text
compensation = min(A - P, 5 seconds, D / 2)
assigned_start = A - compensation
scheduled_completion = assigned_start + D
```

This applies when the prerequisite has completed and `A >= P`; it never anticipates a future prerequisite. Round compensation down if clock precision requires rounding, so neither limit is exceeded. At least half the operation's duration remains after actual acceptance. Compensation cannot make newly accepted work instantly complete or create a chain of already-overdue new operations. Uncompensated delay is not carried into that operation as additional catch-up credit. For example, a three-second operation accepted at 20 after its prerequisite completed at 10 gets only 1.5 seconds of compensation: assigned start 18.5, completion 21.5. A 30-second operation with the same delay gets 5 seconds: assigned start 15, completion 45.

Retain both the assigned simulation-time start and the actual acceptance/start time in task state, preserving the distinction through save/load and making it available to client presentation. A newly accepted compensated task must be visualized from its beginning, rather than seeking forward based on its assigned start. For a delivery, this includes the pickup at the source; compensation alone must not make a courier appear already carrying cargo partway along the route. Fit the normal operation animation into the remaining `D - compensation` simulation seconds, giving a compensation-induced playback factor of `D / (D - compensation)`, at most 2. Both timestamps let clients distinguish this case from work that was already running before they observed it. Purely cosmetic approach/departure remains governed by the existing visualization rules and cannot delay the authoritative schedule.

These limits prevent the simulation's compensation policy from skipping a new operation's visible beginning. They do not guarantee that a client receives its notification immediately. Presentation for late network updates, newly observed areas, and joining clients remains under **SIM-19**, without changing authoritative timing or making simulation depend on observers.

Food is deliberately treated differently: check and consume the full food payment at actual acceptance, without checking whether it existed at the assigned earlier start. Food arriving at 11 may therefore pay at processing time 12 for the operation assigned start 10. Inputs and food are still consumed consistently and exactly once before accepting the task or publishing its result. No payment means no accepted task; no resource may fund two tasks. The exception relaxes historical food availability, not resource ownership or accounting.

If processing cannot start the operation because food is missing, waiting for food becomes a separate cause of delay. When food later becomes available, start normally at successful processing/acceptance time with no compensation; assigned and actual start times are equal. Do not retain compensation credit from the earlier production or delivery. This differs from food already being available at the first processing attempt, where its historical availability remains irrelevant.

Do not introduce historical food-availability tracking, world-state reconstruction, or costly event ordering to support earlier starts. Only use dependency timing that is straightforward to derive from readily available information. If establishing eligibility requires complex resource reasoning, choose the default. Existing lifecycle rules, including rejection of new work by stopped objects, still apply. Destination-capacity requirements remain deferred to the warehouse specification; this exception does not waive them.

The start policy, food exception, compensation limits, two start timestamps, and overload rules below resolve the gameplay semantics of **SIM-05**. The 5-second compensation limit is separate from the 1–2 second allowance for selected condition checks. No scheduling architecture is selected.

## Coordinated slowdown and recovery

Keep normal simulation speed during brief processing delays and apply the late-processing rules above. Do not slow the entire world for every late event. Under a sustained capacity shortage, slow the common simulation clock throughout the world. Production, deliveries, and other processes governed by simulation time use that same time scale. This does not require simultaneous processing of events or a global barrier after each step.

At a sustained speed of 0.5x, ten simulation seconds take approximately twenty real seconds. Accepted tasks retain their simulation-time timestamps, durations, and paid costs; slowdown neither recalculates nor charges them again. The compensation cap remains five simulation seconds, which corresponds to ten real seconds at 0.5x, and the half-duration limit still applies. Camera, input, and interface responsiveness remain independent of the slowed world clock, subject to the existing shared-resource budgets.

When capacity recovers, return to normal 1x speed without accelerating the clock above 1x to catch up to elapsed real time. Simulation time not advanced during slowdown creates no debt. Accepted tasks and pending events remain intact and still require processing; recovery does not discard them. The bounded compensation rule continues to apply where eligible, but there is no additional recovery catch-up allowance.

Do not promise a fixed percentage of production-rate accuracy before the prototype is measured. At the target workload, compare expected and actual output for short operations, long operations, and complete production chains. Measure output relative to simulation time as well as effective simulation speed relative to real time, so intentional slowdown can be distinguished from inter-operation delays. Shared slowdown does not guarantee equal losses across industries; evaluate those differences separately.

Numeric production-rate tolerances are deferred to prototype acceptance criteria in **SIM-03**. Overload/recovery thresholds and measurement windows belong to **SIM-07**, while work budgets and the implementation of the shared slowdown policy remain design work under **SIM-06** and **SIM-08**. Revisit these before accepting the simulation prototype or committing to the corresponding scheduling design.

## Global overload feedback

Provide a world-level simulation-speed indicator and an unobtrusive warning for sustained overload. The speed indicator reports measured simulation-clock advancement relative to real time, averaged over a suitable interval: 75% means approximately 0.75 simulation seconds per real second. Show it separately from rendering FPS, and use measured advancement rather than only the requested clock-speed multiplier. Clock speed alone does not establish that every event is being processed promptly.

Brief delays should not trigger warnings. Use stable conditions for entering and leaving the overload state so the interface does not repeatedly switch between warning and normal states. Warn once when sustained overload begins and retain an indicator while it persists, without interrupting play or repeatedly displaying notifications. After sustained recovery, return the indicator to normal; a separate recovery popup is not required. Thresholds, averaging windows, and the mechanism for stabilizing state changes remain to be selected and validated with the prototype.

Keep this feedback inexpensive through aggregate measurements; do not scan all objects or trigger additional prerequisite checks to explain overload. Detailed attribution to CPU, memory, disk, or world-data service contention is left to debugging tools for now, rather than promised as a player-facing diagnosis.

At this stage, overload feedback does not require object panels or per-object explanations of why an operation has not started automatically. Future panels may show missing gameplay resources, but their design is not selected here. Capacity-waiting statuses and distinctions between unchecked prerequisites and known shortages are not requirements for the current UI scope; reconsider them only when designing the corresponding interfaces.

These global feedback and scope rules partially resolve **SIM-07**. Numeric thresholds for slowdown, warning, and recovery, measurement windows, and treatment of sustained event-processing lag even when clock speed reads 100% remain open for overload-control design and prototype validation. No concrete UI layout or diagnostics implementation is selected.

## Bounded work and fairness

When processing capacity is insufficient, defer accepting new operations. Deferred work has not started: do not consume its resources or advance its operation progress while it waits. Preserve a way to reconsider it later so a capacity-related deferral cannot silently lose work. At eventual acceptance, apply the existing prerequisite, payment, and SIM-05 timing rules; waiting alone does not complete an operation. The representation of deferred work and its wake-up mechanism remain unselected.

Already accepted operations and deliveries remain obligations. Queue pressure must not discard their cargo, completion, or production results. Give processing of accepted work, including completion and result handover, preference over accepting additional work, while ensuring that new eligible work continues to receive opportunities for admission. This is not an absolute priority that can indefinitely starve new work. Processing opportunity does not waive gameplay prerequisites or guarantee access to scarce materials.

Repeated notifications may be combined when their meaning is preserved. Several material arrivals at a workstation can often produce one pending request to reconsider its prerequisites. Every inventory change and completion must still be accounted for, and timing information required by SIM-05 compensation must remain available. Coalescing a request to recheck state must not discard the underlying resource transfers or accepted obligations.

All active regions must receive processing regardless of player presence. A large industrial area may legitimately need more CPU time than a single workstation; equal CPU allocation per chunk is not required. Continuous load in one region must not leave others without processing indefinitely. Player presence may prioritize delivery of visual data, but must not accelerate nearby production. Client requests and subscriptions to the world-data service need bounded budgets so they cannot displace simulation work.

These admission, obligation, notification, and fairness rules partially resolve **SIM-06**. Concrete limits for events, routing and deferred work, budget distribution between work classes and regions, bounded representation and retry of deferred admission, and client-request budgets remain to be designed and measured. Coordinate them with the common-clock slowdown policy and **SIM-03**, **SIM-08**, and **SIM-12**. No queue structure, threading model, or numeric limit is selected.

## Consistency of condition checks

Not every condition check requires a coherent world snapshot. For explicitly discussed cases, recent observations obtained at different moments may be sufficient, even when their combination describes a state that never existed simultaneously. A block already checked need not be checked again merely because it changed before the rest of the validation finished.

This permission must be evaluated for each check during feature design and implementation. A 1–2 second interval of inconsistency is an acceptable starting range for suitable checks, not a blanket tolerance for every rule. The relevant age runs from the observations through use of the result, including any queue delay. Each policy still needs to specify its time basis (real or simulation time), allowed age, and what happens if that age is exceeded.

Two examples establish the boundary:

- **Room recognition needs stricter consistency.** Accepting a room from a mixed observation of roof and walls is unacceptable if a broken roof leaves the room permanently classified as valid. Room validity must account for relevant world changes; a short reading window does not justify an enduring important rule violation. No validation or invalidation mechanism is selected here.
- **Blueprint surroundings may allow relaxed checks.** Suitability for applying a construction blueprint can be checked against recent mixed observations, accepting that concurrent changes to nearby blocks may violate ordinary construction rules. The exact checks and deviations must be discussed in that feature's design and implementation. This is a permitted direction for simplification, not a change to existing blueprint behavior or its specification.

Resource accounting remains consistent. Two operations cannot both spend the same last unit of food, and two deliveries cannot both claim the same cargo because a preliminary check saw it available. Permission for mixed observations applies to eligible condition checks, not to resource consumption or ownership changes.

Logical inconsistency also does not permit memory races, torn reads of compound state, or access to freed data. Avoiding a lock across an entire validation may be useful, but safe reading and writing still need to be established. No lock-free architecture is selected by these rules.

## Consume resources at start

All inputs and operating resources required for an operation or delivery are consumed in full at its successful start. For production, this includes the recipe ingredients and the full food cost. For delivery, the full food cost and any other required operating consumables are paid at departure. If the necessary resources are unavailable, the work cannot start.

The [late-processing exception](#late-processing-and-dependent-work) permits an assigned simulation-time start earlier than actual acceptance. In that case, consumption occurs at acceptance, before the task or its result is committed, and food need only be available at that processing moment. This is an explicit exception to historical payment timing, not permission to defer payment after acceptance.

Consumption and cargo transfers must remain consistent under concurrent work and player actions. A recent positive condition check does not entitle a task to resources that have already been spent or transferred elsewhere. The relaxed validation policy above does not permit double spending, duplicate cargo ownership, or partial accounting that starts unpaid work.

Started work does not reserve these resources for later consumption, consume them gradually, or pay again at completion. Later depletion of the dispenser cannot interrupt already paid work. Food already consumed as payment can no longer spoil and invalidate that payment. This does not change spoilage rules for food still stored or carried as cargo.

Transported goods remain cargo: at departure they leave available source stock and belong to the delivery until handed over. They are distinct from resources consumed to perform transport. Saving and loading must preserve started work and its paid status without charging those resources again. This is a gameplay and persistence requirement; no resource coordination mechanism is selected here.

## Workstation example

Every simulation action has prerequisites. Producing a concrete block at a workstation requires:

- An empty output slot, or a guarantee that it will be free by completion.
- Delivered inputs: cement, crushed stone, sand, and water.
- Coverage by a food dispenser with enough food to pay for the operation.

Whether to require guaranteed destination capacity before starting every delivery is deferred to the warehouse specification in the next PR; see **WH-01** in the [warehouse questions](simulation-open-questions.md#deferred-to-the-warehouse-specification-in-the-next-pr). The output-slot condition above records the workstation example; it does not establish a universal capacity-reservation policy for all work and deliveries.

Relevant changes, such as input delivery or food arriving at the dispenser, must cause the prerequisites to be reconsidered. When all conditions are met and the workstation is enabled, production can start, consuming all recipe inputs and the full food cost at that moment. This describes the triggering behavior without selecting how checks are scheduled or combined.

A player may stop a workstation. It stops accepting new work, finishes already accepted operations and deliveries, and then stays inactive until explicitly enabled again. Materials arriving for accepted deliveries do not automatically restart production while it is stopped. An operation already in progress completes normally.

## Stopping is separate from dismantling

Players must be able to withdraw an object from active simulation without destroying it. Stopping closes it to new work while preserving its participation in outstanding obligations until they finish. For example, a stopped warehouse still receives deliveries it has already accepted, but accepts no new ones. Stopping does not cancel accepted work or remove its destination.

Once outstanding operations and deliveries finish, the object remains intact and inactive. The player can later enable it again or explicitly dismantle it. Stopping does not queue automatic deletion, and dismantling is allowed only after the object has stopped and its outstanding obligations are complete. This avoids requiring a continuously busy object to become idle by chance before it can be taken out of service.

These are gameplay rules, not a selected lifecycle implementation. The exact scope of an accepted obligation, including follow-up work for an operation's output, and the handling of stored materials during dismantling still need specification. The [game vision](game-vision.md#stopping-reactivating-and-dismantling-objects) records the same lifecycle.

## Production and outbound delivery are separate jobs

Moving a produced block to storage is a separate task from producing it. Once the block has been produced, a storage destination is sought. A courier starts transporting it when the required resources are available, consuming the full food cost and any other operating consumables at departure. The produced block itself becomes the delivery's cargo.

In the first version, calculate travel duration when the delivery starts and do not recheck or replan its route afterward. Its accepted food cost and travel duration are not recalculated in response to world changes along the route. This is a deliberate performance simplification. The fixed duration is measured in simulation time; coordinated slowdown under overload changes how quickly that time advances in real time.

Visualization may adjust the NPC's motion to fit current terrain, for example to avoid walking through the air after terrain changes. This is purely visual and must not feed changes back into simulation state, travel timing, food costs, or delivery outcomes. It does not introduce simulation route checks, including when the NPC is observed by several players.

The [travel policy](game-vision.md#responding-to-world-changes-during-travel) applies this simplification to active deliveries; updated routing information serves new deliveries. Stopping a destination preserves already accepted deliveries, and ordinary player dismantling cannot remove it while those obligations remain. Explicit order cancellation and exceptional failures are separate questions whose cargo and task outcomes remain unspecified; they do not introduce route checks in the first version.

## NPC movement does not create congestion

In the first version, NPCs do not collide with or block one another in the simulation. Opposing couriers on a narrow bridge and crowds near a warehouse do not create traffic queues or change travel duration or food costs. Terrain and road properties still matter for route planning.

Movement separation will likely be added as a visual effect to reduce overlap between displayed NPCs. It must not change authoritative routes, progress, arrival times, resource costs, or work outcomes. No visual avoidance algorithm is selected, and the simulation must behave identically without this visual effect or when different players observe the activity.

## Architecture ideas to revisit later

The author has not chosen a simulation architecture. Candidates include:

- World-data service and simulation on the same thread.
- A separate world-data service and a simulation event loop acting as an orchestrator for workers. One variant isolates workers behind inbox communication with the orchestrator; another allows workers to access the world-data service themselves.
- A separate world-data service and simulation worker threads without an orchestrator.
- Another approach if it better serves the requirements.

One possible structural simplification is to ensure that only one simulation worker can modify a particular chunk at a time, reducing synchronization with other simulation workers and ideally with the world-data service. This is an exploratory idea. No chunk ownership, partitioning, worker topology, or cross-chunk coordination scheme has been selected.

### Direct mutation of distant chunks

Another candidate is to let a simulation thread update world-data service data directly, avoiding asynchronous communication for each edit. The world-data service could grant an exclusive mutability lock on a chunk so the simulation thread can perform multiple edits without per-edit coordination while holding it. In this proposal, such access is allowed only for chunks sufficiently far from all current players.

This remains an architecture idea, not a selected mechanism. Acquiring and releasing exclusive access still requires coordination; distance alone does not establish safe exclusive access. The distance threshold, behavior when a player approaches, and interaction with other users of the world-data service remain open. The idea aims to reduce coordination cost without prescribing how ownership or publication works.

## Whole-world operation and visible overload

Simulation must support active work across the entire world, including distant areas. When system resources are insufficient, processing may be throttled and prioritized according to a policy still to be designed. This must preserve the [principles for time, observation, and overload](../DESIGN_PRINCIPLES.md#budget-memory-and-define-overload-behavior), including coordinated slowdown under sustained overload.

Persistent resource shortages must be communicated to the player. Ideally the game should also report how much the simulation is currently slowed, expressed relative to its normal pace. Exact notification thresholds, measurement windows, and UI are not selected.
