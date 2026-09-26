const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const math = @import("../../math.zig");
const attributes = @import("../shaders/attributes.zig");

const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.opengl);

pub const BgImage = attributes.BgImage;
pub const CellBg = attributes.CellBg;
pub const CellText = attributes.CellText;
pub const Image = attributes.Image;
pub const Uniforms = attributes.Uniforms(.opengl);

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_fn = loadShaderCode("full_screen_vertex.glsl"),
            .fragment_fn = loadShaderCode("bg_color_fragment.glsl"),
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_fn = loadShaderCode("full_screen_vertex.glsl"),
            .fragment_fn = loadShaderCode("cell_bg_fragment.glsl"),
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_fn = loadShaderCode("cell_text_vertex.glsl"),
            .fragment_fn = loadShaderCode("cell_text_fragment.glsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_fn = loadShaderCode("image_vertex.glsl"),
            .fragment_fn = loadShaderCode("image_fragment.glsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_fn = loadShaderCode("bg_image_vertex.glsl"),
            .fragment_fn = loadShaderCode("bg_image_fragment.glsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };

/// All the comptime-known info about a pipeline, so that
/// we can define them ahead-of-time in an ergonomic way.
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    step_fn: Pipeline.Options.StepFunction = .per_vertex,
    blending_enabled: bool = true,

    fn initPipeline(self: PipelineDescription) !Pipeline {
        return try .init(self.vertex_attributes, .{
            .vertex_fn = self.vertex_fn,
            .fragment_fn = self.fragment_fn,
            .step_fn = self.step_fn,
            .blending_enabled = self.blending_enabled,
        });
    }
};

/// We create a type for the pipeline collection based on our desc array.
const PipelineCollection = t: {
    const StructField = std.builtin.Type.StructField;

    var names: [pipeline_descs.len][]const u8 = undefined;
    var types = [_]type{Pipeline} ** pipeline_descs.len;
    var attrs = [_]StructField.Attributes{.{ .@"align" = @alignOf(Pipeline) }} ** pipeline_descs.len;

    for (pipeline_descs, &names) |pipeline, *name| {
        name.* = pipeline[0];
    }
    break :t @Struct(.auto, null, &names, &types, &attrs);
};

/// This contains the state for the shaders used by the OpenGL renderer.
pub const Shaders = struct {
    /// Collection of available render pipelines.
    pipelines: PipelineCollection,

    /// Custom shaders to run against the final drawable texture. This
    /// can be used to apply a lot of effects. Each shader is run in sequence
    /// against the output of the previous shader.
    post_pipelines: []const Pipeline,

    /// Set to true when deinited, if you try to deinit a defunct set
    /// of shaders it will just be ignored, to prevent double-free.
    defunct: bool = false,

    pub const uninit: Shaders = .{
        .pipelines = undefined,
        .post_pipelines = &.{},
        .defunct = true,
    };

    /// Initialize our shader set.
    ///
    /// "post_shaders" is an optional list of postprocess shaders to run
    /// against the final drawable texture. This is an array of shader source
    /// code, not file paths.
    pub fn init(
        alloc: Allocator,
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;

        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline();
            initialized_pipelines += 1;
        }

        const post_pipelines: []const Pipeline = initPostPipelines(
            alloc,
            post_shaders,
        ) catch |err| err: {
            // If an error happens while building postprocess shaders we
            // want to just not use any postprocess shaders since we don't
            // want to block Ghostty from working.
            log.warn("error initializing postprocess shaders err={}", .{err});
            break :err &.{};
        };
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(post_pipelines);
        };

        return .{
            .pipelines = pipelines,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        // Release our primary shaders
        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }

        // Release our postprocess shaders
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| {
                pipeline.deinit();
            }
            alloc.free(self.post_pipelines);
        }
    }
};

/// Initialize our custom shader pipelines. The shaders argument is a
/// set of shader source code, not file paths.
fn initPostPipelines(
    alloc: Allocator,
    shaders: []const [:0]const u8,
) ![]const Pipeline {
    // If we have no shaders, do nothing.
    if (shaders.len == 0) return &.{};

    // Keeps track of how many shaders we successfully wrote.
    var i: usize = 0;

    // Initialize our result set. If any error happens, we undo everything.
    var pipelines = try alloc.alloc(Pipeline, shaders.len);
    errdefer {
        for (pipelines[0..i]) |pipeline| {
            pipeline.deinit();
        }
        alloc.free(pipelines);
    }

    // Build each shader. Note we don't use "0.." to build our index
    // because we need to keep track of our length to clean up above.
    for (shaders) |source| {
        pipelines[i] = try initPostPipeline(source);
        i += 1;
    }

    return pipelines;
}

/// Initialize a single custom shader pipeline from shader source.
fn initPostPipeline(data: [:0]const u8) !Pipeline {
    return try Pipeline.init(null, .{
        .vertex_fn = loadShaderCode("full_screen_vertex.glsl"),
        .fragment_fn = data,
    });
}

/// Load and post-process a shader with the given path,
/// generated by the build system.
///
/// Slang's GLSL backend unfortunately targets *Vulkan* GLSL and not
/// OpenGL GLSL due to the experimental status of the OpenGL backend
/// in general, so we have to do a couple hacks here. Particularly
/// troublesome is the fact that it translates `SV_VertexID` to
/// `gl_VertexIndex - gl_BaseVertex`, which is only present when
/// targeting Vulkan. Nevertheless, we can replace the shader header
/// with our own and provide a polyfill for the missing builtins,
/// and the generated shaders will still compile successfully.
fn loadShaderCode(comptime path: []const u8) [:0]const u8 {
    const old = @embedFile(path);

    const main_start = comptime main: {
        var cursor: usize = 0;
        while (std.mem.findScalarPos(u8, old, cursor, '\n')) |line_start| : (cursor = line_start + 1) {
            const line = old[cursor..line_start];
            if (std.mem.startsWith(u8, line, "#version ") or
                std.mem.startsWith(u8, line, "#extension "))
                continue;
            break;
        }
        break :main cursor;
    };

    const s = comptime std.fmt.comptimePrint(
        \\#version 430 core
        \\#define gl_BaseVertex 0
        \\#define gl_VertexIndex gl_VertexID
        \\
        \\{s}
    ,
        .{old[main_start..]},
    );
    return s;
}
