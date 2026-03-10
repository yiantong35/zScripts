const std = @import("std");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const scanner = @import("../core/scanner.zig");
const script_mod = @import("../core/script.zig");
const file_picker = @import("../core/file_picker.zig");
const executor = @import("../core/executor.zig");
const perf_monitor = @import("../core/perf_monitor.zig");
const config = @import("../storage/config.zig");

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

const CardMeta = struct {
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
            saveAddedPaths(&app_state) catch {};
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

    fn showSuccessToast(self: *AppState, message: []const u8) void {
        self.showToast(.success, message);
    }

    fn showErrorToast(self: *AppState, message: []const u8) void {
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
            const meta = try buildCardMeta(self.allocator, &s, cfg);
            self.card_meta_cache.appendAssumeCapacity(meta);
        }
    }

    pub fn rebuildCardMetaForScript(self: *AppState, script_path: []const u8) !void {
        const scripts = self.scanner.getScripts();
        if (self.card_meta_cache.items.len != scripts.len) {
            try self.rebuildCardMetaCache();
            return;
        }

        for (scripts, 0..) |s, idx| {
            if (!std.mem.eql(u8, s.path, script_path)) continue;

            const cfg = try self.config_manager.getScriptConfigView(s.path);
            const new_meta = try buildCardMeta(self.allocator, &s, cfg);
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
            try saveAddedPaths(self);
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

        // 增加标签栏的内边距，让标签更大
        zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 20.0, 18.0 } });
        defer zgui.popStyleVar(.{ .count = 1 });

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
            .home => renderHomePage(self),
            .script => renderScriptPage(self, active_tab),
        }

        renderRemoveScriptPopup(self);
        renderPerfWindow(self);
    }

    pub fn renderOverlays(self: *AppState) void {
        renderToast(self);
    }
};

const TruncateTextResult = struct {
    text: []const u8,
    truncated: bool,
};

fn truncateText(input: []const u8, max_chars: usize, buffer: []u8) TruncateTextResult {
    if (input.len <= max_chars) {
        return .{ .text = input, .truncated = false };
    }

    if (max_chars <= 3 or buffer.len < max_chars) {
        const short_len = @min(@min(max_chars, input.len), buffer.len);
        @memcpy(buffer[0..short_len], input[0..short_len]);
        return .{ .text = buffer[0..short_len], .truncated = true };
    }

    const keep_len = max_chars - 3;
    @memcpy(buffer[0..keep_len], input[0..keep_len]);
    @memcpy(buffer[keep_len..max_chars], "...");
    return .{ .text = buffer[0..max_chars], .truncated = true };
}

fn showItemTooltip(text: []const u8) void {
    if (!zgui.isItemHovered(.{})) return;
    if (zgui.beginTooltip()) {
        zgui.textUnformatted(text);
        zgui.endTooltip();
    }
}

fn drawCenteredTextColored(text: []const u8, color: [4]f32) void {
    const avail_w = zgui.getContentRegionAvail()[0];
    const text_size = zgui.calcTextSize(text, .{});
    if (avail_w > text_size[0]) {
        zgui.setCursorPosX(zgui.getCursorPosX() + (avail_w - text_size[0]) * 0.5);
    }
    zgui.textColored(color, "{s}", .{text});
}

fn buildParamSummary(allocator: std.mem.Allocator, params: []const config.ParameterConfig, buffer: []u8) []const u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var unique_names = std.ArrayList([]const u8).init(allocator);
    defer unique_names.deinit();

    for (params) |param| {
        if (param.name.len == 0) continue;
        if (seen.contains(param.name)) continue;

        seen.put(param.name, {}) catch return "params";
        unique_names.append(param.name) catch return "params";
    }

    const unique_count = unique_names.items.len;
    if (unique_count == 0) return "";

    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();

    writer.print("{d} params", .{unique_count}) catch return "params";

    var shown: usize = 0;
    for (unique_names.items) |name| {
        if (shown >= 4) break;

        if (shown == 0) {
            writer.print(": {s}", .{name}) catch break;
        } else {
            writer.print(", {s}", .{name}) catch break;
        }
        shown += 1;
    }

    if (unique_count > shown) {
        writer.print(", +{d}", .{unique_count - shown}) catch {};
    }

    return stream.getWritten();
}

fn buildCommandPreview(command: []const u8, buffer: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, command, " ");
    if (trimmed.len == 0) return command;

    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();
    var changed = false;
    var first = true;

    var iter = std.mem.tokenizeScalar(u8, trimmed, ' ');
    while (iter.next()) |token| {
        if (!first) {
            writer.writeByte(' ') catch return if (changed) stream.getWritten() else command;
        }
        first = false;

        if (std.mem.indexOfScalar(u8, token, '/')) |_| {
            const basename = std.fs.path.basename(token);
            if (basename.len < token.len) {
                writer.print(".../{s}", .{basename}) catch return if (changed) stream.getWritten() else command;
                changed = true;
                continue;
            }
        }

        writer.writeAll(token) catch return if (changed) stream.getWritten() else command;
    }

    return if (changed) stream.getWritten() else command;
}

fn duplicateOptionalText(allocator: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    if (text) |value| {
        return try allocator.dupe(u8, value);
    }
    return null;
}

