#!/bin/bash

zig fetch --save git+https://github.com/zig-gamedev/zglfw
zig fetch --save git+https://github.com/zig-gamedev/zgpu
# dawn_aarch64_macos have to be updated manually by visiting https://github.com/zig-gamedev/zgpu repo
# zig fetch --save=dawn_aarch64_macos https://github.com/michal-z/webgpu_dawn-aarch64-macos/archive/d2360cdfff0cf4a780cb77aa47c57aca03cc6dfe.tar.gz
zig fetch --save git+https://github.com/zig-gamedev/zgui
zig fetch --save git+https://github.com/zig-gamedev/zmath
zig fetch --save git+https://github.com/zig-gamedev/zstbi
# zig fetch --save git+https://github.com/bacher/gltf_loader
