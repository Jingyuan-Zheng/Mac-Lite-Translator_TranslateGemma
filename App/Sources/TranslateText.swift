import AppKit
import SwiftUI
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
let defaultCloudBackend = "Google"
let guiLanguageOptions = ["Auto", "English", "简体中文"]
let cloudBackendOptions = ["Google", "Bing"]
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

struct LaunchRequest {
    let text: String
    let backendOverride: String?
    let usesLightUI: Bool
    let restoredTarget: String?
    let restoredTranslation: String?
}

func normalizedBackendOverride(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "cloud", "google", "bing", "gemma", "local":
        return normalized == "local" ? "gemma" : normalized
    default:
        return nil
    }
}

func parseLaunchRequest() -> LaunchRequest {
    let args = CommandLine.arguments.dropFirst()
    var backendOverride: String?
    var usesLightUI = false
    var restoredTarget: String?
    var restoredTranslation: String?
    var textParts: [String] = []
    var index = args.startIndex

    while index < args.endIndex {
        let arg = args[index]
        if arg == "--" {
            let rest = args[args.index(after: index)..<args.endIndex]
            textParts.append(contentsOf: rest)
            break
        } else if arg == "--cloud" {
            backendOverride = "cloud"
        } else if arg == "--light" {
            usesLightUI = true
        } else if arg == "--restore-target" {
            let nextIndex = args.index(after: index)
            if nextIndex < args.endIndex {
                restoredTarget = args[nextIndex]
                index = nextIndex
            }
        } else if arg == "--restore-translation-base64" {
            let nextIndex = args.index(after: index)
            if nextIndex < args.endIndex,
               let data = Data(base64Encoded: args[nextIndex]),
               let translation = String(data: data, encoding: .utf8) {
                restoredTranslation = translation
                index = nextIndex
            }
        } else if arg == "--google" {
            backendOverride = "google"
        } else if arg == "--bing" {
            backendOverride = "bing"
        } else if arg == "--gemma" || arg == "--local" {
            backendOverride = "gemma"
        } else if arg == "--backend" || arg == "--engine" {
            let nextIndex = args.index(after: index)
            if nextIndex < args.endIndex, let backend = normalizedBackendOverride(args[nextIndex]) {
                backendOverride = backend
                index = nextIndex
            }
        } else if arg.hasPrefix("--backend=") {
            backendOverride = normalizedBackendOverride(String(arg.dropFirst("--backend=".count))) ?? backendOverride
        } else if arg.hasPrefix("--engine=") {
            backendOverride = normalizedBackendOverride(String(arg.dropFirst("--engine=".count))) ?? backendOverride
        } else {
            textParts.append(arg)
        }
        index = args.index(after: index)
    }
    let text = textParts.isEmpty ? "Hello, waiting for input..." : textParts.joined(separator: " ")
    return LaunchRequest(
        text: text,
        backendOverride: backendOverride,
        usesLightUI: usesLightUI,
        restoredTarget: restoredTarget,
        restoredTranslation: restoredTranslation
    )
}

