const std = @import("std");

const CONFIG_DIR = ".zscripts";
const PERF_LOG_FILE = "perf.jsonl";
const LOG_INTERVAL_MS: i64 = 1000;
const RENDER_HISTORY_CAPACITY: usize = 120;

pub const PerfMonitor = struct {
    allocator: std.mem.Allocator,
    show_window: bool,
    enable_log: bool,
    startup_ms: f64,
    last_refresh_ms: f64,
    last_render_ms: f64,
    avg_render_ms: f64,
    script_count: usize,
    output_bytes: usize,
    render_history: [RENDER_HISTORY_CAPACITY]f64,
    render_history_count: usize,
    render_history_index: usize,
    last_log_ms: i64,
    log_file_path: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) !PerfMonitor {
        var log_file_path: ?[]const u8 = null;

        if (std.posix.getenv("HOME")) |home| {
            const config_dir = try std.fs.path.join(allocator, &[_][]const u8{ home, CONFIG_DIR });
            defer allocator.free(config_dir);
            std.fs.makeDirAbsolute(config_dir) catch {};
            log_file_path = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, PERF_LOG_FILE });
        }

        return .{
            .allocator = allocator,
            .show_window = false,
            .enable_log = false,
            .startup_ms = 0.0,
            .last_refresh_ms = 0.0,
            .last_render_ms = 0.0,
            .avg_render_ms = 0.0,
            .script_count = 0,
            .output_bytes = 0,
            .render_history = std.mem.zeroes([RENDER_HISTORY_CAPACITY]f64),
            .render_history_count = 0,
            .render_history_index = 0,
            .last_log_ms = 0,
            .log_file_path = log_file_path,
        };
    }

    pub fn deinit(self: *PerfMonitor) void {
        if (self.log_file_path) |path| {
            self.allocator.free(path);
        }
    }

    pub fn isEnabled(self: *const PerfMonitor) bool {
        return self.show_window or self.enable_log;
    }

    pub fn setStartupMs(self: *PerfMonitor, startup_ms: f64) void {
        self.startup_ms = startup_ms;
    }

    pub fn recordRefreshMs(self: *PerfMonitor, refresh_ms: f64) void {
        self.last_refresh_ms = refresh_ms;
    }

    pub fn recordRenderMs(self: *PerfMonitor, render_ms: f64) void {
        self.last_render_ms = render_ms;
        self.render_history[self.render_history_index] = render_ms;
        self.render_history_index = (self.render_history_index + 1) % RENDER_HISTORY_CAPACITY;
        if (self.render_history_count < RENDER_HISTORY_CAPACITY) {
            self.render_history_count += 1;
        }

        var sum: f64 = 0.0;
        for (self.render_history[0..self.render_history_count]) |value| {
            sum += value;
        }
        if (self.render_history_count > 0) {
            self.avg_render_ms = sum / @as(f64, @floatFromInt(self.render_history_count));
        } else {
            self.avg_render_ms = 0.0;
        }
    }

    pub fn updateSnapshot(self: *PerfMonitor, script_count: usize, output_bytes: usize) void {
        self.script_count = script_count;
        self.output_bytes = output_bytes;
    }

    pub fn needsTick(self: *const PerfMonitor) bool {
        return self.enable_log;
    }

    pub fn flushLogIfNeeded(self: *PerfMonitor) !void {
        if (!self.enable_log) return;
        const path = self.log_file_path orelse return;

        const now_ms = std.time.milliTimestamp();
        if (self.last_log_ms != 0 and now_ms - self.last_log_ms < LOG_INTERVAL_MS) {
            return;
        }
        self.last_log_ms = now_ms;

        var file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.createFileAbsolute(path, .{}),
            else => return err,
        };
        defer file.close();
        try file.seekFromEnd(0);

        const entry = .{
            .timestamp_ms = now_ms,
            .startup_ms = self.startup_ms,
            .refresh_ms = self.last_refresh_ms,
            .render_ms = self.last_render_ms,
            .render_avg_ms = self.avg_render_ms,
            .script_count = self.script_count,
            .output_bytes = self.output_bytes,
        };

        try std.json.stringify(entry, .{}, file.writer());
        try file.writer().writeByte('\n');
    }
};
