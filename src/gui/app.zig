const std = @import("std");
const zgui = @import("zgui");
const scanner = @import("../core/scanner.zig");
const executor = @import("../core/executor.zig");
const perf_monitor = @import("../core/perf_monitor.zig");
const config = @import("../storage/config.zig");

// 组件模块
pub const home_page = @import("components/home_page.zig");
pub const script_editor = @import("components/script_editor.zig");
pub const execution_view = @import("components/execution_view.zig");
pub const card = @import("components/card.zig");

// 工具模块
pub const text_utils = @import("utils/text_utils.zig");

/// 添加的路径类型
const PathEntry = struct {
    path: []const u8,
    is_directory: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, is_directory: bool) !PathEntry {
        return PathEntry{
            .path = try allocator.dupe(u8, path),
            .is_directory = is_directory,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PathEntry) void {
        self.allocator.free(self.path);
    }
};

pub const CardMeta = struct {
    title_line: []const u8,
    title_tooltip: ?[]const u8,
    desc_line: []const u8,
    desc_tooltip: ?[]const u8,
    has_desc: bool,
    command_line: []const u8,
    command_tooltip: ?[]const u8,
    param_line: []const u8,
    param_tooltip: ?[]const u8,
    has_params: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CardMeta) void {
        self.allocator.free(self.title_line);
        if (self.title_tooltip) |text| self.allocator.free(text);
        self.allocator.free(self.desc_line);
        if (self.desc_tooltip) |text| self.allocator.free(text);
        self.allocator.free(self.command_line);
        if (self.command_tooltip) |text| self.allocator.free(text);
        self.allocator.free(self.param_line);
        if (self.param_tooltip) |text| self.allocator.free(text);
    }
};

const ToastKind = enum {
    success,
    failure,
    info,
};

/// 标签类型
pub const TabType = enum {
    home, // 首页
    script, // 脚本标签页
};

/// 脚本参数（用于 UI 输入）
pub const ScriptParameter = struct {
    name: [128:0]u8, // 参数名缓冲区
    value: [256:0]u8, // 参数值缓冲区

    pub fn init() ScriptParameter {
        var param = ScriptParameter{
            .name = undefined,
            .value = undefined,
        };
        @memset(&param.name, 0);
        @memset(&param.value, 0);
        return param;
    }
};

/// 标签数据
pub const Tab = struct {
    tab_type: TabType,
    title: [:0]const u8, // 以 null 结尾的字符串
    script_path: ?[]const u8, // 如果是脚本标签，存储脚本路径
    script_executor: ?executor.ScriptExecutor, // 脚本执行器（仅脚本标签有）
    description: [512:0]u8, // 脚本描述
    command: [512:0]u8, // 执行命令（可编辑）
    parameters: std.ArrayList(ScriptParameter), // 参数列表
    show_full_output: bool,
    output_auto_scroll: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, tab_type: TabType, title: []const u8, script_path: ?[]const u8) !Tab {
        const title_copy = try allocator.dupeZ(u8, title);
        const path_copy = if (script_path) |path| try allocator.dupe(u8, path) else null;

        // 脚本标签创建执行器
        const exec = if (tab_type == .script) executor.ScriptExecutor.init(allocator) else null;

        var description: [512:0]u8 = undefined;
        @memset(&description, 0);

        // command 由用户手动输入，默认留空
        var command: [512:0]u8 = undefined;
        @memset(&command, 0);

        const parameters = std.ArrayList(ScriptParameter).init(allocator);

        return Tab{
            .tab_type = tab_type,
            .title = title_copy,
            .script_path = path_copy,
            .script_executor = exec,
            .description = description,
            .command = command,
            .parameters = parameters,
            .show_full_output = false,
            .output_auto_scroll = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Tab) void {
        self.allocator.free(self.title);
        if (self.script_path) |path| {
            self.allocator.free(path);
        }
        if (self.script_executor) |*exec| {
            var mut_exec = exec.*;
            mut_exec.deinit();
        }
        self.parameters.deinit();
    }
};

