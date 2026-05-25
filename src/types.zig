const conststring = []const u8;

pub const GltfRoot = struct {
    asset: struct {
        version: f32,
    },
    scenes: []Scene,
    nodes: []Node,
    meshes: []Mesh,
    accessors: []Accessor,
    bufferViews: []BufferView,
    buffers: []Buffer,
    materials: []Material,
    textures: []Texture = &.{},
    samplers: []Sampler = &.{},
    images: []Image = &.{},
};

pub const SceneIndex = enum(u32) { _ };

pub const Scene = struct {
    nodes: []NodeIndex,
};

pub const NodeIndex = enum(u32) { _ };

pub const Node = struct {
    name: ?conststring = null,
    children: ?[]NodeIndex = null,
    rotation: ?[4]f64 = null,
    scale: ?[3]f64 = null,
    translation: ?[3]f64 = null,
    matrix: ?*TransformMatrix = null,
    mesh: ?MeshIndex = null,
    skin: ?u32 = null,
};

pub const MeshIndex = enum(u32) { _ };

pub const Mesh = struct {
    name1: ?conststring = null,
    primitives: []Primitive,
};

pub const Primitive = struct {
    attributes: struct {
        POSITION: AccessorIndex,
        TEXCOORD_0: AccessorIndex,
        NORMAL: AccessorIndex,
        JOINTS_0: ?AccessorIndex = null,
        WEIGHTS_0: ?AccessorIndex = null,
    },
    indices: AccessorIndex,
    material: MaterialIndex,
};

pub const ComponentType = enum(u32) {
    // TODO?
    gl_unsigned_byte = 5121,
    gl_unsigned_short = 5123,
    gl_unsigned_int = 5125,
    gl_float = 5126,
};

pub const AccessorIndex = enum(u32) { _ };

pub const Accessor = struct {
    bufferView: BufferViewIndex,
    byteOffset: u32 = 0,
    componentType: ComponentType,
    count: u32,
    min: ?[]f64 = null,
    max: ?[]f64 = null,
    type: []u8,
};

const TargetType = enum(u32) {
    // TODO?
    some1 = 34962, // regular buffer
    some2 = 34963, // index buffer
};

pub const BufferViewIndex = enum(u32) { _ };

pub const BufferView = struct {
    buffer: BufferIndex,
    byteOffset: u32 = 0,
    byteLength: u32,
    target: ?TargetType = null,
};

pub const BufferIndex = enum(u32) { _ };

pub const Buffer = struct {
    byteLength: u32,
    uri: []const u8,
};

pub const TransformMatrix = [16]f32;

pub const MaterialIndex = enum(u32) { _ };

pub const Material = struct {
    name: ?conststring = null,
    alphaMode: ?conststring = null,
    doubleSided: ?bool = null,
    pbrMetallicRoughness: struct {
        baseColorTexture: ?struct {
            index: TextureIndex,
        } = null,
        baseColorFactor: ?[4]f32 = null,
        metallicFactor: f32,
        roughnessFactor: f32,
    },
};

pub const TextureIndex = enum(u32) { _ };

pub const Texture = struct {
    sampler: SamplerIndex,
    source: ImageIndex,
};

pub const MagFilter = enum(u32) {
    gl_linear = 9729,
};

pub const MinFilter = enum(u32) {
    gl_linear_mipmap_linear = 9987,
    gl_linear_mipmap_nearest = 9985,
};

pub const WrapType = enum(u32) {
    gl_repeat = 10497,
    gl_clamp_to_edge = 33071,
    gl_mirrored_repeat = 33648,
};

pub const SamplerIndex = enum(u32) { _ };

pub const Sampler = struct {
    magFilter: MagFilter,
    minFilter: MinFilter,
    wrapS: WrapType,
    wrapT: WrapType,
};

pub const ImageIndex = enum(u32) { _ };

pub const Image = struct {
    uri: conststring,
};