fn buildCardMeta(allocator: std.mem.Allocator, s: *const script_mod.Script, script_config: ?*const config.ScriptConfig) !CardMeta {
    var meta = CardMeta{
        .title_line = try allocator.dupe(u8, ""),
        .title_tooltip = null,
        .desc_line = try allocator.dupe(u8, ""),
        .desc_tooltip = null,
        .has_desc = false,
        .command_line = try allocator.dupe(u8, ""),
        .command_tooltip = null,
        .param_line = try allocator.dupe(u8, ""),
        .param_tooltip = null,
        .has_params = false,
        .allocator = allocator,
    };
    errdefer meta.deinit();

    var title_preview_buf: [96]u8 = undefined;
    const title_preview = truncateText(s.name, 32, &title_preview_buf);
    allocator.free(meta.title_line);
    meta.title_line = try allocator.dupe(u8, title_preview.text);
    meta.title_tooltip = try duplicateOptionalText(allocator, if (title_preview.truncated) s.name else null);

    var desc_text: []const u8 = "No description";
    if (script_config) |cfg| {
        if (cfg.description.len > 0) {
            desc_text = cfg.description;
            meta.has_desc = true;
        }
    }
    var desc_preview_buf: [120]u8 = undefined;
    const desc_preview = truncateText(desc_text, 52, &desc_preview_buf);
    allocator.free(meta.desc_line);
    meta.desc_line = try allocator.dupe(u8, desc_preview.text);
    meta.desc_tooltip = try duplicateOptionalText(allocator, if (desc_preview.truncated) desc_text else null);

    const cmd = if (script_config) |cfg| cfg.command else "";
    if (cmd.len > 0) {
        var cmd_source_buf: [220]u8 = undefined;
        const cmd_source = buildCommandPreview(cmd, &cmd_source_buf);
        var cmd_preview_buf: [180]u8 = undefined;
        const cmd_preview = truncateText(cmd_source, 46, &cmd_preview_buf);
        var cmd_display_buf: [200]u8 = undefined;
        const cmd_display = std.fmt.bufPrint(&cmd_display_buf, "$ {s}", .{cmd_preview.text}) catch cmd_preview.text;
        allocator.free(meta.command_line);
        meta.command_line = try allocator.dupe(u8, cmd_display);
        const has_cmd_tooltip = cmd_preview.truncated or !std.mem.eql(u8, cmd_source, cmd);
        meta.command_tooltip = try duplicateOptionalText(allocator, if (has_cmd_tooltip) cmd else null);
    } else {
        allocator.free(meta.command_line);
        meta.command_line = try allocator.dupe(u8, "No command");
        meta.command_tooltip = null;
    }

    var param_text: []const u8 = "No params";
    if (script_config) |cfg| {
        if (cfg.parameters.len > 0) {
            var param_summary_buf: [220]u8 = undefined;
            const param_summary = buildParamSummary(allocator, cfg.parameters, &param_summary_buf);
            if (param_summary.len > 0) {
                param_text = param_summary;
                meta.has_params = true;
            }
        }
    }
    var param_preview_buf: [120]u8 = undefined;
    const param_preview = truncateText(param_text, 88, &param_preview_buf);
    allocator.free(meta.param_line);
    meta.param_line = try allocator.dupe(u8, param_preview.text);
    meta.param_tooltip = try duplicateOptionalText(allocator, if (param_preview.truncated) param_text else null);

    return meta;
}

fn tailOutputView(text: []const u8, max_lines: usize, max_bytes: usize) []const u8 {
    if (text.len == 0) return text;

    const min_start = if (text.len > max_bytes) text.len - max_bytes else 0;
    var lines_seen: usize = 0;
    var i = text.len;
    while (i > min_start) {
        i -= 1;
        if (text[i] != '\n') continue;
        lines_seen += 1;
        if (lines_seen > max_lines) {
            return text[i + 1 ..];
        }
    }

    return text[min_start..];
}

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

