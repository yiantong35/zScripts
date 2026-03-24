const std = @import("std");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const app = @import("gui/app.zig");

/// 全局窗口引用，供信号处理使用
var global_window: ?*zglfw.Window = null;
/// 全局 AppState 引用，供 GLFW key callback 使用
var global_app_state: ?*app.AppState = null;

/// SIGINT 处理：通知窗口正常关闭，而不是直接杀进程
fn handleSigint(_: c_int) callconv(.C) void {
    if (global_window) |w| {
        w.setShouldClose(true);
    }
}

/// GLFW key callback：捕获 Cmd+数字 切换标签页
fn handleKeyInput(_: *zglfw.Window, key: zglfw.Key, _: c_int, action: zglfw.Action, mods: zglfw.Mods) callconv(.c) void {
    // 任何键盘活动都标记为输入活跃
    if (global_app_state) |s| {
        if (action == .press or action == .repeat) {
            s.noteInputActivity();
        }
    }
    if (action != .press) return;
    if (!mods.super) return;
    const number_keys = [_]zglfw.Key{ .one, .two, .three, .four, .five, .six, .seven, .eight, .nine };
    for (number_keys, 0..) |nk, idx| {
        if (key == nk) {
            if (global_app_state) |s| {
                s.pending_shortcut_tab = idx;
                s.requestExtraFrames(3);
            }
            return;
        }
    }
}

