# zScripts

macOS 桌面应用，用于管理和执行 Python / Shell 自动化脚本。基于 Zig 0.14 + zgui (ImGui) 构建。

## 功能

- 卡片式首页，4×3 网格展示脚本，支持分页
- 双击卡片打开脚本标签页，编辑描述、命令、参数
- 非阻塞脚本执行，实时输出捕获
- 执行命令完全自定义，用户可自由配置任意命令和参数
- 原生 macOS 文件选择器（NSOpenPanel）
- Cmd+1~9 快捷键切换标签页
- JSON 持久化配置（`~/.zscripts/`）

## 截图

（待添加）

## 构建与运行

### 前置条件

- Zig 0.14.1（不兼容 0.15+）
- Git LFS
- macOS

```bash
# 安装 Zig 0.14
brew install zig@0.14

# 安装 Git LFS
brew install git-lfs && git lfs install
```

### 构建

```bash
export PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH"
zig build
```

首次构建约 5-10 分钟（编译所有依赖）。

### 运行

```bash
zig build run
```

### 测试

```bash
zig build test
```

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| Cmd+1~9 | 切换到对应标签页 |

## 技术栈

- **语言：** Zig 0.14.1
- **GUI：** zgui 0.6.0-dev（ImGui 绑定）
- **窗口：** zglfw 0.10.0-dev（GLFW 绑定）
- **渲染：** zopengl 0.6.0-dev（OpenGL 3.3 Core Profile）
- **文件选择器：** Objective-C（NSOpenPanel）

## 项目结构

```
src/
├── main.zig              # 应用入口，初始化，事件循环
├── core/
│   ├── script.zig        # 脚本数据模型
│   ├── executor.zig      # 脚本执行引擎
│   ├── scanner.zig       # 目录扫描器
│   ├── perf_monitor.zig  # 性能监控
│   ├── file_picker.zig   # 文件选择器 Zig 封装
│   └── file_picker.m     # Objective-C NSOpenPanel 实现
├── gui/
│   └── app.zig           # 主 GUI 逻辑，标签管理，UI 渲染
└── storage/
    └── config.zig        # JSON 持久化
```


## License

MIT