/// 渲染首页
fn renderHomePage(app_state: *AppState) void {
    // 覆盖标签栏底部的线条
    const cursor_y = zgui.getCursorScreenPos()[1];
    const viewport_size = zgui.getMainViewport().getSize();
    const cover_draw_list = zgui.getWindowDrawList();
    const bg_color = zgui.colorConvertFloat4ToU32([4]f32{ 0.0, 0.0, 0.0, 1.0 });

    // 在内容区域顶部绘制覆盖矩形
    cover_draw_list.addRectFilled(.{
        .pmin = [2]f32{ 0, cursor_y - 5 },
        .pmax = [2]f32{ viewport_size[0], cursor_y + 5 },
        .col = bg_color,
    });

    // 工具栏 - 增加按钮高度和文字大小
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 20.0, 15.0 } });

    // 增加按钮文字大小
    zgui.setWindowFontScale(1.2);

    const button_width: f32 = 180;
    const button_height: f32 = 60;

    // 主按钮
    zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.145, 0.137, 0.129, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.188, 0.176, 0.165, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = [4]f32{ 0.227, 0.212, 0.196, 1.0 } });

    const add_scripts_button_pos = zgui.getCursorScreenPos();
    const button_clicked = zgui.button("Add Scripts", .{ .w = button_width, .h = button_height });

    zgui.popStyleColor(.{ .count = 3 });

    if (button_clicked) {
        zgui.openPopup("Select Type", .{});
        app_state.requestExtraFrames(2);
    }

    // 选择类型弹窗 - 固定在按钮下方
    zgui.setNextWindowPos(.{
        .x = add_scripts_button_pos[0],
        .y = add_scripts_button_pos[1] + button_height + 8.0,
        .cond = .appearing,
    });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 15.0, 12.0 } });
    if (zgui.beginPopup("Select Type", .{})) {
        defer zgui.endPopup();

        zgui.setWindowFontScale(1.15);
        defer zgui.setWindowFontScale(1.0);

        if (zgui.selectable("Select Folders", .{ .h = 40 })) {
            importPathsFromPicker(app_state, .directories, true);
        }

        if (zgui.selectable("Select Files", .{ .h = 40 })) {
            importPathsFromPicker(app_state, .files, false);
        }
    }
    zgui.popStyleVar(.{ .count = 1 });

    zgui.sameLine(.{});
    // 次按钮：中性灰色，避免和主按钮抢层级
    zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.145, 0.137, 0.129, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.188, 0.176, 0.165, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = [4]f32{ 0.227, 0.212, 0.196, 1.0 } });
    if (zgui.button("Refresh", .{ .w = button_width, .h = button_height })) {
        const refreshed = blk: {
            app_state.refreshScripts() catch |err| {
                var msg_buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Refresh failed: {s}", .{@errorName(err)}) catch "Refresh failed";
                app_state.showErrorToast(msg);
                break :blk false;
            };
            break :blk true;
        };
        if (refreshed) {
            app_state.current_page = 0;
            var toast_buf: [96]u8 = undefined;
            const toast_msg = std.fmt.bufPrint(&toast_buf, "Refreshed {d} scripts", .{app_state.scanner.getScripts().len}) catch "Refresh complete";
            app_state.showSuccessToast(toast_msg);
        }
    }
    zgui.popStyleColor(.{ .count = 3 });

    // 工具栏样式仅作用于顶部控件，避免影响卡片里的小按钮布局
    zgui.popStyleVar(.{ .count = 1 });
    zgui.setWindowFontScale(1.0);

    zgui.spacing();
    zgui.spacing();

    // 脚本卡片网格标题 + Perf 复选框同行
    const scripts = app_state.scanner.getScripts();
    const total_scripts = scripts.len;
    if (app_state.card_meta_cache.items.len != total_scripts) {
        app_state.rebuildCardMetaCache() catch {};
    }
    const has_card_meta = app_state.card_meta_cache.items.len == total_scripts;

    zgui.setWindowFontScale(1.3);
    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Scripts ({d})", .{total_scripts}) catch "Scripts";
    zgui.text("{s}", .{title});
    zgui.setWindowFontScale(1.0);

    // Perf 复选框放在 Scripts 标题同行靠右
    zgui.sameLine(.{});
    const label_perf_window_w = zgui.calcTextSize("Perf Window", .{})[0];
    const label_perf_log_w = zgui.calcTextSize("Perf Log", .{})[0];
    const checkbox_w: f32 = 20.0;
    const perf_gap: f32 = 8.0;
    const perf_group_width = checkbox_w + label_perf_window_w + perf_gap + checkbox_w + label_perf_log_w + 22.0;
    const perf_right_padding: f32 = 10.0;
    const perf_cursor_x = zgui.getCursorPosX();
    const perf_remain_w = zgui.getContentRegionAvail()[0];
    if (perf_remain_w > perf_group_width + perf_right_padding) {
        zgui.setCursorPosX(perf_cursor_x + perf_remain_w - perf_group_width - perf_right_padding);
    }
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 3.0, 3.0 } });
    _ = zgui.checkbox("Perf Window", .{ .v = &app_state.perf.show_window });
    zgui.sameLine(.{ .spacing = perf_gap });
    _ = zgui.checkbox("Perf Log", .{ .v = &app_state.perf.enable_log });
    zgui.popStyleVar(.{ .count = 1 });

    zgui.spacing();
    zgui.spacing();

    // 计算总页数，单页时隐藏分页栏
    const total_pages = if (total_scripts == 0) 1 else (total_scripts + app_state.scripts_per_page - 1) / app_state.scripts_per_page;
    if (app_state.current_page >= total_pages) {
        app_state.current_page = total_pages - 1;
    }
    const show_pagination = total_pages > 1;

    // 动态计算卡片布局 - 根据可用空间自适应
    const remaining_avail = zgui.getContentRegionAvail();
    const spacing: f32 = 20;
    const cols: usize = 4; // 4 列
    const rows: usize = 3; // 3 行

    // 计算卡片宽度和高度，填满整个可用空间
    const card_width = (remaining_avail[0] - spacing * @as(f32, @floatFromInt(cols + 1))) / @as(f32, @floatFromInt(cols));
    const pagination_height: f32 = if (show_pagination) 80 else 0;
    const card_height = (remaining_avail[1] - pagination_height - spacing * @as(f32, @floatFromInt(rows + 1))) / @as(f32, @floatFromInt(rows));

    // 计算分页
    const start_idx = app_state.current_page * app_state.scripts_per_page;
    const end_idx = @min(start_idx + app_state.scripts_per_page, total_scripts);
    const visible_count = end_idx - start_idx;

    if (visible_count == 0) {
        zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = [4]f32{ 0.090, 0.086, 0.082, 1.0 } });
        zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 8.0 });
        defer zgui.popStyleColor(.{ .count = 1 });
        defer zgui.popStyleVar(.{ .count = 1 });

        if (zgui.beginChild("EmptyState", .{ .w = -1, .h = 220 })) {
            zgui.dummy(.{ .w = 0, .h = 45 });
            zgui.setWindowFontScale(1.2);
            zgui.textColored(.{ 0.925, 0.914, 0.890, 1.0 }, "No scripts yet", .{});
            zgui.setWindowFontScale(1.0);
            zgui.spacing();
            zgui.textColored(.{ 0.655, 0.624, 0.584, 1.0 }, "Click Add Scripts to import your first script.", .{});
        }
        zgui.endChild();
    } else {
        // 脚本卡片 - 仅显示当前页真实脚本，不渲染空占位卡
        for (0..visible_count) |i| {
            const col = i % cols;

            if (col > 0) {
                zgui.sameLine(.{ .spacing = spacing });
            }

            const script_idx = start_idx + i;
            const s = scripts[script_idx];
            const card_meta = if (has_card_meta) &app_state.card_meta_cache.items[script_idx] else null;

            // 绘制卡片阴影
            const draw_list = zgui.getWindowDrawList();
            const cursor_pos = zgui.getCursorScreenPos();
            const shadow_offset: f32 = 4.0;
            const shadow_color = zgui.colorConvertFloat4ToU32([4]f32{ 0.0, 0.0, 0.0, 0.40 });

            draw_list.addRectFilled(.{
                .pmin = [2]f32{ cursor_pos[0] + shadow_offset, cursor_pos[1] + shadow_offset },
                .pmax = [2]f32{ cursor_pos[0] + card_width + shadow_offset, cursor_pos[1] + card_height + shadow_offset },
                .col = shadow_color,
                .rounding = 8.0,
            });

            // 卡片内容区域 - 检测悬停状态设置不同背景色
            var card_id_buf: [32:0]u8 = undefined;
            const card_id = std.fmt.bufPrintZ(&card_id_buf, "##card_{d}", .{script_idx}) catch "##card";

            // 先绘制卡片背景（悬停变色在下面处理）
            zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = [4]f32{ 0.090, 0.086, 0.082, 1.0 } });
            zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 8.0 });
            defer zgui.popStyleColor(.{ .count = 1 });
            defer zgui.popStyleVar(.{ .count = 1 });

            if (zgui.beginChild(card_id, .{ .w = card_width, .h = card_height })) {
                const win_pos = zgui.getWindowPos();
                const win_size = zgui.getWindowSize();
                const content_start = zgui.getCursorPos();
                const hit_size = zgui.getContentRegionAvail();

                var hit_id_buf: [40:0]u8 = undefined;
                const hit_id = std.fmt.bufPrintZ(&hit_id_buf, "##card_hit_{d}", .{script_idx}) catch "##card_hit";
                _ = zgui.invisibleButton(hit_id, .{ .w = hit_size[0], .h = hit_size[1] });
                const is_hovered = zgui.isItemHovered(.rect_only);
                const right_clicked = zgui.isItemClicked(.right);
                const left_double_clicked = is_hovered and zgui.isMouseDoubleClicked(.left);
                zgui.setCursorPos(content_start);

                // 悬停时绘制高亮背景
                if (is_hovered) {
                    const card_draw = zgui.getWindowDrawList();
                    const hover_color = zgui.colorConvertFloat4ToU32([4]f32{ 0.137, 0.129, 0.118, 1.0 });
                    card_draw.addRectFilled(.{
                        .pmin = win_pos,
                        .pmax = [2]f32{ win_pos[0] + win_size[0], win_pos[1] + win_size[1] },
                        .col = hover_color,
                        .rounding = 8.0,
                    });
                }

                // 右键菜单：基于整卡 hit-area，触摸板双指右键触发更稳定
                var popup_id_buf: [56:0]u8 = undefined;
                const popup_id = std.fmt.bufPrintZ(&popup_id_buf, "CardContext##ctx_{d}", .{script_idx}) catch "CardContext";
                if (right_clicked) {
                    const popup_x = win_pos[0] + @max(10.0, win_size[0] - 236.0);
                    const popup_y = win_pos[1] + @max(10.0, win_size[1] - 56.0);
                    zgui.setNextWindowPos(.{ .x = popup_x, .y = popup_y, .cond = .always });
                    zgui.openPopup(popup_id, .{});
                    app_state.requestExtraFrames(2);
                }
                if (zgui.beginPopup(popup_id, .{})) {
                    defer zgui.endPopup();
                    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 14.0, 10.0 } });
                    zgui.setWindowFontScale(1.18);
                    defer zgui.popStyleVar(.{ .count = 1 });
                    defer zgui.setWindowFontScale(1.0);

                    if (zgui.selectable("Remove from zScripts", .{ .h = 40 })) {
                        app_state.requestRemoveScript(s.path, s.name) catch {};
                    }
                }

                // 卡片信息区：整体居中显示
                const content_top = @max(18.0, card_height * 0.16);
                const content_bottom_margin = @max(14.0, card_height * 0.08);
                const row_step = @max(26.0, (card_height - content_top - content_bottom_margin) / 3.0);

                // === 脚本名称（单行，固定第1行） ===
                zgui.setCursorPosY(content_top);
                zgui.setWindowFontScale(1.38);
                drawCenteredTextColored(if (card_meta) |meta| meta.title_line else s.name, [4]f32{ 0.925, 0.914, 0.890, 1.0 });
                if (card_meta) |meta| {
                    if (meta.title_tooltip) |tooltip_text| {
                        showItemTooltip(tooltip_text);
                    }
                }
                zgui.setWindowFontScale(1.0);

                // === 描述（单行，固定第2行） ===
                zgui.setCursorPosY(content_top + row_step);
                zgui.setWindowFontScale(1.16);
                if (card_meta) |meta| {
                    drawCenteredTextColored(meta.desc_line, if (meta.has_desc) [4]f32{ 0.655, 0.624, 0.584, 1.0 } else [4]f32{ 0.545, 0.522, 0.490, 1.0 });
                    if (meta.desc_tooltip) |tooltip_text| {
                        showItemTooltip(tooltip_text);
                    }
                } else {
                    drawCenteredTextColored("No description", [4]f32{ 0.545, 0.522, 0.490, 1.0 });
                }
                zgui.setWindowFontScale(1.0);

                // === 执行命令（单行，固定第3行） ===
                zgui.setCursorPosY(content_top + row_step * 2.0);
                zgui.setWindowFontScale(1.08);
                if (card_meta) |meta| {
                    drawCenteredTextColored(meta.command_line, [4]f32{ 0.545, 0.522, 0.490, 1.0 });
                    if (meta.command_tooltip) |tooltip_text| {
                        showItemTooltip(tooltip_text);
                    }
                } else {
                    drawCenteredTextColored("$", [4]f32{ 0.545, 0.522, 0.490, 1.0 });
                }
                zgui.setWindowFontScale(1.0);

                // === 参数摘要（单行，固定第4行） ===
                zgui.setCursorPosY(content_top + row_step * 3.0);
                zgui.setWindowFontScale(1.12);
                if (card_meta) |meta| {
                    drawCenteredTextColored(meta.param_line, if (meta.has_params) [4]f32{ 0.541, 0.659, 0.745, 1.0 } else [4]f32{ 0.545, 0.522, 0.490, 1.0 });
                    if (meta.param_tooltip) |tooltip_text| {
                        showItemTooltip(tooltip_text);
                    }
                } else {
                    drawCenteredTextColored("No params", [4]f32{ 0.545, 0.522, 0.490, 1.0 });
                }
                zgui.setWindowFontScale(1.0);

                if (left_double_clicked) {
                    app_state.openScriptTab(s.path, s.name) catch {};
                }
            }
            zgui.endChild();
        }
    }

    if (show_pagination) {
        zgui.spacing();
        zgui.spacing();

        // 分页控件 - 水平和垂直居中显示
        const pagination_button_height: f32 = 60;
        const text_width: f32 = 250; // 预估文字宽度
        const pagination_spacing: f32 = 20;
        const total_pagination_width = button_width * 2 + text_width + pagination_spacing * 2;
        const current_page_display = app_state.current_page + 1; // 显示从1开始

        // 获取剩余可用空间
        const remaining_space = zgui.getContentRegionAvail();

        // 垂直居中 - 添加垂直偏移
        const vertical_offset = (remaining_space[1] - pagination_button_height) / 2.0;
        if (vertical_offset > 0) {
            zgui.dummy(.{ .w = 0, .h = vertical_offset });
        }

        // 水平居中
        const pagination_offset = (remaining_space[0] - total_pagination_width) / 2.0;
        if (pagination_offset > 0) {
            zgui.setCursorPosX(zgui.getCursorPosX() + pagination_offset);
        }

        // 按钮样式 - 使用全局强调色，增加文字大小
        zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 20.0, 15.0 } });
        zgui.setWindowFontScale(1.2);
        defer zgui.popStyleVar(.{ .count = 1 });
        defer zgui.setWindowFontScale(1.0);

        // 上一页按钮
        const can_prev = app_state.current_page > 0;
        if (!can_prev) {
            zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.10, 0.10, 0.10, 1.0 } });
            zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.10, 0.10, 0.10, 1.0 } });
            defer zgui.popStyleColor(.{ .count = 2 });
        }
        if (zgui.button("Previous", .{ .w = button_width, .h = pagination_button_height }) and can_prev) {
            app_state.current_page -= 1;
        }
        zgui.sameLine(.{ .spacing = pagination_spacing });

        // 页码显示
        zgui.setWindowFontScale(1.4);
        var page_buf: [32]u8 = undefined;
        const page_text = std.fmt.bufPrint(&page_buf, "Page {d} / {d}", .{ current_page_display, total_pages }) catch "Page 1";
        zgui.text("{s}", .{page_text});
        zgui.setWindowFontScale(1.2); // 恢复到按钮字体大小

        zgui.sameLine(.{ .spacing = pagination_spacing });

        // 下一页按钮
        const can_next = app_state.current_page + 1 < total_pages;
        if (!can_next) {
            zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.10, 0.10, 0.10, 1.0 } });
            zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.10, 0.10, 0.10, 1.0 } });
            defer zgui.popStyleColor(.{ .count = 2 });
        }
        if (zgui.button("Next", .{ .w = button_width, .h = pagination_button_height }) and can_next) {
            app_state.current_page += 1;
        }
    }
}

