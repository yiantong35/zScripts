const std = @import("std");
const config = @import("config.zig");

// 测试用临时目录辅助
fn createTempDir() ![]const u8 {
    const allocator = std.testing.allocator;
    const tmp = try std.fs.path.join(allocator, &[_][]const u8{ "/tmp", "zscripts_test" });
    std.fs.makeDirAbsolute(tmp) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    return tmp;
}

fn cleanupTempDir(dir_path: []const u8) void {
    std.fs.deleteTreeAbsolute(dir_path) catch {};
    std.testing.allocator.free(dir_path);
}

test "atomicWriteFile: basic write and read back" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempDir();
    defer cleanupTempDir(tmp_dir);

    var mgr = try config.ConfigManager.initWithDir(allocator, tmp_dir);
    defer mgr.deinit();

    const paths = [_]config.PathConfig{
        .{ .path = "/usr/local/bin", .is_directory = true },
        .{ .path = "/tmp/test.py", .is_directory = false },
    };

    try mgr.savePaths(&paths);

    // 读回验证
    const loaded = try mgr.loadPaths();
    defer {
        for (loaded) |p| {
            allocator.free(p.path);
        }
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("/usr/local/bin", loaded[0].path);
    try std.testing.expect(loaded[0].is_directory);
    try std.testing.expectEqualStrings("/tmp/test.py", loaded[1].path);
    try std.testing.expect(!loaded[1].is_directory);
}

test "savePaths and loadPaths: round-trip" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempDir();
    defer cleanupTempDir(tmp_dir);

    var mgr = try config.ConfigManager.initWithDir(allocator, tmp_dir);
    defer mgr.deinit();

    // 保存空列表
    const empty = [_]config.PathConfig{};
    try mgr.savePaths(&empty);

    const loaded_empty = try mgr.loadPaths();
    defer allocator.free(loaded_empty);
    try std.testing.expectEqual(@as(usize, 0), loaded_empty.len);

    // 保存多个路径
    const paths = [_]config.PathConfig{
        .{ .path = "/path/one", .is_directory = true },
        .{ .path = "/path/two", .is_directory = false },
        .{ .path = "/path/three", .is_directory = true },
    };
    try mgr.savePaths(&paths);

    const loaded = try mgr.loadPaths();
    defer {
        for (loaded) |p| allocator.free(p.path);
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 3), loaded.len);
    try std.testing.expectEqualStrings("/path/one", loaded[0].path);
    try std.testing.expectEqualStrings("/path/two", loaded[1].path);
    try std.testing.expectEqualStrings("/path/three", loaded[2].path);
}

test "saveHiddenScripts and loadHiddenScripts: round-trip" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempDir();
    defer cleanupTempDir(tmp_dir);

    var mgr = try config.ConfigManager.initWithDir(allocator, tmp_dir);
    defer mgr.deinit();

    const hidden = [_]config.HiddenScriptConfig{
        .{ .path = "/scripts/hidden1.py" },
        .{ .path = "/scripts/hidden2.sh" },
    };
    try mgr.saveHiddenScripts(&hidden);

    const loaded = try mgr.loadHiddenScripts();
    defer mgr.freeHiddenScripts(loaded);

    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("/scripts/hidden1.py", loaded[0].path);
    try std.testing.expectEqualStrings("/scripts/hidden2.sh", loaded[1].path);
}

test "saveScriptConfig and getScriptConfigView: round-trip" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempDir();
    defer cleanupTempDir(tmp_dir);

    var mgr = try config.ConfigManager.initWithDir(allocator, tmp_dir);
    defer mgr.deinit();

    const params = [_]config.ParameterConfig{
        .{ .name = "--verbose", .value = "true" },
        .{ .name = "--output", .value = "/tmp/out" },
    };

    try mgr.saveScriptConfig("/test/script.py", "Test script", "uv run", &params);

    // 强制刷盘
    try mgr.flushPendingWrites(true);

    // 重新加载验证
    mgr.configs_loaded = false;
    const view = try mgr.getScriptConfigView("/test/script.py");
    try std.testing.expect(view != null);

    const cfg = view.?;
    try std.testing.expectEqualStrings("/test/script.py", cfg.path);
    try std.testing.expectEqualStrings("Test script", cfg.description);
    try std.testing.expectEqualStrings("uv run", cfg.command);
    try std.testing.expectEqual(@as(usize, 2), cfg.parameters.len);
    try std.testing.expectEqualStrings("--verbose", cfg.parameters[0].name);
    try std.testing.expectEqualStrings("true", cfg.parameters[0].value);
}

test "loadPaths: empty file returns empty slice" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempDir();
    defer cleanupTempDir(tmp_dir);

    var mgr = try config.ConfigManager.initWithDir(allocator, tmp_dir);
    defer mgr.deinit();

    // 写入空数组
    const empty = [_]config.PathConfig{};
    try mgr.savePaths(&empty);

    const loaded = try mgr.loadPaths();
    defer allocator.free(loaded);
    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

test "loadHiddenScripts: empty file returns empty slice" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempDir();
    defer cleanupTempDir(tmp_dir);

    var mgr = try config.ConfigManager.initWithDir(allocator, tmp_dir);
    defer mgr.deinit();

    const empty = [_]config.HiddenScriptConfig{};
    try mgr.saveHiddenScripts(&empty);

    const loaded = try mgr.loadHiddenScripts();
    defer mgr.freeHiddenScripts(loaded);
    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

test "atomicWriteFile: no .tmp file left after success" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempDir();
    defer cleanupTempDir(tmp_dir);

    var mgr = try config.ConfigManager.initWithDir(allocator, tmp_dir);
    defer mgr.deinit();

    const paths = [_]config.PathConfig{
        .{ .path = "/test/path", .is_directory = true },
    };
    try mgr.savePaths(&paths);

    // 验证 .tmp 文件不存在
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{mgr.paths_file_path});
    defer allocator.free(tmp_path);

    const tmp_exists = blk: {
        std.fs.accessAbsolute(tmp_path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!tmp_exists);
}

test "hasPendingWrites and flushPendingWrites" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempDir();
    defer cleanupTempDir(tmp_dir);

    var mgr = try config.ConfigManager.initWithDir(allocator, tmp_dir);
    defer mgr.deinit();

    try std.testing.expect(!mgr.hasPendingWrites());

    const params = [_]config.ParameterConfig{};
    try mgr.saveScriptConfig("/test/flush.py", "flush test", "bash", &params);

    try std.testing.expect(mgr.hasPendingWrites());

    try mgr.flushPendingWrites(true);
    try std.testing.expect(!mgr.hasPendingWrites());
}
