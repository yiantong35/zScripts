/// 首页组件 - 工具栏、分组卡片网格
const std = @import("std");
const zgui = @import("zgui");
const app_mod = @import("../app.zig");
const scanner = @import("../../core/scanner.zig");
const script_mod = @import("../../core/script.zig");
const file_picker = @import("../../core/file_picker.zig");
const config = @import("../../storage/config.zig");
const layout = @import("../utils/layout.zig");

const AppState = app_mod.AppState;
const Tab = app_mod.Tab;

const drawCenteredTextColored = layout.drawCenteredTextColored;
const showItemTooltip = layout.showItemTooltip;

/// 渲染首页
pub fn render(app_state: *AppState) void {
    // 覆盖标签栏底部的线条
    const cursor_y = zgui.getCursorScreenPos()[1];
    const viewport_size = zgui.getMainViewport().getSize();
    const cover_draw_list = zgui.getWindowDrawList();
    const bg_color = zgui.colorConvertFloat4ToU32([4]f32{ 0.0, 0.0, 0.0, 1.0 });

    cover_draw_list.addRectFilled(.{
        .pmin = [2]f32{ 0, cursor_y - 5 },
        .pmax = [2]f32{ viewport_size[0], cursor_y + 5 },
        .col = bg_color,
    });

    // 工具栏
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 20.0, 15.0 } });
    zgui.setWindowFontScale(1.2);

    const button_width: f32 = 180;
    const button_height: f32 = 60;

    zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.145, 0.137, 0.129, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.188, 0.176, 0.165, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = [4]f32{ 0.227, 0.212, 0.196, 1.0 } });

    const add_scripts_button_pos = zgui.getCursorScreenPos();
    const button_clicked = zgui.button("Add Scripts", .{ .w = button_width, .h = button_height });
    zgui.popStyleColor(.{ .count = 3 });

    if (button_clicked) {
        zgui.openPopup("Select Type", .{});
        app_state.requestExtraFrames(2);
    }

    zgui.setNextWindowPos(.{
        .x = add_scripts_button_pos[0],
        .y = add_scripts_button_pos[1] + button_height + 8.0,
        .cond = .appearing,
    });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 15.0, 12.0 } });
    if (zgui.beginPopup("Select Type", .{})) {
        defer zgui.endPopup();
        zgui.setWindowFontScale(1.15);
        defer zgui.setWindowFontScale(1.0);
        if (zgui.selectable("Select Folders", .{ .h = 40 })) {
            importPathsFromPicker(app_state, .directories, true);
        }
        if (zgui.selectable("Select Files", .{ .h = 40 })) {
            importPathsFromPicker(app_state, .files, false);
        }
    }
    zgui.popStyleVar(.{ .count = 1 });

    zgui.sameLine(.{});
    zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.145, 0.137, 0.129, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.188, 0.176, 0.165, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = [4]f32{ 0.227, 0.212, 0.196, 1.0 } });
    if (zgui.button("Refresh", .{ .w = button_width, .h = button_height })) {
        const refreshed = blk: {
            app_state.refreshScripts() catch |err| {
                var msg_buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Refresh failed: {s}", .{@errorName(err)}) catch "Refresh failed";
                app_state.showErrorToast(msg);
                break :blk false;
            };
            break :blk true;
        };
        if (refreshed) {
            app_state.current_page = 0;
            var toast_buf: [96]u8 = undefined;
            const toast_msg = std.fmt.bufPrint(&toast_buf, "Refreshed {d} scripts", .{app_state.scanner.getScripts().len}) catch "Refresh complete";
            app_state.showSuccessToast(toast_msg);
        }
    }
    zgui.popStyleColor(.{ .count = 3 });

    // 搜索框（高度与按钮一致）
    zgui.sameLine(.{ .spacing = 20.0 });
    zgui.popStyleVar(.{ .count = 1 }); // 先弹出工具栏的 frame_padding
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 20.0, 20.0 } }); // 搜索框专用 padding
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = [4]f32{ 0.090, 0.086, 0.082, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = [4]f32{ 0.118, 0.110, 0.102, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = [4]f32{ 0.137, 0.129, 0.118, 1.0 } });
    const search_avail_w = zgui.getContentRegionAvail()[0];
    const search_width = @min(@max(200.0, search_avail_w - 10.0), 480.0);
    zgui.setNextItemWidth(search_width);
    if (zgui.inputTextWithHint("##search", .{
        .hint = "Search scripts...",
        .buf = app_state.search_query[0..255 :0],
    })) {
        app_state.current_page = 0;
    }
    zgui.popStyleColor(.{ .count = 3 });
    zgui.popStyleVar(.{ .count = 1 }); // 弹出搜索框的 frame_padding

    zgui.setWindowFontScale(1.0);

    zgui.spacing();
    zgui.spacing();

    // 脚本卡片网格标题 + Perf 复选框
    const scripts = app_state.scanner.getScripts();
    const total_scripts = scripts.len;
    if (app_state.card_meta_dirty) {
        app_state.rebuildCardMetaCache() catch {};
    }
    const has_card_meta = app_state.card_meta_cache.items.len == total_scripts;

    // 搜索过滤
    const search_query = app_state.getSearchQuery();
    const is_searching = search_query.len > 0;
    var filtered_indices: [512]usize = undefined;
    var filtered_count: usize = 0;

    for (scripts, 0..) |s, idx| {
        if (is_searching) {
            if (!matchesSearch(s.name, search_query) and
                !(has_card_meta and matchesSearch(app_state.card_meta_cache.items[idx].desc_line, search_query)))
            {
                continue;
            }
        }
        if (filtered_count < filtered_indices.len) {
            filtered_indices[filtered_count] = idx;
            filtered_count += 1;
        }
    }

    zgui.setWindowFontScale(1.3);
    var title_buf: [64]u8 = undefined;
    const title = if (is_searching)
        std.fmt.bufPrint(&title_buf, "Scripts ({d}/{d})", .{ filtered_count, total_scripts }) catch "Scripts"
    else
        std.fmt.bufPrint(&title_buf, "Scripts ({d})", .{total_scripts}) catch "Scripts";
    zgui.text("{s}", .{title});
    zgui.setWindowFontScale(1.0);

    // Perf 复选框
    zgui.sameLine(.{});
    const label_perf_window_w = zgui.calcTextSize("Perf Window", .{})[0];
    const label_perf_log_w = zgui.calcTextSize("Perf Log", .{})[0];
    const checkbox_w: f32 = 20.0;
    const perf_gap: f32 = 8.0;
    const perf_group_width = checkbox_w + label_perf_window_w + perf_gap + checkbox_w + label_perf_log_w + 22.0;
    const perf_right_padding: f32 = 10.0;
    const perf_cursor_x = zgui.getCursorPosX();
    const perf_remain_w = zgui.getContentRegionAvail()[0];
    if (perf_remain_w > perf_group_width + perf_right_padding) {
        zgui.setCursorPosX(perf_cursor_x + perf_remain_w - perf_group_width - perf_right_padding);
    }
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 3.0, 3.0 } });
    _ = zgui.checkbox("Perf Window", .{ .v = &app_state.perf.show_window });
    zgui.sameLine(.{ .spacing = perf_gap });
    _ = zgui.checkbox("Perf Log", .{ .v = &app_state.perf.enable_log });
    zgui.popStyleVar(.{ .count = 1 });

    zgui.spacing();
    zgui.spacing();

    // 卡片布局 - 根据可用空间自适应
    const remaining_avail = zgui.getContentRegionAvail();
    const spacing: f32 = 20;
    const cols: usize = 4;
    const rows: usize = 3;
    const cards_per_page: usize = cols * rows;
    const card_width = (remaining_avail[0] - spacing * @as(f32, @floatFromInt(cols + 1))) / @as(f32, @floatFromInt(cols));

    // 分页计算（基于过滤后的结果）
    const total_pages = if (filtered_count == 0) 1 else (filtered_count + cards_per_page - 1) / cards_per_page;
    if (app_state.current_page >= total_pages) {
        app_state.current_page = if (total_pages > 0) total_pages - 1 else 0;
    }
    const show_pagination = total_pages > 1;
    const pagination_height: f32 = if (show_pagination) 80 else 0;
    const card_height = (remaining_avail[1] - pagination_height - spacing * @as(f32, @floatFromInt(rows + 1))) / @as(f32, @floatFromInt(rows));
    const start_idx = app_state.current_page * cards_per_page;
    const end_idx = @min(start_idx + cards_per_page, filtered_count);

    if (filtered_count == 0) {
        zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = [4]f32{ 0.090, 0.086, 0.082, 1.0 } });
        zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 8.0 });
        defer zgui.popStyleColor(.{ .count = 1 });
        defer zgui.popStyleVar(.{ .count = 1 });
        if (zgui.beginChild("EmptyState", .{ .w = -1, .h = 220 })) {
            const empty_text = if (is_searching) "No matching scripts" else "No scripts yet";
            const hint_text = if (is_searching) "Try a different search term." else "Click Add Scripts to import your first script.";
            const empty_scale: f32 = 1.34;
            const hint_scale: f32 = 1.14;
            const line_gap: f32 = 18.0;
            const child_avail = zgui.getContentRegionAvail();

            zgui.setWindowFontScale(empty_scale);
            const empty_text_size = zgui.calcTextSize(empty_text, .{});
            zgui.setWindowFontScale(1.0);
            zgui.setWindowFontScale(hint_scale);
            const hint_text_size = zgui.calcTextSize(hint_text, .{});
            zgui.setWindowFontScale(1.0);

            const total_text_h = empty_text_size[1] + line_gap + hint_text_size[1];
            const start_y = @max(0.0, (child_avail[1] - total_text_h) * 0.5);
            const child_width = child_avail[0];

            zgui.setCursorPosY(start_y);
            if (child_width > empty_text_size[0]) {
                zgui.setCursorPosX((child_width - empty_text_size[0]) * 0.5);
            }
            zgui.setWindowFontScale(empty_scale);
            zgui.textColored(.{ 0.925, 0.914, 0.890, 1.0 }, "{s}", .{empty_text});
            zgui.setWindowFontScale(1.0);

            zgui.setCursorPosY(start_y + empty_text_size[1] + line_gap);
            if (child_width > hint_text_size[0]) {
                zgui.setCursorPosX((child_width - hint_text_size[0]) * 0.5);
            }
            zgui.setWindowFontScale(hint_scale);
            zgui.textColored(.{ 0.655, 0.624, 0.584, 1.0 }, "{s}", .{hint_text});
            zgui.setWindowFontScale(1.0);
        }
        zgui.endChild();
    } else {
        // 4x3 卡片网格；不足一页时补齐空位，保证分页控件始终在固定位置
        const visible_count = end_idx - start_idx;
        for (0..cards_per_page) |slot_idx| {
            const col = slot_idx % cols;
            if (col > 0) {
                zgui.sameLine(.{ .spacing = spacing });
            }

            if (slot_idx < visible_count) {
                const fi = start_idx + slot_idx;
                const script_idx = filtered_indices[fi];
                const s = scripts[script_idx];
                const card_meta = if (has_card_meta) &app_state.card_meta_cache.items[script_idx] else null;
                renderCard(app_state, s, card_meta, script_idx, card_width, card_height);
            } else {
                zgui.dummy(.{ .w = card_width, .h = card_height });
            }
        }

        // 分页控件
        if (total_pages > 1) {
            zgui.spacing();

            var page_buf: [64]u8 = undefined;
            const page_text = std.fmt.bufPrint(&page_buf, "Page {d} / {d}", .{ app_state.current_page + 1, total_pages }) catch "Page";
            const page_text_size = zgui.calcTextSize(page_text, .{});
            const btn_w: f32 = 92;
            const btn_h: f32 = 38;
            const group_spacing: f32 = 20.0;
            const page_group_w = btn_w + group_spacing + page_text_size[0] + group_spacing + btn_w;
            const remaining_space = zgui.getContentRegionAvail();
            const vertical_offset = @max(0.0, (remaining_space[1] - btn_h) * 0.5);
            if (vertical_offset > 0.0) {
                zgui.dummy(.{ .w = 0.0, .h = vertical_offset });
            }

            const row_y = zgui.getCursorPosY();
            const row_x = zgui.getCursorPosX();
            if (remaining_space[0] > page_group_w) {
                zgui.setCursorPosX(row_x + (remaining_space[0] - page_group_w) * 0.5);
            }

            zgui.pushStyleColor4f(.{ .idx = .button, .c = [4]f32{ 0.145, 0.137, 0.129, 1.0 } });
            zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = [4]f32{ 0.188, 0.176, 0.165, 1.0 } });
            zgui.pushStyleColor4f(.{ .idx = .button_active, .c = [4]f32{ 0.227, 0.212, 0.196, 1.0 } });

            if (app_state.current_page > 0) {
                if (zgui.button("< Prev", .{ .w = btn_w, .h = btn_h })) {
                    app_state.current_page -= 1;
                }
            } else {
                zgui.pushStyleColor4f(.{ .idx = .text, .c = [4]f32{ 0.4, 0.4, 0.4, 1.0 } });
                _ = zgui.button("< Prev", .{ .w = btn_w, .h = btn_h });
                zgui.popStyleColor(.{ .count = 1 });
            }

            zgui.sameLine(.{ .spacing = group_spacing });
            zgui.setCursorPosY(row_y + (btn_h - page_text_size[1]) * 0.5);
            zgui.text("{s}", .{page_text});
            zgui.sameLine(.{ .spacing = group_spacing });
            zgui.setCursorPosY(row_y);

            if (app_state.current_page < total_pages - 1) {
                if (zgui.button("Next >", .{ .w = btn_w, .h = btn_h })) {
                    app_state.current_page += 1;
                }
            } else {
                zgui.pushStyleColor4f(.{ .idx = .text, .c = [4]f32{ 0.4, 0.4, 0.4, 1.0 } });
                _ = zgui.button("Next >", .{ .w = btn_w, .h = btn_h });
                zgui.popStyleColor(.{ .count = 1 });
            }

            zgui.popStyleColor(.{ .count = 3 });
        }
    }
}