fn copyTextToClipboard(allocator: std.mem.Allocator, text: []const u8) bool {
    if (text.len == 0) return false;
    const window = zglfw.getCurrentContext() orelse return false;
    const text_z = std.fmt.allocPrintZ(allocator, "{s}", .{text}) catch return false;
    defer allocator.free(text_z);
    zglfw.setClipboardString(window, text_z);
    return true;
}

fn importPathsFromPicker(app_state: *AppState, picker_type: file_picker.PickerType, is_directory: bool) void {
    const picker_result_opt = file_picker.showFilePicker(app_state.allocator, picker_type) catch |err| {
        var msg_buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Import failed: {s}", .{@errorName(err)}) catch "Import failed";
        app_state.showErrorToast(msg);
        return;
    };
    if (picker_result_opt) |result| {
        var picker_result = result;
        defer picker_result.deinit();

        const scripts_before = app_state.scanner.getScripts().len;
        var added_paths_count: usize = 0;
        for (picker_result.paths) |path| {
            const added = app_state.addPathIfMissing(path, is_directory) catch |err| {
                var msg_buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Import failed: {s}", .{@errorName(err)}) catch "Import failed";
                app_state.showErrorToast(msg);
                return;
            };
            if (added) added_paths_count += 1;
        }

        if (added_paths_count == 0) return;

        app_state.refreshScripts() catch |err| {
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Refresh failed: {s}", .{@errorName(err)}) catch "Refresh failed";
            app_state.showErrorToast(msg);
            return;
        };
        app_state.current_page = 0;
        saveAddedPaths(app_state) catch |err| {
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Save paths failed: {s}", .{@errorName(err)}) catch "Save paths failed";
            app_state.showErrorToast(msg);
            return;
        };

        const scripts_after = app_state.scanner.getScripts().len;
        const imported_scripts = if (scripts_after > scripts_before) scripts_after - scripts_before else 0;
        var success_buf: [96]u8 = undefined;
        const success_msg = if (imported_scripts > 0)
            std.fmt.bufPrint(&success_buf, "Imported {d} scripts", .{imported_scripts}) catch "Import complete"
        else
            std.fmt.bufPrint(&success_buf, "Imported {d} paths", .{added_paths_count}) catch "Import complete";
        app_state.showSuccessToast(success_msg);
    }
}

