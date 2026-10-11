# TODO

- [ ] Split vertex and index buffer structs
- [x] Add depth texture struct with explicit init/deinit
- [ ] Add spectator view to verify cull logic
- [ ] Do not load the same texture several times.
- [ ] Check the camara max distance, is it too big?
- [x] Rename BindGroupDefinition into BindGroupLayouts
- [x] Move BindGroupLayouts initialization into layouts file (instead of engine.zig)

- [ ] Add multiple point and spot lights alongside at most one directional light; implement light accumulation and per-light shadow allocation (deferred; see [lighting plan](docs/rendering.md#lighting-contract-and-extension-plan)).

- [ ] Define voxel GPU memory budgets, oversized-chunk handling, capacity-pressure recovery, and growth/eviction validation (deferred; voxel implementation unchanged; see [voxel follow-ups](docs/voxel-world.md#deferred-capacity-and-lifetime-work)).

- [ ] Define a final player recovery policy when adjacent cells, five seconds of position history, and the bounded eight-metre search contain no clear body-sized space. Currently movement freezes, stderr reports the failure, and recovery retries after terrain updates or once per second.

- [ ] Render block placement failures and dependent blocks in a separate 3D overlay pass, using structured CPU diagnostics; add a placement ghost and target highlighting. See [block placement](docs/block-placement.md).
- [ ] Add temporary construction supports/scaffolding for multi-cell masonry gaps.
- [ ] Add an inventory using authoritative `mined_type` results, recipes, and dedicated construction-material textures.
- [ ] Add an incremental construction dependency index and a memory budget for retained timed chunk state when building scale requires it.