func readLaunchText() -> String {
    parseLaunchRequest().text
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

    func forward(request: LaunchRequest) {
        let userInfo: [String: String] = [
            "text": request.text,
            "backend": request.backendOverride ?? "gemma",
            "ui": request.usesLightUI ? "light" : "full",
        ]
        DistributedNotificationCenter.default().postNotificationName(
            singleInstanceNotificationName,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit {
        release()
    }
}

// Light-mode panel adapted from TranslateKit's FloatingPanel and TranslationView.
// TranslateKit is MIT licensed; the complete notice is bundled as TRANSLATEKIT_LICENSE.txt.
final class LightTranslationModel: ObservableObject {
    @Published var sourceText: String
    @Published var translatedText = ""
    @Published var statusText = "Preparing..."
    @Published var backendName = ""
    @Published var targetLanguage: String
    @Published var isLoading = true
    @Published var errorMessage: String?

    let targetLanguages: [String]
    var onTargetChange: ((String) -> Void)?
    var onShowFullUI: (() -> Void)?

    init(sourceText: String, targetLanguage: String, targetLanguages: [String]) {
        self.sourceText = sourceText
        self.targetLanguage = targetLanguage
        self.targetLanguages = targetLanguages
    }
}

struct LightTranslationView: View {
    @ObservedObject var model: LightTranslationModel
    var onSizeChange: ((CGSize) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            content
            Divider().padding(.horizontal, 12)
            footer
        }
        .background(LightVisualEffectBackground())
        .frame(width: 480)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: LightViewSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(LightViewSizeKey.self) { size in
            onSizeChange?(size)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "translate")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.blue)
            Text("Translate Text")
                .font(.system(size: 13, weight: .semibold))
            Spacer()

            Menu {
                ForEach(model.targetLanguages, id: \.self) { language in
                    Button {
                        guard language != model.targetLanguage else { return }
                        model.targetLanguage = language
                        model.onTargetChange?(language)
                    } label: {
                        if language == model.targetLanguage {
                            Label(language, systemImage: "checkmark")
                        } else {
                            Text(language)
                        }
                    }
                }
            } label: {
                Text(model.targetLanguage)
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                NSApp.keyWindow?.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ORIGINAL")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                ScrollView {
                    Text(model.sourceText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("TRANSLATION")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                Group {
                    if model.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.statusText)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    } else if let error = model.errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    } else {
                        ScrollView {
                            Text(model.translatedText)
                                .font(.system(size: 15, weight: .medium))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(maxHeight: 320)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Label(model.backendName, systemImage: model.backendName.contains("Gemma") ? "cpu" : "cloud")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                model.onShowFullUI?()
            } label: {
                Label("Full UI", systemImage: "macwindow")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.translatedText, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(model.translatedText.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct LightViewSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct LightVisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

final class LightTranslationPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onOutsideClick: (() -> Void)?
    private var menuTrackingTokens: [NSObjectProtocol] = []
    private var isMenuTracking = false
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        delegate = self
        menuTrackingTokens = [
            NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isMenuTracking = true
            },
            NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isMenuTracking = false
            },
        ]
        let clickMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: clickMask) { [weak self] event in
            self?.handleLocalMouseDown(event)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: clickMask) { [weak self] _ in
            self?.handleGlobalMouseDown()
        }
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient]
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear
        hasShadow = true
    }

    func presentNearCursor() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screenFrame = NSScreen.main?.visibleFrame else {
            center()
            orderFrontRegardless()
            return
        }
        let size = frame.size
        var x = mouseLocation.x - size.width / 2
        var y = mouseLocation.y - size.height - 16
        x = max(screenFrame.minX + 8, min(x, screenFrame.maxX - size.width - 8))
        y = max(screenFrame.minY + 8, min(y, screenFrame.maxY - size.height - 8))
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
        makeKey()
    }

    func updateContentSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        setContentSize(size)
        setFrameTopLeftPoint(topLeft)
        guard let screenFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        var origin = frame.origin
        origin.x = max(screenFrame.minX + 8, min(origin.x, screenFrame.maxX - frame.width - 8))
        origin.y = max(screenFrame.minY + 8, min(origin.y, screenFrame.maxY - frame.height - 8))
        if origin != frame.origin { setFrameOrigin(origin) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    deinit {
        menuTrackingTokens.forEach(NotificationCenter.default.removeObserver)
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func handleLocalMouseDown(_ event: NSEvent) {
        guard isVisible, !isMenuTracking, event.window !== self else { return }
        requestOutsideClick()
    }

    private func handleGlobalMouseDown() {
        guard isVisible, !frame.contains(NSEvent.mouseLocation) else { return }
        requestOutsideClick()
    }

    private func requestOutsideClick() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isMenuTracking else { return }
            self.onOutsideClick?()
        }
    }
    override func cancelOperation(_ sender: Any?) { close() }

    override func keyDown(with event: NSEvent) {
        event.keyCode == 53 ? close() : super.keyDown(with: event)
    }
}

