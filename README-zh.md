# Mac Lite Translator for TranslateGemma

[English](README.md)

这是一个原生 macOS 翻译器，提供三种可切换后端：**OS**（Apple 系统翻译）、**LLM**（本地 TranslateGemma MLX 模型）和 **Cloud**（Google、Bing、DeepL 云端回退）。它适合配合 macOS 快捷指令使用，并在一个 App 进程内管理后端实例。

## 主要特性

![Light UI](Screenshots/Light_UI.png)

![Full UI](Screenshots/AppKit_GUI.png)

- 原生 AppKit 界面，支持浅色/深色外观。
- Full UI 可在 OS 系统翻译、本地 LLM 与云端翻译之间切换。
- OS 模式使用 Apple Translation framework 与已下载的系统语言包；云端模式全部失败时，会在可用条件下回退到系统翻译。
- 云端支持 Google、Bing、DeepL，无需 API Key，并可在设置中调整服务回退顺序。
- 运行时切换 OS/LLM/Cloud；本地 LLM 加载后会驻留到 App 退出。
- `--light` 可打开不显示 Dock 图标的轻量动画浮窗，并可切换到 Full UI。
- 适配 macOS 快捷指令，可通过服务菜单或键盘快捷键发送选中文本。
- 单实例运行：重复调用快捷指令会复用已经打开的窗口和后端，不会再次加载一份模型。
- 自动检测原文语言，并自动切换目标语言。
- 支持 Default、Academic、Web Chat、Casual、Dictionary 等翻译风格。
- GUI 支持英文和简体中文，Auto 模式会跟随系统语言。
- 设置可选择默认启动方式；原生“关于”面板提供随界面语言变化的 Credits 与项目链接。

## 系统要求

- Apple Silicon Mac。
- 使用 OS 系统翻译需要 macOS 15 或更高版本；维护中的 App 构建仍面向 Apple Silicon。
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
4. 可选：设置默认启动方式（OS、LLM、Cloud 或指定云端服务）、云端回退顺序、母语、主要外语和 GUI 语言。

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

常用启动参数：

```bash
# 使用设置中的云端提供商启动
'outputs/Translate Text.app/Contents/MacOS/Translate Text' --cloud "Hello world"

# 强制使用 macOS 系统翻译或本地 LLM
'outputs/Translate Text.app/Contents/MacOS/Translate Text' --os "Hello world"
'outputs/Translate Text.app/Contents/MacOS/Translate Text' --llm "Hello world"

# 使用轻量浮窗启动
'outputs/Translate Text.app/Contents/MacOS/Translate Text' --light "Hello world"

# 指定后端
'outputs/Translate Text.app/Contents/MacOS/Translate Text' --backend google "Hello world"
'outputs/Translate Text.app/Contents/MacOS/Translate Text' --backend bing "Hello world"
'outputs/Translate Text.app/Contents/MacOS/Translate Text' --backend llm "Hello world"
```

Finder 或快捷指令通过 `open` 启动时同样支持这些参数：

```bash
/usr/bin/open -n '/Applications/Translate Text.app' --args --light --llm "$1"
```

不提供后端参数时，App 会使用设置中的默认启动方式；已有实例运行时，新请求会先切换真实后端，再翻译新文本。

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
  TRANSLATEKIT_LICENSE.txt          Light UI 使用的 TranslateKit 许可说明
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

**OS 模式是否完全离线？**

下载所需的 Apple 翻译语言包后，译文通过系统框架在设备上生成。某个语言组合首次使用时，系统可能要求联网下载并请求授权。可在“系统设置 → 通用 → 语言与地区 → 翻译语言”管理已下载的语言包。

**需要多少内存？**

如果使用 `translategemma-12b-it-4bit`，建议 16GB 或更高统一内存。模型会占用数 GB 内存。App 使用单实例锁和单一后端进程，重复快捷指令调用以及切换云端后都会复用驻留的本地模型，不会反复加载多份模型。

**支持图片或多模态翻译吗？**

不支持。当前版本是纯文本翻译，重点是快速、流式、本地运行。

**可以改用 Ollama 吗？**

当前版本不支持。后端基于 `mlx-lm`，因为它在 Apple Silicon 上效率更高，也适合这个流式翻译工作流。

**支持 Windows 或 Linux 吗？**

不支持。当前维护版是 macOS AppKit App，并且集成目标是 macOS 快捷指令。翻译后端是 Python，但 App 外壳是 macOS 专用的。

## License

MIT