fn executeScriptFromTab(app_state: *AppState, tab: *Tab) bool {
    if (tab.script_path) |path| {
        saveTabConfig(app_state, tab) catch |err| {
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Save failed: {s}", .{@errorName(err)}) catch "Save failed";
            app_state.showErrorToast(msg);
            return false;
        };

        const script_name = std.fs.path.basename(path);
        const cmd_len = std.mem.indexOfScalar(u8, &tab.command, 0) orelse tab.command.len;
        const command = tab.command[0..cmd_len];

        var script = script_mod.Script.init(tab.allocator, path, script_name, command) catch |err| {
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Prepare failed: {s}", .{@errorName(err)}) catch "Prepare failed";
            app_state.showErrorToast(msg);
            return false;
        };
        defer script.deinit();

        for (tab.parameters.items) |param| {
            const name_len = std.mem.indexOfScalar(u8, &param.name, 0) orelse param.name.len;
            const value_len = std.mem.indexOfScalar(u8, &param.value, 0) orelse param.value.len;
            if (name_len > 0) {
                script.addArg(param.name[0..name_len], param.value[0..value_len]) catch {};
            }
        }

        if (tab.script_executor) |*exec| {
            var mut_exec = exec.*;
            const started = blk: {
                mut_exec.execute(&script) catch |err| {
                    var msg_buf: [256]u8 = undefined;
                    const msg = switch (err) {
                        error.MissingCommand => "Python script requires command, e.g. uv run or python3",
                        error.UnterminatedSingleQuote,
                        error.UnterminatedDoubleQuote,
                        error.TrailingEscape,
                        => std.fmt.bufPrint(&msg_buf, "Invalid command syntax: {s}", .{@errorName(err)}) catch "Invalid command syntax",
                        else => std.fmt.bufPrint(&msg_buf, "Execution error: {s}", .{@errorName(err)}) catch "Execution error",
                    };
                    mut_exec.setStartError(msg);
                    break :blk false;
                };
                break :blk true;
            };
            tab.script_executor = mut_exec;
            return started;
        }
    }
    return false;
}

