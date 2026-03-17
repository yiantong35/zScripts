# zScripts

`zScripts` 是一个 macOS 桌面应用，用来管理和执行 Python / Shell 自动化脚本。  
项目基于 Zig 0.14 + zgui（ImGui）构建，当前默认可产出 macOS `.app` bundle。

## 功能

- 首页 4×3 卡片网格，支持分页、搜索、卡片 hover 提示
- 双击卡片打开脚本页，右键卡片可 `Remove from zScripts`
- 脚本页支持编辑描述、命令、参数，并可运行 / 停止 / 保存 / 删除
- 输出区支持 `Show Full / Show Tail`、清空、复制、自动滚动
- 参数超过 4 个时，首页摘要保持精简，hover 可查看完整参数
- 原生 macOS 文件选择器（`NSOpenPanel`）
- 软删除脚本：仅从 zScripts 隐藏，不删除磁盘文件
- 启动优先走扫描缓存，减少二次启动扫描时间
- 支持中文输入和显示
- 提供 macOS `.app` 打包与自定义应用图标

## 构建与运行

### 前置条件

- macOS
- Zig 0.14.1
- Xcode Command Line Tools

```bash
brew install zig@0.14
```

建议确保 Zig 0.14 在 PATH 中：

```bash
export PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH"
```

### 构建

```bash
zig build
```

构建完成后会得到：

- 可执行文件：`zig-out/bin/zScripts`
- macOS App：`zig-out/zScripts.app`

### 运行

开发运行：

```bash
zig build run
```

以 App 形式打开：

```bash
open zig-out/zScripts.app
```

### 测试

```bash
zig build test
```

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd+1` ~ `Cmd+9` | 切换到对应标签页 |

## 数据存储

配置目录位于：

```text
~/.zscripts/
```

主要文件：

- `paths.json`：已添加的目录 / 文件路径
- `scripts.json`：脚本描述、命令、参数配置
- `hidden_scripts.json`：软删除隐藏列表
- `history.json`：最近执行历史
- `scan_index.json`：扫描结果缓存
- `perf.jsonl`：性能日志（开启 Perf Log 时）

## 技术栈

- Zig 0.14.1
- zgui 0.6.0-dev
- zglfw 0.10.0-dev
- zopengl 0.6.0-dev
- OpenGL 3.3 Core Profile
- Objective-C `NSOpenPanel`

## 项目结构

```text
src/
├── main.zig
├── core/
│   ├── executor.zig
│   ├── file_picker.m
│   ├── file_picker.zig
│   ├── perf_monitor.zig
│   ├── scanner.zig
│   └── script.zig
├── gui/
│   ├── app.zig
│   ├── components/
│   │   ├── card.zig
│   │   ├── execution_view.zig
│   │   ├── home_page.zig
│   │   └── script_editor.zig
│   └── utils/
│       ├── layout.zig
│       └── text_utils.zig
└── storage/
    └── config.zig

tools/
└── generate_app_icon.swift
```

说明：

- 单元测试文件按模块放在源码旁边，命名为 `*_test.zig`
- `tools/generate_app_icon.swift` 是 macOS `.app` 图标生成脚本，属于构建所需文件

## 当前状态

目前项目已可日常使用，适合：

- 管理一批本地 Python / Shell 脚本
- 为脚本保存参数模板
- 直接在桌面 GUI 中运行并查看输出

## License

MIT
