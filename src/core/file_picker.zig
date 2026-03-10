const std = @import("std");

// Objective-C 桥接函数声明
extern "c" fn showOpenPanel(allow_files: bool, allow_directories: bool, allow_multiple: bool, file_types: [*c]const [*c]const u8, file_types_count: c_int) [*c][*c]u8;
extern "c" fn freePathArray(paths: [*c][*c]u8, count: c_int) void;
extern "c" fn getPathArrayCount(paths: [*c][*c]u8) c_int;

/// 文件选择器类型
pub const PickerType = enum {
    files, // 只选择文件
    directories, // 只选择文件夹
};

/// 文件选择器结果
pub const PickerResult = struct {
    paths: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PickerResult) void {
        for (self.paths) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.paths);
    }
};

/// 显示文件选择对话框
pub fn showFilePicker(allocator: std.mem.Allocator, picker_type: PickerType) !?PickerResult {
    const allow_files = picker_type == .files;
    const allow_directories = picker_type == .directories;
    const allow_multiple = true;

    // 文件类型过滤（只用于文件选择）
    const file_types = [_][*c]const u8{ "py", "sh" };
    const file_types_ptr = if (allow_files) @as([*c]const [*c]const u8, &file_types) else null;
    const file_types_count = if (allow_files) @as(c_int, 2) else @as(c_int, 0);

    // 调用 Objective-C 函数
    const paths_ptr = showOpenPanel(
        allow_files,
        allow_directories,
        allow_multiple,
        file_types_ptr,
        file_types_count,
    );

    if (paths_ptr == null) {
        return null; // 用户取消
    }

    // 获取路径数量
    const count = getPathArrayCount(paths_ptr);
    if (count == 0) {
        return null;
    }

    // 复制路径到 Zig 管理的内存
    var paths = try allocator.alloc([]const u8, @intCast(count));
    errdefer allocator.free(paths);

    for (0..@intCast(count)) |i| {
        const c_path = paths_ptr[i + 1]; // 实际路径从索引1开始，索引0存储的是数量
        const path_len = std.mem.len(c_path);
        paths[i] = try allocator.dupe(u8, c_path[0..path_len]);
    }

    // 释放 C 分配的内存
    freePathArray(paths_ptr, count);

    return PickerResult{
        .paths = paths,
        .allocator = allocator,
    };
}
