const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const Pipeline = struct {
    pipeline_handle: zgpu.RenderPipelineHandle,
    pipeline_gpu: wgpu.RenderPipeline,

    pub fn init(gctx: *zgpu.GraphicsContext, pipeline_handle: zgpu.RenderPipelineHandle) Pipeline {
        return .{
            .pipeline_handle = pipeline_handle,
            .pipeline_gpu = gctx.lookupResource(pipeline_handle).?,
        };
    }

    pub fn deinit(pipeline: Pipeline, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(pipeline.pipeline_handle);
    }
};
