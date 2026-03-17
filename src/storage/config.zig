const std = @import("std");

/// 配置文件路径
const CONFIG_DIR = ".zscripts";
const CONFIG_FILE = "scripts.json";
const PATHS_FILE = "paths.json";
const HIDDEN_SCRIPTS_FILE = "hidden_scripts.json";
const HISTORY_FILE = "history.json";
const CONFIG_VERSION: u32 = 2;
const CONFIG_WRITE_DEBOUNCE_MS: i64 = 300;
const MAX_HISTORY_ENTRIES: usize = 100;

/// 脚本参数配置
pub const ParameterConfig = struct {
    name: []const u8,
    value: []const u8,
};

/// 脚本配置
pub const ScriptConfig = struct {
    config_version: u32,
    path: []const u8,
    description: []const u8,
    command: []const u8,
    parameters: []ParameterConfig,
};

/// 路径配置
pub const PathConfig = struct {
    path: []const u8,
    is_directory: bool,
};

pub const HiddenScriptConfig = struct {
    path: []const u8,
};

/// 执行历史记录
pub const HistoryEntry = struct {
    script_path: []const u8,
    script_name: []const u8,
    command: []const u8,
    exit_code: ?i32,
    success: bool,
    timestamp_ms: i64,
};

/// 配置管理器
pub const ConfigManager = struct {
    allocator: std.mem.Allocator,
    config_dir_path: []const u8,
    config_file_path: []const u8,
    paths_file_path: []const u8,
    hidden_file_path: []const u8,
    history_file_path: []const u8,
    script_configs: std.ArrayList(ScriptConfig),
    configs_loaded: bool,
    dirty: bool,
    next_flush_ms: i64,
    needs_migration_writeback: bool,

    pub fn init(allocator: std.mem.Allocator) !ConfigManager {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
        const config_dir = try std.fs.path.join(allocator, &[_][]const u8{ home, CONFIG_DIR });
        defer allocator.free(config_dir);
        return initWithDir(allocator, config_dir);
    }

    pub fn initWithDir(allocator: std.mem.Allocator, config_dir: []const u8) !ConfigManager {
        std.fs.makeDirAbsolute(config_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const config_file = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, CONFIG_FILE });
        const paths_file = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, PATHS_FILE });
        const hidden_file = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, HIDDEN_SCRIPTS_FILE });
        const history_file = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, HISTORY_FILE });

        return ConfigManager{
            .allocator = allocator,
            .config_dir_path = try allocator.dupe(u8, config_dir),
            .config_file_path = config_file,
            .paths_file_path = paths_file,
            .hidden_file_path = hidden_file,
            .history_file_path = history_file,
            .script_configs = std.ArrayList(ScriptConfig).init(allocator),
            .configs_loaded = false,
            .dirty = false,
            .next_flush_ms = 0,
            .needs_migration_writeback = false,
        };
    }

    pub fn deinit(self: *ConfigManager) void {
        self.flushPendingWrites(true) catch {};
        self.freeConfigs(self.script_configs);
        self.allocator.free(self.config_dir_path);
        self.allocator.free(self.config_file_path);
        self.allocator.free(self.paths_file_path);
        self.allocator.free(self.hidden_file_path);
        self.allocator.free(self.history_file_path);
    }

    fn cloneParameters(self: *ConfigManager, parameters: []const ParameterConfig) ![]ParameterConfig {
        const cloned = try self.allocator.alloc(ParameterConfig, parameters.len);
        errdefer self.allocator.free(cloned);

        var i: usize = 0;
        errdefer {
            while (i > 0) {
                i -= 1;
                self.allocator.free(cloned[i].name);
                self.allocator.free(cloned[i].value);
            }
        }

        for (parameters, 0..) |param, idx| {
            cloned[idx] = .{
                .name = try self.allocator.dupe(u8, param.name),
                .value = try self.allocator.dupe(u8, param.value),
            };
            i = idx + 1;
        }

        return cloned;
    }

    fn ensureConfigsLoaded(self: *ConfigManager) !void {
        if (self.configs_loaded) return;

        const loaded = try self.loadAllConfigs();
        self.freeConfigs(self.script_configs);
        self.script_configs = loaded;
        self.configs_loaded = true;

        if (self.needs_migration_writeback) {
            self.dirty = true;
            self.next_flush_ms = std.time.milliTimestamp();
        }
    }

    pub fn hasPendingWrites(self: *const ConfigManager) bool {
        return self.dirty;
    }

    pub fn flushPendingWrites(self: *ConfigManager, force: bool) !void {
        if (!self.dirty) return;
        if (!force and std.time.milliTimestamp() < self.next_flush_ms) return;

        try self.writeConfigs(self.script_configs.items);
        self.dirty = false;
    }

    /// 返回缓存中的脚本配置视图，避免渲染路径中的重复读盘和分配
    pub fn getScriptConfigView(self: *ConfigManager, script_path: []const u8) !?*const ScriptConfig {
        try self.ensureConfigsLoaded();

        for (self.script_configs.items) |*cfg| {
            if (std.mem.eql(u8, cfg.path, script_path)) {
                return cfg;
            }
        }

        return null;
    }

    /// 保存脚本配置
    pub fn saveScriptConfig(self: *ConfigManager, script_path: []const u8, description: []const u8, command: []const u8, parameters: []const ParameterConfig) !void {
        try self.ensureConfigsLoaded();

        var found = false;
        for (self.script_configs.items) |*cfg| {
            if (std.mem.eql(u8, cfg.path, script_path)) {
                self.allocator.free(cfg.description);
                self.allocator.free(cfg.command);
                for (cfg.parameters) |param| {
                    self.allocator.free(param.name);
                    self.allocator.free(param.value);
                }
                self.allocator.free(cfg.parameters);

                cfg.description = try self.allocator.dupe(u8, description);
                cfg.command = try self.allocator.dupe(u8, command);
                cfg.parameters = try self.cloneParameters(parameters);
                cfg.config_version = CONFIG_VERSION;
                found = true;
                break;
            }
        }

        if (!found) {
            try self.script_configs.append(.{
                .config_version = CONFIG_VERSION,
                .path = try self.allocator.dupe(u8, script_path),
                .description = try self.allocator.dupe(u8, description),
                .command = try self.allocator.dupe(u8, command),
                .parameters = try self.cloneParameters(parameters),
            });
        }

        self.dirty = true;
        self.next_flush_ms = std.time.milliTimestamp() + CONFIG_WRITE_DEBOUNCE_MS;
    }

    /// 加载脚本配置
    pub fn loadScriptConfig(self: *ConfigManager, script_path: []const u8) !?ScriptConfig {
        const cached = try self.getScriptConfigView(script_path);
        if (cached == null) return null;
        const cfg = cached.?;

        return ScriptConfig{
            .config_version = cfg.config_version,
            .path = try self.allocator.dupe(u8, cfg.path),
            .description = try self.allocator.dupe(u8, cfg.description),
            .command = try self.allocator.dupe(u8, cfg.command),
            .parameters = try self.cloneParameters(cfg.parameters),
        };
    }

    /// 加载所有配置
    fn loadAllConfigs(self: *ConfigManager) !std.ArrayList(ScriptConfig) {
        var configs = std.ArrayList(ScriptConfig).init(self.allocator);
        self.needs_migration_writeback = false;

        const file = std.fs.openFileAbsolute(self.config_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return configs;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        if (content.len == 0) return configs;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) return configs;

        for (root.array.items) |item| {
            if (item != .object) continue;

            const path = item.object.get("path") orelse continue;
            const desc = item.object.get("description") orelse continue;
            if (path != .string or desc != .string) continue;

            const cfg_version = blk: {
                const value = item.object.get("config_version") orelse break :blk 1;
                if (value == .integer and value.integer > 0) {
                    break :blk @as(u32, @intCast(value.integer));
                }
                break :blk 1;
            };
            const needs_migration = cfg_version < CONFIG_VERSION;
            if (needs_migration) {
                self.needs_migration_writeback = true;
            }

            // command 可选；旧版本升级时清空 command/parameters，要求用户重新填写
            const cmd = if (needs_migration)
                ""
            else if (item.object.get("command")) |c|
                (if (c == .string) c.string else "")
            else
                "";

            var params = std.ArrayList(ParameterConfig).init(self.allocator);
            if (!needs_migration) {
                if (item.object.get("parameters")) |params_json| {
                    if (params_json == .array) {
                        for (params_json.array.items) |param_item| {
                            if (param_item != .object) continue;
                            const name = param_item.object.get("name") orelse continue;
                            const value = param_item.object.get("value") orelse continue;
                            if (name != .string or value != .string) continue;

                            try params.append(.{
                                .name = try self.allocator.dupe(u8, name.string),
                                .value = try self.allocator.dupe(u8, value.string),
                            });
                        }
                    }
                }
            }

            try configs.append(.{
                .config_version = CONFIG_VERSION,
                .path = try self.allocator.dupe(u8, path.string),
                .description = try self.allocator.dupe(u8, desc.string),
                .command = try self.allocator.dupe(u8, cmd),
                .parameters = try params.toOwnedSlice(),
            });
        }

        return configs;
    }

    /// 原子写入文件（临时文件 + fsync + rename）
    fn atomicWriteFile(_: *ConfigManager, target_path: []const u8, content: []const u8) !void {
        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{target_path});

        var tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
        var file_closed = false;

        errdefer {
            if (!file_closed) tmp_file.close();
            std.fs.deleteFileAbsolute(tmp_path) catch {};
        }

        try tmp_file.writeAll(content);
        try tmp_file.sync();

        tmp_file.close();
        file_closed = true;

        try std.fs.renameAbsolute(tmp_path, target_path);
    }

    /// 写入配置到文件
    fn writeConfigs(self: *ConfigManager, configs: []const ScriptConfig) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        const writer = buffer.writer();

        try writer.writeAll("[\n");
        for (configs, 0..) |cfg, i| {
            try writer.writeAll("  {\n");
            try writer.print("    \"config_version\": {d},\n", .{cfg.config_version});
            try writer.print("    \"path\": \"{s}\",\n", .{cfg.path});
            try writer.print("    \"description\": \"{s}\",\n", .{cfg.description});
            try writer.print("    \"command\": \"{s}\",\n", .{cfg.command});
            try writer.writeAll("    \"parameters\": [\n");

            for (cfg.parameters, 0..) |param, j| {
                try writer.writeAll("      {\n");
                try writer.print("        \"name\": \"{s}\",\n", .{param.name});
                try writer.print("        \"value\": \"{s}\"\n", .{param.value});
                if (j < cfg.parameters.len - 1) {
                    try writer.writeAll("      },\n");
                } else {
                    try writer.writeAll("      }\n");
                }
            }

            try writer.writeAll("    ]\n");
            if (i < configs.len - 1) {
                try writer.writeAll("  },\n");
            } else {
                try writer.writeAll("  }\n");
            }
        }
        try writer.writeAll("]\n");

        try self.atomicWriteFile(self.config_file_path, buffer.items);
    }

    /// 释放配置列表
    fn freeConfigs(self: *ConfigManager, configs: std.ArrayList(ScriptConfig)) void {
        for (configs.items) |cfg| {
            self.allocator.free(cfg.path);
            self.allocator.free(cfg.description);
            self.allocator.free(cfg.command);
            for (cfg.parameters) |param| {
                self.allocator.free(param.name);
                self.allocator.free(param.value);
            }
            self.allocator.free(cfg.parameters);
        }
        configs.deinit();
    }

    /// 保存路径列表
    pub fn savePaths(self: *ConfigManager, paths: []const PathConfig) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        const writer = buffer.writer();

        try writer.writeAll("[\n");
        for (paths, 0..) |path_config, i| {
            try writer.writeAll("  {\n");
            try writer.print("    \"path\": \"{s}\",\n", .{path_config.path});
            try writer.print("    \"is_directory\": {}\n", .{path_config.is_directory});
            if (i < paths.len - 1) {
                try writer.writeAll("  },\n");
            } else {
                try writer.writeAll("  }\n");
            }
        }
        try writer.writeAll("]\n");

        try self.atomicWriteFile(self.paths_file_path, buffer.items);
    }

    /// 加载路径列表
    pub fn loadPaths(self: *ConfigManager) ![]PathConfig {
        const file = std.fs.openFileAbsolute(self.paths_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return &[_]PathConfig{};
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        if (content.len == 0) return &[_]PathConfig{};

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) return &[_]PathConfig{};

        var paths = std.ArrayList(PathConfig).init(self.allocator);
        for (root.array.items) |item| {
            if (item != .object) continue;

            const path = item.object.get("path") orelse continue;
            const is_dir = item.object.get("is_directory") orelse continue;

            if (path != .string or is_dir != .bool) continue;

            try paths.append(.{
                .path = try self.allocator.dupe(u8, path.string),
                .is_directory = is_dir.bool,
            });
        }

        return try paths.toOwnedSlice();
    }

    /// 释放路径列表
    pub fn freePaths(self: *ConfigManager, paths: []PathConfig) void {
        for (paths) |path_config| {
            self.allocator.free(path_config.path);
        }
        self.allocator.free(paths);
    }

    pub fn saveHiddenScripts(self: *ConfigManager, hidden: []const HiddenScriptConfig) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        const writer = buffer.writer();
        try writer.writeAll("[\n");
        for (hidden, 0..) |entry, idx| {
            try writer.writeAll("  {\n");
            try writer.print("    \"path\": \"{s}\"\n", .{entry.path});
            if (idx + 1 < hidden.len) {
                try writer.writeAll("  },\n");
            } else {
                try writer.writeAll("  }\n");
            }
        }
        try writer.writeAll("]\n");

        try self.atomicWriteFile(self.hidden_file_path, buffer.items);
    }

    pub fn loadHiddenScripts(self: *ConfigManager) ![]HiddenScriptConfig {
        const file = std.fs.openFileAbsolute(self.hidden_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return &[_]HiddenScriptConfig{};
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        if (content.len == 0) return &[_]HiddenScriptConfig{};

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, content, .{}) catch {
            return &[_]HiddenScriptConfig{};
        };
        defer parsed.deinit();

        if (parsed.value != .array) {
            return &[_]HiddenScriptConfig{};
        }

        var hidden = std.ArrayList(HiddenScriptConfig).init(self.allocator);
        errdefer {
            for (hidden.items) |entry| {
                self.allocator.free(entry.path);
            }
            hidden.deinit();
        }

        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const path = item.object.get("path") orelse continue;
            if (path != .string or path.string.len == 0) continue;
            try hidden.append(.{
                .path = try self.allocator.dupe(u8, path.string),
            });
        }

        return try hidden.toOwnedSlice();
    }

    pub fn freeHiddenScripts(self: *ConfigManager, hidden: []HiddenScriptConfig) void {
        for (hidden) |entry| {
            self.allocator.free(entry.path);
        }
        self.allocator.free(hidden);
    }

    pub fn saveHistory(self: *ConfigManager, entries: []const HistoryEntry) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        const writer = buffer.writer();
        try writer.writeAll("[\n");
        for (entries, 0..) |entry, i| {
            try writer.writeAll("  {\n");
            try writeJsonString(writer, "    \"script_path\": ", entry.script_path);
            try writer.writeAll(",\n");
            try writeJsonString(writer, "    \"script_name\": ", entry.script_name);
            try writer.writeAll(",\n");
            try writeJsonString(writer, "    \"command\": ", entry.command);
            try writer.writeAll(",\n");
            if (entry.exit_code) |code| {
                try writer.print("    \"exit_code\": {d},\n", .{code});
            } else {
                try writer.writeAll("    \"exit_code\": null,\n");
            }
            try writer.print("    \"success\": {s},\n", .{if (entry.success) "true" else "false"});
            try writer.print("    \"timestamp_ms\": {d}\n", .{entry.timestamp_ms});
            if (i < entries.len - 1) {
                try writer.writeAll("  },\n");
            } else {
                try writer.writeAll("  }\n");
            }
        }
        try writer.writeAll("]\n");

        try self.atomicWriteFile(self.history_file_path, buffer.items);
    }

    pub fn loadHistory(self: *ConfigManager) ![]HistoryEntry {
        const file = std.fs.openFileAbsolute(self.history_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return &[_]HistoryEntry{};
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        if (content.len == 0) return &[_]HistoryEntry{};

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, content, .{}) catch {
            return &[_]HistoryEntry{};
        };
        defer parsed.deinit();

        if (parsed.value != .array) return &[_]HistoryEntry{};

        var entries = std.ArrayList(HistoryEntry).init(self.allocator);
        errdefer {
            for (entries.items) |entry| {
                self.allocator.free(entry.script_path);
                self.allocator.free(entry.script_name);
                self.allocator.free(entry.command);
            }
            entries.deinit();
        }

        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const sp = item.object.get("script_path") orelse continue;
            const sn = item.object.get("script_name") orelse continue;
            const cmd = item.object.get("command") orelse continue;
            const ts = item.object.get("timestamp_ms") orelse continue;
            const suc = item.object.get("success") orelse continue;
            if (sp != .string or sn != .string or cmd != .string or ts != .integer or suc != .bool) continue;

            const exit_code: ?i32 = blk: {
                const ec = item.object.get("exit_code") orelse break :blk null;
                if (ec == .integer) break :blk @as(i32, @intCast(ec.integer));
                break :blk null;
            };

            try entries.append(.{
                .script_path = try self.allocator.dupe(u8, sp.string),
                .script_name = try self.allocator.dupe(u8, sn.string),
                .command = try self.allocator.dupe(u8, cmd.string),
                .exit_code = exit_code,
                .success = suc.bool,
                .timestamp_ms = ts.integer,
            });
        }

        return try entries.toOwnedSlice();
    }

    pub fn freeHistory(self: *ConfigManager, entries: []HistoryEntry) void {
        for (entries) |entry| {
            self.allocator.free(entry.script_path);
            self.allocator.free(entry.script_name);
            self.allocator.free(entry.command);
        }
        self.allocator.free(entries);
    }
};

fn writeJsonString(writer: anytype, prefix: []const u8, value: []const u8) !void {
    try writer.writeAll(prefix);
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

test {
    _ = @import("config_test.zig");
}