fn renderCard(app_state: *AppState, s: script_mod.Script, card_meta: ?*const app_mod.CardMeta, script_idx: usize, card_width: f32, card_height: f32) void {
    const draw_list = zgui.getWindowDrawList();
    const cursor_pos = zgui.getCursorScreenPos();
    const shadow_offset: f32 = 4.0;
    const shadow_color = zgui.colorConvertFloat4ToU32([4]f32{ 0.0, 0.0, 0.0, 0.40 });

    draw_list.addRectFilled(.{
        .pmin = [2]f32{ cursor_pos[0] + shadow_offset, cursor_pos[1] + shadow_offset },
        .pmax = [2]f32{ cursor_pos[0] + card_width + shadow_offset, cursor_pos[1] + card_height + shadow_offset },
        .col = shadow_color,
        .rounding = 8.0,
    });

    var card_id_buf: [32:0]u8 = undefined;
    const card_id = std.fmt.bufPrintZ(&card_id_buf, "##card_{d}", .{script_idx}) catch "##card";

    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = [4]f32{ 0.090, 0.086, 0.082, 1.0 } });
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 8.0 });
    defer zgui.popStyleColor(.{ .count = 1 });
    defer zgui.popStyleVar(.{ .count = 1 });

    if (zgui.beginChild(card_id, .{ .w = card_width, .h = card_height })) {
        const win_pos = zgui.getWindowPos();
        const win_size = zgui.getWindowSize();
        const content_start = zgui.getCursorPos();
        const hit_size = zgui.getContentRegionAvail();

        var hit_id_buf: [40:0]u8 = undefined;
        const hit_id = std.fmt.bufPrintZ(&hit_id_buf, "##card_hit_{d}", .{script_idx}) catch "##card_hit";
        _ = zgui.invisibleButton(hit_id, .{ .w = hit_size[0], .h = hit_size[1] });
        const is_hovered = zgui.isItemHovered(.rect_only);
        const right_clicked = zgui.isItemClicked(.right);
        const left_double_clicked = is_hovered and zgui.isMouseDoubleClicked(.left);
        zgui.setCursorPos(content_start);

        if (is_hovered) {
            const card_draw = zgui.getWindowDrawList();
            const hover_color = zgui.colorConvertFloat4ToU32([4]f32{ 0.137, 0.129, 0.118, 1.0 });
            card_draw.addRectFilled(.{
                .pmin = win_pos,
                .pmax = [2]f32{ win_pos[0] + win_size[0], win_pos[1] + win_size[1] },
                .col = hover_color,
                .rounding = 8.0,
            });
        }

        // 右键菜单
        var popup_id_buf: [56:0]u8 = undefined;
        const popup_id = std.fmt.bufPrintZ(&popup_id_buf, "CardContext##ctx_{d}", .{script_idx}) catch "CardContext";
        const popup_margin: f32 = 8.0;
        const popup_label = "Remove from zScripts";
        const popup_label_w = zgui.calcTextSize(popup_label, .{})[0] * 1.18;
        const popup_w = @min(card_width - popup_margin * 2.0, @max(220.0, popup_label_w + 44.0));
        const popup_h: f32 = 58.0;
        const popup_x = @max(win_pos[0] + popup_margin, win_pos[0] + win_size[0] - popup_w - popup_margin);
        const popup_y = @max(win_pos[1] + popup_margin, win_pos[1] + win_size[1] - popup_h - popup_margin);
        if (right_clicked) {
            zgui.openPopup(popup_id, .{});
            app_state.requestExtraFrames(2);
        }
        zgui.setNextWindowPos(.{ .x = popup_x, .y = popup_y, .cond = .always });
        zgui.setNextWindowSize(.{ .w = popup_w, .h = 0.0, .cond = .always });
        if (zgui.beginPopup(popup_id, .{})) {
            defer zgui.endPopup();
            zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ 14.0, 10.0 } });
            zgui.pushStyleVar2f(.{ .idx = .selectable_text_align, .v = [2]f32{ 0.5, 0.5 } });
            zgui.setWindowFontScale(1.18);
            defer zgui.popStyleVar(.{ .count = 2 });
            defer zgui.setWindowFontScale(1.0);
            if (zgui.selectable(popup_label, .{ .h = 40 })) {
                app_state.requestRemoveScript(s.path, s.name) catch {};
            }
        }

        // 卡片信息区
        const content_top = @max(18.0, card_height * 0.16);
        const content_bottom_margin = @max(14.0, card_height * 0.08);
        const row_step = @max(26.0, (card_height - content_top - content_bottom_margin) / 3.0);

        zgui.setCursorPosY(content_top);
        zgui.setWindowFontScale(1.38);
        drawCenteredTextColored(if (card_meta) |meta| meta.title_line else s.name, [4]f32{ 0.925, 0.914, 0.890, 1.0 });
        if (card_meta) |meta| {
            if (meta.title_tooltip) |tt| showItemTooltip(tt);
        }
        zgui.setWindowFontScale(1.0);

        zgui.setCursorPosY(content_top + row_step);
        zgui.setWindowFontScale(1.16);
        if (card_meta) |meta| {
            drawCenteredTextColored(meta.desc_line, if (meta.has_desc) [4]f32{ 0.655, 0.624, 0.584, 1.0 } else [4]f32{ 0.545, 0.522, 0.490, 1.0 });
            if (meta.desc_tooltip) |tt| showItemTooltip(tt);
        } else {
            drawCenteredTextColored("No description", [4]f32{ 0.545, 0.522, 0.490, 1.0 });
        }
        zgui.setWindowFontScale(1.0);

        zgui.setCursorPosY(content_top + row_step * 2.0);
        zgui.setWindowFontScale(1.08);
        if (card_meta) |meta| {
            drawCenteredTextColored(meta.command_line, [4]f32{ 0.545, 0.522, 0.490, 1.0 });
            if (meta.command_tooltip) |tt| showItemTooltip(tt);
        } else {
            drawCenteredTextColored("$", [4]f32{ 0.545, 0.522, 0.490, 1.0 });
        }
        zgui.setWindowFontScale(1.0);

        zgui.setCursorPosY(content_top + row_step * 3.0);
        zgui.setWindowFontScale(1.12);
        if (card_meta) |meta| {
            drawCenteredTextColored(meta.param_line, if (meta.has_params) [4]f32{ 0.541, 0.659, 0.745, 1.0 } else [4]f32{ 0.545, 0.522, 0.490, 1.0 });
            if (meta.param_tooltip) |tt| showItemTooltip(tt);
        } else {
            drawCenteredTextColored("No params", [4]f32{ 0.545, 0.522, 0.490, 1.0 });
        }
        zgui.setWindowFontScale(1.0);

        if (left_double_clicked) {
            app_state.openScriptTab(s.path, s.name) catch {};
        }
    }
    zgui.endChild();
}

