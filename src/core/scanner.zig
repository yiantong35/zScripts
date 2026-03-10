const std = @import("std");
const script = @import("script.zig");

const CACHE_DIR = ".zscripts";
const SCAN_INDEX_FILE = "scan_index.json";
const SCAN_CACHE_VERSION: u32 = 2;
const CACHE_WRITE_INTERVAL_MS: i64 = 500;

const FileFingerprint = struct {
    mtime: i128,
    size: u64,
};

const PersistedScriptEntry = struct {
    path: []const u8,
    mtime: i128,
    size: u64,
};

const PersistedScanRootEntry = struct {
    path: []const u8,
    is_directory: bool,
    exists: bool,
    mtime: i128,
    size: u64,
};

const PersistedScanIndex = struct {
    version: u32,
    scan_roots: []PersistedScanRootEntry,
    scripts: []PersistedScriptEntry,
};

pub const ScanPath = struct {
    path: []const u8,
    is_directory: bool,
};

/// 脚本扫描器
pub const Scanner = struct {
    allocator: std.mem.Allocator,
    scripts: std.ArrayList(script.Script),
    script_index: std.StringHashMap(usize),
    fingerprints: std.StringHashMap(FileFingerprint),
    hidden_paths: std.StringHashMap(void),
    cache_dir_path: ?[]const u8,
    cache_file_path: ?[]const u8,
    last_cache_hash: u64,
    last_cache_hash_valid: bool,
    last_cache_write_ms: i64,

    pub fn init(allocator: std.mem.Allocator) Scanner {
        var cache_dir_path: ?[]const u8 = null;
        var cache_file_path: ?[]const u8 = null;

        if (std.posix.getenv("HOME")) |home_c| {
            const home: []const u8 = home_c;
            cache_dir_path = std.fs.path.join(allocator, &[_][]const u8{ home, CACHE_DIR }) catch null;
            if (cache_dir_path) |dir_path| {
                std.fs.makeDirAbsolute(dir_path) catch {};
                cache_file_path = std.fs.path.join(allocator, &[_][]const u8{ dir_path, SCAN_INDEX_FILE }) catch null;
            }
        }

        return Scanner{
            .allocator = allocator,
            .scripts = std.ArrayList(script.Script).init(allocator),
            .script_index = std.StringHashMap(usize).init(allocator),
            .fingerprints = std.StringHashMap(FileFingerprint).init(allocator),
            .hidden_paths = std.StringHashMap(void).init(allocator),
            .cache_dir_path = cache_dir_path,
            .cache_file_path = cache_file_path,
            .last_cache_hash = 0,
            .last_cache_hash_valid = false,
            .last_cache_write_ms = 0,
        };
    }

    pub fn deinit(self: *Scanner) void {
        self.script_index.deinit();
        self.fingerprints.deinit();
        self.hidden_paths.deinit();
        if (self.cache_dir_path) |path| {
            self.allocator.free(path);
        }
        if (self.cache_file_path) |path| {
            self.allocator.free(path);
        }
        for (self.scripts.items) |*s| {
            s.deinit();
        }
        self.scripts.deinit();
    }

    fn isScriptFile(path: []const u8) bool {
        const basename = std.fs.path.basename(path);
        return std.mem.endsWith(u8, basename, ".py") or std.mem.endsWith(u8, basename, ".sh");
    }

    fn pathBelongsToDirectory(file_path: []const u8, dir_path: []const u8) bool {
        if (!std.mem.startsWith(u8, file_path, dir_path)) return false;
        if (file_path.len == dir_path.len) return true;
        if (dir_path.len > 0 and dir_path[dir_path.len - 1] == std.fs.path.sep) return true;
        return file_path[dir_path.len] == std.fs.path.sep;
    }

    fn pathMatchesScanPaths(script_path: []const u8, scan_paths: []const ScanPath) bool {
        for (scan_paths) |scan_path| {
            if (scan_path.is_directory) {
                if (pathBelongsToDirectory(script_path, scan_path.path)) {
                    return true;
                }
            } else if (std.mem.eql(u8, script_path, scan_path.path)) {
                return true;
            }
        }
        return false;
    }

    fn statPathFingerprint(path: []const u8, is_directory: bool) ?FileFingerprint {
        if (is_directory) {
            var dir = std.fs.cwd().openDir(path, .{}) catch return null;
            defer dir.close();

            const stat = dir.stat() catch return null;
            return .{
                .mtime = stat.mtime,
                .size = stat.size,
            };
        }

        const stat = std.fs.cwd().statFile(path) catch return null;
        return .{
            .mtime = stat.mtime,
            .size = stat.size,
        };
    }

    fn isScanRootsFresh(scan_paths: []const ScanPath, cached_roots: []const PersistedScanRootEntry) bool {
        if (scan_paths.len != cached_roots.len) return false;

        for (scan_paths) |scan_path| {
            var matched = false;
            for (cached_roots) |cached| {
                if (cached.is_directory != scan_path.is_directory) continue;
                if (!std.mem.eql(u8, cached.path, scan_path.path)) continue;

                const current_fp = statPathFingerprint(scan_path.path, scan_path.is_directory);
                if (current_fp) |fp| {
                    if (!cached.exists) return false;
                    if (cached.mtime != fp.mtime or cached.size != fp.size) return false;
                } else {
                    if (cached.exists) return false;
                }

                matched = true;
                break;
            }
            if (!matched) return false;
        }

        return true;
    }

    fn shouldSkipDirectory(name: []const u8) bool {
        return std.mem.eql(u8, name, ".git") or
            std.mem.eql(u8, name, ".hg") or
            std.mem.eql(u8, name, ".svn") or
            std.mem.eql(u8, name, "node_modules") or
            std.mem.eql(u8, name, ".venv") or
            std.mem.eql(u8, name, "venv") or
            std.mem.eql(u8, name, "__pycache__") or
            std.mem.eql(u8, name, ".pytest_cache") or
            std.mem.eql(u8, name, ".mypy_cache");
    }

    pub fn setHiddenPaths(self: *Scanner, paths: []const []const u8) !void {
        self.hidden_paths.clearRetainingCapacity();
        for (paths) |path| {
            try self.hidden_paths.put(path, {});
        }
    }

    pub fn isHiddenPath(self: *const Scanner, path: []const u8) bool {
        return self.hidden_paths.contains(path);
    }

    fn appendScriptWithFingerprint(self: *Scanner, full_path: []const u8, fp: FileFingerprint, touch_flags: ?*std.ArrayList(bool)) !void {
        const basename = std.fs.path.basename(full_path);
        const is_python = std.mem.endsWith(u8, basename, ".py");
        const is_shell = std.mem.endsWith(u8, basename, ".sh");
        if (!is_python and !is_shell) return;
        if (self.isHiddenPath(full_path)) return;

        if (self.script_index.get(full_path)) |idx| {
            if (touch_flags) |flags| {
                flags.items[idx] = true;
            }
            const key = self.scripts.items[idx].path;
            const old_fp = self.fingerprints.get(key);
            if (old_fp == null or old_fp.?.mtime != fp.mtime or old_fp.?.size != fp.size) {
                try self.fingerprints.put(key, fp);
            }
            return;
        }

        const command = if (is_python)
            try std.fmt.allocPrint(self.allocator, "uv run {s}", .{full_path})
        else
            try std.fmt.allocPrint(self.allocator, "bash {s}", .{full_path});
        defer self.allocator.free(command);

        const s = try script.Script.init(self.allocator, full_path, basename, command);
        try self.scripts.append(s);
        if (touch_flags) |flags| {
            try flags.append(true);
        }

        const idx = self.scripts.items.len - 1;
        const key = self.scripts.items[idx].path;
        try self.script_index.put(key, idx);
        try self.fingerprints.put(key, fp);
    }

    fn addScript(self: *Scanner, full_path: []const u8, touch_flags: *std.ArrayList(bool)) !void {
        const stat = std.fs.cwd().statFile(full_path) catch return;
        const fp = FileFingerprint{
            .mtime = stat.mtime,
            .size = stat.size,
        };

        try self.appendScriptWithFingerprint(full_path, fp, touch_flags);
    }

    fn scanDirectoryRecursive(self: *Scanner, dir_path: []const u8, touch_flags: *std.ArrayList(bool)) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
                    defer self.allocator.free(full_path);
                    if (self.isHiddenPath(full_path)) continue;
                    try self.addScript(full_path, touch_flags);
                },
                .directory => {
                    if (shouldSkipDirectory(entry.name)) continue;
                    const child_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
                    defer self.allocator.free(child_path);
                    self.scanDirectoryRecursive(child_path, touch_flags) catch {};
                },
                else => {},
            }
        }
    }

    fn rebuildScriptIndex(self: *Scanner) !void {
        self.script_index.clearRetainingCapacity();
        for (self.scripts.items, 0..) |s, idx| {
            try self.script_index.put(s.path, idx);
        }
    }

    /// 按路径列表增量刷新脚本索引（删除不存在项、更新变化项、添加新增项）
    pub fn refresh(self: *Scanner, scan_paths: []const ScanPath) !void {
        var touch_flags = std.ArrayList(bool).init(self.allocator);
        defer touch_flags.deinit();

        try touch_flags.resize(self.scripts.items.len);
        @memset(touch_flags.items, false);

        for (scan_paths) |scan_path| {
            if (scan_path.is_directory) {
                self.scanDirectoryRecursive(scan_path.path, &touch_flags) catch {};
            } else {
                if (self.isHiddenPath(scan_path.path)) continue;
                try self.addScript(scan_path.path, &touch_flags);
            }
        }

        var i: usize = self.scripts.items.len;
        while (i > 0) {
            i -= 1;
            if (touch_flags.items[i]) continue;

            const removed_path = self.scripts.items[i].path;
            _ = self.script_index.remove(removed_path);
            _ = self.fingerprints.remove(removed_path);

            var removed = self.scripts.orderedRemove(i);
            removed.deinit();
        }

        try self.rebuildScriptIndex();
    }

    /// 从持久化缓存恢复脚本索引。返回 true 表示缓存文件读取成功。
    pub fn loadPersistentCache(self: *Scanner, scan_paths: []const ScanPath) !bool {
        const cache_file_path = self.cache_file_path orelse return false;

        const file = std.fs.openFileAbsolute(cache_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 16 * 1024 * 1024);
        defer self.allocator.free(content);
        if (content.len == 0) return false;

        const parsed = std.json.parseFromSlice(PersistedScanIndex, self.allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch return false;
        defer parsed.deinit();

        if (parsed.value.version != SCAN_CACHE_VERSION) {
            return false;
        }
        if (!isScanRootsFresh(scan_paths, parsed.value.scan_roots)) {
            return false;
        }

        self.clear();
        for (parsed.value.scripts) |cached_script| {
            if (!isScriptFile(cached_script.path)) continue;
            if (!pathMatchesScanPaths(cached_script.path, scan_paths)) continue;
            if (self.isHiddenPath(cached_script.path)) continue;

            self.appendScriptWithFingerprint(cached_script.path, .{
                .mtime = cached_script.mtime,
                .size = cached_script.size,
            }, null) catch {};
        }

        try self.rebuildScriptIndex();
        return true;
    }

    /// 将当前扫描结果轻量持久化，供下次启动快速恢复
    pub fn savePersistentCache(self: *Scanner, scan_paths: []const ScanPath) !void {
        const cache_file_path = self.cache_file_path orelse return;
        if (self.cache_dir_path) |dir_path| {
            std.fs.makeDirAbsolute(dir_path) catch {};
        }

        var persisted_roots = std.ArrayList(PersistedScanRootEntry).init(self.allocator);
        defer persisted_roots.deinit();
        try persisted_roots.ensureTotalCapacity(scan_paths.len);
        for (scan_paths) |scan_path| {
            const fp = statPathFingerprint(scan_path.path, scan_path.is_directory);
            persisted_roots.appendAssumeCapacity(.{
                .path = scan_path.path,
                .is_directory = scan_path.is_directory,
                .exists = fp != null,
                .mtime = if (fp) |value| value.mtime else 0,
                .size = if (fp) |value| value.size else 0,
            });
        }

        var persisted_scripts = std.ArrayList(PersistedScriptEntry).init(self.allocator);
        defer persisted_scripts.deinit();

        try persisted_scripts.ensureTotalCapacity(self.scripts.items.len);
        for (self.scripts.items) |s| {
            const fp = self.fingerprints.get(s.path) orelse continue;
            persisted_scripts.appendAssumeCapacity(.{
                .path = s.path,
                .mtime = fp.mtime,
                .size = fp.size,
            });
        }

        const payload = PersistedScanIndex{
            .version = SCAN_CACHE_VERSION,
            .scan_roots = persisted_roots.items,
            .scripts = persisted_scripts.items,
        };

        var content = std.ArrayList(u8).init(self.allocator);
        defer content.deinit();
        try std.json.stringify(payload, .{}, content.writer());
        try content.writer().writeByte('\n');

        const content_hash = std.hash.Wyhash.hash(0, content.items);
        if (self.last_cache_hash_valid and self.last_cache_hash == content_hash) {
            return;
        }

        const now_ms = std.time.milliTimestamp();
        if (self.last_cache_hash_valid and now_ms - self.last_cache_write_ms < CACHE_WRITE_INTERVAL_MS) {
            return;
        }

        const file = try std.fs.createFileAbsolute(cache_file_path, .{});
        defer file.close();

        try file.writeAll(content.items);
        self.last_cache_hash = content_hash;
        self.last_cache_hash_valid = true;
        self.last_cache_write_ms = now_ms;
    }

    /// 扫描目录，查找所有 .py 和 .sh 文件（增量添加，不删除旧项）
    pub fn scanDirectory(self: *Scanner, dir_path: []const u8) !void {
        var touch_flags = std.ArrayList(bool).init(self.allocator);
        defer touch_flags.deinit();

        try touch_flags.resize(self.scripts.items.len);
        @memset(touch_flags.items, true);

        try self.scanDirectoryRecursive(dir_path, &touch_flags);
        try self.rebuildScriptIndex();
    }

    /// 获取扫描到的脚本列表
    pub fn getScripts(self: *const Scanner) []const script.Script {
        return self.scripts.items;
    }

    /// 清空脚本列表
    pub fn clear(self: *Scanner) void {
        for (self.scripts.items) |*s| {
            s.deinit();
        }
        self.scripts.clearRetainingCapacity();
        self.script_index.clearRetainingCapacity();
        self.fingerprints.clearRetainingCapacity();
    }
};
