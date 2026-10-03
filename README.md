# zig-engine

## Build and Run

```shell
zig build run
```

## Voxel app

Run `zig build run_voxel`. Press `Z` to drop a dirt block under the camera and `X` to remove the top block below it.

The world-data service owns block contents and revisions. Each worker uses its own client endpoint to submit one `put` or `remove` operation with global block coordinates. Replies include the operation status and authoritative chunk snapshot. A put fails if the block is occupied; a remove fails if it is already empty. The main thread applies edits optimistically and replays outstanding commands over received snapshots to reconcile failures and concurrent changes.

Loading a chunk subscribes that client to snapshots of subsequent changes. Eviction unsubscribes it; subscription tokens prevent queued responses from restoring evicted chunks. Stop client workers before destroying the service, which drains submitted edits and owns endpoint lifetimes. Modified chunks are retained in memory; disk persistence is not implemented.

Local edits and received snapshots mark affected loaded chunks dirty. After processing updates and camera loading, each dirty chunk's mesh is rebuilt once from its latest contents and uploaded before rendering. Unloading a chunk cancels its pending rebuild.

An **unreachable chunk** is enclosed by the fully solid adjacent faces of its six neighbors. It keeps its regular CPU block data and subscriptions, but skips mesh generation and GPU upload. Generation certifies enclosure using the heightmap plus a one-block strip beyond each horizontal face, with x wrapping; outer y/z boundary chunks remain reachable. This assumes the generated terrain has no caves or transparent blocks. A noclip camera inside an enclosed chunk would need a rendering exception.

Opening a neighboring wall clears `is_unreachable` immediately in the main-thread cache, including across snapshot reconciliation. The service independently clears the flag, advances the revealed chunk's revision, retains it as modified even if nobody has loaded it, and notifies its subscribers. Reveals are permanent: rebuilding a wall does not hide the chunk again. This avoids waiting for a service round trip when digging across chunk boundaries. A metadata-only reveal retains the full CPU block data, so it can increase service memory usage.

A simulation worker places a dirt block at the surface midpoint of the central chunk column, removes it after two seconds, and places it again two seconds later. It communicates only with the world-data service, so the main thread receives these changes through the same subscription mechanism.

Run `zig build test` for the protocol, cache reconciliation, and simulation tests.

## Versions

### v0.0.3

* Billboard render mode added

![v0.0.3](screenshots/2026-04-09.png)

### v0.0.2

* Cascade shadow maps added

![v0.0.2](screenshots/2026-03-22.png)

### v0.0.1

![v0.0.1](screenshots/2025-06-05.jpg)

### v0.0.0

![v0.0.0](screenshots/2025-06-04.jpg)

## Funny glitches

![matrix glitch](screenshots/zig-engine-glitch.gif)
