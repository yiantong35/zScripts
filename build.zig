const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_macos = target.result.os.tag == .macos;

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

    if (is_macos) {
        const bundle_name = "zScripts.app";
        const bundle_contents = bundle_name ++ "/Contents";
        const bundle_macos = bundle_contents ++ "/MacOS";
        const bundle_resources = bundle_contents ++ "/Resources";

        const app_exe_install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = bundle_macos } },
            .dest_sub_path = "zScripts",
        });
        b.getInstallStep().dependOn(&app_exe_install.step);

        const write_files = b.addWriteFiles();
        const info_plist = write_files.add("Info.plist", b.fmt(
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\    <key>CFBundleDevelopmentRegion</key>
            \\    <string>en</string>
            \\    <key>CFBundleDisplayName</key>
            \\    <string>zScripts</string>
            \\    <key>CFBundleExecutable</key>
            \\    <string>zScripts</string>
            \\    <key>CFBundleIconFile</key>
            \\    <string>AppIcon</string>
            \\    <key>CFBundleIdentifier</key>
            \\    <string>com.tangyujie.zscripts</string>
            \\    <key>CFBundleInfoDictionaryVersion</key>
            \\    <string>6.0</string>
            \\    <key>CFBundleName</key>
            \\    <string>zScripts</string>
            \\    <key>CFBundlePackageType</key>
            \\    <string>APPL</string>
            \\    <key>CFBundleShortVersionString</key>
            \\    <string>1.0</string>
            \\    <key>CFBundleVersion</key>
            \\    <string>1</string>
            \\    <key>LSApplicationCategoryType</key>
            \\    <string>public.app-category.developer-tools</string>
            \\    <key>LSMinimumSystemVersion</key>
            \\    <string>13.0</string>
            \\    <key>NSHighResolutionCapable</key>
            \\    <true/>
            \\</dict>
            \\</plist>
        , .{}));
        const install_info_plist = b.addInstallFileWithDir(info_plist, .prefix, bundle_contents ++ "/Info.plist");
        b.getInstallStep().dependOn(&install_info_plist.step);

        const generate_icon = b.addSystemCommand(&.{ "/usr/bin/xcrun", "swift" });
        generate_icon.setEnvironmentVariable("SWIFT_MODULECACHE_PATH", b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "swift-module-cache" }));
        generate_icon.setEnvironmentVariable("CLANG_MODULE_CACHE_PATH", b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "clang-module-cache" }));
        generate_icon.addFileArg(b.path("tools/generate_app_icon.swift"));
        const icns_file = generate_icon.addOutputFileArg("AppIcon.icns");

        const install_icon = b.addInstallFileWithDir(icns_file, .prefix, bundle_resources ++ "/AppIcon.icns");
        b.getInstallStep().dependOn(&install_icon.step);

        const app_step = b.step("app", "Build macOS .app bundle");
        app_step.dependOn(b.getInstallStep());
    } else {
        b.installArtifact(exe);
    }

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

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
