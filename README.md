# zig-engine

A Zig 3D engine with a demo application and a voxel-world application. The engine renders scene objects, animated meshes, terrain, skyboxes, and voxels through WebGPU, with cascaded directional shadows and screen-space ambient occlusion (SSAO).

## Build and run

The package declares Zig 0.16.0 as its minimum version. External dependencies are pinned in `build.zig.zon`; the glTF loader is a local package.

```shell
zig build             # Build/install the library, both applications, and content
zig build run         # Run the demo application
zig build run_voxel   # Run the voxel application
zig build test        # Run registered unit/regression tests
zig build test-gpu    # Optional headless Dawn GPU checks (requires graphics adapter)
```

The applications load installed content relative to the executable directory. See [architecture](docs/architecture.md) for the build and startup flow.

## Documentation

These documents describe the current implementation, extracted from existing docs and source. The initial extraction is for review; it does not establish that every implementation choice is intended behavior.

| Document | Contents |
| --- | --- |
| [Architecture and review points](docs/architecture.md) | Subsystem map, engine/application boundaries, state ownership, concurrency, startup, and frame order. Start here. |
| [Scenes, objects, and input](docs/scenes.md) | Scene contents, transform hierarchy, instance updates, current visibility index, controls, and lifetime. |
| [Rendering](docs/rendering.md) | Pass sequence, geometry paths, shadows, SSAO, GPU layouts, and current rendering limitations. |
| [Assets and animation](docs/assets-animation.md) | glTF subset, shared models, textures, per-object playback, and resource ownership. |
| [Voxel world](docs/voxel-world.md) | Generation, service protocol, optimistic edits, streaming, masks, revisions, persistence, and capacity. |
| [Coordinates and rendering precision](docs/coordinates.md) | f64 CPU positions, signed chunks, camera-relative GPU coordinates, wrapping, and regression coverage. |
| [World configuration](docs/world-configuration.md) | Runtime dimensions, compile-time optional x wrapping, immutable layouts, shader specialization, and validation. |
| [World configuration research](docs/world-configuration-options.md) | Original tradeoff analysis and isolated compiler measurements. |

The subsystem docs link to implementing modules and existing tests. The [Zig/WGSL type naming agreement](docs/rendering.md#zigwgsl-type-naming-agreement) requires `GPU_` for Zig shader payload types. [TODO.md](TODO.md) is a task list. [Agent session logs](agent-sessions/README.md) are historical records.

## Controls

The voxel app starts in player mode: W/A/S/D walk, mouse movement looks around, and Space jumps up to 1.05 blocks to cross holes or reach a one-block elevation. Holding Space for 0.25 seconds enables automatic climbing of one-block steps and catching nearby hole edges without ground support. Pressing Space while airborne enables climbing immediately, only while held; releasing Space or movement cancels an ascent and resumes gravity. Grounded ascents ease over 0.25 seconds while moving forward, and small airborne lip catches use shorter ascents to preserve walking speed. A hole with a far edge one block higher requires jumping first; keep holding Space to enable climbing after 0.25 seconds, or release and press it again in flight to enable climbing immediately. Terrain blocks stop movement, gravity is 10 m/s², and one block is one metre.

Q switches between player and debug spectator modes. Each spectator excursion starts at the player's eyes; the player freezes and returning restores its position and view. Spectator controls are W/A/S/D, Space/C for up/down, and looking while holding the left mouse button. The demo app uses these spectator controls by default. Escape exits. Ctrl+E toggles SSAO, Ctrl+R toggles its debug view, and B toggles blur.

In the voxel app, Tab switches between removing (the initial mode) and putting. Left click performs the active mode's action; X also removes in removing mode, and E also places in putting mode. Keys 1-8 select loose soil, crushed stone, trunk, planks, rebar, reinforced concrete, solid country road, and adaptive country road. Supported straight runs of 4–12 adaptive road cells form walkable slopes between solid endpoints one level apart; see [country roads](docs/country-roads.md). Reach is four metres from the camera to the edited cube's nearest vertex by default. R switches between nearest-vertex and cube-center distance; the bottom-left label shows the current rule. Removal measures the first block under the crosshair; placement measures the empty cube adjacent to its hit face, even if that face is beyond four metres. Highlighting and actual actions share the reach check. Removing mode shows green focus edges and skips placement previews. Putting mode shows an opaque cyan outline for allowed placement or red for rejection, matching the green focus outline's width and opacity, with translucent orange outlines around problematic blocks or missing support cells; it hides green focus edges. Hidden hints remain faintly visible through terrain. Rejected placement shows small orange error text at the bottom centre on a translucent rounded background. Actual edit failures show medium red text at the top centre without a background for four seconds; both messages can appear together. Each press edits once. The block mode and reach rule persist when Q switches between player and spectator control. Placement overlapping the player is rejected, including during spectating. There is no material selection UI yet. See [block placement rules](docs/block-placement.md), [scenes and input](docs/scenes.md), and [voxel tools](docs/voxel-world.md#tools-and-simulation-example).

Putting mode also displays the selected textured block at the bottom centre of the camera view, tilted as a held item and partially clipped by the viewport's bottom edge. It stays visible over nearby terrain and updates immediately with material selection, even without a placement target. Removing mode hides the held item. Its resting position, rotation, and scale are shared by player and spectator modes; it displays the block without hand meshes.

Held items use Hybrid animation: walking bob, acceleration lag, jump/landing response, and look sway from actual camera movement. Looking down smoothly raises the item to reveal more of it; looking up lowers it. This pitch offset persists while holding the angle, and looking straight ahead restores the approved resting pose after motion settles. Changing material preserves the animation. Both player and spectator modes follow their active camera, with motion scaling with speed. See [held-item motion and tuning](docs/rendering.md#held-item-motion).

The voxel app displays a small white circular crosshair with a black outline at the centre of the screen in both player and spectator modes. The crosshair, error-message fonts and layout, and debug window follow the current display's DPI when the window moves between monitors.

## Voxel app

The player starts standing on the current block surface. Before the first frame, the world-data service finds a supported position near the preferred spawn point using current blocks, including committed edits. It checks an empty 2×2×3 volume and support under the player's actual feet.

The world-data service owns authoritative blocks and revisions. The main thread applies edits optimistically and reconciles them against subscribed snapshots. The normal neighborhood retains blocks in a 3×3×3 core and requests surrounding geometry within a 7×7×7 box; outstanding edits pin chunks during reconciliation. Both local and service meshes use neighbor boundary masks and the same exposed-face extractor.

The fixed GPU face buffer is 4 MiB. Capacity pressure reduces the outer box to 5×5×5; uploads remain pending if that still cannot fit. Modified blocks and permanent reveal flags survive subscription eviction in service memory. Disk persistence is not implemented. A separate simulation worker edits one surface block through its own service endpoint.

See [voxel world, streaming, and editing](docs/voxel-world.md) for the full protocol, handoff, meshing, and shutdown behavior.

## Large-world rendering

CPU positions and accumulated parent/child transforms use f64. GPU transforms remove a chunk origin before narrowing translation to f32. Camera and directional-shadow matrices use the same local frame. Applications choose immutable world dimensions per scene and optional x wrapping at compile time; the voxel app always wraps x. Skyboxes use camera rotation only.

The active scene visibility index currently returns every registered object, without spatial culling. Voxel shadows include only resident GPU geometry. See [coordinates](docs/coordinates.md), [scenes](docs/scenes.md#visibility-behavior), and [rendering](docs/rendering.md).

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