/// 应用状态
pub const AppState = struct {
    tabs: std.ArrayList(Tab),
    active_tab_index: usize,
    allocator: std.mem.Allocator,
    scanner: scanner.Scanner,
    current_page: usize, // 当前页码（从0开始）
    scripts_per_page: usize, // 每页显示的脚本数量
    added_paths: std.ArrayList(PathEntry), // 已添加的路径列表
    hidden_scripts: std.StringHashMap(void), // 软删除脚本路径集合
    card_meta_cache: std.ArrayList(CardMeta), // 首页卡片预计算缓存
    card_meta_dirty: bool, // 卡片缓存需要重建
    pending_tab_switch: ?usize, // 待切换的标签索引（用于强制切换）
    pending_shortcut_tab: ?usize, // Cmd+数字快捷键待切换的标签索引
    extra_frames_needed: u8, // 延迟 UI 操作还需要的活跃渲染帧数
    pending_remove_path: ?[]const u8, // 待确认删除的脚本路径
    pending_remove_name: ?[]const u8, // 待确认删除的脚本名称
    pending_remove_has_error: bool, // 删除失败提示
    pending_remove_error: [256:0]u8, // 删除失败信息
    toast_kind: ToastKind,
    toast_message: [192:0]u8,
    toast_until_ms: i64,
    input_grace_until_ms: i64,
    last_mouse_pos: [2]f32,
    last_mouse_pos_valid: bool,
    search_query: [256:0]u8, // 搜索查询字符串
    execution_history: std.ArrayList(config.HistoryEntry), // 执行历史记录
    perf: perf_monitor.PerfMonitor, // 性能观测
    config_manager: config.ConfigManager, // 配置管理器

    pub fn init(allocator: std.mem.Allocator) !AppState {
        var tabs = std.ArrayList(Tab).init(allocator);

        // 创建首页标签
        const home_tab = try Tab.init(allocator, .home, "Home", null);
        try tabs.append(home_tab);

        // 创建 AppState
        var pending_remove_error: [256:0]u8 = undefined;
        @memset(&pending_remove_error, 0);
        var toast_message: [192:0]u8 = undefined;
        @memset(&toast_message, 0);
        var search_query: [256:0]u8 = undefined;
        @memset(&search_query, 0);
        var app_state = AppState{
            .tabs = tabs,
            .active_tab_index = 0,
            .allocator = allocator,
            .scanner = scanner.Scanner.init(allocator),
            .current_page = 0,
            .scripts_per_page = 12,
            .added_paths = std.ArrayList(PathEntry).init(allocator),
            .hidden_scripts = std.StringHashMap(void).init(allocator),
            .card_meta_cache = std.ArrayList(CardMeta).init(allocator),
            .card_meta_dirty = true,
            .pending_tab_switch = null,
            .pending_shortcut_tab = null,
            .extra_frames_needed = 0,
            .pending_remove_path = null,
            .pending_remove_name = null,
            .pending_remove_has_error = false,
            .pending_remove_error = pending_remove_error,
            .toast_kind = .success,
            .toast_message = toast_message,
            .toast_until_ms = 0,
            .input_grace_until_ms = 0,
            .last_mouse_pos = .{ 0.0, 0.0 },
            .last_mouse_pos_valid = false,
            .search_query = search_query,
            .execution_history = std.ArrayList(config.HistoryEntry).init(allocator),
            .perf = try perf_monitor.PerfMonitor.init(allocator),
            .config_manager = try config.ConfigManager.init(allocator),
        };

        const hidden_scripts = try app_state.config_manager.loadHiddenScripts();
        defer app_state.config_manager.freeHiddenScripts(hidden_scripts);
        for (hidden_scripts) |entry| {
            const normalized = try normalizePath(app_state.allocator, entry.path);
            defer app_state.allocator.free(normalized);
            _ = try app_state.addHiddenScriptPath(normalized);
        }
        try app_state.syncHiddenPathsToScanner();

        // 加载保存的路径并扫描
        const saved_paths = try app_state.config_manager.loadPaths();
        defer app_state.config_manager.freePaths(saved_paths);

        for (saved_paths) |path_config| {
            _ = try app_state.addPathIfMissing(path_config.path, path_config.is_directory);
        }

        // 启动时优先加载扫描缓存，命中失败再做一次真实扫描
        const cache_loaded = try app_state.loadScriptsFromPersistentCache();
        if (!cache_loaded) {
            try app_state.refreshScripts();
        }
        if (app_state.added_paths.items.len != saved_paths.len) {
            home_page.saveAddedPaths(&app_state) catch {};
        }

        // 加载执行历史
        const saved_history = app_state.config_manager.loadHistory() catch &[_]config.HistoryEntry{};
        for (saved_history) |entry| {
            app_state.execution_history.append(.{
                .script_path = allocator.dupe(u8, entry.script_path) catch continue,
                .script_name = allocator.dupe(u8, entry.script_name) catch continue,
                .command = allocator.dupe(u8, entry.command) catch continue,
                .exit_code = entry.exit_code,
                .success = entry.success,
                .timestamp_ms = entry.timestamp_ms,
            }) catch {};
        }
        if (saved_history.len > 0) {
            app_state.config_manager.freeHistory(@constCast(saved_history));
        }

        return app_state;
    }

    pub fn deinit(self: *AppState) void {
        for (self.tabs.items) |*tab| {
            tab.deinit();
        }
        self.tabs.deinit();
        self.scanner.deinit();
        for (self.added_paths.items) |*entry| {
            entry.deinit();
        }
        self.added_paths.deinit();
        var hidden_iter = self.hidden_scripts.iterator();
        while (hidden_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.hidden_scripts.deinit();
        self.clearPendingRemove();
        self.clearCardMetaCache();
        self.card_meta_cache.deinit();
        self.freeExecutionHistory();
        self.execution_history.deinit();
        self.config_manager.flushPendingWrites(true) catch {};
        self.perf.deinit();
        self.config_manager.deinit();
    }

    /// 检查是否有脚本正在运行
    pub fn hasRunningScript(self: *const AppState) bool {
        for (self.tabs.items) |*tab| {
            if (tab.script_executor) |*exec| {
                if (exec.isRunning()) return true;
            }
        }
        return false;
    }

    pub fn setStartupMs(self: *AppState, startup_ms: f64) void {
        self.perf.setStartupMs(startup_ms);
    }

    pub fn recordFrameMetrics(self: *AppState, render_ms: f64) void {
        if (!self.perf.isEnabled()) return;

        self.perf.recordRenderMs(render_ms);

        var output_bytes: usize = 0;
        for (self.tabs.items) |*tab| {
            if (tab.script_executor) |*exec| {
                output_bytes += exec.getOutput().len;
            }
        }

        self.perf.updateSnapshot(self.scanner.getScripts().len, output_bytes);
    }

    /// 当交互需要立刻渲染下一帧（例如单击打开新标签）时返回 true
    pub fn needsImmediateRedraw(self: *const AppState) bool {
        return self.pending_tab_switch != null or self.extra_frames_needed > 0;
    }

    pub fn requestExtraFrames(self: *AppState, n: u8) void {
        if (n > self.extra_frames_needed) self.extra_frames_needed = n;
    }

    pub fn consumeExtraFrame(self: *AppState) void {
        if (self.extra_frames_needed > 0) self.extra_frames_needed -= 1;
    }

    pub fn noteInputActivity(self: *AppState) void {
        const next_until = std.time.milliTimestamp() + 140;
        if (next_until > self.input_grace_until_ms) self.input_grace_until_ms = next_until;
    }

    pub fn updatePointerActivity(self: *AppState, mouse_pos: [2]f32) void {
        if (!self.last_mouse_pos_valid or mouse_pos[0] != self.last_mouse_pos[0] or mouse_pos[1] != self.last_mouse_pos[1]) {
            self.last_mouse_pos = mouse_pos;
            self.last_mouse_pos_valid = true;
            self.noteInputActivity();
        }
    }

    pub fn needsInteractiveIdleRedraw(self: *const AppState) bool {
        return self.input_grace_until_ms > std.time.milliTimestamp();
    }

    pub fn getSearchQuery(self: *const AppState) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.search_query, 0) orelse self.search_query.len;
        return self.search_query[0..len];
    }

    pub fn addHistoryEntry(self: *AppState, script_path: []const u8, script_name: []const u8, command: []const u8, exit_code: ?i32, success: bool) void {
        const entry = config.HistoryEntry{
            .script_path = self.allocator.dupe(u8, script_path) catch return,
            .script_name = self.allocator.dupe(u8, script_name) catch return,
            .command = self.allocator.dupe(u8, command) catch return,
            .exit_code = exit_code,
            .success = success,
            .timestamp_ms = std.time.milliTimestamp(),
        };

        self.execution_history.append(entry) catch return;

        // 超过上限时移除最旧的记录
        while (self.execution_history.items.len > 100) {
            const old = self.execution_history.orderedRemove(0);
            self.allocator.free(old.script_path);
            self.allocator.free(old.script_name);
            self.allocator.free(old.command);
        }

        // 持久化
        self.config_manager.saveHistory(self.execution_history.items) catch {};
    }

    fn freeExecutionHistory(self: *AppState) void {
        for (self.execution_history.items) |entry| {
            self.allocator.free(entry.script_path);
            self.allocator.free(entry.script_name);
            self.allocator.free(entry.command);
        }
        self.execution_history.clearRetainingCapacity();
    }

    fn hasActiveToast(self: *const AppState) bool {
        return self.toast_until_ms > std.time.milliTimestamp() and self.toast_message[0] != 0;
    }

    fn showToast(self: *AppState, kind: ToastKind, message: []const u8) void {
        @memset(&self.toast_message, 0);
        const max_len = self.toast_message.len - 1;
        const copy_len = @min(message.len, max_len);
        @memcpy(self.toast_message[0..copy_len], message[0..copy_len]);
        self.toast_message[copy_len] = 0;
        self.toast_kind = kind;
        self.toast_until_ms = std.time.milliTimestamp() + 1600;
        self.requestExtraFrames(2);
    }

    pub fn showSuccessToast(self: *AppState, message: []const u8) void {
        self.showToast(.success, message);
    }

    pub fn showErrorToast(self: *AppState, message: []const u8) void {
        self.showToast(.failure, message);
    }

    pub fn needsBackgroundTick(self: *const AppState) bool {
        return self.config_manager.hasPendingWrites() or self.perf.needsTick() or self.hasActiveToast();
    }

    pub fn flushBackgroundTasks(self: *AppState) void {
        self.config_manager.flushPendingWrites(false) catch |err| {
            std.debug.print("flush config failed: {}\n", .{err});
        };
        self.perf.flushLogIfNeeded() catch |err| {
            std.debug.print("flush perf log failed: {}\n", .{err});
        };
    }

    fn clearCardMetaCache(self: *AppState) void {
        for (self.card_meta_cache.items) |*meta| {
            meta.deinit();
        }
        self.card_meta_cache.clearRetainingCapacity();
    }

    pub fn rebuildCardMetaCache(self: *AppState) !void {
        self.clearCardMetaCache();

        const scripts = self.scanner.getScripts();
        try self.card_meta_cache.ensureTotalCapacity(scripts.len);
        for (scripts) |s| {
            const cfg = try self.config_manager.getScriptConfigView(s.path);
            const meta = try card.buildCardMeta(self.allocator, &s, cfg);
            self.card_meta_cache.appendAssumeCapacity(meta);
        }
        self.card_meta_dirty = false;
    }

    pub fn rebuildCardMetaForScript(self: *AppState, script_path: []const u8) !void {
        const scripts = self.scanner.getScripts();
        if (self.card_meta_dirty or self.card_meta_cache.items.len != scripts.len) {
            try self.rebuildCardMetaCache();
            return;
        }

        for (scripts, 0..) |s, idx| {
            if (!std.mem.eql(u8, s.path, script_path)) continue;

            const cfg = try self.config_manager.getScriptConfigView(s.path);
            const new_meta = try card.buildCardMeta(self.allocator, &s, cfg);
            self.card_meta_cache.items[idx].deinit();
            self.card_meta_cache.items[idx] = new_meta;
            return;
        }
    }

    fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try allocator.dupe(u8, path),
        };
    }

    fn addHiddenScriptPath(self: *AppState, script_path: []const u8) !bool {
        if (self.hidden_scripts.contains(script_path)) {
            return false;
        }

        const owned = try self.allocator.dupe(u8, script_path);
        errdefer self.allocator.free(owned);
        try self.hidden_scripts.put(owned, {});
        return true;
    }

    fn removeHiddenScriptPath(self: *AppState, script_path: []const u8) bool {
        const removed = self.hidden_scripts.fetchRemove(script_path);
        if (removed) |entry| {
            self.allocator.free(entry.key);
            return true;
        }
        return false;
    }

    fn syncHiddenPathsToScanner(self: *AppState) !void {
        var hidden_paths = std.ArrayList([]const u8).init(self.allocator);
        defer hidden_paths.deinit();

        try hidden_paths.ensureTotalCapacity(self.hidden_scripts.count());
        var iter = self.hidden_scripts.iterator();
        while (iter.next()) |entry| {
            hidden_paths.appendAssumeCapacity(entry.key_ptr.*);
        }

        try self.scanner.setHiddenPaths(hidden_paths.items);
    }

    fn persistHiddenScripts(self: *AppState) !void {
        var hidden_list = std.ArrayList(config.HiddenScriptConfig).init(self.allocator);
        defer hidden_list.deinit();

        try hidden_list.ensureTotalCapacity(self.hidden_scripts.count());
        var iter = self.hidden_scripts.iterator();
        while (iter.next()) |entry| {
            hidden_list.appendAssumeCapacity(.{
                .path = entry.key_ptr.*,
            });
        }

        try self.config_manager.saveHiddenScripts(hidden_list.items);
    }

    fn clearPendingRemove(self: *AppState) void {
        if (self.pending_remove_path) |path| {
            self.allocator.free(path);
            self.pending_remove_path = null;
        }
        if (self.pending_remove_name) |name| {
            self.allocator.free(name);
            self.pending_remove_name = null;
        }
        self.pending_remove_has_error = false;
        @memset(&self.pending_remove_error, 0);
    }

    fn setPendingRemoveError(self: *AppState, message: []const u8) void {
        @memset(&self.pending_remove_error, 0);
        const max_len = self.pending_remove_error.len - 1;
        const copy_len = @min(message.len, max_len);
        @memcpy(self.pending_remove_error[0..copy_len], message[0..copy_len]);
        self.pending_remove_error[copy_len] = 0;
        self.pending_remove_has_error = true;
    }

    pub fn requestRemoveScript(self: *AppState, script_path: []const u8, script_name: []const u8) !void {
        self.clearPendingRemove();
        self.pending_remove_path = try self.allocator.dupe(u8, script_path);
        errdefer self.clearPendingRemove();
        self.pending_remove_name = try self.allocator.dupe(u8, script_name);
        self.requestExtraFrames(2);
    }

    fn closeTabsForScript(self: *AppState, script_path: []const u8) void {
        var i = self.tabs.items.len;
        while (i > 1) {
            i -= 1;
            if (self.tabs.items[i].script_path) |path| {
                if (std.mem.eql(u8, path, script_path)) {
                    self.closeTab(i);
                }
            }
        }
    }

    pub fn addPathIfMissing(self: *AppState, path: []const u8, is_directory: bool) !bool {
        const normalized = try normalizePath(self.allocator, path);
        defer self.allocator.free(normalized);

        var changed = false;
        if (!is_directory and self.removeHiddenScriptPath(normalized)) {
            try self.persistHiddenScripts();
            try self.syncHiddenPathsToScanner();
            changed = true;
        }

        for (self.added_paths.items) |entry| {
            if (entry.is_directory == is_directory and std.mem.eql(u8, entry.path, normalized)) {
                return changed;
            }
        }

        const new_entry = try PathEntry.init(self.allocator, normalized, is_directory);
        try self.added_paths.append(new_entry);
        return true;
    }

    pub fn removeScriptFromZscripts(self: *AppState, script_path: []const u8) !void {
        const normalized = try normalizePath(self.allocator, script_path);
        defer self.allocator.free(normalized);

        var path_removed = false;
        var i: usize = 0;
        while (i < self.added_paths.items.len) {
            const entry = self.added_paths.items[i];
            if (!entry.is_directory and std.mem.eql(u8, entry.path, normalized)) {
                var removed_entry = self.added_paths.orderedRemove(i);
                removed_entry.deinit();
                path_removed = true;
                continue;
            }
            i += 1;
        }

        const hidden_added = try self.addHiddenScriptPath(normalized);
        if (path_removed) {
            try home_page.saveAddedPaths(self);
        }
        if (hidden_added) {
            try self.persistHiddenScripts();
            try self.syncHiddenPathsToScanner();
        }

        self.closeTabsForScript(normalized);
        self.active_tab_index = 0;
        self.pending_tab_switch = 0;
        self.requestExtraFrames(3);

        try self.refreshScripts();
        self.current_page = 0;
    }

    pub fn refreshScripts(self: *AppState) !void {
        const refresh_begin_ns = std.time.nanoTimestamp();
        var scan_paths = std.ArrayList(scanner.ScanPath).init(self.allocator);
        defer scan_paths.deinit();

        try scan_paths.ensureTotalCapacity(self.added_paths.items.len);
        for (self.added_paths.items) |entry| {
            scan_paths.appendAssumeCapacity(.{
                .path = entry.path,
                .is_directory = entry.is_directory,
            });
        }

        try self.scanner.refresh(scan_paths.items);
        self.scanner.savePersistentCache(scan_paths.items) catch |err| {
            std.debug.print("Failed to save scan cache: {}\n", .{err});
        };
        const refresh_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - refresh_begin_ns)) / 1_000_000.0;
        self.perf.recordRefreshMs(refresh_ms);
        try self.rebuildCardMetaCache();
    }

    pub fn loadScriptsFromPersistentCache(self: *AppState) !bool {
        var scan_paths = std.ArrayList(scanner.ScanPath).init(self.allocator);
        defer scan_paths.deinit();

        try scan_paths.ensureTotalCapacity(self.added_paths.items.len);
        for (self.added_paths.items) |entry| {
            scan_paths.appendAssumeCapacity(.{
                .path = entry.path,
                .is_directory = entry.is_directory,
            });
        }

        const loaded = try self.scanner.loadPersistentCache(scan_paths.items);
        if (loaded) {
            try self.rebuildCardMetaCache();
        }
        return loaded;
    }

    /// 打开新的脚本标签
    pub fn openScriptTab(self: *AppState, script_path: []const u8, script_name: []const u8) !void {
        // 检查是否已经打开
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.script_path) |path| {
                if (std.mem.eql(u8, path, script_path)) {
                    self.active_tab_index = i;
                    self.pending_tab_switch = i;
                    self.requestExtraFrames(3);
                    return;
                }
            }
        }

        // 创建新标签
        var new_tab = try Tab.init(self.allocator, .script, script_name, script_path);

        // 加载保存的配置（从缓存视图读取）
        if (self.config_manager.getScriptConfigView(script_path) catch null) |saved_config| {
            // 恢复描述
            const desc_len = @min(saved_config.description.len, 511);
            @memcpy(new_tab.description[0..desc_len], saved_config.description[0..desc_len]);
            new_tab.description[desc_len] = 0;

            // 恢复命令
            if (saved_config.command.len > 0) {
                const cmd_len = @min(saved_config.command.len, 511);
                @memcpy(new_tab.command[0..cmd_len], saved_config.command[0..cmd_len]);
                new_tab.command[cmd_len] = 0;
            }

            // 恢复参数
            new_tab.parameters.clearRetainingCapacity();
            for (saved_config.parameters) |param| {
                var new_param = ScriptParameter.init();
                const name_len = @min(param.name.len, 127);
                const value_len = @min(param.value.len, 255);
                @memcpy(new_param.name[0..name_len], param.name[0..name_len]);
                @memcpy(new_param.value[0..value_len], param.value[0..value_len]);
                new_param.name[name_len] = 0;
                new_param.value[value_len] = 0;
                try new_tab.parameters.append(new_param);
            }
        }

        try self.tabs.append(new_tab);
        const new_index = self.tabs.items.len - 1;
        self.active_tab_index = new_index;
        self.pending_tab_switch = new_index;
        self.requestExtraFrames(3);
    }

    /// 关闭标签
    pub fn closeTab(self: *AppState, index: usize) void {
        if (index == 0) return; // 不能关闭首页
        if (index >= self.tabs.items.len) return;

        var tab = self.tabs.orderedRemove(index);
        tab.deinit();

        // 关闭标签后固定返回首页
        self.active_tab_index = 0;
        self.pending_tab_switch = 0;

        // 请求额外渲染帧，确保标签切换立即生效
        self.requestExtraFrames(3);
    }

    /// 渲染标签栏
    pub fn renderTabBar(self: *AppState) void {
        // 消费 Cmd+数字 快捷键（由 GLFW key callback 设置）
        if (self.pending_shortcut_tab) |idx| {
            self.pending_shortcut_tab = null;
            if (idx < self.tabs.items.len) {
                self.active_tab_index = idx;
                self.pending_tab_switch = idx;
                self.requestExtraFrames(3);
            }
        }

        // 微调标签内边距和内部间距，让关闭按钮更贴近右侧
        zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 16.0, 18.0 } });
        zgui.pushStyleVar2f(.{ .idx = .item_inner_spacing, .v = [2]f32{ 8.0, 8.0 } });
        defer zgui.popStyleVar(.{ .count = 2 });

        // 增加标签文字大小
        zgui.setWindowFontScale(1.2);
        defer zgui.setWindowFontScale(1.0);

        if (zgui.beginTabBar("MainTabBar", .{})) {
            defer zgui.endTabBar();

            // 跟踪用户本帧点击了哪个非当前标签（ImGui 内部会排队切换到下一帧）
            var user_clicked_tab: ?usize = null;
            var tab_to_close: ?usize = null;

            for (self.tabs.items, 0..) |tab, i| {
                // 如果有待切换的标签，强制选中它
                const should_select = if (self.pending_tab_switch) |pending_idx|
                    i == pending_idx
                else
                    false;

                const flags: zgui.TabItemFlags = if (should_select)
                    .{ .set_selected = true }
                else
                    .{};

                var open = true;
                const can_close = tab.tab_type != .home; // 首页不能关闭

                // 创建以 null 结尾的标题字符串
                const title_z = tab.title;

                if (can_close) {
                    if (zgui.beginTabItem(title_z, .{ .p_open = &open, .flags = flags })) {
                        // 标签被选中，更新活动索引
                        self.active_tab_index = i;
                        zgui.endTabItem();
                    } else if (zgui.isItemClicked(.left)) {
                        // 点击了当前未选中的标签：ImGui 已将切换排队到下一帧，
                        // 记录下来以确保下一帧立即渲染
                        user_clicked_tab = i;
                    }
                    if (!open) {
                        tab_to_close = i;
                    }
                } else {
                    if (zgui.beginTabItem(title_z, .{ .flags = flags })) {
                        // 标签被选中，更新活动索引
                        self.active_tab_index = i;
                        zgui.endTabItem();
                    } else if (zgui.isItemClicked(.left)) {
                        user_clicked_tab = i;
                    }
                }
            }

            // 在循环外关闭标签，避免迭代时修改切片导致段错误
            if (tab_to_close) |idx| {
                self.closeTab(idx);
            }

            // 清除待切换标志；若用户点击了非当前标签，设置 pending_tab_switch
            // 使 needsImmediateRedraw() 返回 true，确保下一帧用 pollEvents() 立即渲染，
            // 避免 waitEvents() 阻塞导致标签切换内容出现可见延迟
            if (user_clicked_tab) |idx| {
                self.pending_tab_switch = idx;
                self.requestExtraFrames(3);
            } else {
                self.pending_tab_switch = null;
            }
        }
    }

    /// 渲染当前活动标签的内容
    pub fn renderActiveTab(self: *AppState) void {
        if (self.active_tab_index >= self.tabs.items.len) return;

        const active_tab = &self.tabs.items[self.active_tab_index];
        switch (active_tab.tab_type) {
            .home => home_page.render(self),
            .script => script_editor.render(self, active_tab),
        }

        renderRemoveScriptPopup(self);
        renderPerfWindow(self);
    }

    pub fn renderOverlays(self: *AppState) void {
        renderToast(self);
    }
};