fn importPathsFromPicker(app_state: *AppState, picker_type: file_picker.PickerType, is_directory: bool) void {
    const picker_result_opt = file_picker.showFilePicker(app_state.allocator, picker_type) catch |err| {
        var msg_buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Import failed: {s}", .{@errorName(err)}) catch "Import failed";
        app_state.showErrorToast(msg);
        return;
    };
    if (picker_result_opt) |result| {
        var picker_result = result;
        defer picker_result.deinit();

        const scripts_before = app_state.scanner.getScripts().len;
        var added_paths_count: usize = 0;
        for (picker_result.paths) |path| {
            const added = app_state.addPathIfMissing(path, is_directory) catch |err| {
                var msg_buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Import failed: {s}", .{@errorName(err)}) catch "Import failed";
                app_state.showErrorToast(msg);
                return;
            };
            if (added) added_paths_count += 1;
        }

        if (added_paths_count == 0) return;

        app_state.refreshScripts() catch |err| {
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Refresh failed: {s}", .{@errorName(err)}) catch "Refresh failed";
            app_state.showErrorToast(msg);
            return;
        };
        app_state.current_page = 0;
        saveAddedPaths(app_state) catch |err| {
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Save paths failed: {s}", .{@errorName(err)}) catch "Save paths failed";
            app_state.showErrorToast(msg);
            return;
        };

        const scripts_after = app_state.scanner.getScripts().len;
        const imported_scripts = if (scripts_after > scripts_before) scripts_after - scripts_before else 0;
        var success_buf: [96]u8 = undefined;
        const success_msg = if (imported_scripts > 0)
            std.fmt.bufPrint(&success_buf, "Imported {d} scripts", .{imported_scripts}) catch "Import complete"
        else
            std.fmt.bufPrint(&success_buf, "Imported {d} paths", .{added_paths_count}) catch "Import complete";
        app_state.showSuccessToast(success_msg);
    }
}

pub fn saveAddedPaths(app_state: *AppState) !void {
    var paths = std.ArrayList(config.PathConfig).init(app_state.allocator);
    defer paths.deinit();

    for (app_state.added_paths.items) |entry| {
        paths.append(.{
            .path = entry.path,
            .is_directory = entry.is_directory,
        }) catch continue;
    }

    try app_state.config_manager.savePaths(paths.items);
}

/// 大小写不敏感的子串匹配
fn matchesSearch(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (text.len < query.len) return false;

    const end = text.len - query.len + 1;
    for (0..end) |i| {
        var matched = true;
        for (0..query.len) |j| {
            if (std.ascii.toLower(text[i + j]) != std.ascii.toLower(query[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}
