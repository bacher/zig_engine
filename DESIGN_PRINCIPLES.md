# Design principles

The game's primary goal is to sustain a massive world simulation. NPCs act as workers, builders, and couriers while many production chains, resource extraction operations, and construction sites run simultaneously. Logistics must support all of this activity: moving materials and supplies is part of the simulation itself.

These principles guide feature design, implementation, and integration. The [game vision](docs/game-vision.md) describes the experience we are building toward; this document defines the priorities for choosing how to build it. Feature specifications should make the resulting tradeoffs explicit.

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
