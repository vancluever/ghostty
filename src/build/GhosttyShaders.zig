const GhosttyShaders = @This();
const std = @import("std");

msl: std.Build.LazyPath,
glsl: std.EnumMap(Entrypoint, std.Build.LazyPath),

/// The source Slang shader.
source: std.Build.LazyPath,

/// Synchronize with src/renderer/shaders/shaders.slang.
pub const Entrypoint = enum {
    full_screen_vertex,
    bg_color_fragment,
    bg_image_vertex,
    bg_image_fragment,
    cell_bg_fragment,
    cell_text_vertex,
    cell_text_fragment,
    image_vertex,
    image_fragment,
};

// Compile a Slang shader to multiple output types.
//
// Currently supports MSL (Metal) and GLSL (OpenGL). Note that each
// output type gets its own slangc invocation: slangc doesn't support
// multiple GLSL entry points in a single invocation.
pub fn init(b: *std.Build, source: std.Build.LazyPath) !GhosttyShaders {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(source);
    cmd.addArgs(&.{
        // Buffer 0 is reserved for the vertex buffer for some renderers
        // (e.g. Metal). Shift all the other buffers by 1 to get the
        // correct indices.
        "-fvk-b-shift", "1",     "0",
        "-target",      "metal",
    });
    cmd.addArg("-o");
    const msl = cmd.addOutputFileArg("shaders.metal");

    var glsl: std.EnumMap(Entrypoint, std.Build.LazyPath) = .{};
    for (std.meta.tags(Entrypoint)) |ep| {
        const file = b.fmt("{t}.glsl", .{ep});
        const ep_cmd = b.addSystemCommand(&.{"slangc"});
        ep_cmd.addFileArg(source);
        ep_cmd.addArgs(&.{
            "-fvk-b-shift", "1",    "0",
            "-target",      "glsl", "-entry",
            @tagName(ep),
        });
        ep_cmd.addArg("-o");
        glsl.put(ep, ep_cmd.addOutputFileArg(file));
    }

    return .{
        .msl = msl,
        .glsl = glsl,
        .source = source,
    };
}
