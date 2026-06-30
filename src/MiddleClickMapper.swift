import AppKit
import ApplicationServices
import Foundation

// MARK: - 常量

private let middleMouseButtonNumber: Int64 = 2
private let launchAgentLabel = "com.middleclick.helper"
private let configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/MiddleClickMapper/config.json")
private let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
private let rightCommandKeyCode: CGKeyCode = 0x36
private var rightCommandIsDown = false

// 统一的水平边距常量，保证整窗左右对齐
private let HMargin: CGFloat = 28

// MARK: - Shortcut 模型

private struct Shortcut: Codable {
    var keyCode: CGKeyCode
    var modifierKeyCodes: [CGKeyCode]
    var flagsRawValue: UInt64
    var label: String

    static let rightCommand = Shortcut(
        keyCode: 0x36,
        modifierKeyCodes: [],
        flagsRawValue: CGEventFlags.maskCommand.rawValue,
        label: "右 Command"
    )

    var flags: CGEventFlags { CGEventFlags(rawValue: flagsRawValue) }
}

private let modifierKeyCodes: [CGKeyCode: (label: String, cgFlag: CGEventFlags)] = [
    0x38: ("Shift", .maskShift),
    0x3C: ("右 Shift", .maskShift),
    0x3B: ("Control", .maskControl),
    0x3E: ("右 Control", .maskControl),
    0x3A: ("Option", .maskAlternate),
    0x3D: ("右 Option", .maskAlternate),
    0x37: ("Command", .maskCommand),
    0x36: ("右 Command", .maskCommand)
]

private let defaultModifierKeys: [(NSEvent.ModifierFlags, CGKeyCode, String, CGEventFlags)] = [
    (.control, 0x3B, "Control", .maskControl),
    (.option, 0x3A, "Option", .maskAlternate),
    (.shift, 0x38, "Shift", .maskShift),
    (.command, 0x37, "Command", .maskCommand)
]

// MARK: - 配置读写

private func saveShortcut(_ shortcut: Shortcut) {
    try? FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if let data = try? JSONEncoder().encode(shortcut) {
        try? data.write(to: configURL, options: .atomic)
    }
}

private func loadShortcut() -> Shortcut {
    guard
        let data = try? Data(contentsOf: configURL),
        let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
    else {
        saveShortcut(.rightCommand)
        return .rightCommand
    }
    return shortcut
}

// MARK: - 按键映射辅助

private func keyLabel(for keyCode: CGKeyCode) -> String {
    let labels: [CGKeyCode: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
        0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",
        0x31: "空格", 0x24: "回车", 0x30: "Tab", 0x33: "删除", 0x35: "Esc",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11",
        0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16",
        0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20"
    ]
    return labels[keyCode] ?? "按键 \(keyCode)"
}

private func shortcutFromEvent(_ event: NSEvent) -> Shortcut? {
    if event.type == .flagsChanged, let modifier = modifierKeyCodes[event.keyCode] {
        return Shortcut(
            keyCode: event.keyCode,
            modifierKeyCodes: [],
            flagsRawValue: modifier.cgFlag.rawValue,
            label: modifier.label
        )
    }

    guard event.type == .keyDown else { return nil }

    let cleanFlags = event.modifierFlags.intersection([.control, .option, .shift, .command])
    var labels: [String] = []
    var modifierKeys: [CGKeyCode] = []
    var cgFlags: CGEventFlags = []

    for (flag, keyCode, label, cgFlag) in defaultModifierKeys where cleanFlags.contains(flag) {
        labels.append(label)
        modifierKeys.append(keyCode)
        cgFlags.insert(cgFlag)
    }

    labels.append(keyLabel(for: event.keyCode))
    return Shortcut(
        keyCode: event.keyCode,
        modifierKeyCodes: modifierKeys,
        flagsRawValue: cgFlags.rawValue,
        label: labels.joined(separator: " + ")
    )
}