pub fn main() !void {
    // 初始化 GLFW
    try zglfw.init();
    defer zglfw.terminate();

    // 设置 OpenGL 版本
    zglfw.windowHint(.context_version_major, 3);
    zglfw.windowHint(.context_version_minor, 3);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.opengl_forward_compat, true);
    zglfw.windowHint(.visible, false); // 先隐藏窗口，渲染完第一帧再显示

    // 创建窗口
    const window = try zglfw.createWindow(1280, 720, "zScripts", null);
    defer zglfw.destroyWindow(window);

    // 注册 SIGINT 处理，Ctrl+C 触发正常退出流程
    global_window = window;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    zglfw.makeContextCurrent(window);
    zglfw.swapInterval(1); // 启用垂直同步

    // 加载 OpenGL 函数指针
    try zopengl.loadCoreProfile(zglfw.getProcAddress, 3, 3);
    const gl = zopengl.bindings;

    // 初始化内存分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化 zgui
    zgui.init(allocator);
    defer zgui.deinit();

    // 加载 Monaco 字体
    const font_path = "/System/Library/Fonts/Monaco.ttf";
    const font_size = 22.0; // 增加到 22px
    _ = zgui.io.addFontFromFile(font_path, font_size);

    // 合并中文字体（STHeiti Medium），支持中文显示和输入
    var cjk_config = zgui.FontConfig.init();
    cjk_config.merge_mode = true;
    _ = zgui.io.addFontFromFileWithConfig(
        "/System/Library/Fonts/STHeiti Medium.ttc",
        font_size,
        cjk_config,
        zgui.io.getGlyphRangesChineseSimplifiedCommon(),
    );

    // 设置全局缩放
    const scale_factor: f32 = 1.5;
    zgui.getStyle().scaleAllSizes(scale_factor);

    // 设置纯黑主题
    const style = zgui.getStyle();

    // 背景色 - 黑 + 暖灰
    style.setColor(.window_bg, [4]f32{ 0.043, 0.043, 0.047, 1.0 });
    style.setColor(.child_bg, [4]f32{ 0.090, 0.086, 0.082, 1.0 });
    style.setColor(.popup_bg, [4]f32{ 0.090, 0.086, 0.082, 1.0 });

    // 文字颜色
    style.setColor(.text, [4]f32{ 0.925, 0.914, 0.890, 1.0 });
    style.setColor(.text_disabled, [4]f32{ 0.655, 0.624, 0.584, 1.0 });

    // 去掉所有边框和分隔线
    style.setColor(.border, [4]f32{ 0.0, 0.0, 0.0, 0.0 });
    style.setColor(.separator, [4]f32{ 0.0, 0.0, 0.0, 0.0 });

    // 设置边框宽度为0
    style.window_border_size = 0.0;
    style.child_border_size = 0.0;
    style.popup_border_size = 0.0;
    style.frame_border_size = 0.0;
    style.tab_border_size = 0.0;

    // 输入框和框架
    style.setColor(.frame_bg, [4]f32{ 0.106, 0.102, 0.094, 1.0 });
    style.setColor(.frame_bg_hovered, [4]f32{ 0.137, 0.129, 0.118, 1.0 });
    style.setColor(.frame_bg_active, [4]f32{ 0.165, 0.153, 0.137, 1.0 });

    // 按钮和标题
    style.setColor(.button, [4]f32{ 0.145, 0.137, 0.129, 1.0 });
    style.setColor(.button_hovered, [4]f32{ 0.188, 0.176, 0.165, 1.0 });
    style.setColor(.button_active, [4]f32{ 0.227, 0.212, 0.196, 1.0 });
    style.setColor(.header, [4]f32{ 0.129, 0.122, 0.110, 1.0 });
    style.setColor(.header_hovered, [4]f32{ 0.165, 0.153, 0.137, 1.0 });
    style.setColor(.header_active, [4]f32{ 0.188, 0.176, 0.165, 1.0 });

    // 标签页 - tab_selected 设为背景色以隐藏装饰线
    style.setColor(.tab, [4]f32{ 0.090, 0.086, 0.082, 1.0 });
    style.setColor(.tab_hovered, [4]f32{ 0.145, 0.137, 0.129, 1.0 });
    style.setColor(.tab_selected, [4]f32{ 0.043, 0.043, 0.047, 1.0 });
    style.setColor(.tab_dimmed, [4]f32{ 0.071, 0.067, 0.063, 1.0 });
    style.setColor(.tab_dimmed_selected, [4]f32{ 0.106, 0.102, 0.094, 1.0 });

    // 装饰线设为透明
    style.setColor(.tab_selected_overline, [4]f32{ 0.0, 0.0, 0.0, 0.0 });
    style.setColor(.tab_dimmed_selected_overline, [4]f32{ 0.0, 0.0, 0.0, 0.0 });

    // 标题栏
    style.setColor(.title_bg, [4]f32{ 0.090, 0.086, 0.082, 1.0 });
    style.setColor(.title_bg_active, [4]f32{ 0.129, 0.122, 0.110, 1.0 });
    style.setColor(.title_bg_collapsed, [4]f32{ 0.071, 0.067, 0.063, 1.0 });

    // 注册 Cmd+数字 快捷键回调（必须在 zgui.backend.init 之前，ImGui 会链式调用）
    _ = window.setKeyCallback(handleKeyInput);

    // 初始化 zgui backend
    zgui.backend.init(window);
    defer zgui.backend.deinit();

    // 初始化应用状态
    const startup_begin_ns = std.time.nanoTimestamp();
    var app_state = try app.AppState.init(allocator);
    defer app_state.deinit();
    global_app_state = &app_state;
    const startup_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - startup_begin_ns)) / 1_000_000.0;
    app_state.setStartupMs(startup_ms);

    // 主循环
    var first_frame = true;
    while (!window.shouldClose()) {
        const window_focused = window.getAttribute(.focused);

        if (first_frame) {
            zglfw.pollEvents();
        } else if (app_state.needsImmediateRedraw()) {
            // 避免 waitEvents 阻塞导致点击开标签需要额外输入事件才刷新
            zglfw.pollEvents();
        } else if (window_focused and app_state.needsInteractiveIdleRedraw()) {
            // 触摸板轻点/双指点击后保留一个很短的活跃窗口，确保延迟 UI 状态能落到屏幕上
            zglfw.waitEventsTimeout(0.016);
        } else if (app_state.hasRunningScript() or app_state.needsBackgroundTick()) {
            zglfw.waitEventsTimeout(0.05);
        } else {
            zglfw.waitEvents();
        }

        // 清屏 - 纯黑背景
        gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0.043, 0.043, 0.047, 1.0 });

        // 开始新的 zgui 帧
        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(
            @intCast(fb_size[0]),
            @intCast(fb_size[1]),
        );

        const mouse_pos = zgui.getMousePos();
        app_state.updatePointerActivity(mouse_pos);
        if (zgui.isMouseClicked(.left) or zgui.isMouseClicked(.right) or zgui.isMouseReleased(.left) or zgui.isMouseReleased(.right) or zgui.isMouseDown(.left) or zgui.isMouseDown(.right)) {
            app_state.noteInputActivity();
        }

        // 渲染 UI
        const render_begin_ns = std.time.nanoTimestamp();
        renderUI(&app_state);
        const render_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - render_begin_ns)) / 1_000_000.0;
        app_state.recordFrameMetrics(render_ms);
        app_state.flushBackgroundTasks();
        app_state.consumeExtraFrame();

        // 渲染 zgui
        zgui.backend.draw();

        window.swapBuffers();

        // 第一帧渲染完成后再显示窗口，避免黑屏闪烁
        if (first_frame) {
            window.show();
            first_frame = false;
        }
    }
}

fn renderUI(app_state: *app.AppState) void {
    // 创建全屏窗口
    const viewport = zgui.getMainViewport();
    const viewport_pos = viewport.getPos();
    const viewport_size = viewport.getSize();

    zgui.setNextWindowPos(.{ .x = viewport_pos[0], .y = viewport_pos[1] });
    zgui.setNextWindowSize(.{ .w = viewport_size[0], .h = viewport_size[1] });

    const window_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
        .no_bring_to_front_on_focus = true,
        .no_scrollbar = true,
        .no_scroll_with_mouse = true,
        .no_background = false,
    };

    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = 0.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = [2]f32{ 0.0, 0.0 } });
    defer zgui.popStyleVar(.{ .count = 2 });

    if (zgui.begin("MainWindow", .{ .flags = window_flags })) {
        defer zgui.end();

        // 添加一些内边距
        zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = [2]f32{ 10.0, 10.0 } });
        defer zgui.popStyleVar(.{ .count = 1 });

        // 渲染标签栏
        app_state.renderTabBar();

        zgui.spacing();

        // 渲染当前活动标签的内容
        app_state.renderActiveTab();
    }

    app_state.renderOverlays();
}
