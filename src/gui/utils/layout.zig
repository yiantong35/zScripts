/// 布局辅助函数
const zgui = @import("zgui");

/// 居中绘制带颜色的文本
pub fn drawCenteredTextColored(text: []const u8, color: [4]f32) void {
    const avail_w = zgui.getContentRegionAvail()[0];
    const text_size = zgui.calcTextSize(text, .{});
    if (avail_w > text_size[0]) {
        zgui.setCursorPosX(zgui.getCursorPosX() + (avail_w - text_size[0]) * 0.5);
    }
    zgui.textColored(color, "{s}", .{text});
}

/// 显示悬停提示
pub fn showItemTooltip(text: []const u8) void {
    if (!zgui.isItemHovered(.{})) return;
    if (zgui.beginTooltip()) {
        zgui.textUnformatted(text);
        zgui.endTooltip();
    }
}
