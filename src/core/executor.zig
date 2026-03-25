const std = @import("std");
const script_mod = @import("script.zig");
const max_output_bytes: usize = 2 * 1024 * 1024;
const active_poll_grace_ms: i64 = 700;
const CommandParseError = error{
    UnterminatedSingleQuote,
    UnterminatedDoubleQuote,
    TrailingEscape,
};

const ParsedCommand = struct {
    allocator: std.mem.Allocator,
    tokens: std.ArrayList([]u8),

    fn init(allocator: std.mem.Allocator) ParsedCommand {
        return .{
            .allocator = allocator,
            .tokens = std.ArrayList([]u8).init(allocator),
        };
    }

    fn deinit(self: *ParsedCommand) void {
        for (self.tokens.items) |token| {
            self.allocator.free(token);
        }
        self.tokens.deinit();
    }
};

/// 执行状态
pub const ExecutionStatus = enum {
    idle, // 空闲
    running, // 运行中
    completed, // 完成
    failed, // 失败
    stopped, // 被停止
};

/// 执行结果
pub const ExecutionResult = struct {
    status: ExecutionStatus,
    exit_code: ?i32,
    // 固定容量环形缓冲区，避免长时间输出时的大块内存搬移
    output_ring: []u8,
    output_head: usize,
    output_len: usize,
    output_linearized: std.ArrayList(u8),
    output_dirty: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ExecutionResult {
        return ExecutionResult{
            .status = .idle,
            .exit_code = null,
            .output_ring = allocator.alloc(u8, max_output_bytes) catch @panic("executor: out of memory"),
            .output_head = 0,
            .output_len = 0,
            .output_linearized = std.ArrayList(u8).init(allocator),
            .output_dirty = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ExecutionResult) void {
        self.output_linearized.deinit();
        self.allocator.free(self.output_ring);
    }

    pub fn clearOutput(self: *ExecutionResult) void {
        self.output_head = 0;
        self.output_len = 0;
        self.output_dirty = true;
    }

    pub fn appendOutput(self: *ExecutionResult, text: []const u8) !void {
        if (text.len == 0) return;

        if (text.len >= self.output_ring.len) {
            @memcpy(self.output_ring[0..self.output_ring.len], text[text.len - self.output_ring.len ..]);
            self.output_head = 0;
            self.output_len = self.output_ring.len;
            self.output_dirty = true;
            return;
        }

        for (text) |byte| {
            if (self.output_len < self.output_ring.len) {
                const tail = (self.output_head + self.output_len) % self.output_ring.len;
                self.output_ring[tail] = byte;
                self.output_len += 1;
            } else {
                // 缓冲区满时覆盖最旧字节
                self.output_ring[self.output_head] = byte;
                self.output_head = (self.output_head + 1) % self.output_ring.len;
            }
        }

        self.output_dirty = true;
    }

    fn rebuildLinearized(self: *ExecutionResult) !void {
        if (!self.output_dirty) return;

        self.output_linearized.clearRetainingCapacity();
        if (self.output_len == 0) {
            self.output_dirty = false;
            return;
        }

        try self.output_linearized.ensureTotalCapacity(self.output_len);

        if (self.output_head + self.output_len <= self.output_ring.len) {
            try self.output_linearized.appendSlice(self.output_ring[self.output_head .. self.output_head + self.output_len]);
        } else {
            const first_len = self.output_ring.len - self.output_head;
            const second_len = self.output_len - first_len;
            try self.output_linearized.appendSlice(self.output_ring[self.output_head..]);
            try self.output_linearized.appendSlice(self.output_ring[0..second_len]);
        }

        self.output_dirty = false;
    }

    pub fn getOutput(self: *ExecutionResult) []const u8 {
        self.rebuildLinearized() catch return "";
        return self.output_linearized.items;
    }
};

/// 脚本执行器
pub const ScriptExecutor = struct {
    allocator: std.mem.Allocator,
    child_process: ?std.process.Child,
    child_pgid: ?std.posix.pid_t,
    active_poll_until_ms: i64,
    result: ExecutionResult,

    pub fn init(allocator: std.mem.Allocator) ScriptExecutor {
        return ScriptExecutor{
            .allocator = allocator,
            .child_process = null,
            .child_pgid = null,
            .active_poll_until_ms = 0,
            .result = ExecutionResult.init(allocator),
        };
    }

    pub fn deinit(self: *ScriptExecutor) void {
        self.stop();
        self.result.deinit();
    }

    pub fn setStartError(self: *ScriptExecutor, message: []const u8) void {
        self.result.clearOutput();
        self.result.status = .failed;
        self.result.exit_code = null;
        self.result.appendOutput("=== Start failed ===\n") catch {};
        self.result.appendOutput(message) catch {};
        self.result.appendOutput("\n") catch {};
    }

    fn parseCommandTokens(self: *ScriptExecutor, command: []const u8) !ParsedCommand {
        var parsed = ParsedCommand.init(self.allocator);
        errdefer parsed.deinit();

        var current = std.ArrayList(u8).init(self.allocator);
        defer current.deinit();

        var in_single = false;
        var in_double = false;
        var escape_next = false;

        for (command) |ch| {
            if (escape_next) {
                try current.append(ch);
                escape_next = false;
                continue;
            }

            if (!in_single and ch == '\\') {
                escape_next = true;
                continue;
            }

            if (!in_double and ch == '\'') {
                in_single = !in_single;
                continue;
            }

            if (!in_single and ch == '"') {
                in_double = !in_double;
                continue;
            }

            if (!in_single and !in_double and std.ascii.isWhitespace(ch)) {
                if (current.items.len > 0) {
                    try parsed.tokens.append(try self.allocator.dupe(u8, current.items));
                    current.clearRetainingCapacity();
                }
                continue;
            }

            try current.append(ch);
        }

        if (escape_next) return CommandParseError.TrailingEscape;
        if (in_single) return CommandParseError.UnterminatedSingleQuote;
        if (in_double) return CommandParseError.UnterminatedDoubleQuote;

        if (current.items.len > 0) {
            try parsed.tokens.append(try self.allocator.dupe(u8, current.items));
        }

        return parsed;
    }

    fn appendArgvDisplay(self: *ScriptExecutor, argv: []const []const u8) !void {
        if (argv.len == 0) return;

        try self.result.appendOutput("Command: ");
        for (argv, 0..) |token, idx| {
            if (idx > 0) try self.result.appendOutput(" ");
            try self.result.appendOutput(token);
        }
        try self.result.appendOutput("\n\n");
    }

    fn markActivePolling(self: *ScriptExecutor) void {
        self.active_poll_until_ms = std.time.milliTimestamp() + active_poll_grace_ms;
    }

    /// 执行脚本
    pub fn execute(self: *ScriptExecutor, script: *const script_mod.Script) !void {
        // 如果已有进程在运行，先停止
        if (self.child_process != null) {
            return error.AlreadyRunning;
        }

        // 重置结果
        self.result.clearOutput();
        self.result.status = .running;
        self.result.exit_code = null;
        self.markActivePolling();

        const trimmed_command = std.mem.trim(u8, script.command, " \t\r\n");
        const basename = std.fs.path.basename(script.path);
        const is_python_script = std.mem.endsWith(u8, basename, ".py");
        const is_shell_script = std.mem.endsWith(u8, basename, ".sh");

        if (is_python_script and trimmed_command.len == 0) {
            return error.MissingCommand;
        }

        var parsed = try self.parseCommandTokens(trimmed_command);
        defer parsed.deinit();

        // 构建参数数组（command tokens + 脚本路径 + 参数）
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        for (parsed.tokens.items) |token| {
            try args.append(token);
        }

        if (is_python_script or is_shell_script) {
            if (trimmed_command.len > 0 or is_python_script) {
                try args.append(script.path);
            } else if (is_shell_script) {
                try args.append(script.path);
            }
        }

        for (script.args.items) |arg| {
            if (arg.name.len > 0) try args.append(arg.name);
            if (arg.value.len > 0) try args.append(arg.value);
        }

        if (args.items.len == 0) {
            return error.EmptyCommand;
        }

        // 创建子进程
        var child = std.process.Child.init(args.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.stdin_behavior = .Ignore;

        // 启动进程
        try child.spawn();

        // 设置子进程为独立进程组（子进程成为组长）
        const pid = child.id;
        if (std.posix.setpgid(pid, pid)) |_| {
            self.child_pgid = pid;
        } else |_| {
            self.child_pgid = null; // setpgid 失败，回退到单进程 kill
        }

        // 设置 stdout/stderr 为非阻塞模式
        const O_NONBLOCK: i32 = 0x0004; // macOS O_NONBLOCK flag
        if (child.stdout) |stdout| {
            const flags = try std.posix.fcntl(stdout.handle, std.posix.F.GETFL, 0);
            _ = try std.posix.fcntl(stdout.handle, std.posix.F.SETFL, flags | O_NONBLOCK);
        }
        if (child.stderr) |stderr| {
            const flags = try std.posix.fcntl(stderr.handle, std.posix.F.GETFL, 0);
            _ = try std.posix.fcntl(stderr.handle, std.posix.F.SETFL, flags | O_NONBLOCK);
        }

        self.child_process = child;

        // 添加启动信息
        try self.result.appendOutput("=== Starting script ===\n");
        try self.appendArgvDisplay(args.items);
    }

    /// 检查进程状态并收集输出（非阻塞）
    pub fn poll(self: *ScriptExecutor) !void {
        if (self.child_process) |*child| {
            var saw_activity = false;

            // 读取 stdout（非阻塞）
            if (child.stdout) |stdout| {
                var buf: [4096]u8 = undefined;
                while (true) {
                    const n = stdout.read(&buf) catch |err| {
                        if (err == error.WouldBlock) break;
                        return err;
                    };
                    if (n == 0) break;
                    saw_activity = true;
                    try self.result.appendOutput(buf[0..n]);
                }
            }

            // 读取 stderr（非阻塞）
            if (child.stderr) |stderr| {
                var buf: [4096]u8 = undefined;
                while (true) {
                    const n = stderr.read(&buf) catch |err| {
                        if (err == error.WouldBlock) break;
                        return err;
                    };
                    if (n == 0) break;
                    saw_activity = true;
                    try self.result.appendOutput("[STDERR] ");
                    try self.result.appendOutput(buf[0..n]);
                }
            }

            if (saw_activity) {
                self.markActivePolling();
            }

            // 使用 waitpid 非阻塞检查进程状态
            const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);

            if (result.pid == 0) {
                // 进程还在运行
                return;
            }

            // 进程已结束，读取剩余输出
            if (child.stdout) |stdout| {
                var buf: [4096]u8 = undefined;
                while (true) {
                    const n = stdout.read(&buf) catch break;
                    if (n == 0) break;
                    try self.result.appendOutput(buf[0..n]);
                }
                stdout.close();
                child.stdout = null;
            }
            if (child.stderr) |stderr| {
                var buf: [4096]u8 = undefined;
                while (true) {
                    const n = stderr.read(&buf) catch break;
                    if (n == 0) break;
                    try self.result.appendOutput("[STDERR] ");
                    try self.result.appendOutput(buf[0..n]);
                }
                stderr.close();
                child.stderr = null;
            }

            const status = std.posix.W.EXITSTATUS(result.status);
            const signaled = std.posix.W.IFSIGNALED(result.status);
            const stopped = std.posix.W.IFSTOPPED(result.status);

            if (signaled) {
                const sig = std.posix.W.TERMSIG(result.status);
                self.result.exit_code = null;
                self.result.status = .stopped;

                var status_msg: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&status_msg, "\n=== Script stopped by signal {} ===\n", .{sig});
                try self.result.appendOutput(msg);
            } else if (stopped) {
                const sig = std.posix.W.STOPSIG(result.status);
                self.result.exit_code = null;
                self.result.status = .stopped;

                var status_msg: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&status_msg, "\n=== Script stopped by signal {} ===\n", .{sig});
                try self.result.appendOutput(msg);
            } else {
                self.result.exit_code = @intCast(status);
                self.result.status = if (status == 0) .completed else .failed;

                var status_msg: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&status_msg, "\n=== Script finished with exit code {} ===\n", .{status});
                try self.result.appendOutput(msg);
            }

            self.markActivePolling();
            self.child_process = null;
            self.child_pgid = null;
        }
    }

    /// 停止执行
    pub fn stop(self: *ScriptExecutor) void {
        if (self.child_process) |*child| {
            // 杀死整个进程组（包括子进程）
            if (self.child_pgid) |pgid| {
                std.posix.kill(-pgid, std.posix.SIG.KILL) catch {};
                self.child_pgid = null;
            } else {
                _ = child.kill() catch {};
            }

            // 关闭流
            if (child.stdout) |stdout| {
                stdout.close();
                child.stdout = null;
            }
            if (child.stderr) |stderr| {
                stderr.close();
                child.stderr = null;
            }

            _ = child.wait() catch {}; // 回收子进程，防止僵尸进程
            self.result.status = .stopped;
            self.child_process = null;
        }
    }

    /// 获取输出内容
    pub fn getOutput(self: *ScriptExecutor) []const u8 {
        return self.result.getOutput();
    }

    /// 清空当前输出缓存（不影响进程状态）
    pub fn clearOutput(self: *ScriptExecutor) void {
        self.result.clearOutput();
    }

    /// 是否正在运行
    pub fn isRunning(self: *const ScriptExecutor) bool {
        return self.result.status == .running;
    }

    pub fn prefersFrequentPolling(self: *const ScriptExecutor) bool {
        return self.isRunning() and self.active_poll_until_ms > std.time.milliTimestamp();
    }
};

test {
    _ = @import("executor_test.zig");
}
