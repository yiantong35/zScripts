const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zglfw = b.dependency("zglfw", .{
        .target = target,
    });

    const zgui = b.dependency("zgui", .{
        .target = target,
        .backend = .glfw_opengl3,
    });

    const zopengl = b.dependency("zopengl", .{
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zScripts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zglfw", .module = zglfw.module("root") },
                .{ .name = "zgui", .module = zgui.module("root") },
                .{ .name = "zopengl", .module = zopengl.module("root") },
            },
        }),
    });

    exe.linkLibrary(zglfw.artifact("glfw"));
    exe.linkLibrary(zgui.artifact("imgui"));

    // 添加 Objective-C 文件
    exe.addCSourceFile(.{
        .file = b.path("src/core/file_picker.m"),
        .flags = &.{"-fobjc-arc"},
    });

    // 链接 macOS 框架
    exe.linkFramework("OpenGL");
    exe.linkFramework("Cocoa");

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);
}
