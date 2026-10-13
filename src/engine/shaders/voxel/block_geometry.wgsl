// Shared cube faces and material atlas coordinates for world and held blocks.
const ATLAS_SLOT = 0.046875;

fn getUv(side: u32, vertex_index: u32, block_type: u32) -> vec2f {
    var shift = vec2(0.0, 0.0);
    // Keep numeric types in sync with voxel/voxel_chunk.zig's BlockType enum.
    switch block_type {
        case 0, default: { /* none  */ shift = vec2( 0.0,  0.0); }
        case 1:          { /* stone */ shift = vec2( 1.0,  0.0); }
        case 2:          { /* dirt  */ shift = vec2( 2.0,  0.0); }
        case 3:          { /* grass */
            switch side {
                case 5:  { shift = vec2( 12.0, 12.0); }
                case 4:  { shift = vec2(  0.0,  2.0); }
                default: { shift = vec2(  3.0,  0.0); }
            }
        }
        case 4:          { /* water */ shift = vec2(13.0, 12.0); }
        case 5:          { /* sand  */ shift = vec2( 2.0,  1.0); }
        case 6:          { /* snow  */ shift = vec2( 0.0,  4.0); }
        case 7:          { /* packed soil */ shift = vec2(2.0, 0.0); }
        case 8:          { /* crushed stone */ shift = vec2(0.0, 1.0); }
        case 9:          { /* tree trunk */
            if side == 4u || side == 5u {
                shift = vec2(5.0, 1.0);
            } else {
                shift = vec2(4.0, 1.0);
            }
        }
        case 10:         { /* planks */ shift = vec2(4.0, 0.0); }
        case 11:         { /* rebar: existing metal atlas tile */ shift = vec2(6.0, 1.0); }
        case 12:         { /* reinforced concrete: existing stone atlas tile */ shift = vec2(1.0, 0.0); }
    }

    var uv = vec2(0.0, 0.0);
    switch vertex_index {
        case 0, default: { uv = vec2(0.0, 1.0); }
        case 1:          { uv = vec2(1.0, 0.0); }
        case 2:          { uv = vec2(0.0, 0.0); }
        case 3:          { uv = vec2(0.0, 1.0); }
        case 4:          { uv = vec2(1.0, 1.0); }
        case 5:          { uv = vec2(1.0, 0.0); }
    }

    return (shift + uv) * ATLAS_SLOT;
}

fn getPosition(side: u32, vertex_index: u32) -> vec3<u32> {
    switch side {
        // left
        case 0, default: {
            switch vertex_index {
                case 0, default: { return vec3(0, 1, 0); }
                case 1:          { return vec3(0, 0, 1); }
                case 2:          { return vec3(0, 1, 1); }
                case 3:          { return vec3(0, 1, 0); }
                case 4:          { return vec3(0, 0, 0); }
                case 5:          { return vec3(0, 0, 1); }
            }
        }
        // right
        case 1: {
            switch vertex_index {
                case 0, default: { return vec3(1, 0, 0); }
                case 1:          { return vec3(1, 1, 1); }
                case 2:          { return vec3(1, 0, 1); }
                case 3:          { return vec3(1, 0, 0); }
                case 4:          { return vec3(1, 1, 0); }
                case 5:          { return vec3(1, 1, 1); }
            }
        }
        // front
        case 2: {
            switch vertex_index {
                case 0, default: { return vec3(0, 0, 0); }
                case 1:          { return vec3(1, 0, 1); }
                case 2:          { return vec3(0, 0, 1); }
                case 3:          { return vec3(0, 0, 0); }
                case 4:          { return vec3(1, 0, 0); }
                case 5:          { return vec3(1, 0, 1); }
            }
        }
        // back
        case 3: {
            switch vertex_index {
                case 0, default: { return vec3(1, 1, 0); }
                case 1:          { return vec3(0, 1, 1); }
                case 2:          { return vec3(1, 1, 1); }
                case 3:          { return vec3(1, 1, 0); }
                case 4:          { return vec3(0, 1, 0); }
                case 5:          { return vec3(0, 1, 1); }
            }
        }
        // bottom
        case 4: {
            switch vertex_index {
                case 0, default: { return vec3(0, 1, 0); }
                case 1:          { return vec3(1, 0, 0); }
                case 2:          { return vec3(0, 0, 0); }
                case 3:          { return vec3(0, 1, 0); }
                case 4:          { return vec3(1, 1, 0); }
                case 5:          { return vec3(1, 0, 0); }
            }
        }
        // top
        case 5: {
            switch vertex_index {
                case 0, default: { return vec3(0, 0, 1); }
                case 1:          { return vec3(1, 1, 1); }
                case 2:          { return vec3(0, 1, 1); }
                case 3:          { return vec3(0, 0, 1); }
                case 4:          { return vec3(1, 0, 1); }
                case 5:          { return vec3(1, 1, 1); }
            }
        }
    }
}

fn getNormal(side: u32) -> vec3<f32> {
    switch side {
        case 0, default: { return vec3(-1.0,  0.0,  0.0); }
        case 1:          { return vec3( 1.0,  0.0,  0.0); }
        case 2:          { return vec3( 0.0, -1.0,  0.0); }
        case 3:          { return vec3( 0.0,  1.0,  0.0); }
        case 4:          { return vec3( 0.0,  0.0, -1.0); }
        case 5:          { return vec3( 0.0,  0.0,  1.0); }
    }
}
