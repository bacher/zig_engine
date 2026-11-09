# Design principles

The game's primary goal is to sustain a massive world simulation. Many production chains, resource extraction operations, deliveries, and construction sites run simultaneously, represented visually by NPC workers, builders, and couriers. Logistics must support all of this activity: moving materials and supplies is part of the simulation itself.

These principles guide feature design, implementation, and integration. The [game vision](docs/game-vision.md) describes the experience we are building toward; this document defines the priorities for choosing how to build it. Feature specifications should make the resulting tradeoffs explicit.

## Optimize for an automated world

The primary scenario is a worldwide economy with automated extraction, resource processing, construction-material and tool production, logistics, and construction up to megastructures. Players can build and carry goods themselves, but direct labor becomes marginal as automation grows. Optimize the ordinary simulation path for this mature economy.

When players are not intervening, simulation work should not incur synchronization overhead specifically to coordinate with player actions. When a player and the simulation concurrently make conflicting edits to the same blocks, simulation edits always take precedence. Establish this guarantee so simulation logic does not need to roll back its work because it lost a conflict with a player edit. This requirement does not select a coordination mechanism or remove handling for unrelated failures or conflicts within the simulation.

Player interaction must remain compatible with asynchronous messages from future network clients and cannot depend on shared in-process synchronization with those clients. The world-data service and simulation will remain in the same server process and may use in-process synchronization with each other. These boundaries do not select their threads or require them to communicate only through messages. The [simulation notes](docs/simulation-notes.md) preserve the requirements and unselected architecture ideas.

## Prioritize throughput over latency

This priority applies primarily to world simulation and the world-data service as the layer directly supporting it. Shape world rules and execution conditions to minimize waiting and coordination for the simulation thread or threads, so the mature automated economy can sustain activity throughout the world at its intended pace. Immediate propagation of every world change is not a default requirement for this path. Prefer batching, asynchronous processing, deferred updates, and reuse of computed results when they substantially increase simulation throughput. Any relaxation of consistency remains subject to the per-check rules below and consistent resource accounting.

Client threads responsible for the player experience may balance throughput and latency differently. Favor low latency for input, feedback, and presentation where doing so does not degrade overall system performance or the simulation's sustainable throughput. This applies both to clients in the current process and to future network clients.

Client demand on the world-data service must remain controlled: faster or more frequent requests are not a successful latency optimization if the resulting load or contention slows the world-data service and, through it, the simulation. Evaluate client improvements together with their effect on this shared path and other system resources. The primary performance goal remains sustained whole-world simulation in the late game; the existing overload policy is a fallback when capacity is exceeded.

Choose freshness and response-time requirements per feature according to their gameplay impact. A smooth presentation does not require every simulation subsystem to process every change in real time. Evaluate performance under many concurrent workers, deliveries, production jobs, and construction projects, rather than only the latency of an isolated action.

## Allow temporary disagreement, preserve coherent outcomes

The world follows an eventual consistency model. Subsystems may temporarily observe different versions of the world, and visual state may briefly lag behind simulation state. Changes must still converge to a coherent result without seriously breaking the game's overall logic.

For each feature, identify which state can be stale, which invariants must hold, and how conflicting or outdated work is reconciled. A delivery animation may briefly lag behind its recorded progress. Resource consumption and transfers must remain consistent: competing jobs cannot spend the same resources or claim the same cargo. Eventual consistency alone does not justify permanently inconsistent outcomes.

We may deliberately relax an invariant when doing so offers a worthwhile simplification or performance gain. This can be acceptable when a violation is extraordinarily rare in practice, or when the invariant has little gameplay importance and violations are still rare. Such exceptions require an explicit account of their likelihood and consequences, including whether repeated occurrences can accumulate into a serious problem. They must preserve the overall coherence of production, construction, and logistics. This allowance does not relax consistent resource accounting.

Some condition checks may use recent observations from different moments instead of one coherent snapshot. The combined observations may even describe a world state that never existed as a whole. Whether this is acceptable must be discussed for each check during feature design and implementation; it is not the default permission for every validator. A roughly 1–2 second inconsistency window is acceptable for suitable checks, subject to their chosen policy. Account for observation age until the result is used, including time spent queued, and define the time basis and behavior when the window is exceeded.

