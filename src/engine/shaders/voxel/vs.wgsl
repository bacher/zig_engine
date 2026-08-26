@group(0) @binding(0) var<uniform> clip_from_world: mat4x4<f32>;
@group(0) @binding(1) var<uniform> view_from_world: mat4x4<f32>;

struct ChunkInfo /* 32 byte */ {
    side_data_indices: array<u32, 3>,
    chunk_origin: vec3u,
    slot_index: u32,
}

@group(2) @binding(0) var<uniform> light_clip_from_object_array: array<mat4x4<f32>, 3>;
@group(3) @binding(0) var<storage, read> chunk_info_array: array<ChunkInfo>;
@group(3) @binding(1) var<storage, read> block_array: array<u32>;

// SHOULD BE IN SYNC WITH THE SAME NAMED CONSTANT IN ZIG CODE (in src/engine/voxel_grid.zig)
const BLOCKS_PER_SLOT = 256;
const WORLD_ORIGIN = vec3u(256, 128, 4);
const CHUNK_SIZE = 32;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) normal: vec3<f32>,
    @location(1) texcoord: vec2<f32>,
    // --
    @location(2) position_light_clip_0: vec4<f32>,
    @location(3) position_light_clip_1: vec4<f32>,
    @location(4) position_light_clip_2: vec4<f32>,
}


fn getUv(side: u32, vertex_index: u32) -> vec2f {
    switch vertex_index {
        case 0, default: {
            return vec2(0.0, 1.0);
        }
        case 1: {
            return vec2(1.0, 0.0);
        }
        case 2: {
            return vec2(0.0, 0.0);
        }
        case 3: {
            return vec2(0.0, 1.0);
        }
        case 4: {
            return vec2(1.0, 1.0);
        }
        case 5: {
            return vec2(1.0, 0.0);
        }
    }
}

fn getPosition(side: u32, vertex_index: u32) -> vec3<u32> {
    switch side {
        // top
        case 0, default: {
            switch vertex_index {
                case 0, default: {
                    return vec3(0, 0, 1);
                }
                case 1: {
                    return vec3(1, 1, 1);
                }
                case 2: {
                    return vec3(0, 1, 1);
                }
                case 3: {
                    return vec3(0, 0, 1);
                }
                case 4: {
                    return vec3(1, 0, 1);
                }
                case 5: {
                    return vec3(1, 1, 1);
                }
            }
        }
        // bottom
        case 1: {
            switch vertex_index {
                case 0, default: {
                    return vec3(0, 1, 0);
                }
                case 1: {
                    return vec3(1, 0, 0);
                }
                case 2: {
                    return vec3(0, 0, 0);
                }
                case 3: {
                    return vec3(0, 1, 0);
                }
                case 4: {
                    return vec3(1, 1, 0);
                }
                case 5: {
                    return vec3(1, 0, 0);
                }
            }
        }
        // front
        case 2: {
            switch vertex_index {
                case 0, default: {
                    return vec3(0, 0, 0);
                }
                case 1: {
                    return vec3(1, 0, 1);
                }
                case 2: {
                    return vec3(0, 0, 1);
                }
                case 3: {
                    return vec3(0, 0, 0);
                }
                case 4: {
                    return vec3(1, 0, 0);
                }
                case 5: {
                    return vec3(1, 0, 1);
                }
            }
        }
        // back
        case 3: {
            switch vertex_index {
                case 0, default: {
                    return vec3(1, 1, 0);
                }
                case 1: {
                    return vec3(0, 1, 1);
                }
                case 2: {
                    return vec3(1, 1, 1);
                }
                case 3: {
                    return vec3(1, 1, 0);
                }
                case 4: {
                    return vec3(0, 1, 0);
                }
                case 5: {
                    return vec3(0, 1, 1);
                }
            }
        }
        // left
        case 4: {
            switch vertex_index {
                case 0, default: {
                    return vec3(0, 1, 0);
                }
                case 1: {
                    return vec3(0, 0, 1);
                }
                case 2: {
                    return vec3(0, 1, 1);
                }
                case 3: {
                    return vec3(0, 1, 0);
                }
                case 4: {
                    return vec3(0, 0, 0);
                }
                case 5: {
                    return vec3(0, 0, 1);
                }
            }
        }
        // right
        case 5: {
            switch vertex_index {
                case 0, default: {
                    return vec3(1, 0, 0);
                }
                case 1: {
                    return vec3(1, 1, 1);
                }
                case 2: {
                    return vec3(1, 0, 1);
                }
                case 3: {
                    return vec3(1, 0, 0);
                }
                case 4: {
                    return vec3(1, 1, 0);
                }
                case 5: {
                    return vec3(1, 1, 1);
                }
            }
        }
    }
}

fn getNormal(side: u32) -> vec3<f32> {
    switch side {
        case 0, default: {
            return vec3(0.0, 0.0, 1.0);
        }
        case 1: {
            return vec3(0.0, 0.0, -1.0);
        }
        case 2: {
            return vec3(0.0, -1.0, 0.0);
        }
        case 3: {
            return vec3(0.0, 1.0, 0.0);
        }
        case 4: {
            return vec3(-1.0, 0.0, 0.0);
        }
        case 5: {
            return vec3(1.0, 0.0, 0.0);
        }
    }
}

// decoding [3]u32 into [6]u16
fn extractSideDataIndex(indices: array<u32, 3>, side: u32) -> u32 {
    switch side {
        case 0, default: {
            return indices[0] & 0xffffu;
        }
        case 1: {
            return indices[0] >> 16u;
        }
        case 2: {
            return indices[1] & 0xffffu;
        }
        case 3: {
            return indices[1] >> 16u;
        }
        case 4: {
            return indices[2] & 0xffffu;
        }
        case 5: {
            return indices[2] >> 16u;
        }
    }
}

@vertex fn main(
    @builtin(instance_index) instance_index: u32,
    @builtin(vertex_index) vertex_index: u32,
) -> VertexOut {
    let chunk_index = instance_index >> 3;
    let chunk_side = instance_index & 0x7u;

    let chunk_info = chunk_info_array[chunk_index];
    let chunk_origin = (vec3i(chunk_info.chunk_origin) - vec3i(WORLD_ORIGIN)) * CHUNK_SIZE;
    let block_index = vertex_index / 6;
    let global_block_index =
        chunk_info.slot_index * BLOCKS_PER_SLOT +
        extractSideDataIndex(chunk_info.side_data_indices, chunk_side) +
        block_index;

    let block = block_array[global_block_index];
    let block_origin = vec3(
        block & 0xffu,
        (block >> 8) & 0xffu,
        (block >> 16) & 0xffu,
    );
    let block_type = (block >> 24) & 0xffu;

    let side_vertex_index = vertex_index % 6;

    let block_vertex = getPosition(chunk_side, side_vertex_index);
    let uv = getUv(chunk_side, side_vertex_index);
    let normal = getNormal(chunk_side);

    let position4 = vec4f(vec3f(chunk_origin + vec3i(block_origin + block_vertex)), 1.0);

    var output: VertexOut;
    output.position_clip = clip_from_world * position4;
    output.normal = (view_from_world * vec4f(normal, 0)).xyz;
    output.texcoord = uv;
    output.position_light_clip_0 = light_clip_from_object_array[0] * position4;
    output.position_light_clip_1 = light_clip_from_object_array[1] * position4;
    output.position_light_clip_2 = light_clip_from_object_array[2] * position4;
    return output;
}
