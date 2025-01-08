const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

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
};
