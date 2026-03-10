const std = @import("std");

/// 脚本参数
pub const ScriptArg = struct {
    name: []const u8, // 参数名，如 "-k"
    value: []const u8, // 参数值，如 "hello"
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, value: []const u8) !ScriptArg {
        return ScriptArg{
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ScriptArg) void {
        self.allocator.free(self.name);
        self.allocator.free(self.value);
    }
};

/// 脚本配置
pub const Script = struct {
    path: []const u8, // 脚本文件路径
    name: []const u8, // 显示名称
    command: []const u8, // 运行命令，如 "uv run test.py"
    args: std.ArrayList(ScriptArg), // 参数列表
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, name: []const u8, command: []const u8) !Script {
        return Script{
            .path = try allocator.dupe(u8, path),
            .name = try allocator.dupe(u8, name),
            .command = try allocator.dupe(u8, command),
            .args = std.ArrayList(ScriptArg).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Script) void {
        for (self.args.items) |*arg| {
            arg.deinit();
        }
        self.args.deinit();
        self.allocator.free(self.path);
        self.allocator.free(self.name);
        self.allocator.free(self.command);
    }

    pub fn addArg(self: *Script, name: []const u8, value: []const u8) !void {
        const arg = try ScriptArg.init(self.allocator, name, value);
        try self.args.append(arg);
    }

    /// 构建完整的命令行
    pub fn buildCommandLine(self: *const Script, allocator: std.mem.Allocator) ![]const u8 {
        var cmd = std.ArrayList(u8).init(allocator);
        defer cmd.deinit();

        try cmd.appendSlice(self.command);

        for (self.args.items) |arg| {
            try cmd.append(' ');
            try cmd.appendSlice(arg.name);
            if (arg.value.len > 0) {
                try cmd.append(' ');
                try cmd.appendSlice(arg.value);
            }
        }

        return cmd.toOwnedSlice();
    }
};
