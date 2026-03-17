const std = @import("std");
const scanner_mod = @import("scanner.zig");

fn createTempTestDir() ![]const u8 {
    const allocator = std.testing.allocator;
    const tmp = try std.fs.path.join(allocator, &[_][]const u8{ "/tmp", "zscripts_scanner_test" });
    std.fs.deleteTreeAbsolute(tmp) catch {};
    try std.fs.makeDirAbsolute(tmp);
    return tmp;
}

fn cleanupTempDir(dir_path: []const u8) void {
    std.fs.deleteTreeAbsolute(dir_path) catch {};
    std.testing.allocator.free(dir_path);
}

fn createFile(dir: []const u8, name: []const u8, content: []const u8) ![]const u8 {
    const allocator = std.testing.allocator;
    const path = try std.fs.path.join(allocator, &[_][]const u8{ dir, name });
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(content);
    return path;
}

fn createSubDir(parent: []const u8, name: []const u8) ![]const u8 {
    const allocator = std.testing.allocator;
    const path = try std.fs.path.join(allocator, &[_][]const u8{ parent, name });
    try std.fs.makeDirAbsolute(path);
    return path;
}

test "Scanner: init and deinit" {
    const allocator = std.testing.allocator;
    var s = scanner_mod.Scanner.init(allocator);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 0), s.getScripts().len);
}

test "Scanner: scanDirectory finds .py and .sh files" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempTestDir();
    defer cleanupTempDir(tmp_dir);

    const py_path = try createFile(tmp_dir, "test.py", "#!/usr/bin/env python3\nprint('hello')\n");
    defer allocator.free(py_path);
    const sh_path = try createFile(tmp_dir, "test.sh", "#!/bin/bash\necho hello\n");
    defer allocator.free(sh_path);
    const txt_path = try createFile(tmp_dir, "readme.txt", "not a script");
    defer allocator.free(txt_path);

    var s = scanner_mod.Scanner.init(allocator);
    defer s.deinit();

    try s.scanDirectory(tmp_dir);

    const scripts = s.getScripts();
    try std.testing.expectEqual(@as(usize, 2), scripts.len);
}

test "Scanner: scanDirectory recurses into subdirectories" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempTestDir();
    defer cleanupTempDir(tmp_dir);

    const sub_dir = try createSubDir(tmp_dir, "subdir");
    defer allocator.free(sub_dir);

    const py_path = try createFile(sub_dir, "nested.py", "print('nested')\n");
    defer allocator.free(py_path);
    const sh_path = try createFile(tmp_dir, "root.sh", "echo root\n");
    defer allocator.free(sh_path);

    var s = scanner_mod.Scanner.init(allocator);
    defer s.deinit();

    try s.scanDirectory(tmp_dir);

    const scripts = s.getScripts();
    try std.testing.expectEqual(@as(usize, 2), scripts.len);
}

test "Scanner: scanDirectory skips hidden directories" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempTestDir();
    defer cleanupTempDir(tmp_dir);

    // 创建应被跳过的目录
    const git_dir = try createSubDir(tmp_dir, ".git");
    defer allocator.free(git_dir);
    const venv_dir = try createSubDir(tmp_dir, ".venv");
    defer allocator.free(venv_dir);
    const node_dir = try createSubDir(tmp_dir, "node_modules");
    defer allocator.free(node_dir);

    const git_py = try createFile(git_dir, "hook.py", "# git hook");
    defer allocator.free(git_py);
    const venv_py = try createFile(venv_dir, "activate.py", "# venv");
    defer allocator.free(venv_py);
    const node_sh = try createFile(node_dir, "install.sh", "# node");
    defer allocator.free(node_sh);

    // 创建应被扫描的文件
    const root_py = try createFile(tmp_dir, "main.py", "print('main')");
    defer allocator.free(root_py);

    var s = scanner_mod.Scanner.init(allocator);
    defer s.deinit();

    try s.scanDirectory(tmp_dir);

    const scripts = s.getScripts();
    try std.testing.expectEqual(@as(usize, 1), scripts.len);
}

test "Scanner: setHiddenPaths and isHiddenPath" {
    const allocator = std.testing.allocator;
    var s = scanner_mod.Scanner.init(allocator);
    defer s.deinit();

    const hidden = [_][]const u8{ "/path/to/hidden.py", "/path/to/secret.sh" };
    try s.setHiddenPaths(&hidden);

    try std.testing.expect(s.isHiddenPath("/path/to/hidden.py"));
    try std.testing.expect(s.isHiddenPath("/path/to/secret.sh"));
    try std.testing.expect(!s.isHiddenPath("/path/to/visible.py"));
}

test "Scanner: hidden paths are excluded from scan" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempTestDir();
    defer cleanupTempDir(tmp_dir);

    const py1 = try createFile(tmp_dir, "visible.py", "print('visible')");
    defer allocator.free(py1);
    const py2 = try createFile(tmp_dir, "hidden.py", "print('hidden')");
    defer allocator.free(py2);

    var s = scanner_mod.Scanner.init(allocator);
    defer s.deinit();

    const hidden = [_][]const u8{py2};
    try s.setHiddenPaths(&hidden);

    try s.scanDirectory(tmp_dir);

    const scripts = s.getScripts();
    try std.testing.expectEqual(@as(usize, 1), scripts.len);
    try std.testing.expect(std.mem.endsWith(u8, scripts[0].path, "visible.py"));
}

test "Scanner: clear removes all scripts" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempTestDir();
    defer cleanupTempDir(tmp_dir);

    const py_path = try createFile(tmp_dir, "test.py", "print('test')");
    defer allocator.free(py_path);

    var s = scanner_mod.Scanner.init(allocator);
    defer s.deinit();

    try s.scanDirectory(tmp_dir);
    try std.testing.expect(s.getScripts().len > 0);

    s.clear();
    try std.testing.expectEqual(@as(usize, 0), s.getScripts().len);
}

test "Scanner: refresh removes deleted files" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempTestDir();
    defer cleanupTempDir(tmp_dir);

    const py1 = try createFile(tmp_dir, "keep.py", "print('keep')");
    defer allocator.free(py1);
    const py2 = try createFile(tmp_dir, "delete.py", "print('delete')");
    defer allocator.free(py2);

    var s = scanner_mod.Scanner.init(allocator);
    defer s.deinit();

    const scan_paths = [_]scanner_mod.ScanPath{
        .{ .path = tmp_dir, .is_directory = true },
    };

    try s.refresh(&scan_paths);
    try std.testing.expectEqual(@as(usize, 2), s.getScripts().len);

    // 删除一个文件
    try std.fs.deleteFileAbsolute(py2);

    try s.refresh(&scan_paths);
    try std.testing.expectEqual(@as(usize, 1), s.getScripts().len);
}

test "Scanner: getScripts returns empty for empty directory" {
    const allocator = std.testing.allocator;
    const tmp_dir = try createTempTestDir();
    defer cleanupTempDir(tmp_dir);

    var s = scanner_mod.Scanner.init(allocator);
    defer s.deinit();

    try s.scanDirectory(tmp_dir);
    try std.testing.expectEqual(@as(usize, 0), s.getScripts().len);
}
