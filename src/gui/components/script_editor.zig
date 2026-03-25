/// 脚本编辑器组件 - 描述、命令、参数编辑 + 执行控制按钮
const std = @import("std");
const zgui = @import("zgui");
const app_mod = @import("../app.zig");
const script_mod = @import("../../core/script.zig");
const executor = @import("../../core/executor.zig");
const config = @import("../../storage/config.zig");
const execution_view = @import("execution_view.zig");
const layout = @import("../utils/layout.zig");

const AppState = app_mod.AppState;
const Tab = app_mod.Tab;
const ScriptParameter = app_mod.ScriptParameter;
const showItemTooltip = layout.showItemTooltip;

/// 渲染脚本标签页
pub fn render(app_state: *AppState, tab: *Tab) void {
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
                if (zgui.isItemActive()) {
                    app_state.noteInputActivity();
                }
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
                if (zgui.isItemActive()) {
                    app_state.noteInputActivity();
                }
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
                    renderParamList(app_state, tab, detail_font_scale);
                }
                zgui.endChild();
            }
            zgui.endChild();
        }
        zgui.endChild();

        zgui.sameLine(.{ .spacing = 16.0 });
        if (zgui.beginChild("ControlRight", .{ .w = -1, .h = -1 })) {
            renderActionButtons(app_state, tab, detail_font_scale);
        }
        zgui.endChild();
    }
    zgui.endChild();

    // 输出面板 - 委托给 execution_view 组件
    execution_view.render(app_state, tab, output_height, detail_font_scale);
}

fn renderParamList(app_state: *AppState, tab: *Tab, detail_font_scale: f32) void {
    const row_width = zgui.getContentRegionAvail()[0];
    const name_width = row_width * 0.22;
    const usage_width = row_width * 0.33;
    const value_width = row_width * 0.37;
    const remove_width = @max(36.0, row_width - name_width - usage_width - value_width - 24.0);

    zgui.setWindowFontScale(detail_font_scale);
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 10.0, 8.0 } });
    defer zgui.popStyleVar(.{ .count = 1 });
    zgui.textDisabled("Name", .{});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.setCursorPosX(zgui.getCursorPosX() + name_width + 4.0);
    zgui.textDisabled("Usage", .{});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.setCursorPosX(zgui.getCursorPosX() + usage_width + 4.0);
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
        if (zgui.isItemActive()) {
            app_state.noteInputActivity();
        }

        zgui.sameLine(.{ .spacing = 8.0 });
        var usage_id_buf: [40:0]u8 = undefined;
        const usage_id = std.fmt.bufPrintZ(&usage_id_buf, "##pusage{d}", .{i}) catch "##pusage";
        zgui.setNextItemWidth(usage_width);
        _ = zgui.inputTextWithHint(usage_id, .{
            .hint = "what this param does",
            .buf = param.usage[0..255 :0],
        });
        if (zgui.isItemActive()) {
            app_state.noteInputActivity();
        }
        const usage_len = std.mem.indexOfScalar(u8, &param.usage, 0) orelse param.usage.len;
        if (usage_len > 0) {
            showItemTooltip(param.usage[0..usage_len]);
        }

        zgui.sameLine(.{ .spacing = 8.0 });
        var value_id_buf: [40:0]u8 = undefined;
        const value_id = std.fmt.bufPrintZ(&value_id_buf, "##pval{d}", .{i}) catch "##pval";
        zgui.setNextItemWidth(value_width);
        _ = zgui.inputText(value_id, .{ .buf = param.value[0..255 :0] });
        if (zgui.isItemActive()) {
            app_state.noteInputActivity();
        }

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

fn renderActionButtons(app_state: *AppState, tab: *Tab, detail_font_scale: f32) void {
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

pub fn saveTabConfig(app_state: *AppState, tab: *Tab) !void {
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
            const usage_len = std.mem.indexOfScalar(u8, &param.usage, 0) orelse param.usage.len;
            const value_len = std.mem.indexOfScalar(u8, &param.value, 0) orelse param.value.len;

            // 只保存有名称的参数
            if (name_len > 0) {
                params.append(.{
                    .name = param.name[0..name_len],
                    .usage = param.usage[0..usage_len],
                    .value = param.value[0..value_len],
                }) catch continue;
            }
        }

        // 保存配置
        try app_state.config_manager.saveScriptConfig(path, description, command, params.items);
        try app_state.rebuildCardMetaForScript(path);
    }
}
