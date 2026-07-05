# Mac Lite Translator for TranslateGemma

[English](README.md)

这是一个面向本地 **TranslateGemma** MLX 模型的原生 macOS 翻译 App。它适合配合 macOS 快捷指令使用，从任意 App 选中文字后快速翻译，并且保证模型在内存中只加载一次。

## 主要特性

![AppKit GUI](Screenshots/AppKit_GUI.png)

- 原生 AppKit 界面，支持浅色/深色外观。
- 使用 `mlx-lm` 在本地翻译；模型下载后无需 API Key、无需联网请求。
- 适配 macOS 快捷指令，可通过服务菜单或键盘快捷键发送选中文本。
- 单实例运行：重复调用快捷指令会复用已经打开的窗口和后端，不会再次加载一份模型。
- 自动检测原文语言，并自动切换目标语言。
- 支持 Default、Academic、Web Chat、Casual、Dictionary 等翻译风格。
- GUI 支持英文和简体中文，Auto 模式会跟随系统语言。

## 系统要求

- Apple Silicon Mac。
- macOS 13 或更高版本。
- Python 3.10+，并安装 `mlx-lm`。
- 本地 TranslateGemma MLX 模型文件夹，例如 `translategemma-12b-it-4bit`。
- 12B 4-bit 模型建议使用 16GB 或更高统一内存。

## 安装依赖

在你希望 App 使用的 Python 环境中安装依赖：

```bash
pip install -r requirements.txt
```

如果依赖安装在非默认 Python 环境中，可以在快捷指令启动 App 时设置 `TRANSLATE_TEXT_PYTHON`。

## 构建 App

```bash
python3 App/build_app.py
```

构建后的 App 位于：

```text
outputs/Translate Text.app
```

你也可以移动到 `/Applications`：

```bash
cp -R "outputs/Translate Text.app" /Applications/
```

## 首次启动

1. 打开 `Translate Text.app`。
2. 从菜单栏打开 `Settings...` / `设置`。
3. 选择你的本地 TranslateGemma 模型文件夹。
4. 可选：设置母语、主要外语和 GUI 语言。

本仓库不会写入任何个人默认模型路径。首次使用时必须在设置里选择模型文件夹。

## 配合 macOS 快捷指令使用

创建一个快捷指令，让它从快速操作或共享表单接收 **文本**，然后添加 **运行 Shell 脚本** 动作，并将输入设置为 **作为参数**。

如果 App 放在 `/Applications`，脚本示例：

```bash
'/Applications/Translate Text.app/Contents/MacOS/Translate Text' "$1" >/dev/null 2>&1 &
```

如果你的 Python 依赖位于特定环境中，可以显式指定 Python：

```bash
export TRANSLATE_TEXT_PYTHON="/path/to/your/python"
'/Applications/Translate Text.app/Contents/MacOS/Translate Text' "$1" >/dev/null 2>&1 &
```

这里推荐直接调用 App 内的可执行文件，而不是只用 `open -a`。这样在 App 已经打开时，新的快捷指令调用会把文本转发给已有实例并立即退出，不会再次加载模型。

## 命令行运行

```bash
'outputs/Translate Text.app/Contents/MacOS/Translate Text' "Hello world"
```

## 支持语言

当前 GUI 内置：

- 简体中文
- 繁體中文
- English
- 日本語
- 한국어
- Français
- Deutsch
- Italiano
- Español
- Русский
- Português
- العربية
- हिन्दी
- Malti

TranslateGemma 模型本身可能支持更多语言。如果需要扩展语言列表，可以修改 `App/Sources/TranslateText.swift` 和 `App/Workers/translate_text_worker.py`。

## 项目结构

```text
App/
  Sources/TranslateText.swift       原生 macOS App
  Workers/translate_text_worker.py  MLX 翻译后端
  build_app.py                      App 打包脚本
assets/
  translator.icns
legacy/tk/
  translate.py                      已归档的 Tkinter 旧版
Screenshots/
```

## 旧版 Tkinter 实现

原始 Python/Tkinter 版本保留在 `legacy/tk/`，仅作为历史参考。当前维护版本是 Swift AppKit 原生 App。旧版演示视频保留在 `legacy/tk/README.md`。

## FAQ

**模型从哪里下载？**

请从 Hugging Face 或你常用的模型管理器下载 TranslateGemma MLX 模型，然后在设置里选择本地模型文件夹。本仓库不包含模型权重。

**为什么需要手动选择模型路径？**

模型文件夹很大，而且路径和每台机器有关。开源版不会内置任何个人默认路径。你选择后，路径会保存在本机的 macOS UserDefaults 中。

**需要多少内存？**

如果使用 `translategemma-12b-it-4bit`，建议 16GB 或更高统一内存。模型会占用数 GB 内存。App 已加入单实例锁，重复快捷指令调用会复用同一个已加载模型，不会反复加载多份模型。

**支持图片或多模态翻译吗？**

不支持。当前版本是纯文本翻译，重点是快速、流式、本地运行。

**可以改用 Ollama 吗？**

当前版本不支持。后端基于 `mlx-lm`，因为它在 Apple Silicon 上效率更高，也适合这个流式翻译工作流。

**支持 Windows 或 Linux 吗？**

不支持。当前维护版是 macOS AppKit App，并且集成目标是 macOS 快捷指令。翻译后端是 Python，但 App 外壳是 macOS 专用的。

## License

MIT
