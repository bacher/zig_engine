const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const BindGroupDefinition = @import("./bind_group.zig").BindGroupDefinition;

pub const Pipeline = struct {
    pipeline_handle: zgpu.RenderPipelineHandle,
    pipeline_gpu: wgpu.RenderPipeline,

    pub fn init(gctx: *zgpu.GraphicsContext, pipeline_handle: zgpu.RenderPipelineHandle) !Pipeline {
        if (gctx.lookupResource(pipeline_handle)) |pipeline_gpu| {
            return .{
                .pipeline_handle = pipeline_handle,
                .pipeline_gpu = pipeline_gpu,
            };
        } else {
            return error.PipelineNotReady;
        }
    }

    pub fn deinit(pipeline: Pipeline, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(pipeline.pipeline_handle);
    }
};
