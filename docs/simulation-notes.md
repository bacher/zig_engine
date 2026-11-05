# Simulation notes

These notes capture the author's gameplay intent, constraints, and architecture ideas from 2026-11-05 for the upcoming simulation. They accompany the [game vision](game-vision.md) and [design principles](../DESIGN_PRINCIPLES.md). They are not an implementation design or a description of implemented behavior. Architecture alternatives below remain unselected.

## Primary scenario and player intervention

The long-term goal is fully automated extraction and resource processing, production of construction materials and tools, logistics, and construction of large numbers of buildings and structures worldwide, including megastructures. Players can participate directly in building and carrying resources, but this becomes of little practical value as the economy develops. Optimize for the automated scenario, prioritizing throughput over latency wherever practical.

Without player intervention, the simulation should not pay synchronization overhead specifically for coordinating with player actions. When a player and the simulation concurrently make conflicting edits to the same blocks, simulation edits always win. This strengthens the earlier allowance to favor the simulation into a required guarantee for these conflicts.

Simulation logic should benefit from that guarantee: it must not need rollback handling for losing an edit conflict to a player. The guarantee must be established by the future coordination model, rather than assumed while conflicts remain possible. Handling player edits, conflicts between simulation workers, and unrelated failures still needs design; this rule does not imply that every simulation action is infallible.

## Participants and process boundaries

There are three participants:

- **Players** issue actions primarily to the world-data service. Direct delivery of some events to the simulation is an option to consider, not a selected interface.
- **World-data service** accepts changes from players and the simulation and distributes up-to-date chunk data.
- **Simulation** maintains its own state, relies on world-data service data, and communicates primarily with that service. Player edits may affect it, but coordinating with those edits should not dominate its processing cost.

Player action handling currently runs in the same OS process as the game and the existing simulation logic. Future multiplayer clients will interact with the server through asynchronous messages over the network. Player interaction therefore cannot depend on in-process synchronization between client and server.

The world-data service and simulation will remain together in one server process. They may use in-process synchronization, including atomics, semaphores, and mutexes. This is a process constraint, not a choice of threads or synchronization primitives.

## Simulation state and startup

The simulation needs its own index and may also maintain state distinct from the data currently stored in chunks. Opening a world must resume simulation in all areas containing active event emitters without scanning the whole world. The index, stored state, and recovery mechanism have not been designed.

## Workstation example

Every simulation action has prerequisites. Producing a concrete block at a workstation requires:

- An empty output slot, or a guarantee that it will be free by completion.
- Delivered inputs: cement, crushed stone, sand, and water.
- Coverage by a food dispenser with enough food to pay for the operation.

Relevant changes, such as input delivery or food arriving at the dispenser, must cause the prerequisites to be reconsidered. When all conditions are met and the workstation is enabled, production can start. This describes the triggering behavior without selecting how checks are scheduled or combined.

A player may disable a workstation. It then stops automatically starting work and stays disabled until the player enables it again. The effect of disabling it on an operation already in progress remains unspecified.

## Production and outbound delivery are separate jobs

Moving a produced block to storage is a separate task from producing it. Once the block has been produced, a storage destination is sought. A courier starts transporting it when sufficient food is available from the dispenser to pay for that operation.

In the first version, calculate travel duration when the delivery starts and do not recheck or replan its route afterward. Its accepted food cost and travel duration are not recalculated in response to world changes along the route. This is a deliberate performance simplification. The fixed duration is measured in simulation time; coordinated slowdown under overload changes how quickly that time advances in real time.

Visualization may adjust the NPC's motion to fit current terrain, for example to avoid walking through the air after terrain changes. This is purely visual and must not feed changes back into simulation state, travel timing, food costs, or delivery outcomes. It does not introduce simulation route checks, including when the NPC is observed by several players.

The [travel policy](game-vision.md#responding-to-world-changes-during-travel) applies this simplification to active deliveries; updated routing information serves new deliveries. A removed destination, canceled order, or unavailable recipient still needs an explicit cargo and task outcome. Those are separate task-lifecycle questions, not permission to recheck the route in the first version. These notes do not choose those outcomes.

## Architecture ideas to revisit later

The author has not chosen a simulation architecture. Candidates include:

- World-data service and simulation on the same thread.
- A separate world-data service and a simulation event loop acting as an orchestrator for workers. One variant isolates workers behind inbox communication with the orchestrator; another allows workers to access the service themselves.
- A separate world-data service and simulation worker threads without an orchestrator.
- Another approach if it better serves the requirements.

One possible structural simplification is to ensure that only one simulation worker can modify a particular chunk at a time, reducing synchronization with other simulation workers and ideally with the world-data service. This is an exploratory idea. No chunk ownership, partitioning, worker topology, or cross-chunk coordination scheme has been selected.

### Direct mutation of distant chunks

Another candidate is to let a simulation thread update world-data service data directly, avoiding asynchronous communication for each edit. The service could grant an exclusive mutability lock on a chunk so the simulation thread can perform multiple edits without per-edit coordination while holding it. In this proposal, such access is allowed only for chunks sufficiently far from all current players.

This remains an architecture idea, not a selected mechanism. Acquiring and releasing exclusive access still requires coordination; distance alone does not establish safe exclusive access. The distance threshold, behavior when a player approaches, and interaction with other service users remain open. The idea aims to reduce coordination cost without prescribing how ownership or publication works.

## Whole-world operation and visible overload

Simulation must support active work across the entire world, including distant areas. When system resources are insufficient, processing may be throttled and prioritized according to a policy still to be designed. This must preserve the [principles for time, observation, and overload](../DESIGN_PRINCIPLES.md#budget-memory-and-define-overload-behavior), including coordinated slowdown under sustained overload.

Persistent resource shortages must be communicated to the player. Ideally the game should also report how much the simulation is currently slowed, expressed relative to its normal pace. Exact notification thresholds, measurement windows, and UI are not selected.
