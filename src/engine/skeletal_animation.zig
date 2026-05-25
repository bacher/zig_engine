const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");
const gltf_loader = @import("gltf_loader");
const types = @import("./types.zig");

const gltf_types = gltf_loader.types;

const Self = @This();

pub const JointMatrixUniform = [types.max_skin_joints]zmath.Mat;

pub const JointMatrixBuffer = struct {
    handle: zgpu.BufferHandle,
    gpu_buffer: wgpu.Buffer,

    pub fn deinit(self: JointMatrixBuffer, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(self.handle);
    }
};

allocator: std.mem.Allocator,
mesh_node_index: usize,
joint_matrix_buffer: JointMatrixBuffer,
inverse_bind_matrices: []zmath.Mat,
joint_matrices: []zmath.Mat,
joint_node_indices: []usize,
parent_node_indices: []?usize,
base_node_transforms: []NodeTransform,
current_node_transforms: []NodeTransform,
node_global_matrices: []zmath.Mat,
node_global_computed: []bool,
channels: []AnimationChannel,
start_time: f32,
end_time: f32,

const NodeTransform = struct {
    translation: zmath.Vec,
    rotation: zmath.Quat,
    scale: zmath.Vec,
    matrix: ?zmath.Mat = null,

    fn fromNode(node: gltf_types.Node) NodeTransform {
        const translation = if (node.translation) |value|
            zmath.Vec{ @floatCast(value[0]), @floatCast(value[1]), @floatCast(value[2]), 0 }
        else
            zmath.Vec{ 0, 0, 0, 0 };

        const rotation = if (node.rotation) |value|
            zmath.Quat{ @floatCast(value[0]), @floatCast(value[1]), @floatCast(value[2]), @floatCast(value[3]) }
        else
            zmath.Quat{ 0, 0, 0, 1 };

        const scale = if (node.scale) |value|
            zmath.Vec{ @floatCast(value[0]), @floatCast(value[1]), @floatCast(value[2]), 0 }
        else
            zmath.Vec{ 1, 1, 1, 0 };

        return .{
            .translation = translation,
            .rotation = rotation,
            .scale = scale,
            .matrix = if (node.matrix) |matrix| zmath.matFromArr(matrix.*) else null,
        };
    }

    fn toMatrix(transform: NodeTransform) zmath.Mat {
        if (transform.matrix) |matrix| {
            return matrix;
        }

        return zmath.mul(
            zmath.scaling(transform.scale[0], transform.scale[1], transform.scale[2]),
            zmath.mul(
                zmath.matFromQuat(transform.rotation),
                zmath.translation(
                    transform.translation[0],
                    transform.translation[1],
                    transform.translation[2],
                ),
            ),
        );
    }
};

const AnimationTargetPath = enum {
    translation,
    rotation,
    scale,
};

const AnimationChannelValues = union(AnimationTargetPath) {
    translation: [][3]f32,
    rotation: [][4]f32,
    scale: [][3]f32,
};

