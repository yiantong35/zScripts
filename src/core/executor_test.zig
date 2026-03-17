const std = @import("std");
const executor = @import("executor.zig");
const script_mod = @import("script.zig");

test "ExecutionResult: init and deinit" {
    const allocator = std.testing.allocator;
    var result = executor.ExecutionResult.init(allocator);
    defer result.deinit();

    try std.testing.expectEqual(executor.ExecutionStatus.idle, result.status);
    try std.testing.expectEqual(@as(?i32, null), result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), result.output_len);
}

test "ExecutionResult: appendOutput basic" {
    const allocator = std.testing.allocator;
    var result = executor.ExecutionResult.init(allocator);
    defer result.deinit();

    try result.appendOutput("Hello");
    try result.appendOutput(" ");
    try result.appendOutput("World");

    const output = result.getOutput();
    try std.testing.expectEqualStrings("Hello World", output);
}

test "ExecutionResult: ring buffer overflow" {
    const allocator = std.testing.allocator;
    var result = executor.ExecutionResult.init(allocator);
    defer result.deinit();

    // 填充超过环形缓冲区容量的数据
    const large_text = "X" ** 1024;
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        try result.appendOutput(large_text);
    }

    const output = result.getOutput();
    // 验证输出不为空且被截断到缓冲区大小
    try std.testing.expect(output.len > 0);
    try std.testing.expect(output.len <= 2 * 1024 * 1024);
}

test "ExecutionResult: clearOutput" {
    const allocator = std.testing.allocator;
    var result = executor.ExecutionResult.init(allocator);
    defer result.deinit();

    try result.appendOutput("Test data");
    try std.testing.expect(result.output_len > 0);

    result.clearOutput();
    try std.testing.expectEqual(@as(usize, 0), result.output_len);
    try std.testing.expectEqualStrings("", result.getOutput());
}

test "ScriptExecutor: init and deinit" {
    const allocator = std.testing.allocator;
    var exec = executor.ScriptExecutor.init(allocator);
    defer exec.deinit();

    try std.testing.expectEqual(@as(?std.process.Child, null), exec.child_process);
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), exec.child_pgid);
    try std.testing.expectEqual(executor.ExecutionStatus.idle, exec.result.status);
}

test "ScriptExecutor: execute simple shell command" {
    const allocator = std.testing.allocator;
    var exec = executor.ScriptExecutor.init(allocator);
    defer exec.deinit();

    // 创建临时测试脚本
    const test_script_path = "/tmp/test_executor.sh";
    {
        const file = try std.fs.createFileAbsolute(test_script_path, .{});
        defer file.close();
        try file.writeAll("#!/bin/bash\necho 'test output'\n");
    }
    defer std.fs.deleteFileAbsolute(test_script_path) catch {};

    // 设置执行权限
    try std.posix.chmod(test_script_path, 0o755);

    var script = script_mod.Script.init(allocator, test_script_path);
    defer script.deinit();
    script.command = try allocator.dupe(u8, "bash");

    try exec.execute(&script);
    try std.testing.expectEqual(executor.ExecutionStatus.running, exec.result.status);
    try std.testing.expect(exec.child_process != null);
}