// MARK: - CGEvent 模拟按键

private func postKey(_ keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
        return
    }
    event.flags = flags.union(.maskNonCoalesced)
    event.post(tap: .cghidEventTap)
}

private func postRightCommand(keyDown: Bool) {
    guard rightCommandIsDown != keyDown else { return }
    rightCommandIsDown = keyDown

    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: rightCommandKeyCode, keyDown: keyDown) else {
        return
    }
    event.flags = keyDown ? [.maskCommand, .maskNonCoalesced] : [.maskNonCoalesced]
    event.post(tap: .cghidEventTap)
}

// MARK: - 权限与 LaunchAgent

private func isRunningFromDiskImage() -> Bool {
    Bundle.main.bundlePath.hasPrefix("/Volumes/")
}

private func isAccessibilityTrusted(prompt: Bool) -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

private func openAccessibilitySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
    }
}

private func runLaunchctl(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func installLaunchAtLogin() -> Bool {
    // 直接执行 app 的可执行文件，而非用 /usr/bin/open 中转。
    // 这样 launchd 的 program 就是 app 二进制本身，登录项里会显示 app 的真实名字，
    // 而不是“open”。--login 参数让 app 进入后台（agent）模式。
    guard let executablePath = Bundle.main.executableURL?.path else {
        return false
    }
    let plist: [String: Any] = [
        "Label": launchAgentLabel,
        "ProgramArguments": [executablePath, "--login"],
        "RunAtLoad": true,
        "KeepAlive": false,
        "StandardOutPath": FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MiddleClickMapper.log").path,
        "StandardErrorPath": FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MiddleClickMapper.err.log").path,
        "ProcessType": "Interactive"
    ]

    do {
        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(launchAgentLabel)"])
        return runLaunchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
    } catch {
        return false
    }
}

private func removeLaunchAtLogin() {
    _ = runLaunchctl(["bootout", "gui/\(getuid())/\(launchAgentLabel)"])
    try? FileManager.default.removeItem(at: launchAgentURL)
}

private func launchAtLoginIsInstalled() -> Bool {
    FileManager.default.fileExists(atPath: launchAgentURL.path)
}

// MARK: - 状态指示圆点

private final class StatusDot: NSView {
    var isOk: Bool = false {
        didSet { layer?.backgroundColor = (isOk ? NSColor.systemGreen : NSColor.systemRed).cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.systemRed.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - AppDelegate

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem?

    // 状态卡片
    private var statusBg: NSView!
    private var permissionDot: StatusDot!
    private var permissionLabel: NSTextField!
    private var permissionValue: NSTextField!
    private var permissionButton: NSButton!
    private var tapDot: StatusDot!
    private var tapLabel: NSTextField!
    private var tapValue: NSTextField!
    private var tapButton: NSButton!

    // 快捷键
    private var shortcutTitleLabel: NSTextField!
    private var shortcutBox: NSView!
    private var shortcutLabel: NSTextField!
    private var shortcutHintLabel: NSTextField!

    // 开机自启 / 操作
    private var launchAtLoginSwitch: NSButton!
    private var recordButton: NSButton!

    // 底部
    private var separator: NSBox!
    private var versionLabel: NSTextField!
    private var doneButton: NSButton!

    // 状态
    private var monitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var currentShortcut = loadShortcut()
    private var pressedKeys: [CGKeyCode] = []
    private var mappingIsDown = false
    private let loginMode = CommandLine.arguments.contains("--login")
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        buildWindow()

        if !loginMode {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if !isAccessibilityTrusted(prompt: false) {
                _ = isAccessibilityTrusted(prompt: true)
            }
        }

        startEventTap()
        launchAtLoginSwitch.state = launchAtLoginIsInstalled() ? .on : .off
        refreshStatus()
        startStatusRefresher()
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseMapping()
        statusTimer?.invalidate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    // 点击 Dock 图标（或 Finder 里再次打开）时唤出窗口。
    // 没有 LSUIElement=true 时，这是 Dock 重新打开界面的关键回调。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshStatus()
    }

    // MARK: 菜单栏图标

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            button.image = NSImage(systemSymbolName: "command", accessibilityDescription: "鼠标中键映射助手")?
                .withSymbolConfiguration(config)
            button.action = #selector(toggleWindow)
            button.target = self
        }
    }

    @objc private func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        } else {
            showWindow()
        }
    }

    // MARK: 界面构建

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 394),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "鼠标中键映射助手"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView()
        window.contentView = content

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"

        let title = NSTextField(labelWithString: "鼠标中键映射助手")
        title.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "鼠标中键 → 自定义快捷键")
        subtitle.font = NSFont.systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // 状态卡片背景
        statusBg = NSView()
        statusBg.wantsLayer = true
        statusBg.layer?.cornerRadius = 12
        statusBg.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        statusBg.translatesAutoresizingMaskIntoConstraints = false

        // 状态行：辅助功能权限
        permissionDot = StatusDot(frame: .zero)
        permissionDot.translatesAutoresizingMaskIntoConstraints = false

        permissionLabel = NSTextField(labelWithString: "辅助功能权限")
        permissionLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        permissionLabel.translatesAutoresizingMaskIntoConstraints = false

        permissionValue = NSTextField(labelWithString: "")
        permissionValue.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        permissionValue.alignment = .right
        permissionValue.translatesAutoresizingMaskIntoConstraints = false

        permissionButton = NSButton(title: "前往授权", target: self, action: #selector(requestPermission))
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small
        permissionButton.translatesAutoresizingMaskIntoConstraints = false

        // 状态行：中键监听
        tapDot = StatusDot(frame: .zero)
        tapDot.translatesAutoresizingMaskIntoConstraints = false

        tapLabel = NSTextField(labelWithString: "中键监听")
        tapLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        tapLabel.translatesAutoresizingMaskIntoConstraints = false

        tapValue = NSTextField(labelWithString: "")
        tapValue.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        tapValue.alignment = .right
        tapValue.translatesAutoresizingMaskIntoConstraints = false

        tapButton = NSButton(title: "打开设置", target: self, action: #selector(requestPermission))
        tapButton.bezelStyle = .rounded
        tapButton.controlSize = .small
        tapButton.translatesAutoresizingMaskIntoConstraints = false

        // 触发快捷键
        shortcutTitleLabel = NSTextField(labelWithString: "触发快捷键")
        shortcutTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        shortcutTitleLabel.textColor = .secondaryLabelColor
        shortcutTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutBox = NSView()
        shortcutBox.wantsLayer = true
        shortcutBox.layer?.cornerRadius = 12
        shortcutBox.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        shortcutBox.translatesAutoresizingMaskIntoConstraints = false

        shortcutLabel = NSTextField(labelWithString: currentShortcut.label)
        shortcutLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        shortcutLabel.alignment = .center
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutHintLabel = NSTextField(labelWithString: "按一下鼠标中键，这里会闪烁确认")
        shortcutHintLabel.font = NSFont.systemFont(ofSize: 11)
        shortcutHintLabel.textColor = .tertiaryLabelColor
        shortcutHintLabel.alignment = .center
        shortcutHintLabel.translatesAutoresizingMaskIntoConstraints = false

        // 开机自启开关
        launchAtLoginSwitch = NSButton(checkboxWithTitle: "开机自动启动", target: self, action: #selector(toggleLaunchAtLogin))
        launchAtLoginSwitch.translatesAutoresizingMaskIntoConstraints = false

        recordButton = NSButton(title: "设置快捷键", target: self, action: #selector(startRecording))
        recordButton.bezelStyle = .rounded
        recordButton.translatesAutoresizingMaskIntoConstraints = false

        // 底部分隔线（macOS 设置面板的标准做法，把功能区与底部操作区分开）
        separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // 底部
        versionLabel = NSTextField(labelWithString: "v\(version)")
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        doneButton = NSButton(title: "完成", target: self, action: #selector(done))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        // 添加子视图：先放状态卡片背景，再放其余控件，保证背景在最下层
        content.addSubview(statusBg)
        let controls: [NSView] = [
            title, subtitle,
            permissionDot, permissionLabel, permissionValue, permissionButton,
            tapDot, tapLabel, tapValue, tapButton,
            shortcutTitleLabel, shortcutBox, shortcutLabel, shortcutHintLabel,
            launchAtLoginSwitch, recordButton, separator, versionLabel, doneButton
        ]
        controls.forEach { content.addSubview($0) }
        shortcutBox.addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            // ═══ 垂直线性堆叠链：每个元素明确跟在前一个下方，消除悬空空白 ═══
            // 顶部边距
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HMargin),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HMargin),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            // 状态卡片
            statusBg.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            statusBg.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HMargin),
            statusBg.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HMargin),
            statusBg.heightAnchor.constraint(equalToConstant: 74),

            // 触发快捷键区（紧跟卡片下方）
            shortcutTitleLabel.topAnchor.constraint(equalTo: statusBg.bottomAnchor, constant: 14),
            shortcutTitleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HMargin),
            shortcutTitleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HMargin),

            shortcutBox.topAnchor.constraint(equalTo: shortcutTitleLabel.bottomAnchor, constant: 8),
            shortcutBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HMargin),
            shortcutBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HMargin),
            shortcutBox.heightAnchor.constraint(equalToConstant: 44),

            shortcutLabel.centerYAnchor.constraint(equalTo: shortcutBox.centerYAnchor),
            shortcutLabel.centerXAnchor.constraint(equalTo: shortcutBox.centerXAnchor),
            shortcutLabel.leadingAnchor.constraint(equalTo: shortcutBox.leadingAnchor, constant: 12),
            shortcutLabel.trailingAnchor.constraint(equalTo: shortcutBox.trailingAnchor, constant: -12),

            shortcutHintLabel.topAnchor.constraint(equalTo: shortcutBox.bottomAnchor, constant: 7),
            shortcutHintLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HMargin),
            shortcutHintLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HMargin),

            // 开机自启 + 设置快捷键
            launchAtLoginSwitch.topAnchor.constraint(equalTo: shortcutHintLabel.bottomAnchor, constant: 14),
            launchAtLoginSwitch.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HMargin),
            recordButton.centerYAnchor.constraint(equalTo: launchAtLoginSwitch.centerYAnchor),
            recordButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HMargin),

            // 底部分隔线
            separator.topAnchor.constraint(equalTo: launchAtLoginSwitch.bottomAnchor, constant: 16),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HMargin),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HMargin),
            separator.heightAnchor.constraint(equalToConstant: 1),

            // 版本号 + 完成按钮：紧贴分隔线下方，完成按钮的底就是链的终点
            versionLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            versionLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HMargin),
            versionLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            doneButton.centerYAnchor.constraint(equalTo: versionLabel.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HMargin),

            // ═══ 状态卡片内部三栏（相对卡片顶部的固定 Y） ═══
            permissionDot.centerYAnchor.constraint(equalTo: statusBg.topAnchor, constant: 23),
            permissionDot.leadingAnchor.constraint(equalTo: statusBg.leadingAnchor, constant: 16),
            permissionDot.widthAnchor.constraint(equalToConstant: 12),
            permissionDot.heightAnchor.constraint(equalToConstant: 12),

            permissionLabel.centerYAnchor.constraint(equalTo: permissionDot.centerYAnchor),
            permissionLabel.leadingAnchor.constraint(equalTo: permissionDot.trailingAnchor, constant: 8),
            permissionLabel.widthAnchor.constraint(equalTo: tapLabel.widthAnchor),

            permissionValue.centerYAnchor.constraint(equalTo: permissionDot.centerYAnchor),
            permissionValue.leadingAnchor.constraint(equalTo: permissionLabel.trailingAnchor, constant: 10),
            permissionValue.trailingAnchor.constraint(lessThanOrEqualTo: permissionButton.leadingAnchor, constant: -10),

            permissionButton.centerYAnchor.constraint(equalTo: permissionDot.centerYAnchor),
            permissionButton.trailingAnchor.constraint(equalTo: statusBg.trailingAnchor, constant: -12),

            tapDot.centerYAnchor.constraint(equalTo: statusBg.topAnchor, constant: 51),
            tapDot.leadingAnchor.constraint(equalTo: statusBg.leadingAnchor, constant: 16),
            tapDot.widthAnchor.constraint(equalToConstant: 12),
            tapDot.heightAnchor.constraint(equalToConstant: 12),

            tapLabel.centerYAnchor.constraint(equalTo: tapDot.centerYAnchor),
            tapLabel.leadingAnchor.constraint(equalTo: tapDot.trailingAnchor, constant: 8),

            tapValue.centerYAnchor.constraint(equalTo: tapDot.centerYAnchor),
            tapValue.leadingAnchor.constraint(equalTo: tapLabel.trailingAnchor, constant: 10),
            tapValue.trailingAnchor.constraint(lessThanOrEqualTo: tapButton.leadingAnchor, constant: -10),

            tapButton.centerYAnchor.constraint(equalTo: tapDot.centerYAnchor),
            tapButton.trailingAnchor.constraint(equalTo: statusBg.trailingAnchor, constant: -12)
        ])
    }

    // MARK: 状态刷新

    private func startStatusRefresher() {
        guard statusTimer == nil else { return }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 拿到权限后若 event tap 尚未建立，则建立
            if self.eventTap == nil, isAccessibilityTrusted(prompt: false) {
                self.startEventTap()
            }
            self.refreshStatus()
        }
    }

    private func refreshStatus() {
        let permissionOK = isAccessibilityTrusted(prompt: false)
        let tapOK = eventTap != nil

        permissionDot.isOk = permissionOK
        tapDot.isOk = tapOK

        permissionValue.stringValue = permissionOK ? "✓ 已授权" : "未授权"
        permissionValue.textColor = permissionOK ? .systemGreen : .systemRed
        tapValue.stringValue = tapOK ? "运行中" : "未运行"
        tapValue.textColor = tapOK ? .systemGreen : .secondaryLabelColor

        // 按钮永远显示：未授权时为「前往授权」并触发系统弹窗；已授权后降级为「打开设置」
        if permissionOK {
            permissionButton.title = "打开设置"
            permissionButton.action = #selector(openAccessibilityPanel)
            permissionButton.keyEquivalent = ""
        } else {
            permissionButton.title = "前往授权"
            permissionButton.action = #selector(requestPermission)
            // ⏎ 作为 keyEquivalent 让按钮可高亮（不实际触发授权流程）
        }
        tapButton.title = "打开设置"
        tapButton.action = #selector(openAccessibilityPanel)

        if !monitorIsActive() {
            shortcutLabel.stringValue = currentShortcut.label
        }
        statusItem?.button?.toolTip = "鼠标中键映射助手 · 权限\(permissionOK ? "✓" : "✗") · 监听\(tapOK ? "中" : "停")"
    }

    private func monitorIsActive() -> Bool { monitor != nil }

    // MARK: 触发反馈

    private func flashTriggered() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.shortcutBox.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.2).cgColor
            self.shortcutLabel.stringValue = "✓ 已触发"
            self.shortcutLabel.textColor = .systemGreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.restoreShortcutBox()
            }
        }
    }

    private func restoreShortcutBox() {
        shortcutBox.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        shortcutLabel.stringValue = currentShortcut.label
        shortcutLabel.textColor = .labelColor
    }

    // MARK: Event Tap（监听中键）

    private func startEventTap() {
        guard eventTap == nil else { return }
        guard isAccessibilityTrusted(prompt: false) else { return }

        let eventMask =
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = (NSApp.delegate as? AppDelegate)?.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passRetained(event)
                }

                guard type == .otherMouseDown || type == .otherMouseUp else {
                    return Unmanaged.passRetained(event)
                }

                let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
                guard buttonNumber == middleMouseButtonNumber else {
                    return Unmanaged.passRetained(event)
                }

                if type == .otherMouseDown {
                    (NSApp.delegate as? AppDelegate)?.pressMapping()
                } else {
                    (NSApp.delegate as? AppDelegate)?.releaseMapping()
                }
                return nil
            },
            userInfo: nil
        )

        guard let eventTap else { return }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func pressMapping() {
        guard !mappingIsDown else { return }
        mappingIsDown = true
        pressedKeys.removeAll()
        currentShortcut = loadShortcut()

        flashTriggered()

        if currentShortcut.keyCode == rightCommandKeyCode && currentShortcut.modifierKeyCodes.isEmpty {
            postRightCommand(keyDown: true)
            pressedKeys.append(rightCommandKeyCode)
            return
        }

        var activeFlags: CGEventFlags = []
        for keyCode in currentShortcut.modifierKeyCodes {
            if let modifier = modifierKeyCodes[keyCode] {
                activeFlags.insert(modifier.cgFlag)
            }
            postKey(keyCode, keyDown: true, flags: activeFlags)
            pressedKeys.append(keyCode)
        }

        postKey(currentShortcut.keyCode, keyDown: true, flags: currentShortcut.flags)
        pressedKeys.append(currentShortcut.keyCode)
    }

    private func releaseMapping() {
        guard mappingIsDown || !pressedKeys.isEmpty else { return }
        if pressedKeys == [rightCommandKeyCode] {
            postRightCommand(keyDown: false)
            pressedKeys.removeAll()
            mappingIsDown = false
            return
        }

        for keyCode in pressedKeys.reversed() {
            postKey(keyCode, keyDown: false, flags: [])
        }
        pressedKeys.removeAll()
        mappingIsDown = false
    }

    // MARK: 按钮动作

    // 点击「前往授权」：同时打开辅助功能面板 + 触发系统授权弹窗
    @objc private func requestPermission() {
        _ = isAccessibilityTrusted(prompt: true)
        openAccessibilitySettings()
    }

    // 点击「打开设置」：仅打开辅助功能面板，供已授权用户手动检查
    @objc private func openAccessibilityPanel() {
        openAccessibilitySettings()
    }

    @objc private func toggleLaunchAtLogin() {
        if launchAtLoginSwitch.state == .on {
            if isRunningFromDiskImage() {
                launchAtLoginSwitch.state = .off
                shortcutHintLabel.stringValue = "请先把应用拖到 Applications，再开启开机自启。"
                return
            }
            if !installLaunchAtLogin() {
                launchAtLoginSwitch.state = .off
            }
        } else {
            removeLaunchAtLogin()
        }
    }

    @objc private func startRecording() {
        shortcutHintLabel.stringValue = "请按下目标 App 里设置的快捷键（单独的右 Command 也可以）"
        recordButton.isEnabled = false

        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, let shortcut = shortcutFromEvent(event) else { return nil }

            self.currentShortcut = shortcut
            saveShortcut(shortcut)

            if let monitor = self.monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            self.recordButton.isEnabled = true
            self.restoreShortcutBox()
            self.shortcutHintLabel.stringValue = "已保存。现在可以按住鼠标中键测试。"
            return nil
        }
    }

    @objc private func done() {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - 启动

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(CommandLine.arguments.contains("--login") ? .accessory : .regular)
app.run()