/// 渲染脚本标签页
fn renderScriptPage(app_state: *AppState, tab: *Tab) void {
    const detail_font_scale: f32 = 1.22;
    const cursor_y = zgui.getCursorScreenPos()[1];
    const viewport_size = zgui.getMainViewport().getSize();
    const cover_draw_list = zgui.getWindowDrawList();
    const bg_color = zgui.colorConvertFloat4ToU32([4]f32{ 0.14, 0.14, 0.16, 1.0 });

    cover_draw_list.addRectFilled(.{
        .pmin = [2]f32{ 0, cursor_y - 5 },
        .pmax = [2]f32{ viewport_size[0], cursor_y + 5 },
        .col = bg_color,
    });

    if (tab.script_executor) |*exec| {
        var mut_exec = exec.*;
        if (mut_exec.isRunning()) {
            mut_exec.poll() catch |err| {
                std.debug.print("Poll error: {}\n", .{err});
            };
            tab.script_executor = mut_exec;
        }
    }

    const avail = zgui.getContentRegionAvail();
    const control_ratio: f32 = 0.42;
    const min_control_h: f32 = 250.0;
    const min_output_h: f32 = 220.0;
    var control_height = avail[1] * control_ratio;
    if (avail[1] >= min_control_h + min_output_h) {
        control_height = @max(min_control_h, @min(control_height, avail[1] - min_output_h));
    } else {
        control_height = avail[1] * 0.5;
    }
    const output_height = @max(0.0, avail[1] - control_height);

    if (zgui.beginChild("ControlPanel", .{ .w = -1, .h = control_height })) {
        const panel_avail = zgui.getContentRegionAvail();
        var right_width = @max(280.0, panel_avail[0] * 0.28);
        if (right_width > panel_avail[0] - 260.0) {
            right_width = @max(220.0, panel_avail[0] * 0.34);
        }
        const left_width = @max(220.0, panel_avail[0] - right_width - 16.0);

        if (zgui.beginChild("ControlLeft", .{ .w = left_width, .h = -1 })) {
            zgui.spacing();

            zgui.setWindowFontScale(1.58);
            zgui.textColored(.{ 0.925, 0.914, 0.890, 1.0 }, "Script: {s}", .{tab.title});
            zgui.setWindowFontScale(1.0);
            zgui.dummy(.{ .w = 0.0, .h = 10.0 });

            const card_bg = [4]f32{ 0.067, 0.067, 0.071, 1.0 };
            const card_border = [4]f32{ 0.165, 0.149, 0.129, 1.0 };
            const header_bg = [4]f32{ 0.118, 0.106, 0.094, 1.0 };
            const header_text = [4]f32{ 0.925, 0.890, 0.824, 1.0 };

            zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = card_bg });
            zgui.pushStyleColor4f(.{ .idx = .border, .c = card_border });
            zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = [4]f32{ 0.082, 0.078, 0.075, 1.0 } });
            zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = [4]f32{ 0.102, 0.094, 0.086, 1.0 } });
            zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = [4]f32{ 0.118, 0.106, 0.094, 1.0 } });
            zgui.pushStyleVar1f(.{ .idx = .child_border_size, .v = 1.0 });
            zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 8.0 });
            defer zgui.popStyleVar(.{ .count = 2 });
            defer zgui.popStyleColor(.{ .count = 5 });

            if (zgui.beginChild("DescSection", .{ .w = -1, .h = 100.0 })) {
                zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = header_bg });
                if (zgui.beginChild("DescHeader", .{ .w = -1, .h = 40.0 })) {
                    zgui.setCursorPosY(zgui.getCursorPosY() + 8.0);
                    zgui.setWindowFontScale(detail_font_scale);
                    zgui.textColored(header_text, "Description", .{});
                    zgui.setWindowFontScale(1.0);
                }
                zgui.endChild();
                zgui.popStyleColor(.{ .count = 1 });

                zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 14.0, 12.0 } });
                zgui.setWindowFontScale(detail_font_scale);
                zgui.setNextItemWidth(-1);
                _ = zgui.inputText("##description", .{ .buf = tab.description[0..511 :0] });
                zgui.setWindowFontScale(1.0);
                zgui.popStyleVar(.{ .count = 1 });
            }
            zgui.endChild();

            zgui.dummy(.{ .w = 0.0, .h = 6.0 });
            if (zgui.beginChild("CmdSection", .{ .w = -1, .h = 100.0 })) {
                zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = header_bg });
                if (zgui.beginChild("CmdHeader", .{ .w = -1, .h = 40.0 })) {
                    zgui.setCursorPosY(zgui.getCursorPosY() + 8.0);
                    zgui.setWindowFontScale(detail_font_scale);
                    zgui.textColored(header_text, "Command", .{});
                    zgui.setWindowFontScale(1.0);
                }
                zgui.endChild();
                zgui.popStyleColor(.{ .count = 1 });

                zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 14.0, 12.0 } });
                zgui.setWindowFontScale(detail_font_scale);
                zgui.setNextItemWidth(-1);
                _ = zgui.inputText("##command", .{ .buf = tab.command[0..511 :0] });
                zgui.setWindowFontScale(1.0);
                zgui.popStyleVar(.{ .count = 1 });
            }
            zgui.endChild();

            zgui.dummy(.{ .w = 0.0, .h = 6.0 });
            const remaining_h = zgui.getContentRegionAvail()[1];
            if (zgui.beginChild("ParamSection", .{ .w = -1, .h = @max(120.0, remaining_h) })) {
                zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = header_bg });
                if (zgui.beginChild("ParamHeader", .{ .w = -1, .h = 44.0 })) {
                    const header_width = zgui.getContentRegionAvail()[0];
                    zgui.setCursorPosY(zgui.getCursorPosY() + 8.0);
                    zgui.setWindowFontScale(detail_font_scale);
                    zgui.textColored(header_text, "Parameters", .{});
                    zgui.setWindowFontScale(1.0);
                    zgui.sameLine(.{ .spacing = 8.0 });
                    zgui.setCursorPosX(@max(0.0, header_width - 96.0));
                    zgui.setWindowFontScale(detail_font_scale);
                    if (zgui.button("+ Add", .{ .w = 90, .h = 30 })) {
                        tab.parameters.append(ScriptParameter.init()) catch {};
                    }
                    zgui.setWindowFontScale(1.0);
                }
                zgui.endChild();
                zgui.popStyleColor(.{ .count = 1 });

                zgui.spacing();
                const param_list_height = @max(74.0, zgui.getContentRegionAvail()[1] - 8.0);
                if (zgui.beginChild("ParamList", .{ .w = -1, .h = param_list_height })) {
                    const row_width = zgui.getContentRegionAvail()[0];
                    const name_width = row_width * 0.30;
                    const value_width = row_width * 0.58;
                    const remove_width = @max(36.0, row_width - name_width - value_width - 20.0);

                    zgui.setWindowFontScale(detail_font_scale);
                    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 10.0, 8.0 } });
                    defer zgui.popStyleVar(.{ .count = 1 });
                    zgui.textDisabled("Name", .{});
                    zgui.sameLine(.{ .spacing = 8.0 });
                    zgui.setCursorPosX(zgui.getCursorPosX() + name_width + 4.0);
                    zgui.textDisabled("Value", .{});
                    zgui.spacing();

                    var i: usize = 0;
                    var to_remove: ?usize = null;
                    while (i < tab.parameters.items.len) : (i += 1) {
                        var param = &tab.parameters.items[i];

                        var name_id_buf: [40:0]u8 = undefined;
                        const name_id = std.fmt.bufPrintZ(&name_id_buf, "##pname{d}", .{i}) catch "##pname";
                        zgui.setNextItemWidth(name_width);
                        _ = zgui.inputText(name_id, .{ .buf = param.name[0..127 :0] });

                        zgui.sameLine(.{ .spacing = 8.0 });
                        var value_id_buf: [40:0]u8 = undefined;
                        const value_id = std.fmt.bufPrintZ(&value_id_buf, "##pval{d}", .{i}) catch "##pval";
                        zgui.setNextItemWidth(value_width);
                        _ = zgui.inputText(value_id, .{ .buf = param.value[0..255 :0] });

                        zgui.sameLine(.{ .spacing = 8.0 });
                        var remove_id_buf: [40:0]u8 = undefined;
                        const remove_id = std.fmt.bufPrintZ(&remove_id_buf, "X##prm{d}", .{i}) catch "X##prm";
                        zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.145, 0.137, 0.129, 1.0 } });
                        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.235, 0.192, 0.196, 1.0 } });
                        if (zgui.button(remove_id, .{ .w = remove_width, .h = 38 })) {
                            to_remove = i;
                        }
                        zgui.popStyleColor(.{ .count = 2 });

                        zgui.spacing();
                    }
                    zgui.setWindowFontScale(1.0);

                    if (to_remove) |idx| {
                        _ = tab.parameters.orderedRemove(idx);
                    }
                }
                zgui.endChild();
            }
            zgui.endChild();
        }
        zgui.endChild();

        zgui.sameLine(.{ .spacing = 16.0 });
        if (zgui.beginChild("ControlRight", .{ .w = -1, .h = -1 })) {
            const is_running = if (tab.script_executor) |*exec| exec.isRunning() else false;
            const col_gap: f32 = 12.0;
            const row_gap: f32 = 28.0;
            const btn_height: f32 = 58.0;
            const width = zgui.getContentRegionAvail()[0];
            const btn_width = @max(90.0, (width - col_gap) * 0.5);
            const layout_height = btn_height * 2.0 + row_gap;
            const vertical_pad = @max(0.0, (zgui.getContentRegionAvail()[1] - layout_height) * 0.5);

            if (vertical_pad > 0) {
                zgui.dummy(.{ .w = 0, .h = vertical_pad });
            }
            zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 10.0, 10.0 } });
            zgui.setWindowFontScale(detail_font_scale);
            defer zgui.popStyleVar(.{ .count = 1 });
            defer zgui.setWindowFontScale(1.0);

            zgui.beginDisabled(.{ .disabled = is_running });
            zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.145, 0.137, 0.129, 1.0 } });
            zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.220, 0.247, 0.220, 1.0 } });
            if (zgui.button("Run", .{ .w = btn_width, .h = btn_height })) {
                if (executeScriptFromTab(app_state, tab)) {
                    app_state.showSuccessToast("Execution started");
                }
            }
            zgui.popStyleColor(.{ .count = 2 });
            zgui.endDisabled();

            zgui.sameLine(.{ .spacing = col_gap });
            zgui.beginDisabled(.{ .disabled = !is_running });
            zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.145, 0.137, 0.129, 1.0 } });
            zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.188, 0.176, 0.165, 1.0 } });
            if (zgui.button("Stop", .{ .w = btn_width, .h = btn_height })) {
                if (tab.script_executor) |*exec| {
                    var mut_exec = exec.*;
                    mut_exec.stop();
                    tab.script_executor = mut_exec;
                    app_state.showSuccessToast("Execution stopped");
                }
            }
            zgui.popStyleColor(.{ .count = 2 });
            zgui.endDisabled();

            zgui.dummy(.{ .w = 0, .h = row_gap });

            zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.145, 0.137, 0.129, 1.0 } });
            zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.212, 0.224, 0.239, 1.0 } });
            if (zgui.button("Save", .{ .w = btn_width, .h = btn_height })) {
                const saved = blk: {
                    saveTabConfig(app_state, tab) catch |err| {
                        var msg_buf: [160]u8 = undefined;
                        const msg = std.fmt.bufPrint(&msg_buf, "Save failed: {s}", .{@errorName(err)}) catch "Save failed";
                        app_state.showErrorToast(msg);
                        break :blk false;
                    };
                    break :blk true;
                };
                if (saved) {
                    app_state.showSuccessToast("Saved");
                }
            }
            zgui.popStyleColor(.{ .count = 2 });

            zgui.sameLine(.{ .spacing = col_gap });
            zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.145, 0.137, 0.129, 1.0 } });
            zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.235, 0.192, 0.196, 1.0 } });
            if (zgui.button("Remove", .{ .w = btn_width, .h = btn_height })) {
                if (tab.script_path) |path| {
                    app_state.requestRemoveScript(path, tab.title) catch {};
                }
            }
            zgui.popStyleColor(.{ .count = 2 });
        }
        zgui.endChild();
    }
    zgui.endChild();

    zgui.setWindowFontScale(detail_font_scale);
    zgui.text("Output:", .{});
    zgui.setWindowFontScale(detail_font_scale);
    zgui.sameLine(.{ .spacing = 12.0 });

    const output_slice = if (tab.script_executor) |*exec| exec.getOutput() else "";
    const output_view = if (tab.show_full_output)
        output_slice
    else
        tailOutputView(output_slice, 300, 64 * 1024);

    if (zgui.button(if (tab.show_full_output) "Show Tail" else "Show Full", .{ .w = 136, .h = 38 })) {
        tab.show_full_output = !tab.show_full_output;
    }
    zgui.sameLine(.{ .spacing = 8.0 });
    if (zgui.button("Clear", .{ .w = 96, .h = 38 })) {
        if (tab.script_executor) |*exec| {
            var mut_exec = exec.*;
            mut_exec.clearOutput();
            tab.script_executor = mut_exec;
        }
    }
    zgui.sameLine(.{ .spacing = 8.0 });
    if (zgui.button("Copy", .{ .w = 96, .h = 38 })) {
        _ = copyTextToClipboard(app_state.allocator, output_view);
    }
    zgui.sameLine(.{ .spacing = 10.0 });
    _ = zgui.checkbox("Auto-scroll", .{ .v = &tab.output_auto_scroll });
    zgui.setWindowFontScale(1.0);
    zgui.spacing();

    if (zgui.beginChild("OutputPanel", .{ .w = -1, .h = output_height - 56.0 })) {
        zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = [4]f32{ 0.055, 0.052, 0.049, 1.0 } });
        defer zgui.popStyleColor(.{ .count = 1 });

        zgui.spacing();
        zgui.indent(.{ .indent_w = 10 });
        defer zgui.unindent(.{ .indent_w = 10 });

        if (output_view.len > 0) {
            zgui.setWindowFontScale(detail_font_scale);
            zgui.textUnformatted(output_view);
            zgui.setWindowFontScale(1.0);
            if (tab.output_auto_scroll) {
                zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
            }
            if (!tab.show_full_output and output_view.len < output_slice.len) {
                zgui.spacing();
                zgui.setWindowFontScale(detail_font_scale);
                zgui.textColored(.{ 0.545, 0.522, 0.490, 1.0 }, "... truncated, switch to Show Full for complete output", .{});
                zgui.setWindowFontScale(1.0);
            }
        } else {
            zgui.setWindowFontScale(detail_font_scale);
            zgui.textColored(.{ 0.655, 0.624, 0.584, 1.0 }, "Waiting for execution...", .{});
            zgui.setWindowFontScale(1.0);
        }
    }
    zgui.endChild();
}

