const std = @import("std");
const script_mod = @import("script.zig");

test "ScriptArg: init and deinit" {
    const allocator = std.testing.allocator;
    var arg = try script_mod.ScriptArg.init(allocator, "--verbose", "true");
    defer arg.deinit();

    try std.testing.expectEqualStrings("--verbose", arg.name);
    try std.testing.expectEqualStrings("true", arg.value);
}

test "ScriptArg: empty value" {
    const allocator = std.testing.allocator;
    var arg = try script_mod.ScriptArg.init(allocator, "-v", "");
    defer arg.deinit();

    try std.testing.expectEqualStrings("-v", arg.name);
    try std.testing.expectEqualStrings("", arg.value);
}

test "Script: init and deinit" {
    const allocator = std.testing.allocator;
    var s = try script_mod.Script.init(allocator, "/path/to/script.py", "script.py", "uv run /path/to/script.py");
    defer s.deinit();

    try std.testing.expectEqualStrings("/path/to/script.py", s.path);
    try std.testing.expectEqualStrings("script.py", s.name);
    try std.testing.expectEqualStrings("uv run /path/to/script.py", s.command);
    try std.testing.expectEqual(@as(usize, 0), s.args.items.len);
}

test "Script: addArg single argument" {
    const allocator = std.testing.allocator;
    var s = try script_mod.Script.init(allocator, "/test.py", "test.py", "python /test.py");
    defer s.deinit();

    try s.addArg("--output", "/tmp/out.txt");

    try std.testing.expectEqual(@as(usize, 1), s.args.items.len);
    try std.testing.expectEqualStrings("--output", s.args.items[0].name);
    try std.testing.expectEqualStrings("/tmp/out.txt", s.args.items[0].value);
}

test "Script: addArg multiple arguments" {
    const allocator = std.testing.allocator;
    var s = try script_mod.Script.init(allocator, "/test.sh", "test.sh", "bash /test.sh");
    defer s.deinit();

    try s.addArg("-v", "");
    try s.addArg("--config", "config.json");
    try s.addArg("--port", "8080");

    try std.testing.expectEqual(@as(usize, 3), s.args.items.len);
    try std.testing.expectEqualStrings("-v", s.args.items[0].name);
    try std.testing.expectEqualStrings("", s.args.items[0].value);
    try std.testing.expectEqualStrings("--config", s.args.items[1].name);
    try std.testing.expectEqualStrings("config.json", s.args.items[1].value);
}

test "Script: buildCommandLine no arguments" {
    const allocator = std.testing.allocator;
    var s = try script_mod.Script.init(allocator, "/test.py", "test.py", "python test.py");
    defer s.deinit();

    const cmd = try s.buildCommandLine(allocator);
    defer allocator.free(cmd);

    try std.testing.expectEqualStrings("python test.py", cmd);
}

test "Script: buildCommandLine with arguments" {
    const allocator = std.testing.allocator;
    var s = try script_mod.Script.init(allocator, "/test.py", "test.py", "python test.py");
    defer s.deinit();

    try s.addArg("--verbose", "");
    try s.addArg("--output", "/tmp/out.txt");
    try s.addArg("-n", "10");

    const cmd = try s.buildCommandLine(allocator);
    defer allocator.free(cmd);

    try std.testing.expectEqualStrings("python test.py --verbose --output /tmp/out.txt -n 10", cmd);
}

test "Script: buildCommandLine with flag (no value)" {
    const allocator = std.testing.allocator;
    var s = try script_mod.Script.init(allocator, "/test.sh", "test.sh", "bash test.sh");
    defer s.deinit();

    try s.addArg("-v", "");
    try s.addArg("-x", "");

    const cmd = try s.buildCommandLine(allocator);
    defer allocator.free(cmd);

    try std.testing.expectEqualStrings("bash test.sh -v -x", cmd);
}

test "Script: buildCommandLine with special characters" {
    const allocator = std.testing.allocator;
    var s = try script_mod.Script.init(allocator, "/test.py", "test.py", "python test.py");
    defer s.deinit();

    try s.addArg("--message", "hello world");
    try s.addArg("--path", "/tmp/test file.txt");

    const cmd = try s.buildCommandLine(allocator);
    defer allocator.free(cmd);

    try std.testing.expectEqualStrings("python test.py --message hello world --path /tmp/test file.txt", cmd);
}

test "Script: empty args list" {
    const allocator = std.testing.allocator;
    var s = try script_mod.Script.init(allocator, "/test.py", "test.py", "python test.py");
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 0), s.args.items.len);
}

test "Script: init with empty strings" {
    const allocator = std.testing.allocator;
    var s = try script_mod.Script.init(allocator, "", "", "");
    defer s.deinit();

    try std.testing.expectEqualStrings("", s.path);
    try std.testing.expectEqualStrings("", s.name);
    try std.testing.expectEqualStrings("", s.command);
}