Judge the consequences as well as the reading window. Building recognition must follow stricter consistency rules: a room must not retain a valid status indefinitely after its roof is broken. Checking the surroundings for applying a construction blueprint is a candidate for relaxed validation, even if concurrent nearby edits leave the result outside ordinary construction rules. The feature must record the exact accepted deviations. This does not change current blueprint validation or select its future implementation.

These permissions concern logical condition checks. They neither make stale resource-availability observations sufficient to authorize consumption nor permit unsafe concurrent memory access, torn structures, or use of freed data. They may remove the need to hold a whole-area lock throughout a check; the choice of safe access and coordination mechanisms remains open. See the [validation notes](docs/simulation-notes.md#consistency-of-condition-checks).

## Match rule enforcement to a noncompetitive game

The game is noncompetitive. Preventing every possible loophole is not a goal in itself, and an obscure way to bend a rule can be an acceptable cost of a simpler, faster simulation.

Loopholes must not be trivial to discover or easy to exploit repeatedly. Assess rarity under deliberate player behavior as well as ordinary play: a race that rarely occurs by accident may become an easy resource duplication loop once its trigger is known. Favor proportionate safeguards that protect the meaningful role of production and logistics without paying for competitive-grade enforcement of every rule.

## Actively explore simplifications for every feature

When designing a new feature and integrating it into the game, always ask: **what are we willing to simplify to make processing this feature substantially more efficient?**

Consider simplifying gameplay rules as well as implementation details. Candidates include less frequent updates, coarser simulation steps, aggregated work, delayed reactions, approximate choices, and reduced coordination between subsystems. Each candidate must be assessed against the simulation's purpose and the consistency principles above.

When a simplification could yield a substantial performance or throughput improvement, raise it for discussion and actively work through the alternatives. Do not silently discard it to preserve exact or immediate behavior by default. Record the selected tradeoff in the feature's specification or design notes, with enough detail to answer:

- What work or coordination does the simplification avoid, and what improvement is expected or measured at scale?
- What behavior changes for players, including temporary visual discrepancies or delayed reactions?
- Which invariants remain guaranteed, which are deliberately relaxed, and how does state converge where required?
- How likely and consequential are exceptional outcomes, and can a player trigger them easily or repeatedly?

Use measurements where available and label estimates as estimates. Revisit a tradeoff when actual scale, observed failures, or easy exploitation contradict its assumptions.

## Spend work on meaningful changes

Simulation cost should primarily follow changes that can affect outcomes. A production job with a known completion time need not recompute its progress continuously. A workstation waiting for resources need not repeatedly check unchanged prerequisites. Identify what can change a result and what processing those changes require.

Use a local workforce model: work may start automatically once its prerequisites, including resources and food, are satisfied. The simulation does not require a persistent population of individual NPCs, a search for an available worker, or simulated approach and return journeys. Client-side NPC models represent active work and may appear, disappear, or be reused without affecting that work. The simulation retains the tasks, cargo, schedules, and progress needed for correct outcomes; visual NPC identity is not an execution prerequisite.

Opening a world must allow simulation to resume in every area with active event emitters without scanning the entire world. The simulation needs its own index, and potentially additional state beyond chunk data; its representation remains an implementation decision.

Rendered motion may be reconstructed when needed. Observation must not change authoritative schedules or outcomes, including when several players watch the same activity. These are design requirements for the upcoming simulation; they do not select a scheduler or require every subsystem to use the same update mechanism.

In the first version, NPCs do not collide with or block one another in the simulation and do not create traffic congestion. Terrain and roads still determine traversability and travel costs. Movement separation may be added purely in visualization, without changing authoritative routes, progress, timing, costs, or work outcomes. The presence or absence of that visual adjustment must have no simulation effect.

## Keep accepted plans stable

Choosing suppliers and destinations and planning routes can cost more than executing the resulting plans. A newly available better option does not by itself require reconsidering active work. Favor sufficiently good decisions that remain useful over continuous optimization.

Consume all required inputs and operating resources in full when an operation or delivery starts. Started work is already paid for and does not depend on later replenishment or continued availability of those resources. Resources are not consumed progressively or charged again at completion. Transported cargo moves into the delivery's custody; it is not consumed as a transport cost. See the [resource consumption rule](docs/simulation-notes.md#consume-resources-at-start).

Define which changes invalidate a plan and when they are checked. For deliveries in the first version, calculate travel duration at the start and do not recheck or replan the route after departure. Changes along the route do not change the accepted food cost or duration in simulation time; new deliveries account for the changed world through updated routing data. Visual movement may adapt to current terrain, but cannot change authoritative simulation state, timing, or outcomes. The [game vision](docs/game-vision.md#responding-to-world-changes-during-travel) records this policy and the remaining choices about cargo and task outcomes.

Stopping an object and dismantling it are separate player actions. Stopping prevents new work from being accepted while already accepted operations and deliveries finish. The object then remains in the world, inactive until explicitly enabled again; stopping never automatically deletes it. Dismantling is allowed only after the object has stopped and its outstanding obligations have completed. This preserves accepted work and lets players withdraw an object from the simulation without destroying it. See the [object lifecycle](docs/game-vision.md#stopping-reactivating-and-dismantling-objects).

## Bound the work caused by ordinary changes

An ordinary local change should cause a limited amount of work. Placing a block should not by default replan every delivery's route; creating a job should not search all world suppliers; changing one warehouse should not reconsider the whole economy.

Consider service areas, limited candidate searches, approximate choices, and selective invalidation where they preserve useful gameplay. If consequences genuinely extend across the world, their processing must be distributable over time. Account for both direct processing and the follow-up work it triggers.

## Define time independently of processing delays

Simulation advances while the world is running and not paused. Closing the world or stopping its server stops simulation time; reopening resumes from the saved simulation time without offline progress or catch-up for elapsed real time. A running dedicated server may continue simulating with no connected players. An absent client does not make a running server offline. See the [world-time rules](docs/simulation-notes.md#world-time-and-no-offline-progress).

Each feature must define when an action takes effect in simulation time, when dependent actions become eligible, and how late processing is handled. Processing a completion late must not accidentally change production rates, operating costs, or the relative speeds of different industries.

Distinguish delayed knowledge of an event from a deliberate delay to the event itself. Specify how dependent work preserves causality when updates arrive late. Any slowdown of simulation time or delay to new work under load must follow an explicit policy, rather than emerge from whichever subsystem falls behind first.

## Budget memory and define overload behavior

For each subsystem, account for the state retained for jobs, routes, notifications, and deferred changes, including how that state grows with world activity. Queues must have a capacity or admission policy that prevents unbounded growth under sustained overload.

Repeated requests to recompute the same state may be combined; accepted deliveries and their cargo need a policy that preserves their meaning. Under temporary overload, first defer new assignments and replanning while preserving the meaning of accepted work. Under sustained overload, coordinated slowdown of simulation time is acceptable while camera and interface interaction remain responsive. Individual industries must not accidentally run at different relative speeds because their queues lag differently. The mechanism and thresholds remain to be designed; a queue alone does not solve a throughput deficit.

Simulation must support activity throughout the world, including areas far from players. Resource limits may require throttling and prioritizing work; these policies must remain consistent with observation-independent outcomes and explicit simulation-time semantics. Notify the player when resource shortages are sustained. Ideally, also show the current effective simulation speed relative to the normal pace, so the player can understand the extent of the slowdown. Thresholds, measurement windows, and presentation remain to be defined.

## Make scale measurable from the first simulation prototype

The initial scale target is **100,000 simultaneously active work and delivery tasks**, expressed in gameplay as 100,000 active NPC workers, builders, and couriers. Under the local workforce model this measures simulated activity in production, extraction, construction, and logistics, not a persistent population, idle NPCs, or 100,000 models rendered simultaneously. It is a design and benchmarking target for the upcoming simulation, not a measured capability of the current game, and may be revised using prototype results.

Target a mid-range gaming PC with **4–8 CPU cores and 32 GB of system RAM**, with operation on **16 GB of system RAM** as a desirable goal. These are whole-machine resources, not a budget reserved for simulation. Leave CPU time and memory for rendering, world data, streaming, persistence, and the operating system. Measure against the lower CPU end as well as the upper end; exact reference CPU models and subsystem budgets remain to be selected.

Define a representative workload around this target, including the mix of NPC roles, simultaneous production jobs, deliveries, construction sites, and world edits. The goal is to sustain the game's normal simulation pace at the target workload; slowdown is a fallback when capacity is exceeded. The concrete time scale and acceptable processing delays remain to be selected. NPC count alone is insufficient to define or demonstrate capacity.

The first simulation prototype should support running without graphics. Measure sustained useful work, memory consumption, queue growth, and whether the economy maintains its intended pace. Include changes that disrupt ongoing work, not just a steady world with no edits. Use these measurements to evaluate design choices before committing to a threading model, scheduler, or other implementation architecture.