// 公共 re-exports（供 execution_view 等组件使用）
pub const tailOutputView = text_utils.tailOutputView;
pub const copyTextToClipboard = text_utils.copyTextToClipboard;

fn renderRemoveScriptPopup(app_state: *AppState) void {
    if (app_state.pending_remove_path != null) {
        zgui.openPopup("Remove Script", .{});
    }

    if (zgui.beginPopupModal("Remove Script", .{ .flags = .{ .always_auto_resize = true, .no_resize = true, .no_saved_settings = true, .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
        defer zgui.endPopup();

        zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = [2]f32{ 28.0, 22.0 } });
        zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 16.0, 12.0 } });
        defer zgui.popStyleVar(.{ .count = 2 });

        const script_name = app_state.pending_remove_name orelse "this script";
        const button_height: f32 = 54.0;
        const cancel_width: f32 = 192.0;
        const remove_width: f32 = 212.0;

        const content_anchor = zgui.getCursorPos();
        zgui.dummy(.{ .w = 860.0, .h = 0.0 });
        zgui.setCursorPos(content_anchor);

        zgui.setWindowFontScale(1.38);
        zgui.text("Remove '{s}' from zScripts?", .{script_name});
        zgui.setWindowFontScale(1.0);
        zgui.dummy(.{ .w = 0.0, .h = 10.0 });

        zgui.setWindowFontScale(1.24);
        zgui.textColored(.{ 0.545, 0.522, 0.490, 1.0 }, "This only hides it in zScripts and keeps files unchanged.", .{});
        zgui.textColored(.{ 0.545, 0.522, 0.490, 1.0 }, "Click Remove again to confirm.", .{});
        zgui.setWindowFontScale(1.0);
        if (app_state.pending_remove_has_error) {
            zgui.dummy(.{ .w = 0.0, .h = 10.0 });
            const msg_len = std.mem.indexOfScalar(u8, &app_state.pending_remove_error, 0) orelse app_state.pending_remove_error.len;
            zgui.setWindowFontScale(1.18);
            zgui.textColored(.{ 0.90, 0.45, 0.45, 1.0 }, "{s}", .{app_state.pending_remove_error[0..msg_len]});
            zgui.setWindowFontScale(1.0);
        }
        zgui.dummy(.{ .w = 0.0, .h = 12.0 });
        zgui.separator();
        zgui.dummy(.{ .w = 0.0, .h = 12.0 });

        const row_start_x = zgui.getCursorPosX();
        const available_width = zgui.getContentRegionAvail()[0];

        if (zgui.button("Cancel", .{ .w = cancel_width, .h = button_height })) {
            app_state.clearPendingRemove();
            zgui.closeCurrentPopup();
            return;
        }

        zgui.sameLine(.{ .spacing = 0.0 });
        zgui.setCursorPosX(row_start_x + available_width - remove_width);
        zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.145, 0.137, 0.129, 1.0 } });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.235, 0.192, 0.196, 1.0 } });
        defer zgui.popStyleColor(.{ .count = 2 });

        if (zgui.button("Remove", .{ .w = remove_width, .h = button_height })) {
            if (app_state.pending_remove_path) |path| {
                app_state.removeScriptFromZscripts(path) catch |err| {
                    var msg_buf: [192]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "Remove failed: {s}", .{@errorName(err)}) catch "Remove failed";
                    app_state.setPendingRemoveError(msg);
                    return;
                };
            }
            app_state.showSuccessToast("Removed from zScripts");
            app_state.clearPendingRemove();
            zgui.closeCurrentPopup();
        }
    }
}

