import AppKit
import UniformTypeIdentifiers
import Darwin

struct Language {
    let name: String
    let code: String
}

let singleInstanceNotificationName = Notification.Name("local.shortcut-translate-text.open-request")
let defaultNativeLanguage = "简体中文"
let defaultPrimaryForeignLanguage = "English"
let defaultModelPath = ""
let guiLanguageOptions = ["Auto", "English", "简体中文"]
let languages: [Language] = [
    Language(name: "简体中文", code: "zh"),
    Language(name: "繁體中文", code: "zh-Hant"),
    Language(name: "English", code: "en"),
    Language(name: "日本語", code: "ja"),
    Language(name: "한국어", code: "ko"),
    Language(name: "Français", code: "fr"),
    Language(name: "Deutsch", code: "de"),
    Language(name: "Italiano", code: "it"),
    Language(name: "Español", code: "es"),
    Language(name: "Русский", code: "ru"),
    Language(name: "Português", code: "pt"),
    Language(name: "العربية", code: "ar"),
    Language(name: "हिन्दी", code: "hi"),
    Language(name: "Malti", code: "mt"),
]
let styles = ["Default", "Academic", "Web Chat", "Casual", "Dictionary"]

func readLaunchText() -> String {
    let args = CommandLine.arguments.dropFirst()
    if !args.isEmpty {
        return args.joined(separator: " ")
    }
    return "Hello, waiting for input..."
}

final class SingleInstanceLock {
    private var fileDescriptor: Int32 = -1

    func acquire() -> Bool {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("local.shortcut-translate-text.lock")
        fileDescriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { return true }
        if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            return true
        }
        close(fileDescriptor)
        fileDescriptor = -1
        return false
    }

    func forward(text: String) {
        DistributedNotificationCenter.default().postNotificationName(
            singleInstanceNotificationName,
            object: nil,
            userInfo: ["text": text],
            deliverImmediately: true
        )
    }

    deinit {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }
}