/// 保存标签页配置
fn saveTabConfig(app_state: *AppState, tab: *Tab) !void {
    if (tab.script_path) |path| {
        // 获取描述
        const desc_len = std.mem.indexOfScalar(u8, &tab.description, 0) orelse tab.description.len;
        const description = tab.description[0..desc_len];

        // 获取命令
        const cmd_len = std.mem.indexOfScalar(u8, &tab.command, 0) orelse tab.command.len;
        const command = tab.command[0..cmd_len];

        // 构建参数列表
        var params = std.ArrayList(config.ParameterConfig).init(app_state.allocator);
        defer params.deinit();

        for (tab.parameters.items) |*param| {
            const name_len = std.mem.indexOfScalar(u8, &param.name, 0) orelse param.name.len;
            const value_len = std.mem.indexOfScalar(u8, &param.value, 0) orelse param.value.len;

            // 只保存有名称的参数
            if (name_len > 0) {
                params.append(.{
                    .name = param.name[0..name_len],
                    .value = param.value[0..value_len],
                }) catch continue;
            }
        }

        // 保存配置
        try app_state.config_manager.saveScriptConfig(path, description, command, params.items);
        try app_state.rebuildCardMetaForScript(path);
    }
}

/// 保存添加的路径列表
fn saveAddedPaths(app_state: *AppState) !void {
    var paths = std.ArrayList(config.PathConfig).init(app_state.allocator);
    defer paths.deinit();

    for (app_state.added_paths.items) |entry| {
        paths.append(.{
            .path = entry.path,
            .is_directory = entry.is_directory,
        }) catch continue;
    }

    try app_state.config_manager.savePaths(paths.items);
}
