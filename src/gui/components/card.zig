/// 卡片组件 - CardMeta 构建逻辑
const std = @import("std");
const app_mod = @import("../app.zig");
const script_mod = @import("../../core/script.zig");
const config = @import("../../storage/config.zig");
const text_utils = @import("../utils/text_utils.zig");

pub const CardMeta = app_mod.CardMeta;

const truncateText = text_utils.truncateText;
const buildParamSummary = text_utils.buildParamSummary;
const buildParamTooltip = text_utils.buildParamTooltip;
const buildCommandPreview = text_utils.buildCommandPreview;
const duplicateOptionalText = text_utils.duplicateOptionalText;

pub fn buildCardMeta(allocator: std.mem.Allocator, s: *const script_mod.Script, script_config: ?*const config.ScriptConfig) !CardMeta {
    var meta = CardMeta{
        .title_line = try allocator.dupe(u8, ""),
        .title_tooltip = null,
        .desc_line = try allocator.dupe(u8, ""),
        .desc_tooltip = null,
        .has_desc = false,
        .command_line = try allocator.dupe(u8, ""),
        .command_tooltip = null,
        .param_line = try allocator.dupe(u8, ""),
        .param_tooltip = null,
        .has_params = false,
        .allocator = allocator,
    };
    errdefer meta.deinit();

    var title_preview_buf: [96]u8 = undefined;
    const title_preview = truncateText(s.name, 32, &title_preview_buf);
    allocator.free(meta.title_line);
    meta.title_line = try allocator.dupe(u8, title_preview.text);
    meta.title_tooltip = try duplicateOptionalText(allocator, if (title_preview.truncated) s.name else null);

    var desc_text: []const u8 = "No description";
    if (script_config) |cfg| {
        if (cfg.description.len > 0) {
            desc_text = cfg.description;
            meta.has_desc = true;
        }
    }
    var desc_preview_buf: [120]u8 = undefined;
    const desc_preview = truncateText(desc_text, 52, &desc_preview_buf);
    allocator.free(meta.desc_line);
    meta.desc_line = try allocator.dupe(u8, desc_preview.text);
    meta.desc_tooltip = try duplicateOptionalText(allocator, if (desc_preview.truncated) desc_text else null);

    const cmd = if (script_config) |cfg| cfg.command else "";
    if (cmd.len > 0) {
        var cmd_source_buf: [220]u8 = undefined;
        const cmd_source = buildCommandPreview(cmd, &cmd_source_buf);
        var cmd_preview_buf: [180]u8 = undefined;
        const cmd_preview = truncateText(cmd_source, 46, &cmd_preview_buf);
        var cmd_display_buf: [200]u8 = undefined;
        const cmd_display = std.fmt.bufPrint(&cmd_display_buf, "$ {s}", .{cmd_preview.text}) catch cmd_preview.text;
        allocator.free(meta.command_line);
        meta.command_line = try allocator.dupe(u8, cmd_display);
        const has_cmd_tooltip = cmd_preview.truncated or !std.mem.eql(u8, cmd_source, cmd);
        meta.command_tooltip = try duplicateOptionalText(allocator, if (has_cmd_tooltip) cmd else null);
    } else {
        allocator.free(meta.command_line);
        meta.command_line = try allocator.dupe(u8, "No command");
        meta.command_tooltip = null;
    }

    var param_text: []const u8 = "No params";
    if (script_config) |cfg| {
        if (cfg.parameters.len > 0) {
            var param_summary_buf: [220]u8 = undefined;
            const param_summary = buildParamSummary(allocator, cfg.parameters, &param_summary_buf);
            if (param_summary.len > 0) {
                param_text = param_summary;
                meta.has_params = true;
            }
            meta.param_tooltip = try buildParamTooltip(allocator, cfg.parameters);
        }
    }
    var param_preview_buf: [120]u8 = undefined;
    const param_preview = truncateText(param_text, 88, &param_preview_buf);
    allocator.free(meta.param_line);
    meta.param_line = try allocator.dupe(u8, param_preview.text);
    if (meta.param_tooltip == null) {
        meta.param_tooltip = try duplicateOptionalText(allocator, if (param_preview.truncated) param_text else null);
    }

    return meta;
}