const AnimationChannel = struct {
    target_node_index: usize,
    path: AnimationTargetPath,
    interpolation: gltf_types.AnimationInterpolation,
    times: []f32,
    values: AnimationChannelValues,

    fn deinit(channel: AnimationChannel, allocator: std.mem.Allocator) void {
        allocator.free(channel.times);
        switch (channel.values) {
            .translation => |values| allocator.free(values),
            .rotation => |values| allocator.free(values),
            .scale => |values| allocator.free(values),
        }
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    loader: *const gltf_loader.GltfLoader,
    object: *const gltf_loader.SceneObject,
    animation_name: ?[]const u8,
) !?Self {
    const skin_index = object.skin orelse return null;
    const mesh_node = object.node_index orelse return error.MissingMeshNodeIndex;
    const mesh_node_index: usize = @intFromEnum(mesh_node);
    const animation = if (animation_name) |name|
        loader.findAnimationByName(name) orelse return error.AnimationNotFound
    else
        loader.findFirstAnimation() orelse return null;

    var player = Self{
        .allocator = allocator,
        .mesh_node_index = mesh_node_index,
        .joint_matrix_buffer = try createIdentityJointMatrixBuffer(gctx),
        .inverse_bind_matrices = &.{},
        .joint_matrices = &.{},
        .joint_node_indices = &.{},
        .parent_node_indices = &.{},
        .base_node_transforms = &.{},
        .current_node_transforms = &.{},
        .node_global_matrices = &.{},
        .node_global_computed = &.{},
        .channels = &.{},
        .start_time = std.math.floatMax(f32),
        .end_time = 0,
    };
    errdefer player.deinit(gctx);

    const nodes = loader.getNodes();
    try player.loadNodeData(nodes);
    try player.loadSkinData(loader, skin_index);
    try player.loadAnimationData(loader, animation);

    if (player.channels.len == 0) {
        return error.NoAnimationChannels;
    }

    return player;
}

pub fn deinit(self: Self, gctx: *zgpu.GraphicsContext) void {
    self.joint_matrix_buffer.deinit(gctx);
    self.allocator.free(self.inverse_bind_matrices);
    self.allocator.free(self.joint_matrices);
    self.allocator.free(self.joint_node_indices);
    self.allocator.free(self.parent_node_indices);
    self.allocator.free(self.base_node_transforms);
    self.allocator.free(self.current_node_transforms);
    self.allocator.free(self.node_global_matrices);
    self.allocator.free(self.node_global_computed);
    for (self.channels) |channel| {
        channel.deinit(self.allocator);
    }
    self.allocator.free(self.channels);
}

pub fn update(
    self: *Self,
    gctx: *zgpu.GraphicsContext,
    time: f32,
) void {
    if (self.channels.len == 0) {
        return;
    }

    std.mem.copyForwards(NodeTransform, self.current_node_transforms, self.base_node_transforms);

    const local_time = self.loopedTime(time);
    for (self.channels) |channel| {
        self.applyChannel(channel, local_time);
    }

    @memset(self.node_global_computed, false);
    const mesh_global = self.computeGlobalNodeMatrix(self.mesh_node_index);
    const inverse_mesh_global = zmath.inverse(mesh_global);

    for (self.joint_node_indices, 0..) |node_index, joint_index| {
        const joint_global = self.computeGlobalNodeMatrix(node_index);
        self.joint_matrices[joint_index] = zmath.mul(
            zmath.mul(self.inverse_bind_matrices[joint_index], joint_global),
            inverse_mesh_global,
        );
    }

    var uniform: JointMatrixUniform = undefined;
    self.writeJointMatrixUniform(&uniform);
    gctx.queue.writeBuffer(self.joint_matrix_buffer.gpu_buffer, 0, zmath.Mat, uniform[0..]);
}

fn writeJointMatrixUniform(self: *const Self, target: *JointMatrixUniform) void {
    for (target) |*matrix| {
        matrix.* = zmath.identity();
    }

    const joint_count = @min(self.joint_matrices.len, target.len);
    for (self.joint_matrices[0..joint_count], 0..) |matrix, index| {
        target[index] = zmath.transpose(matrix);
    }
}

pub fn createIdentityJointMatrixBuffer(gctx: *zgpu.GraphicsContext) !JointMatrixBuffer {
    var uniform: JointMatrixUniform = undefined;
    for (&uniform) |*matrix| {
        matrix.* = zmath.identity();
    }

    return try createJointMatrixBuffer(gctx, &uniform);
}

fn createJointMatrixBuffer(
    gctx: *zgpu.GraphicsContext,
    initial_data: *const JointMatrixUniform,
) !JointMatrixBuffer {
    const handle = gctx.createBuffer(.{
        .usage = .{
            .copy_dst = true,
            .uniform = true,
        },
        .size = @sizeOf(JointMatrixUniform),
    });

    const gpu_buffer = gctx.lookupResource(handle) orelse return error.BufferIsNotReady;
    gctx.queue.writeBuffer(gpu_buffer, 0, zmath.Mat, initial_data[0..]);

    return .{
        .handle = handle,
        .gpu_buffer = gpu_buffer,
    };
}

fn loadNodeData(self: *Self, nodes: []const gltf_types.Node) !void {
    self.parent_node_indices = try self.allocator.alloc(?usize, nodes.len);
    @memset(self.parent_node_indices, null);

    self.base_node_transforms = try self.allocator.alloc(NodeTransform, nodes.len);
    self.current_node_transforms = try self.allocator.alloc(NodeTransform, nodes.len);
    self.node_global_matrices = try self.allocator.alloc(zmath.Mat, nodes.len);
    self.node_global_computed = try self.allocator.alloc(bool, nodes.len);
    @memset(self.node_global_computed, false);

    for (nodes, 0..) |node, node_index| {
        self.base_node_transforms[node_index] = .fromNode(node);

        if (node.children) |children| {
            for (children) |child_node_index| {
                self.parent_node_indices[@intFromEnum(child_node_index)] = node_index;
            }
        }
    }

    std.mem.copyForwards(NodeTransform, self.current_node_transforms, self.base_node_transforms);
}

fn loadSkinData(
    self: *Self,
    loader: *const gltf_loader.GltfLoader,
    skin_index: gltf_types.SkinIndex,
) !void {
    const skin = loader.getSkin(skin_index);

    self.joint_node_indices = try self.allocator.alloc(usize, skin.joints.len);
    for (skin.joints, 0..) |joint_node_index, index| {
        self.joint_node_indices[index] = @intFromEnum(joint_node_index);
    }

    const inverse_bind_buffer = try loader.loadAccessorBuffer(self.allocator, skin.inverseBindMatrices);
    defer self.allocator.free(inverse_bind_buffer.buffer);

    const inverse_bind_matrices = try inverse_bind_buffer.asTypedSlice([16]f32);
    if (inverse_bind_matrices.len != skin.joints.len) {
        return error.InvalidInverseBindMatrixCount;
    }

    self.inverse_bind_matrices = try self.allocator.alloc(zmath.Mat, inverse_bind_matrices.len);
    self.joint_matrices = try self.allocator.alloc(zmath.Mat, inverse_bind_matrices.len);
    for (inverse_bind_matrices, 0..) |matrix, index| {
        self.inverse_bind_matrices[index] = zmath.matFromArr(matrix);
        self.joint_matrices[index] = zmath.identity();
    }
}

fn loadAnimationData(
    self: *Self,
    loader: *const gltf_loader.GltfLoader,
    animation: *const gltf_types.Animation,
) !void {
    self.channels = try self.allocator.alloc(AnimationChannel, animation.channels.len);
    var channels_count: usize = 0;
    errdefer {
        for (self.channels[0..channels_count]) |channel| {
            channel.deinit(self.allocator);
        }
    }

    for (animation.channels) |channel| {
        const sampler_index: usize = @intCast(channel.sampler);
        if (sampler_index >= animation.samplers.len) {
            return error.InvalidAnimationSamplerIndex;
        }

        const path: AnimationTargetPath = switch (channel.target.path) {
            .translation => .translation,
            .rotation => .rotation,
            .scale => .scale,
            .weights => return error.UnsupportedAnimationTargetPath,
        };
        const sampler = animation.samplers[sampler_index];
        if (sampler.interpolation == .CUBICSPLINE) {
            return error.UnsupportedAnimationInterpolation;
        }

        const times = try self.loadAnimationTimes(loader, sampler.input);
        errdefer self.allocator.free(times);

        const values = try self.loadAnimationValues(loader, sampler.output, path);
        errdefer switch (values) {
            .translation => |value| self.allocator.free(value),
            .rotation => |value| self.allocator.free(value),
            .scale => |value| self.allocator.free(value),
        };

        if (times.len == 0) {
            return error.EmptyAnimationSampler;
        }

        self.start_time = @min(self.start_time, times[0]);
        self.end_time = @max(self.end_time, times[times.len - 1]);

        self.channels[channels_count] = .{
            .target_node_index = @intFromEnum(channel.target.node),
            .path = path,
            .interpolation = sampler.interpolation,
            .times = times,
            .values = values,
        };
        channels_count += 1;
    }

    self.channels = try self.allocator.realloc(self.channels, channels_count);
}

fn loadAnimationTimes(
    self: *Self,
    loader: *const gltf_loader.GltfLoader,
    accessor_index: gltf_types.AccessorIndex,
) ![]f32 {
    const buffer = try loader.loadAccessorBuffer(self.allocator, accessor_index);
    defer self.allocator.free(buffer.buffer);

    const source = try buffer.asTypedSlice([1]f32);
    const times = try self.allocator.alloc(f32, source.len);
    for (source, 0..) |time, index| {
        times[index] = time[0];
    }

    return times;
}

fn loadAnimationValues(
    self: *Self,
    loader: *const gltf_loader.GltfLoader,
    accessor_index: gltf_types.AccessorIndex,
    path: AnimationTargetPath,
) !AnimationChannelValues {
    const buffer = try loader.loadAccessorBuffer(self.allocator, accessor_index);
    defer self.allocator.free(buffer.buffer);

    return switch (path) {
        .translation => .{
            .translation = try self.allocator.dupe([3]f32, try buffer.asTypedSlice([3]f32)),
        },
        .rotation => .{
            .rotation = try self.allocator.dupe([4]f32, try buffer.asTypedSlice([4]f32)),
        },
        .scale => .{
            .scale = try self.allocator.dupe([3]f32, try buffer.asTypedSlice([3]f32)),
        },
    };
}

fn loopedTime(self: *const Self, time: f32) f32 {
    const duration = self.end_time - self.start_time;
    if (duration <= 0) {
        return self.start_time;
    }

    return self.start_time + @mod(time, duration);
}

fn applyChannel(self: *Self, channel: AnimationChannel, time: f32) void {
    const transform = &self.current_node_transforms[channel.target_node_index];
    transform.matrix = null;

    const sample = sampleRange(channel.times, time);

    switch (channel.values) {
        .translation => |values| {
            transform.translation = vecFrom3(
                interpolateVec3(values[sample.from], values[sample.to], sample.factor, channel.interpolation),
                0,
            );
        },
        .rotation => |values| {
            transform.rotation = quatFromArray(interpolateQuat(values[sample.from], values[sample.to], sample.factor, channel.interpolation));
        },
        .scale => |values| {
            transform.scale = vecFrom3(
                interpolateVec3(values[sample.from], values[sample.to], sample.factor, channel.interpolation),
                0,
            );
        },
    }
}

fn sampleRange(times: []const f32, time: f32) struct { from: usize, to: usize, factor: f32 } {
    if (times.len == 1 or time <= times[0]) {
        return .{ .from = 0, .to = 0, .factor = 0 };
    }

    const last_index = times.len - 1;
    if (time >= times[last_index]) {
        return .{ .from = last_index, .to = last_index, .factor = 0 };
    }

    for (0..last_index) |index| {
        const from_time = times[index];
        const to_time = times[index + 1];
        if (time >= from_time and time <= to_time) {
            return .{
                .from = index,
                .to = index + 1,
                .factor = (time - from_time) / (to_time - from_time),
            };
        }
    }

    return .{ .from = last_index, .to = last_index, .factor = 0 };
}

fn computeGlobalNodeMatrix(self: *Self, node_index: usize) zmath.Mat {
    if (self.node_global_computed[node_index]) {
        return self.node_global_matrices[node_index];
    }

    const local_matrix = self.current_node_transforms[node_index].toMatrix();
    const global_matrix = if (self.parent_node_indices[node_index]) |parent_index|
        zmath.mul(local_matrix, self.computeGlobalNodeMatrix(parent_index))
    else
        local_matrix;

    self.node_global_matrices[node_index] = global_matrix;
    self.node_global_computed[node_index] = true;
    return global_matrix;
}

fn interpolateVec3(from: [3]f32, to: [3]f32, factor: f32, interpolation: gltf_types.AnimationInterpolation) [3]f32 {
    if (interpolation == .STEP) {
        return from;
    }

    return .{
        from[0] + (to[0] - from[0]) * factor,
        from[1] + (to[1] - from[1]) * factor,
        from[2] + (to[2] - from[2]) * factor,
    };
}

fn interpolateQuat(from: [4]f32, to: [4]f32, factor: f32, interpolation: gltf_types.AnimationInterpolation) [4]f32 {
    if (interpolation == .STEP) {
        return from;
    }

    var target = to;
    const dot = from[0] * to[0] + from[1] * to[1] + from[2] * to[2] + from[3] * to[3];
    if (dot < 0) {
        target = .{ -to[0], -to[1], -to[2], -to[3] };
    }

    return normalizeQuat(.{
        from[0] + (target[0] - from[0]) * factor,
        from[1] + (target[1] - from[1]) * factor,
        from[2] + (target[2] - from[2]) * factor,
        from[3] + (target[3] - from[3]) * factor,
    });
}

fn normalizeQuat(quat: [4]f32) [4]f32 {
    const length = @sqrt(quat[0] * quat[0] + quat[1] * quat[1] + quat[2] * quat[2] + quat[3] * quat[3]);
    if (length <= 0.000001) {
        return .{ 0, 0, 0, 1 };
    }

    return .{ quat[0] / length, quat[1] / length, quat[2] / length, quat[3] / length };
}

fn vecFrom3(value: [3]f32, w: f32) zmath.Vec {
    return .{ value[0], value[1], value[2], w };
}

fn quatFromArray(value: [4]f32) zmath.Quat {
    return .{ value[0], value[1], value[2], value[3] };
}