fn renderToast(app_state: *AppState) void {
    const now_ms = std.time.milliTimestamp();
    if (app_state.toast_until_ms <= now_ms or app_state.toast_message[0] == 0) return;

    const viewport = zgui.getMainViewport();
    const viewport_pos = viewport.getPos();
    const viewport_size = viewport.getSize();
    const text_len = std.mem.indexOfScalar(u8, &app_state.toast_message, 0) orelse app_state.toast_message.len;
    const toast_text = app_state.toast_message[0..text_len];

    const bg_color = switch (app_state.toast_kind) {
        .success => [4]f32{ 0.157, 0.165, 0.149, 0.98 },
        .failure => [4]f32{ 0.192, 0.149, 0.149, 0.98 },
        .info => [4]f32{ 0.165, 0.153, 0.137, 0.98 },
    };
    const border_color = switch (app_state.toast_kind) {
        .success => [4]f32{ 0.345, 0.384, 0.349, 1.0 },
        .failure => [4]f32{ 0.384, 0.302, 0.302, 1.0 },
        .info => [4]f32{ 0.345, 0.329, 0.306, 1.0 },
    };
    const text_color = switch (app_state.toast_kind) {
        .success => [4]f32{ 0.871, 0.851, 0.820, 1.0 },
        .failure => [4]f32{ 0.922, 0.839, 0.839, 1.0 },
        .info => [4]f32{ 0.890, 0.867, 0.827, 1.0 },
    };

    zgui.setNextWindowPos(.{
        .x = viewport_pos[0] + viewport_size[0] - 24.0,
        .y = viewport_pos[1] + 24.0,
        .cond = .always,
        .pivot_x = 1.0,
        .pivot_y = 0.0,
    });
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = bg_color });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = border_color });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = 10.0 });
    zgui.pushStyleVar1f(.{ .idx = .window_border_size, .v = 1.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = [2]f32{ 24.0, 16.0 } });
    defer zgui.popStyleColor(.{ .count = 2 });
    defer zgui.popStyleVar(.{ .count = 3 });

    const flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_saved_settings = true,
        .no_focus_on_appearing = true,
        .always_auto_resize = true,
    };

    if (zgui.begin("Toast", .{ .flags = flags })) {
        zgui.setWindowFontScale(1.3);
        zgui.textColored(text_color, "{s}", .{toast_text});
        zgui.setWindowFontScale(1.0);
    }
    zgui.end();
}

fn renderPerfWindow(app_state: *AppState) void {
    if (!app_state.perf.show_window) return;

    var open = app_state.perf.show_window;
    zgui.setNextWindowSize(.{ .w = 430, .h = 320 });
    zgui.setNextWindowPos(.{ .x = 60.0, .y = 80.0, .cond = .first_use_ever });
    if (zgui.begin("Performance", .{ .popen = &open })) {
        zgui.setWindowFontScale(1.15);
        defer zgui.setWindowFontScale(1.0);
        zgui.text("startup_ms: {d:.2}", .{app_state.perf.startup_ms});
        zgui.text("refresh_ms: {d:.2}", .{app_state.perf.last_refresh_ms});
        zgui.text("render_ms: {d:.2}", .{app_state.perf.last_render_ms});
        zgui.text("render_avg_ms: {d:.2}", .{app_state.perf.avg_render_ms});
        zgui.text("script_count: {d}", .{app_state.perf.script_count});
        zgui.text("output_bytes: {d}", .{app_state.perf.output_bytes});
        zgui.separator();
        zgui.text("perf_log: {s}", .{if (app_state.perf.enable_log) "ON" else "OFF"});
    }
    zgui.end();
    app_state.perf.show_window = open;
}
