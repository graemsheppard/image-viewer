const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "jpeg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,

            // Required for GLFW
            .link_libc = true
        }),
        // For debugging
        .use_llvm = true
    });

    // libglfw3.a should be in /usr/local/lib
    exe.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    exe.linkSystemLibrary("glfw3");

    // link GLAD loader
    exe.addIncludePath(b.path("deps/glad/include"));
    exe.addCSourceFile(.{
        .file = b.path("deps/glad/src/glad.c"),
        .flags = &.{}
    });

    // Required by GLFW
    exe.linkFramework("Cocoa");
    exe.linkFramework("IOKit");
    exe.linkFramework("CoreVideo");
    exe.linkFramework("OpenGL");

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);

    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
