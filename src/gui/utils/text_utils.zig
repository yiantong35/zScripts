/// 文本处理工具函数
const std = @import("std");
const zglfw = @import("zglfw");
const config = @import("../../storage/config.zig");

pub const TruncateTextResult = struct {
    text: []const u8,
    truncated: bool,
};

pub fn truncateText(input: []const u8, max_chars: usize, buffer: []u8) TruncateTextResult {
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

pub fn tailOutputView(text: []const u8, max_lines: usize, max_bytes: usize) []const u8 {
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

pub fn copyTextToClipboard(allocator: std.mem.Allocator, text: []const u8) bool {
    if (text.len == 0) return false;
    const window = zglfw.getCurrentContext() orelse return false;
    const text_z = std.fmt.allocPrintZ(allocator, "{s}", .{text}) catch return false;
    defer allocator.free(text_z);
    zglfw.setClipboardString(window, text_z);
    return true;
}

pub fn appendUniqueParamNames(allocator: std.mem.Allocator, params: []const config.ParameterConfig, unique_names: *std.ArrayList([]const u8)) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (params) |param| {
        if (param.name.len == 0) continue;
        if (seen.contains(param.name)) continue;

        try seen.put(param.name, {});
        try unique_names.append(param.name);
    }
}

pub fn buildParamSummary(allocator: std.mem.Allocator, params: []const config.ParameterConfig, buffer: []u8) []const u8 {
    var unique_names = std.ArrayList([]const u8).init(allocator);
    defer unique_names.deinit();

    appendUniqueParamNames(allocator, params, &unique_names) catch return "params";

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

pub fn buildParamTooltip(allocator: std.mem.Allocator, params: []const config.ParameterConfig) !?[]const u8 {
    var unique_names = std.ArrayList([]const u8).init(allocator);
    defer unique_names.deinit();

    try appendUniqueParamNames(allocator, params, &unique_names);
    if (unique_names.items.len <= 4) return null;

    var tooltip = std.ArrayList(u8).init(allocator);
    errdefer tooltip.deinit();
    const writer = tooltip.writer();

    try writer.print("{d} params", .{unique_names.items.len});
    for (unique_names.items, 0..) |name, idx| {
        if (idx == 0) {
            try writer.print(": {s}", .{name});
        } else {
            try writer.print(", {s}", .{name});
        }
    }

    return try tooltip.toOwnedSlice();
}

pub fn buildCommandPreview(command: []const u8, buffer: []u8) []const u8 {
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

pub fn duplicateOptionalText(allocator: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    if (text) |value| {
        return try allocator.dupe(u8, value);
    }
    return null;
}
