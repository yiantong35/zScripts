/// 执行输出视图组件 - 输出面板、自动滚动、复制/清除
const std = @import("std");
const zgui = @import("zgui");
const app_mod = @import("../app.zig");

const AppState = app_mod.AppState;
const Tab = app_mod.Tab;

/// 渲染执行输出面板（工具栏 + 输出内容）
pub fn render(app_state: *AppState, tab: *Tab, output_height: f32, detail_font_scale: f32) void {
    const toolbar_button_h: f32 = 38.0;
    const output_label = "Output:";
    zgui.setWindowFontScale(detail_font_scale);
    zgui.alignTextToFramePadding();
    zgui.text(output_label, .{});
    zgui.setWindowFontScale(detail_font_scale);
    zgui.sameLine(.{ .spacing = 12.0 });

    const output_slice = if (tab.script_executor) |*exec| exec.getOutput() else "";
    const output_view = if (tab.show_full_output)
        output_slice
    else
        app_mod.tailOutputView(output_slice, 300, 64 * 1024);

    if (zgui.button(if (tab.show_full_output) "Show Tail" else "Show Full", .{ .w = 136, .h = toolbar_button_h })) {
        tab.show_full_output = !tab.show_full_output;
    }
    zgui.sameLine(.{ .spacing = 8.0 });
    if (zgui.button("Clear", .{ .w = 96, .h = toolbar_button_h })) {
        if (tab.script_executor) |*exec| {
            var mut_exec = exec.*;
            mut_exec.clearOutput();
            tab.script_executor = mut_exec;
        }
    }
    zgui.sameLine(.{ .spacing = 8.0 });
    if (zgui.button("Copy", .{ .w = 96, .h = toolbar_button_h })) {
        _ = app_mod.copyTextToClipboard(app_state.allocator, output_view);
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
