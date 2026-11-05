# Simulation notes

These notes capture the author's gameplay intent, constraints, and architecture ideas from 2026-11-05 for the upcoming simulation. They accompany the [game vision](game-vision.md) and [design principles](../DESIGN_PRINCIPLES.md). They are not an implementation design or a description of implemented behavior. Architecture alternatives below remain unselected.

## Primary scenario and player intervention

The long-term goal is fully automated extraction and resource processing, production of construction materials and tools, logistics, and construction of large numbers of buildings and structures worldwide, including megastructures. Players can participate directly in building and carrying resources, but this becomes of little practical value as the economy develops. Optimize for the automated scenario, prioritizing throughput over latency wherever practical.

Without player intervention, the simulation should not pay synchronization overhead specifically for coordinating with player actions. When actions conflict, it is acceptable to give simulation actions precedence. Exact conflict rules remain open.

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

After transport starts, its accepted food cost and travel duration are not recalculated in response to world changes along the route. This is a deliberate performance simplification. The fixed duration is measured in simulation time; coordinated slowdown under overload changes how quickly that time advances in real time.

The [travel policy](game-vision.md#responding-to-world-changes-during-travel) starts with checking plans at defined points and permits selected changes to affect only new deliveries. How those checks interact with fixed travel duration in exceptional cases remains to be clarified. A removed destination, canceled order, or unavailable recipient still needs an explicit cargo and task outcome. These notes do not choose those outcomes.

## Architecture ideas to revisit later

The author has not chosen a simulation architecture. Candidates include:

- World-data service and simulation on the same thread.
- A separate world-data service and a simulation event loop acting as an orchestrator for workers. One variant isolates workers behind inbox communication with the orchestrator; another allows workers to access the service themselves.
- A separate world-data service and simulation worker threads without an orchestrator.
- Another approach if it better serves the requirements.

One possible structural simplification is to ensure that only one simulation worker can modify a particular chunk at a time, reducing synchronization with other simulation workers and ideally with the world-data service. This is an exploratory idea. No chunk ownership, partitioning, worker topology, or cross-chunk coordination scheme has been selected.