test "ScriptExecutor: poll and wait for completion" {
    const allocator = std.testing.allocator;
    var exec = executor.ScriptExecutor.init(allocator);
    defer exec.deinit();

    // 创建快速完成的测试脚本
    const test_script_path = "/tmp/test_executor_poll.sh";
    {
        const file = try std.fs.createFileAbsolute(test_script_path, .{});
        defer file.close();
        try file.writeAll("#!/bin/bash\necho 'poll test'\nexit 0\n");
    }
    defer std.fs.deleteFileAbsolute(test_script_path) catch {};
    try std.posix.chmod(test_script_path, 0o755);

    var script = script_mod.Script.init(allocator, test_script_path);
    defer script.deinit();
    script.command = try allocator.dupe(u8, "bash");

    try exec.execute(&script);

    // 轮询直到进程完成（带超时保护）
    const timeout_ns: u64 = 5 * std.time.ns_per_s;
    const start = std.time.nanoTimestamp();
    while (true) {
        try exec.poll();
        if (exec.result.status != .running) break;
        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        if (elapsed > timeout_ns) {
            exec.stop();
            return error.TestTimeout;
        }
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expectEqual(executor.ExecutionStatus.completed, exec.result.status);
    try std.testing.expectEqual(@as(?i32, 0), exec.result.exit_code);
}

test "ScriptExecutor: stop running process" {
    const allocator = std.testing.allocator;
    var exec = executor.ScriptExecutor.init(allocator);
    defer exec.deinit();

    // 创建长时间运行的脚本
    const test_script_path = "/tmp/test_executor_stop.sh";
    {
        const file = try std.fs.createFileAbsolute(test_script_path, .{});
        defer file.close();
        try file.writeAll("#!/bin/bash\nsleep 60\n");
    }
    defer std.fs.deleteFileAbsolute(test_script_path) catch {};
    try std.posix.chmod(test_script_path, 0o755);

    var script = script_mod.Script.init(allocator, test_script_path);
    defer script.deinit();
    script.command = try allocator.dupe(u8, "bash");

    try exec.execute(&script);
    try std.testing.expectEqual(executor.ExecutionStatus.running, exec.result.status);

    // 停止进程
    exec.stop();
    try std.testing.expectEqual(executor.ExecutionStatus.stopped, exec.result.status);
    try std.testing.expectEqual(@as(?std.process.Child, null), exec.child_process);
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), exec.child_pgid);
}

test "ScriptExecutor: isRunning" {
    const allocator = std.testing.allocator;
    var exec = executor.ScriptExecutor.init(allocator);
    defer exec.deinit();

    try std.testing.expect(!exec.isRunning());

    const test_script_path = "/tmp/test_executor_running.sh";
    {
        const file = try std.fs.createFileAbsolute(test_script_path, .{});
        defer file.close();
        try file.writeAll("#!/bin/bash\nsleep 1\n");
    }
    defer std.fs.deleteFileAbsolute(test_script_path) catch {};
    try std.posix.chmod(test_script_path, 0o755);

    var script = script_mod.Script.init(allocator, test_script_path);
    defer script.deinit();
    script.command = try allocator.dupe(u8, "bash");

    try exec.execute(&script);
    try std.testing.expect(exec.isRunning());

    exec.stop();
    try std.testing.expect(!exec.isRunning());
}

test "ScriptExecutor: setStartError" {
    const allocator = std.testing.allocator;
    var exec = executor.ScriptExecutor.init(allocator);
    defer exec.deinit();

    exec.setStartError("command not found");
    try std.testing.expectEqual(executor.ExecutionStatus.failed, exec.result.status);
    try std.testing.expectEqual(@as(?i32, null), exec.result.exit_code);

    const output = exec.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "Start failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "command not found") != null);
}

test "ScriptExecutor: poll on idle executor is no-op" {
    const allocator = std.testing.allocator;
    var exec = executor.ScriptExecutor.init(allocator);
    defer exec.deinit();

    // poll 在没有进程时应该是安全的 no-op
    try exec.poll();
    try std.testing.expectEqual(executor.ExecutionStatus.idle, exec.result.status);
}

test "ScriptExecutor: stop on idle executor is no-op" {
    const allocator = std.testing.allocator;
    var exec = executor.ScriptExecutor.init(allocator);
    defer exec.deinit();

    // stop 在没有进程时应该是安全的 no-op
    exec.stop();
    try std.testing.expectEqual(executor.ExecutionStatus.idle, exec.result.status);
}

test "ExecutionResult: appendOutput empty string" {
    const allocator = std.testing.allocator;
    var result = executor.ExecutionResult.init(allocator);
    defer result.deinit();

    try result.appendOutput("");
    try std.testing.expectEqual(@as(usize, 0), result.output_len);
    try std.testing.expectEqualStrings("", result.getOutput());
}