final class TranslateTextApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    private var window: NSWindow!
    private var rootView: NSVisualEffectView!
    private var loadingView: NSVisualEffectView!
    private var mainContent: NSStackView!
    private var statusLabel: NSTextField!
    private var subtitleLabel: NSTextField!
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
    private var backendModeControl: NSSegmentedControl!
    private var backendSwitchProgress: NSProgressIndicator!
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
    private var settingsCloudBackendPopup: NSPopUpButton?
    private var settingsModelField: NSTextField?
    private let instanceLock: SingleInstanceLock
    private var lightPanel: LightTranslationPanel?
    private var lightModel: LightTranslationModel?

    private var worker: Process?
    private var workerInput: Pipe?
    private var isReady = false
    private var isSwitchingBackend = false
    private var isSyncingBackendModeControl = false
    private var localBackendReady = false
    private var backendBeforeSwitch: String?
    private var isOriginalExpanded = false
    private var initialText = "Hello, waiting for input..."
    private var launchBackendOverride: String?
    private var usesLightUI: Bool
    private var restoredTarget: String?
    private var restoredTranslation: String?
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

    private var cloudBackendSetting: String {
        let value = UserDefaults.standard.string(forKey: "cloudBackend") ?? defaultCloudBackend
        return cloudBackendOptions.contains(value) ? value : defaultCloudBackend
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

    private var activeWorkerBackend: String {
        switch launchBackendOverride {
        case "cloud":
            return cloudBackendSetting.lowercased()
        case "google", "bing", "gemma":
            return launchBackendOverride!
        default:
            return "gemma"
        }
    }

    init(launchRequest: LaunchRequest, instanceLock: SingleInstanceLock) {
        self.initialText = launchRequest.text
        self.launchBackendOverride = launchRequest.backendOverride
        self.usesLightUI = launchRequest.usesLightUI
        self.restoredTarget = launchRequest.restoredTarget
        self.restoredTranslation = launchRequest.restoredTranslation
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
        if let restoredTarget {
            targetPopup.selectItem(withTitle: restoredTarget)
            updateTranslationHeader()
        }
        if let restoredTranslation {
            translationTextView.string = restoredTranslation
        }
        buildMenu()
        startWorker()
        if usesLightUI {
            window.orderOut(nil)
            showLightUI()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        if !usesLightUI {
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !usesLightUI
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        sendCommand(["action": "quit"])
        worker?.terminate()
    }

    private func showLightUI() {
        usesLightUI = true
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)

        if let model = lightModel, let panel = lightPanel {
            model.sourceText = originalTextView.string
            model.targetLanguage = targetPopup.titleOfSelectedItem ?? nativeLanguage
            model.backendName = backendDisplayName()
            model.translatedText = translationTextView.string == tr("translating") + "..." ? "" : translationTextView.string
            panel.hidesOnDeactivate = false
            panel.onOutsideClick = { [weak self, weak panel] in
                guard let self, self.usesLightUI, self.lightPanel === panel, self.isUsingCloudBackend else { return }
                NSApp.terminate(nil)
            }
            panel.presentNearCursor()
            return
        }

        let model = LightTranslationModel(
            sourceText: originalTextView.string,
            targetLanguage: targetPopup.titleOfSelectedItem ?? nativeLanguage,
            targetLanguages: languages.map(\.name)
        )
        model.backendName = backendDisplayName()
        model.onTargetChange = { [weak self] language in
            guard let self else { return }
            self.targetPopup.selectItem(withTitle: language)
            self.translateCurrentText()
        }
        model.onShowFullUI = { [weak self] in
            self?.showFullUI()
        }

        let panel = LightTranslationPanel()
        panel.hidesOnDeactivate = false
        let view = LightTranslationView(model: model) { [weak panel] size in
            panel?.updateContentSize(size)
        }
        let hostingView = NSHostingView(rootView: view)
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)
        panel.onClose = { [weak self, weak panel] in
            guard let self, self.usesLightUI, self.lightPanel === panel else { return }
            NSApp.terminate(nil)
        }
        panel.onOutsideClick = { [weak self, weak panel] in
            guard let self, self.usesLightUI, self.lightPanel === panel, self.isUsingCloudBackend else { return }
            NSApp.terminate(nil)
        }
        lightModel = model
        lightPanel = panel
        panel.presentNearCursor()
    }

    private func showFullUI() {
        usesLightUI = false
        lightPanel?.orderOut(nil)
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            case "settingsSubtitle": return "配置默认语言、本地模型路径、云端翻译提供商和界面语言。"
            case "guiLanguage": return "界面语言"
            case "cloudBackend": return "云端后端"
            case "backendMode": return "模型"
            case "localModel": return "本地"
            case "cloudModel": return "云端"
            case "loadingLocalModel": return "正在加载本地模型..."
            case "switchingBackend": return "正在切换模型..."
            case "nativeLanguage": return "母语"
            case "primaryForeign": return "主要外语"
            case "modelPath": return "模型路径"
            case "browse": return "浏览"
            case "cancel": return "取消"
            case "save": return "保存"
            case "settingsSaved": return "设置已保存"
            case "settingsSavedMessage": return "语言默认值和云端后端已更新。模型路径和界面语言会在下次启动时生效。"
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
        case "settingsSubtitle": return "Configure the default language pair, local model path, cloud translation provider, and interface language."
        case "guiLanguage": return "GUI Language"
        case "cloudBackend": return "Cloud Backend"
        case "backendMode": return "Model"
        case "localModel": return "Local"
        case "cloudModel": return "Cloud"
        case "loadingLocalModel": return "Loading local model..."
        case "switchingBackend": return "Switching model..."
        case "nativeLanguage": return "Native Language"
        case "primaryForeign": return "Primary Foreign"
        case "modelPath": return "Model Path"
        case "browse": return "Browse"
        case "cancel": return "Cancel"
        case "save": return "Save"
        case "settingsSaved": return "Settings Saved"
        case "settingsSavedMessage": return "Language defaults and cloud backend are updated. Model path and interface language changes apply the next time Translate Text launches."
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
        subtitleLabel = label(subtitleText(), size: 14)
        let header = NSStackView(views: [title, subtitleLabel])
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
        let originalTextBox = textBox(originalScroll)
        let originalStack = paddedStack([sectionHeader(tr("originalText")), originalTextBox])
        originalPanel.addSubview(originalStack)
        pin(originalStack, to: originalPanel)

        targetPopup = popup(languages.map(\.name), action: #selector(selectionChanged(_:)))
        stylePopup = popup(styles, action: #selector(selectionChanged(_:)))
        backendModeControl = NSSegmentedControl(
            labels: [tr("localModel"), tr("cloudModel")],
            trackingMode: .selectOne,
            target: self,
            action: #selector(backendModeChanged(_:))
        )
        backendModeControl.controlSize = .large
        backendModeControl.segmentStyle = .rounded
        backendModeControl.segmentDistribution = .fillEqually
        backendModeControl.selectedSegment = isUsingCloudBackend ? 1 : 0

        backendSwitchProgress = NSProgressIndicator()
        backendSwitchProgress.style = .spinning
        backendSwitchProgress.controlSize = .small
        backendSwitchProgress.isDisplayedWhenStopped = false
        let backendSelectorRow = NSStackView(views: [backendModeControl, backendSwitchProgress])
        backendSelectorRow.orientation = .horizontal
        backendSelectorRow.alignment = .centerY
        backendSelectorRow.spacing = 8
        autoSelectTargetLanguage(for: initialText)

        expandButton = button(tr("expandOriginal"), symbol: "arrow.up.left.and.arrow.down.right", action: #selector(toggleOriginal(_:)))
        updateButton = button(tr("updateTranslate"), symbol: "arrow.clockwise", action: #selector(updateAndTranslate(_:)))
        swapButton = button(tr("swap"), symbol: "arrow.left.arrow.right", action: #selector(swapAndTranslate(_:)))
        stopButton = button(tr("stop"), symbol: "stop.fill", action: #selector(stopTranslation(_:)))
        stopButton.contentTintColor = .systemRed
        if let redStopImage = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: tr("stop"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) {
            redStopImage.isTemplate = false
            stopButton.image = redStopImage
        }
        stopButton.attributedTitle = NSAttributedString(
            string: tr("stop"),
            attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ]
        )

        let actionRow = NSStackView(views: [expandButton, updateButton, swapButton, stopButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 12
        actionRow.alignment = .centerY
        actionRow.distribution = .fillEqually

        let optionsRow = NSStackView(views: [
            inlineControl(tr("target"), control: targetPopup),
            inlineControl(tr("style"), control: stylePopup),
            inlineControl(tr("backendMode"), control: backendSelectorRow),
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
        let translationTextBox = textBox(translationScroll)
        let translationStack = paddedStack([sectionHeader(translationHeaderLabel), translationTextBox])
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

        originalHeightConstraint = originalTextBox.heightAnchor.constraint(equalToConstant: 72)

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
            translationTextBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            footerProgress.widthAnchor.constraint(equalToConstant: 20),
            footerProgress.heightAnchor.constraint(equalToConstant: 20),
            targetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            stylePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            backendModeControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            backendSwitchProgress.widthAnchor.constraint(equalToConstant: 16),
            backendSwitchProgress.heightAnchor.constraint(equalToConstant: 16),
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
        environment["TRANSLATE_TEXT_BACKEND"] = activeWorkerBackend
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
            if activeWorkerBackend == "gemma" {
                localBackendReady = true
            }
            showMainPage()
            setControlsEnabled(true)
            footerProgress.stopAnimation(nil)
            footerStatusLabel.stringValue = tr("ready")
            updateBackendDependentControls()
            lightModel?.statusText = tr("ready")
            lightModel?.backendName = backendDisplayName()
            if let restoredTranslation {
                translationTextView.string = restoredTranslation
                footerStatusLabel.stringValue = tr("complete")
                self.restoredTranslation = nil
            } else {
                translateCurrentText()
            }
        case "status":
            let status: String
            if isSwitchingBackend, activeWorkerBackend == "gemma" {
                status = tr("loadingLocalModel")
            } else {
                status = payload["text"] as? String ?? ""
            }
            setStatus(status)
            lightModel?.statusText = status
        case "backend_ready":
            guard isSwitchingBackend,
                  let backend = payload["backend"] as? String,
                  backend == activeWorkerBackend else { return }
            if backend == "gemma" {
                localBackendReady = true
            }
            isSwitchingBackend = false
            backendBeforeSwitch = nil
            backendSwitchProgress.stopAnimation(nil)
            setControlsEnabled(true)
            footerProgress.stopAnimation(nil)
            footerStatusLabel.stringValue = tr("ready")
            updateBackendDependentControls()
            translateCurrentText()
        case "started":
            translationTextView.string = tr("translating") + "..."
            footerProgress.startAnimation(nil)
            footerStatusLabel.stringValue = tr("translating")
            withAnimation {
                lightModel?.translatedText = ""
                lightModel?.errorMessage = nil
                lightModel?.statusText = tr("translating") + "..."
                lightModel?.isLoading = true
            }
        case "replace":
            translationTextView.string = payload["text"] as? String ?? ""
            lightModel?.translatedText = translationTextView.string
        case "token":
            appendTranslation(payload["text"] as? String ?? "")
            lightModel?.translatedText = translationTextView.string
        case "complete":
            footerProgress.stopAnimation(nil)
            footerStatusLabel.stringValue = tr("complete")
            withAnimation {
                lightModel?.translatedText = translationTextView.string
                lightModel?.statusText = tr("complete")
                lightModel?.isLoading = false
            }
        case "stopped":
            footerProgress.stopAnimation(nil)
            footerStatusLabel.stringValue = tr("stopped")
            withAnimation {
                lightModel?.statusText = tr("stopped")
                lightModel?.isLoading = false
            }
        case "error":
            if isSwitchingBackend {
                launchBackendOverride = backendBeforeSwitch
                backendBeforeSwitch = nil
                isSwitchingBackend = false
                backendSwitchProgress.stopAnimation(nil)
                setControlsEnabled(true)
                updateBackendDependentControls()
            }
            loadingProgress.stopAnimation(nil)
            footerProgress.stopAnimation(nil)
            loadingStatusLabel.stringValue = usesChineseUI ? "模型加载失败" : "Failed to load model"
            footerStatusLabel.stringValue = tr("failed")
            let message = payload["message"] as? String ?? "Unknown error"
            withAnimation {
                lightModel?.errorMessage = message
                lightModel?.isLoading = false
            }
            if !usesLightUI {
                showAlert(title: payload["title"] as? String ?? "Error", message: message)
            }
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
        let requestedBackend = normalizedBackendOverride(notification.userInfo?["backend"] as? String)
        let requestsLightUI = notification.userInfo?["ui"] as? String == "light"
        launchBackendOverride = requestedBackend
        replaceOriginalText(text)
        if requestsLightUI {
            showLightUI()
        } else if usesLightUI {
            showFullUI()
        } else if let window {
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
        lightModel?.sourceText = newText
        translationTextView.string = ""
        lightModel?.translatedText = ""
        autoSelectTargetLanguage(for: newText)
        updateTranslationHeader()
        lightModel?.targetLanguage = targetPopup.titleOfSelectedItem ?? nativeLanguage
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
        guard isReady, !isSwitchingBackend else { return }
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
        updateBackendDependentControls()
        lightModel?.sourceText = text
        lightModel?.targetLanguage = target
        lightModel?.backendName = backendDisplayName()
        sendCommand([
            "action": "translate",
            "text": text,
            "target": target,
            "style": stylePopup.titleOfSelectedItem ?? "Default",
            "backend": activeWorkerBackend,
        ])
    }

    @objc private func updateAndTranslate(_ sender: Any?) {
        translateCurrentText()
    }

    @objc private func selectionChanged(_ sender: Any?) {
        updateTranslationHeader()
        translateCurrentText()
    }

    @objc private func backendModeChanged(_ sender: NSSegmentedControl) {
        guard !isSyncingBackendModeControl else { return }
        guard !usesLightUI else {
            syncBackendModeControl()
            return
        }
        switchBackend(to: sender.selectedSegment == 1 ? "cloud" : "gemma")
    }

    private func switchBackend(to requestedBackend: String) {
        guard isReady, !isSwitchingBackend else {
            syncBackendModeControl()
            return
        }
        let normalized = normalizedBackendOverride(requestedBackend) ?? "gemma"
        let resolvedBackend = normalized == "cloud" ? cloudBackendSetting.lowercased() : normalized
        guard resolvedBackend != activeWorkerBackend else {
            syncBackendModeControl()
            return
        }

        backendBeforeSwitch = launchBackendOverride
        launchBackendOverride = normalized
        isSwitchingBackend = true
        syncBackendModeControl()
        setControlsEnabled(false)

        let needsLocalLoad = resolvedBackend == "gemma" && !localBackendReady
        if needsLocalLoad {
            backendSwitchProgress.startAnimation(nil)
            footerProgress.startAnimation(nil)
            footerStatusLabel.stringValue = tr("loadingLocalModel")
            setStatus(tr("loadingLocalModel"))
        } else {
            backendSwitchProgress.stopAnimation(nil)
            footerProgress.stopAnimation(nil)
            footerStatusLabel.stringValue = tr("switchingBackend")
            setStatus(tr("switchingBackend"))
        }
        updateBackendDependentControls(controlsEnabled: false)
        sendCommand(["action": "prepare_backend", "backend": resolvedBackend])
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
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 415),
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
        settingsCloudBackendPopup = popup(cloudBackendOptions, action: #selector(noop(_:)))
        settingsCloudBackendPopup?.selectItem(withTitle: cloudBackendSetting)
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
            settingsRow(tr("cloudBackend"), control: settingsCloudBackendPopup!),
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
            settingsCloudBackendPopup!.widthAnchor.constraint(equalToConstant: 250),
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
        UserDefaults.standard.set(settingsCloudBackendPopup?.titleOfSelectedItem ?? defaultCloudBackend, forKey: "cloudBackend")
        UserDefaults.standard.set(settingsModelField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultModelPath, forKey: "modelPath")
        settingsPanel?.close()
        settingsPanel = nil
        lastForeignLanguage = primaryForeignLanguage
        autoSelectTargetLanguage(for: originalTextView.string)
        updateTranslationHeader()
        updateBackendDependentControls()
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
        [targetPopup, expandButton, updateButton, swapButton, copyOriginalButton, copyTranslationButton].forEach {
            $0?.isEnabled = enabled
        }
        backendModeControl?.isEnabled = enabled
        stopButton?.isEnabled = enabled
        originalTextView?.isEditable = enabled
        updateBackendDependentControls(controlsEnabled: enabled)
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

    private func updateBackendDependentControls(controlsEnabled: Bool? = nil) {
        let enabled = controlsEnabled ?? isReady
        stylePopup?.isEnabled = enabled && !isUsingCloudBackend
        backendModeControl?.isEnabled = enabled && !isSwitchingBackend
        syncBackendModeControl()
        subtitleLabel?.stringValue = subtitleText()
        statusLabel?.stringValue = backendDisplayName()
    }

    private var isUsingCloudBackend: Bool {
        activeWorkerBackend == "google" || activeWorkerBackend == "bing"
    }

    private func syncBackendModeControl() {
        isSyncingBackendModeControl = true
        backendModeControl?.selectedSegment = isUsingCloudBackend ? 1 : 0
        isSyncingBackendModeControl = false
    }

    private func subtitleText() -> String {
        if usesChineseUI {
            switch activeWorkerBackend {
            case "google":
                return "使用 Google Translate 云端翻译所选文本。"
            case "bing":
                return "使用 Bing Translator 云端翻译所选文本。"
            default:
                return "使用本地 TranslateGemma 模型翻译所选文本。"
            }
        }

        switch activeWorkerBackend {
        case "google":
            return "Translate selected text with Google Translate."
        case "bing":
            return "Translate selected text with Bing Translator."
        default:
            return "Translate selected text with the local TranslateGemma model."
        }
    }

    private func backendDisplayName() -> String {
        switch activeWorkerBackend {
        case "google":
            return "Google Translate"
        case "bing":
            return "Bing Translator"
        default:
            return modelDisplayName()
        }
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

    private func textBox(_ scroll: NSScrollView) -> NSVisualEffectView {
        let box = NSVisualEffectView()
        box.material = .contentBackground
        box.blendingMode = .withinWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.masksToBounds = true
        box.addSubview(scroll)
        pin(scroll, to: box)
        return box
    }

    private func bodyTextFont() -> NSFont {
        NSFont.systemFont(ofSize: 16)
    }

    private func panel() -> NSView {
        NSView()
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

let launchRequest = parseLaunchRequest()
let instanceLock = SingleInstanceLock()
if !instanceLock.acquire() {
    instanceLock.forward(request: launchRequest)
    exit(0)
}

let app = NSApplication.shared
if launchRequest.usesLightUI {
    app.setActivationPolicy(.accessory)
} else {
    app.setActivationPolicy(.regular)
}
let delegate = TranslateTextApp(launchRequest: launchRequest, instanceLock: instanceLock)
app.delegate = delegate
app.run()