final class TranslateTextApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    private var window: NSWindow!
    private var rootView: NSVisualEffectView!
    private var loadingView: NSVisualEffectView!
    private var mainContent: NSStackView!
    private var statusLabel: NSTextField!
    private var loadingStatusLabel: NSTextField!
    private var footerStatusLabel: NSTextField!
    private var loadingProgress: NSProgressIndicator!
    private var footerProgress: NSProgressIndicator!
    private var originalScroll: NSScrollView!
    private var originalTextView: NSTextView!
    private var translationScroll: NSScrollView!
    private var translationTextView: NSTextView!
    private var translationHeaderLabel: NSTextField!
    private var targetPopup: NSPopUpButton!
    private var stylePopup: NSPopUpButton!
    private var expandButton: NSButton!
    private var updateButton: NSButton!
    private var swapButton: NSButton!
    private var stopButton: NSButton!
    private var copyOriginalButton: NSButton!
    private var copyTranslationButton: NSButton!
    private var originalHeightConstraint: NSLayoutConstraint!
    private var settingsPanel: NSPanel?
    private var settingsNativePopup: NSPopUpButton?
    private var settingsForeignPopup: NSPopUpButton?
    private var settingsGuiPopup: NSPopUpButton?
    private var settingsModelField: NSTextField?
    private let instanceLock: SingleInstanceLock

    private var worker: Process?
    private var workerInput: Pipe?
    private var isReady = false
    private var isOriginalExpanded = false
    private var initialText = "Hello, waiting for input..."
    private var lastForeignLanguage: String {
        get { settingString("primaryForeignLanguage", fallback: defaultPrimaryForeignLanguage) }
        set { UserDefaults.standard.set(newValue, forKey: "primaryForeignLanguage") }
    }

    private var nativeLanguage: String {
        settingString("nativeLanguage", fallback: defaultNativeLanguage)
    }

    private var primaryForeignLanguage: String {
        settingString("primaryForeignLanguage", fallback: defaultPrimaryForeignLanguage)
    }

    private var modelPath: String {
        settingString("modelPath", fallback: defaultModelPath)
    }

    private var guiLanguageSetting: String {
        UserDefaults.standard.string(forKey: "guiLanguage") ?? "Auto"
    }

    private var usesChineseUI: Bool {
        let setting = guiLanguageSetting
        if setting == "简体中文" { return true }
        if setting == "English" { return false }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
    }

    private var workerPath: String {
        Bundle.main.path(forResource: "translate_text_worker", ofType: "py") ?? ""
    }

    init(initialText: String, instanceLock: SingleInstanceLock) {
        self.initialText = initialText
        self.instanceLock = instanceLock
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalOpenRequest(_:)),
            name: singleInstanceNotificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        buildWindow()
        buildMenu()
        startWorker()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        sendCommand(["action": "quit"])
        worker?.terminate()
    }

    private func tr(_ key: String) -> String {
        if usesChineseUI {
            switch key {
            case "appTitle": return "翻译文本"
            case "subtitle": return "使用本地 TranslateGemma 模型翻译所选文本。"
            case "loadingTitle": return "正在加载 TranslateGemma"
            case "loadingStatus": return "正在准备本地翻译模型..."
            case "loadingModel": return "正在加载模型..."
            case "originalText": return "原文"
            case "translation": return "译文"
            case "target": return "目标语言"
            case "style": return "风格"
            case "expandOriginal": return "展开原文"
            case "collapseOriginal": return "收起原文"
            case "updateTranslate": return "更新并翻译"
            case "swap": return "交换"
            case "stop": return "停止"
            case "copyOriginal": return "复制原文"
            case "copyTranslation": return "复制译文"
            case "ready": return "就绪"
            case "translating": return "翻译中"
            case "complete": return "完成"
            case "stopped": return "已停止"
            case "failed": return "失败"
            case "backendStopped": return "后端已停止"
            case "detected": return "检测到"
            case "settings": return "设置"
            case "settingsSubtitle": return "配置默认语言、本地模型路径和界面语言。"
            case "guiLanguage": return "界面语言"
            case "nativeLanguage": return "母语"
            case "primaryForeign": return "主要外语"
            case "modelPath": return "模型路径"
            case "browse": return "浏览"
            case "cancel": return "取消"
            case "save": return "保存"
            case "settingsSaved": return "设置已保存"
            case "settingsSavedMessage": return "语言默认值已更新。模型路径和界面语言会在下次启动时生效。"
            case "openTextFile": return "打开文本文件..."
            case "copyOriginalText": return "复制原文"
            case "expandCollapseOriginal": return "展开/收起原文"
            case "swapOriginalTranslation": return "交换原文和译文"
            case "stopTranslation": return "停止翻译"
            case "selectTextFile": return "选择文本文件"
            case "readError": return "读取错误"
            case "warning": return "警告"
            case "emptyOriginal": return "原文为空。"
            default: break
            }
        }
        switch key {
        case "appTitle": return "Translate Text"
        case "subtitle": return "Translate selected text with the local TranslateGemma model."
        case "loadingTitle": return "Loading TranslateGemma"
        case "loadingStatus": return "Preparing local translation model..."
        case "loadingModel": return "Loading model..."
        case "originalText": return "Original Text"
        case "translation": return "Translation"
        case "target": return "Target"
        case "style": return "Style"
        case "expandOriginal": return "Expand Original"
        case "collapseOriginal": return "Collapse Original"
        case "updateTranslate": return "Update & Translate"
        case "swap": return "Swap"
        case "stop": return "Stop"
        case "copyOriginal": return "Copy Original"
        case "copyTranslation": return "Copy Translation"
        case "ready": return "Ready"
        case "translating": return "Translating"
        case "complete": return "Complete"
        case "stopped": return "Stopped"
        case "failed": return "Failed"
        case "backendStopped": return "Backend stopped"
        case "detected": return "Detected"
        case "settings": return "Settings"
        case "settingsSubtitle": return "Configure the default language pair, local model path, and interface language."
        case "guiLanguage": return "GUI Language"
        case "nativeLanguage": return "Native Language"
        case "primaryForeign": return "Primary Foreign"
        case "modelPath": return "Model Path"
        case "browse": return "Browse"
        case "cancel": return "Cancel"
        case "save": return "Save"
        case "settingsSaved": return "Settings Saved"
        case "settingsSavedMessage": return "Language defaults are updated. Model path and interface language changes apply the next time Translate Text launches."
        case "openTextFile": return "Open Text File..."
        case "copyOriginalText": return "Copy Original Text"
        case "expandCollapseOriginal": return "Expand/Collapse Original"
        case "swapOriginalTranslation": return "Swap Original/Translation"
        case "stopTranslation": return "Stop Translation"
        case "selectTextFile": return "Select a Text File"
        case "readError": return "Read Error"
        case "warning": return "Warning"
        case "emptyOriginal": return "Original text is empty."
        default: return key
        }
    }

    private func localizedLanguageForDisplay(_ language: String) -> String {
        guard usesChineseUI else { return language }
        switch language {
        case "English": return "英语"
        case "日本語": return "日语"
        case "한국어": return "韩语"
        case "Français": return "法语"
        case "Deutsch": return "德语"
        case "Italiano": return "意大利语"
        case "Español": return "西班牙语"
        case "Русский": return "俄语"
        case "Português": return "葡萄牙语"
        case "العربية": return "阿拉伯语"
        case "हिन्दी": return "印地语"
        case "Malti": return "马耳他语"
        default: return language
        }
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = tr("appTitle")
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 620)
        window.center()

        rootView = NSVisualEffectView()
        rootView.material = .hudWindow
        rootView.blendingMode = .behindWindow
        rootView.state = .active
        rootView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = rootView

        buildLoadingView()
        buildMainContent()
        showLoadingPage()
    }

    private func buildLoadingView() {
        loadingView = NSVisualEffectView()
        loadingView.material = .contentBackground
        loadingView.blendingMode = .withinWindow
        loadingView.state = .active
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.wantsLayer = true
        loadingView.layer?.cornerRadius = 22

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "globe.asia.australia.fill", accessibilityDescription: "Translate")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 42, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = label(tr("loadingTitle"), size: 26, weight: .bold)
        title.textColor = .labelColor
        title.alignment = .center

        loadingStatusLabel = label(tr("loadingStatus"), size: 14)
        loadingStatusLabel.alignment = .center

        loadingProgress = NSProgressIndicator()
        loadingProgress.style = .spinning
        loadingProgress.controlSize = .large
        loadingProgress.translatesAutoresizingMaskIntoConstraints = false
        loadingProgress.startAnimation(nil)

        let stack = NSStackView(views: [icon, title, loadingStatusLabel, loadingProgress])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        loadingView.addSubview(stack)
        rootView.addSubview(loadingView)

        NSLayoutConstraint.activate([
            loadingView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            loadingView.widthAnchor.constraint(equalToConstant: 440),
            loadingView.heightAnchor.constraint(equalToConstant: 260),
            stack.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 58),
            icon.heightAnchor.constraint(equalToConstant: 58),
            loadingProgress.widthAnchor.constraint(equalToConstant: 28),
            loadingProgress.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func buildMainContent() {
        let title = label(tr("appTitle"), size: 26, weight: .bold)
        title.textColor = .labelColor
        let subtitle = label(tr("subtitle"), size: 14)
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.spacing = 3
        header.alignment = .leading

        statusLabel = label(tr("loadingModel"), size: 13)
        statusLabel.alignment = .right

        let headerRow = NSStackView(views: [header, statusLabel])
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.distribution = .fill
        headerRow.spacing = 18
        header.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let originalPanel = panel()
        originalPanel.translatesAutoresizingMaskIntoConstraints = false
        originalScroll = textScroll(editable: true)
        originalTextView = originalScroll.documentView as? NSTextView
        originalTextView.string = initialText
        originalTextView.delegate = self
        let originalStack = paddedStack([sectionHeader(tr("originalText")), originalScroll])
        originalPanel.addSubview(originalStack)
        pin(originalStack, to: originalPanel)

        targetPopup = popup(languages.map(\.name), action: #selector(selectionChanged(_:)))
        stylePopup = popup(styles, action: #selector(selectionChanged(_:)))
        autoSelectTargetLanguage(for: initialText)

        expandButton = button(tr("expandOriginal"), symbol: "arrow.up.left.and.arrow.down.right", action: #selector(toggleOriginal(_:)))
        updateButton = button(tr("updateTranslate"), symbol: "arrow.clockwise", action: #selector(updateAndTranslate(_:)))
        swapButton = button(tr("swap"), symbol: "arrow.left.arrow.right", action: #selector(swapAndTranslate(_:)))
        stopButton = button(tr("stop"), symbol: "stop.fill", action: #selector(stopTranslation(_:)))

        let actionRow = NSStackView(views: [expandButton, updateButton, swapButton, stopButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 12
        actionRow.alignment = .centerY
        actionRow.distribution = .fillEqually

        let optionsRow = NSStackView(views: [
            inlineControl(tr("target"), control: targetPopup),
            inlineControl(tr("style"), control: stylePopup),
        ])
        optionsRow.orientation = .horizontal
        optionsRow.alignment = .centerY
        optionsRow.distribution = .fillEqually
        optionsRow.spacing = 18

        let controlsStack = NSStackView(views: [optionsRow, actionRow])
        controlsStack.orientation = .vertical
        controlsStack.alignment = .width
        controlsStack.spacing = 14
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        let controlsView = NSView()
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(controlsStack)

        let translationPanel = panel()
        translationPanel.translatesAutoresizingMaskIntoConstraints = false
        translationScroll = textScroll(editable: false)
        translationTextView = translationScroll.documentView as? NSTextView
        translationHeaderLabel = label("", size: 13, weight: .semibold)
        let translationStack = paddedStack([sectionHeader(translationHeaderLabel), translationScroll])
        translationPanel.addSubview(translationStack)
        pin(translationStack, to: translationPanel)
        updateTranslationHeader()

        copyOriginalButton = button(tr("copyOriginal"), symbol: "doc.on.doc", action: #selector(copyOriginal(_:)))
        copyTranslationButton = button(tr("copyTranslation"), symbol: "doc.on.clipboard", action: #selector(copyTranslation(_:)), prominent: true)
        footerProgress = NSProgressIndicator()
        footerProgress.style = .spinning
        footerProgress.isDisplayedWhenStopped = false
        footerStatusLabel = label(tr("loadingTitle") + "...", size: 13)
        let footerLeft = NSStackView(views: [footerProgress, footerStatusLabel])
        footerLeft.orientation = .horizontal
        footerLeft.spacing = 8
        footerLeft.alignment = .centerY
        let footerRight = NSStackView(views: [copyOriginalButton, copyTranslationButton])
        footerRight.orientation = .horizontal
        footerRight.spacing = 10
        footerRight.alignment = .centerY
        let footer = NSStackView(views: [footerLeft, NSView(), footerRight])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false

        let footerView = NSView()
        footerView.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(footer)

        mainContent = NSStackView(views: [headerRow, originalPanel, controlsView, translationPanel, footerView])
        mainContent.orientation = .vertical
        mainContent.alignment = .width
        mainContent.spacing = 13
        mainContent.edgeInsets = NSEdgeInsets(top: 54, left: 28, bottom: 20, right: 28)
        mainContent.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(mainContent)

        originalHeightConstraint = originalScroll.heightAnchor.constraint(equalToConstant: 72)

        NSLayoutConstraint.activate([
            mainContent.topAnchor.constraint(equalTo: rootView.topAnchor),
            mainContent.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            mainContent.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            mainContent.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            headerRow.widthAnchor.constraint(equalTo: mainContent.widthAnchor, constant: -56),
            originalPanel.widthAnchor.constraint(equalTo: mainContent.widthAnchor, constant: -56),
            controlsView.widthAnchor.constraint(equalTo: mainContent.widthAnchor, constant: -56),
            translationPanel.widthAnchor.constraint(equalTo: mainContent.widthAnchor, constant: -56),
            footerView.widthAnchor.constraint(equalTo: mainContent.widthAnchor, constant: -56),
            controlsStack.topAnchor.constraint(equalTo: controlsView.topAnchor),
            controlsStack.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor),
            controlsStack.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor),
            controlsStack.bottomAnchor.constraint(equalTo: controlsView.bottomAnchor),
            optionsRow.widthAnchor.constraint(equalTo: controlsStack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: controlsStack.widthAnchor),
            footer.topAnchor.constraint(equalTo: footerView.topAnchor),
            footer.leadingAnchor.constraint(equalTo: footerView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: footerView.bottomAnchor),
            originalHeightConstraint,
            originalScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 600),
            translationScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 600),
            translationScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            footerProgress.widthAnchor.constraint(equalToConstant: 20),
            footerProgress.heightAnchor.constraint(equalToConstant: 20),
            targetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            stylePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        setControlsEnabled(false)
        footerProgress.startAnimation(nil)
        mainContent.isHidden = true
    }

    private func buildMenu() {
        let menuBar = NSMenu()
        NSApp.mainMenu = menuBar

        let appItem = NSMenuItem()
        menuBar.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let settingsItem = appMenu.addItem(withTitle: tr("settings") + "...", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: usesChineseUI ? "退出" : "Quit Translate Text", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        menuBar.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: tr("openTextFile"), action: #selector(openTextFile(_:)), keyEquivalent: "o").target = self

        let editItem = NSMenuItem()
        menuBar.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: tr("copyOriginalText"), action: #selector(copyOriginal(_:)), keyEquivalent: "").target = self
        editMenu.addItem(withTitle: tr("copyTranslation"), action: #selector(copyTranslation(_:)), keyEquivalent: "").target = self

        let actionItem = NSMenuItem()
        menuBar.addItem(actionItem)
        let actionMenu = NSMenu(title: "Actions")
        actionItem.submenu = actionMenu
        actionMenu.addItem(withTitle: tr("expandCollapseOriginal"), action: #selector(toggleOriginal(_:)), keyEquivalent: "e").target = self
        actionMenu.addItem(withTitle: tr("updateTranslate"), action: #selector(updateAndTranslate(_:)), keyEquivalent: "r").target = self
        actionMenu.addItem(withTitle: tr("swapOriginalTranslation"), action: #selector(swapAndTranslate(_:)), keyEquivalent: "t").target = self
        actionMenu.addItem(withTitle: tr("stopTranslation"), action: #selector(stopTranslation(_:)), keyEquivalent: ".").target = self

        let styleItem = NSMenuItem()
        menuBar.addItem(styleItem)
        let styleMenu = NSMenu(title: "Style")
        styleItem.submenu = styleMenu
        for style in styles {
            let item = styleMenu.addItem(withTitle: style, action: #selector(selectStyleFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style
        }

        let languageItem = NSMenuItem()
        menuBar.addItem(languageItem)
        let languageMenu = NSMenu(title: "Language")
        languageItem.submenu = languageMenu
        for language in languages {
            let item = languageMenu.addItem(withTitle: language.name, action: #selector(selectLanguageFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.name
        }

        menuBar.addItem(NSMenuItem(title: "Window", action: nil, keyEquivalent: ""))
    }

    private func startWorker() {
        guard !workerPath.isEmpty else {
            showAlert(title: usesChineseUI ? "后端缺失" : "Worker Missing", message: "translate_text_worker.py was not found in the app bundle.")
            return
        }
        let process = Process()
        var environment = ProcessInfo.processInfo.environment
        if let pythonPath = environment["TRANSLATE_TEXT_PYTHON"], !pythonPath.isEmpty {
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = [workerPath]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", workerPath]
        }
        environment["TRANSLATE_TEXT_MODEL"] = modelPath
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        workerInput = input
        worker = process

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.handleWorkerOutput(text)
            }
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                fputs(text, stderr)
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.setStatus(self?.tr("backendStopped") ?? "Backend stopped")
                self?.setControlsEnabled(false)
            }
        }
        do {
            try process.run()
        } catch {
            showAlert(title: usesChineseUI ? "无法启动后端" : "Could Not Start Backend", message: error.localizedDescription)
        }
    }

    private var partialOutput = ""
    private func handleWorkerOutput(_ text: String) {
        partialOutput += text
        while let newline = partialOutput.firstIndex(of: "\n") {
            let line = String(partialOutput[..<newline])
            partialOutput.removeSubrange(...newline)
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventName = event["event"] as? String else { continue }
            handleWorkerEvent(eventName, payload: event)
        }
    }

    private func handleWorkerEvent(_ event: String, payload: [String: Any]) {
        switch event {
        case "ready":
            isReady = true
            showMainPage()
            setControlsEnabled(true)
            footerProgress.stopAnimation(nil)
            footerStatusLabel.stringValue = tr("ready")
            statusLabel.stringValue = modelDisplayName()
            translateCurrentText()
        case "status":
            setStatus(payload["text"] as? String ?? "")
        case "started":
            translationTextView.string = tr("translating") + "..."
            footerProgress.startAnimation(nil)
            footerStatusLabel.stringValue = tr("translating")
        case "replace":
            translationTextView.string = payload["text"] as? String ?? ""
        case "token":
            appendTranslation(payload["text"] as? String ?? "")
        case "complete":
            footerProgress.stopAnimation(nil)
            footerStatusLabel.stringValue = tr("complete")
        case "stopped":
            footerProgress.stopAnimation(nil)
            footerStatusLabel.stringValue = tr("stopped")
        case "error":
            loadingProgress.stopAnimation(nil)
            footerProgress.stopAnimation(nil)
            loadingStatusLabel.stringValue = usesChineseUI ? "模型加载失败" : "Failed to load model"
            footerStatusLabel.stringValue = tr("failed")
            showAlert(title: payload["title"] as? String ?? "Error", message: payload["message"] as? String ?? "Unknown error")
        default:
            break
        }
    }

    private func showLoadingPage() {
        loadingView.isHidden = false
        mainContent.isHidden = true
        loadingProgress.startAnimation(nil)
    }

    private func showMainPage() {
        loadingProgress.stopAnimation(nil)
        loadingView.isHidden = true
        mainContent.isHidden = false
    }

    @objc private func handleExternalOpenRequest(_ notification: Notification) {
        guard let text = notification.userInfo?["text"] as? String else { return }
        replaceOriginalText(text)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func replaceOriginalText(_ text: String) {
        let newText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? readLaunchText() : text
        if originalTextView == nil {
            initialText = newText
            return
        }
        originalTextView.string = newText
        translationTextView.string = ""
        autoSelectTargetLanguage(for: newText)
        updateTranslationHeader()
        if isReady {
            translateCurrentText()
        }
    }

    private func sendCommand(_ command: [String: Any]) {
        guard let input = workerInput,
              let data = try? JSONSerialization.data(withJSONObject: command),
              let text = String(data: data, encoding: .utf8) else { return }
        input.fileHandleForWriting.write(Data((text + "\n").utf8))
    }

    private func translateCurrentText() {
        guard isReady else { return }
        let text = originalTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            showAlert(title: tr("warning"), message: tr("emptyOriginal"))
            return
        }
        let target = targetPopup.titleOfSelectedItem ?? nativeLanguage
        if target != nativeLanguage {
            lastForeignLanguage = target
        }
        updateTranslationHeader()
        sendCommand(["action": "translate", "text": text, "target": target, "style": stylePopup.titleOfSelectedItem ?? "Default"])
    }

    @objc private func updateAndTranslate(_ sender: Any?) {
        translateCurrentText()
    }

    @objc private func selectionChanged(_ sender: Any?) {
        updateTranslationHeader()
        translateCurrentText()
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === originalTextView else { return }
        updateTranslationHeader()
    }

    @objc private func stopTranslation(_ sender: Any?) {
        sendCommand(["action": "stop"])
    }

    @objc private func toggleOriginal(_ sender: Any?) {
        isOriginalExpanded.toggle()
        originalHeightConstraint.constant = isOriginalExpanded ? 150 : 72
        expandButton.title = isOriginalExpanded ? tr("collapseOriginal") : tr("expandOriginal")
        expandButton.image = symbol(isOriginalExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    @objc private func swapAndTranslate(_ sender: Any?) {
        let translation = cleanTranslation()
        guard !translation.isEmpty else { return }
        let currentSource = originalTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedOrigin = detectBestLanguage(currentSource)
        let currentTarget = targetPopup.titleOfSelectedItem ?? nativeLanguage

        originalTextView.string = translation
        translationTextView.string = ""

        var newTarget: String?
        if let detectedOrigin, detectedOrigin != currentTarget {
            newTarget = detectedOrigin
            if detectedOrigin != nativeLanguage {
                lastForeignLanguage = detectedOrigin
            }
        } else if currentTarget == nativeLanguage {
            newTarget = lastForeignLanguage
        } else {
            newTarget = nativeLanguage
            lastForeignLanguage = currentTarget
        }
        if let newTarget {
            targetPopup.selectItem(withTitle: newTarget)
        }
        translateCurrentText()
    }

    @objc private func copyOriginal(_ sender: Any?) {
        copyToClipboard(originalTextView.string.trimmingCharacters(in: .whitespacesAndNewlines))
        flash(button: copyOriginalButton, title: "Copied")
    }

    @objc private func copyTranslation(_ sender: Any?) {
        let translation = cleanTranslation()
        guard !translation.isEmpty else { return }
        copyToClipboard(translation)
        flash(button: copyTranslationButton, title: "Copied")
    }

    @objc private func openTextFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = tr("selectTextFile")
        panel.allowedContentTypes = [
            .plainText,
            .text,
            UTType(filenameExtension: "md")!,
            UTType(filenameExtension: "json")!,
            UTType(filenameExtension: "py")!,
            UTType(filenameExtension: "js")!,
            UTType(filenameExtension: "html")!,
            UTType(filenameExtension: "csv")!,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                originalTextView.string = content
                if !isOriginalExpanded {
                    toggleOriginal(nil)
                }
                autoSelectTargetLanguage(for: content)
                translateCurrentText()
            } catch {
                showAlert(title: tr("readError"), message: (usesChineseUI ? "无法读取文件：\n" : "Failed to read file:\n") + error.localizedDescription)
            }
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        if let settingsPanel {
            settingsPanel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 370),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = tr("settings")
        panel.isFloatingPanel = true
        panel.center()

        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        panel.contentView = content

        let title = label(tr("settings"), size: 24, weight: .bold)
        title.textColor = .labelColor
        let subtitle = label(tr("settingsSubtitle"), size: 13)

        settingsGuiPopup = popup(guiLanguageOptions, action: #selector(noop(_:)))
        settingsGuiPopup?.selectItem(withTitle: guiLanguageSetting)
        settingsNativePopup = popup(languages.map(\.name), action: #selector(noop(_:)))
        settingsNativePopup?.selectItem(withTitle: nativeLanguage)
        settingsForeignPopup = popup(languages.map(\.name), action: #selector(noop(_:)))
        settingsForeignPopup?.selectItem(withTitle: primaryForeignLanguage)
        settingsModelField = NSTextField(string: modelPath)
        settingsModelField?.bezelStyle = .roundedBezel
        settingsModelField?.controlSize = .large

        let modelRow = NSStackView(views: [
            settingsModelField!,
            button(tr("browse"), symbol: "folder", action: #selector(browseModelPath(_:)))
        ])
        modelRow.orientation = .horizontal
        modelRow.spacing = 8

        let form = NSStackView(views: [
            settingsRow(tr("guiLanguage"), control: settingsGuiPopup!),
            settingsRow(tr("nativeLanguage"), control: settingsNativePopup!),
            settingsRow(tr("primaryForeign"), control: settingsForeignPopup!),
            settingsRow(tr("modelPath"), control: modelRow),
        ])
        form.orientation = .vertical
        form.alignment = .width
        form.spacing = 14

        let buttons = NSStackView(views: [
            NSView(),
            button(tr("cancel"), symbol: "xmark", action: #selector(closeSettings(_:))),
            button(tr("save"), symbol: "checkmark", action: #selector(saveSettings(_:)), prominent: true)
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        let header = NSStackView(views: [leftAligned(title), leftAligned(subtitle)])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4

        form.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let stack = NSStackView(views: [header, form, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 44),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -44),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -34),
            settingsGuiPopup!.widthAnchor.constraint(equalToConstant: 250),
            settingsNativePopup!.widthAnchor.constraint(equalToConstant: 250),
            settingsForeignPopup!.widthAnchor.constraint(equalToConstant: 250),
            settingsModelField!.widthAnchor.constraint(equalToConstant: 300),
            form.widthAnchor.constraint(equalToConstant: 560),
            buttons.widthAnchor.constraint(equalTo: form.widthAnchor),
        ])

        settingsPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func browseModelPath(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = usesChineseUI ? "选择模型文件夹" : "Select Model Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settingsModelField?.stringValue = url.path
        }
    }

    @objc private func saveSettings(_ sender: Any?) {
        UserDefaults.standard.set(settingsNativePopup?.titleOfSelectedItem ?? defaultNativeLanguage, forKey: "nativeLanguage")
        UserDefaults.standard.set(settingsForeignPopup?.titleOfSelectedItem ?? defaultPrimaryForeignLanguage, forKey: "primaryForeignLanguage")
        UserDefaults.standard.set(settingsGuiPopup?.titleOfSelectedItem ?? "Auto", forKey: "guiLanguage")
        UserDefaults.standard.set(settingsModelField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultModelPath, forKey: "modelPath")
        settingsPanel?.close()
        settingsPanel = nil
        lastForeignLanguage = primaryForeignLanguage
        autoSelectTargetLanguage(for: originalTextView.string)
        updateTranslationHeader()
        showAlert(title: tr("settingsSaved"), message: tr("settingsSavedMessage"))
    }

    @objc private func closeSettings(_ sender: Any?) {
        settingsPanel?.close()
        settingsPanel = nil
    }

    @objc private func noop(_ sender: Any?) {}

    @objc private func selectStyleFromMenu(_ sender: NSMenuItem) {
        if let style = sender.representedObject as? String {
            stylePopup.selectItem(withTitle: style)
            translateCurrentText()
        }
    }

    @objc private func selectLanguageFromMenu(_ sender: NSMenuItem) {
        if let language = sender.representedObject as? String {
            targetPopup.selectItem(withTitle: language)
            translateCurrentText()
        }
    }

    private func setControlsEnabled(_ enabled: Bool) {
        [targetPopup, stylePopup, expandButton, updateButton, swapButton, stopButton, copyOriginalButton, copyTranslationButton].forEach {
            $0?.isEnabled = enabled
        }
        originalTextView?.isEditable = enabled
    }

    private func setStatus(_ text: String) {
        statusLabel?.stringValue = text
        loadingStatusLabel?.stringValue = text
    }

    private func appendTranslation(_ text: String) {
        if translationTextView.string.hasPrefix("Translating") || translationTextView.string.hasPrefix(tr("translating")) {
            translationTextView.string = ""
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: bodyTextFont(),
            .foregroundColor: NSColor.labelColor
        ]
        translationTextView.textStorage?.append(NSAttributedString(string: text, attributes: attributes))
        translationTextView.scrollToEndOfDocument(nil)
    }

    private func cleanTranslation() -> String {
        var content = translationTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        content = content.replacingOccurrences(of: "⚠️ [Mode Switch: Input detected as a phrase/sentence. Switching to Default style...]", with: "")
        content = content.replacingOccurrences(of: "[Stopped]", with: "")
        if content.hasPrefix("Translating") || content.hasPrefix(tr("translating")) {
            return ""
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func autoSelectTargetLanguage(for text: String) {
        guard let detected = detectBestLanguage(text) else {
            targetPopup.selectItem(withTitle: nativeLanguage)
            updateTranslationHeader()
            return
        }
        targetPopup.selectItem(withTitle: detected == nativeLanguage ? primaryForeignLanguage : nativeLanguage)
        updateTranslationHeader()
    }

    private func updateTranslationHeader() {
        let text = originalTextView?.string ?? initialText
        if let detected = detectBestLanguage(text) {
            translationHeaderLabel?.stringValue = "\(tr("translation")) · \(tr("detected")) \(localizedLanguageForDisplay(detected))"
        } else {
            translationHeaderLabel?.stringValue = tr("translation")
        }
    }

    private func detectBestLanguage(_ text: String) -> String? {
        if text.isEmpty { return nil }
        if text.range(of: "[\\u3040-\\u30ff]", options: .regularExpression) != nil {
            return "日本語"
        }
        if text.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil {
            return nativeLanguage == "繁體中文" ? "繁體中文" : "简体中文"
        }
        if text.range(of: "[\\uac00-\\ud7a3]", options: .regularExpression) != nil {
            return "한국어"
        }
        return "English"
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func flash(button: NSButton, title: String) {
        let oldTitle = button.title
        button.title = title
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            button.title = oldTitle
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = title.lowercased().contains("error") || title.lowercased().contains("failed") ? .critical : .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func readInitialText() -> String {
        let args = CommandLine.arguments.dropFirst()
        if !args.isEmpty {
            return args.joined(separator: " ")
        }
        return "Hello, waiting for input..."
    }

    private func settingString(_ key: String, fallback: String) -> String {
        let value = UserDefaults.standard.string(forKey: key) ?? fallback
        return languages.contains(where: { $0.name == value }) || key == "modelPath" ? value : fallback
    }

    private func modelDisplayName() -> String {
        let name = URL(fileURLWithPath: modelPath).lastPathComponent
        if name.isEmpty {
            return "TranslateGemma"
        }
        return name.replacingOccurrences(of: "translategemma", with: "TranslateGemma", options: .caseInsensitive)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = .secondaryLabelColor
        field.alignment = .left
        field.lineBreakMode = .byTruncatingTail
        field.baseWritingDirection = .leftToRight
        return field
    }

    private func sectionHeader(_ title: String) -> NSStackView {
        let field = label(title, size: 13, weight: .semibold)
        return sectionHeader(field)
    }

    private func sectionHeader(_ field: NSTextField) -> NSStackView {
        field.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        let row = NSStackView(views: [field, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        return row
    }

    private func leftAligned(_ view: NSView) -> NSStackView {
        let row = NSStackView(views: [view, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        view.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func inlineControl(_ title: String, control: NSView) -> NSStackView {
        let field = label(title, size: 13, weight: .medium)
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 54).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [field, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        return row
    }

    private func settingsRow(_ title: String, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let field = label(title, size: 13, weight: .medium)
        field.alignment = .left
        field.baseWritingDirection = .leftToRight
        field.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addSubview(field)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            field.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 130),
            control.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 150),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
        ])
        return row
    }

    private func button(_ title: String, symbol name: String, action: Selector, prominent: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.image = symbol(name)
        button.imagePosition = .imageLeading
        if prominent {
            button.keyEquivalent = "\r"
        }
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        }
        return button
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func popup(_ items: [String], action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.controlSize = .large
        popup.target = self
        popup.action = action
        for item in items {
            popup.addItem(withTitle: item)
        }
        if #available(macOS 26.0, *) {
            popup.bezelStyle = .glass
        }
        return popup
    }

    private func textScroll(editable: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let textView = NSTextView()
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.font = bodyTextFont()
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 12, height: 12)
        scroll.documentView = textView
        return scroll
    }

    private func bodyTextFont() -> NSFont {
        NSFont.systemFont(ofSize: 16)
    }

    private func panel() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .contentBackground
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 18
        return view
    }

    private func paddedStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func pin(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}

let launchText = readLaunchText()
let instanceLock = SingleInstanceLock()
if !instanceLock.acquire() {
    instanceLock.forward(text: launchText)
    exit(0)
}

let app = NSApplication.shared
let delegate = TranslateTextApp(initialText: launchText, instanceLock: instanceLock)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
