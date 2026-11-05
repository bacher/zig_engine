# Design principles

The game's primary goal is to sustain a massive world simulation. NPCs act as workers, builders, and couriers while many production chains, resource extraction operations, and construction sites run simultaneously. Logistics must support all of this activity: moving materials and supplies is part of the simulation itself.

These principles guide feature design, implementation, and integration. The [game vision](docs/game-vision.md) describes the experience we are building toward; this document defines the priorities for choosing how to build it. Feature specifications should make the resulting tradeoffs explicit.

## Optimize for an automated world

The primary scenario is a worldwide economy with automated extraction, resource processing, construction-material and tool production, logistics, and construction up to megastructures. Players can build and carry goods themselves, but direct labor becomes marginal as automation grows. Optimize the ordinary simulation path for this mature economy.

When players are not intervening, simulation work should not incur synchronization overhead specifically to coordinate with player actions. Handle intervention where it matters; simulation actions may take precedence when they conflict with player actions. This permits such conflict policies without prescribing a universal winner or a synchronization mechanism.

Player interaction must remain compatible with asynchronous messages from future network clients and cannot depend on shared in-process synchronization with those clients. The world-data service and simulation will remain in the same server process and may use in-process synchronization with each other. These boundaries do not select their threads or require them to communicate only through messages. The [simulation notes](docs/simulation-notes.md) preserve the requirements and unselected architecture ideas.

## Prioritize throughput over latency

Optimize for the amount of useful simulation work the game can sustain as the world grows. Immediate propagation of every world change is not a default requirement. Prefer batching, asynchronous processing, deferred updates, and reuse of computed results when they substantially increase throughput.

Choose freshness and response-time requirements per feature according to their gameplay impact. A smooth presentation does not require every simulation subsystem to process every change in real time. Evaluate performance under many concurrent workers, deliveries, production jobs, and construction projects, rather than only the latency of an isolated action.

## Allow temporary disagreement, preserve coherent outcomes

The world follows an eventual consistency model. Subsystems may temporarily observe different versions of the world, and visual state may briefly lag behind simulation state. Changes must still converge to a coherent result without seriously breaking the game's overall logic.

For each feature, identify which state can be stale, which invariants must hold, and how conflicting or outdated work is reconciled. For example, a delivery animation may briefly lag behind its recorded progress; whether materials can be consumed by competing jobs is a separate simulation rule that needs an explicit decision. Eventual consistency alone does not justify permanently inconsistent outcomes.

We may deliberately relax an invariant when doing so offers a worthwhile simplification or performance gain. This can be acceptable when a violation is extraordinarily rare in practice, or when the invariant has little gameplay importance and violations are still rare. Such exceptions require an explicit account of their likelihood and consequences, including whether repeated occurrences can accumulate into a serious problem. They must preserve the overall coherence of production, construction, and logistics.

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

Simulation cost should primarily follow changes that can affect outcomes. A production job with a known completion time need not recompute its progress continuously. An idle worker need not repeatedly search for work when no relevant opportunity has appeared. Identify what can change a result and what processing those changes require.

Opening a world must allow simulation to resume in every area with active event emitters without scanning the entire world. The simulation needs its own index, and potentially additional state beyond chunk data; its representation remains an implementation decision.

Rendered motion may be reconstructed when needed. Observation must not change authoritative schedules or outcomes, including when several players watch the same activity. These are design requirements for the upcoming simulation; they do not select a scheduler or require every subsystem to use the same update mechanism.

## Keep accepted plans stable

Assigning workers, choosing suppliers, and planning routes can cost more than executing the resulting plans. A newly available better option does not by itself require reconsidering active work. Favor sufficiently good decisions that remain useful over continuous optimization.

Define which changes invalidate a plan and when they are checked. The starting approach for travel is to check at defined points, such as before entering another route segment, rather than immediately notifying and replanning every affected courier after each edit. For selected changes, it is acceptable for active deliveries to finish under their accepted plans while new deliveries account for the changed world. The [game vision](docs/game-vision.md#responding-to-world-changes-during-travel) records this policy and the remaining choices.

## Bound the work caused by ordinary changes

An ordinary local change should cause a limited amount of work. Placing a block should not by default replan every courier's route; creating a job should not search the entire worker population; changing one warehouse should not reconsider the whole economy.

Consider service areas, limited candidate searches, approximate choices, and selective invalidation where they preserve useful gameplay. If consequences genuinely extend across the world, their processing must be distributable over time. Account for both direct processing and the follow-up work it triggers.

## Define time independently of processing delays

Each feature must define when an action takes effect in simulation time, when dependent actions become eligible, and how late processing is handled. Processing a completion late must not accidentally change production rates, operating costs, or the relative speeds of different industries.

Distinguish delayed knowledge of an event from a deliberate delay to the event itself. Specify how dependent work preserves causality when updates arrive late. Any slowdown of simulation time or delay to new work under load must follow an explicit policy, rather than emerge from whichever subsystem falls behind first.

## Budget memory and define overload behavior

For each subsystem, account for the state retained for jobs, routes, notifications, and deferred changes, including how that state grows with world activity. Queues must have a capacity or admission policy that prevents unbounded growth under sustained overload.

Repeated requests to recompute the same state may be combined; accepted deliveries and their cargo need a policy that preserves their meaning. Under temporary overload, first defer new assignments and replanning while preserving the meaning of accepted work. Under sustained overload, coordinated slowdown of simulation time is acceptable while camera and interface interaction remain responsive. Individual industries must not accidentally run at different relative speeds because their queues lag differently. The mechanism and thresholds remain to be designed; a queue alone does not solve a throughput deficit.

## Make scale measurable from the first simulation prototype

The initial scale target is **100,000 simultaneously active NPCs** in a developed world, working in production, extraction, construction, and logistics. This counts agents doing work or traveling, rather than decorative inhabitants or merely registered idle entities. It is a design and benchmarking target for the upcoming simulation, not a measured capability of the current game, and may be revised using prototype results.

Target a mid-range gaming PC with **4–8 CPU cores and 32 GB of system RAM**, with operation on **16 GB of system RAM** as a desirable goal. These are whole-machine resources, not a budget reserved for simulation. Leave CPU time and memory for rendering, world data, streaming, persistence, and the operating system. Measure against the lower CPU end as well as the upper end; exact reference CPU models and subsystem budgets remain to be selected.

Define a representative workload around this target, including the mix of NPC roles, simultaneous production jobs, deliveries, construction sites, and world edits. The goal is to sustain the game's normal simulation pace at the target workload; slowdown is a fallback when capacity is exceeded. The concrete time scale and acceptable processing delays remain to be selected. NPC count alone is insufficient to define or demonstrate capacity.

The first simulation prototype should support running without graphics. Measure sustained useful work, memory consumption, queue growth, and whether the economy maintains its intended pace. Include changes that disrupt ongoing work, not just a steady world with no edits. Use these measurements to evaluate design choices before committing to a threading model, scheduler, or other implementation architecture.
