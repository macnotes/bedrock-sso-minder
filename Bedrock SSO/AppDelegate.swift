//  AppDelegate.swift
//  Bedrock SSO

import Cocoa
import AppKit
import UserNotifications

enum ExpiryAction: String, CaseIterable {
    case autoLogin = "autoLogin"
    case notification = "notification"
    case redIcon = "redIcon"
    case pulseIcon = "pulseIcon"

    var label: String {
        switch self {
        case .autoLogin: return "Auto-attempt login"
        case .notification: return "Show notification"
        case .redIcon: return "Red icon"
        case .pulseIcon: return "Pulse icon"
        }
    }

    var defaultsKey: String { "expiryAction_\(rawValue)" }
}

enum CheckInterval: Int, CaseIterable {
    case five = 300
    case fifteen = 900
    case thirty = 1800

    var label: String {
        switch self {
        case .five: return "5 minutes"
        case .fifteen: return "15 minutes"
        case .thirty: return "30 minutes"
        }
    }
}

@main @MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var pulseTimer: Timer?
    var pulseVisible = true

    let profileName = "claude-code-bedrock"
    let shellPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    var isAuthenticated = false
    var wasAuthenticated = false
    var identityInfo: [String: String]? = nil

    // MARK: - Defaults helpers

    let defaults = UserDefaults.standard
    static let checkIntervalKey = "checkInterval"
    static let checkOnWakeKey = "checkOnWake"

    func isExpiryActionEnabled(_ action: ExpiryAction) -> Bool {
        if defaults.object(forKey: action.defaultsKey) == nil {
            // Sensible defaults: red icon on by default
            return action == .redIcon
        }
        return defaults.bool(forKey: action.defaultsKey)
    }

    func toggleExpiryAction(_ action: ExpiryAction) {
        defaults.set(!isExpiryActionEnabled(action), forKey: action.defaultsKey)
        rebuildMenu()
        applyExpiryVisuals()
    }

    var checkInterval: CheckInterval {
        get {
            let raw = defaults.integer(forKey: Self.checkIntervalKey)
            return CheckInterval(rawValue: raw) ?? .five
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.checkIntervalKey)
            rescheduleTimer()
            rebuildMenu()
        }
    }

    var checkOnWake: Bool {
        get {
            if defaults.object(forKey: Self.checkOnWakeKey) == nil { return true }
            return defaults.bool(forKey: Self.checkOnWakeKey)
        }
        set {
            defaults.set(newValue, forKey: Self.checkOnWakeKey)
            rebuildMenu()
        }
    }

    // MARK: - Lifecycle

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = createStatusImage(state: .inactive)
        }

        rebuildMenu()
        checkSSOStatus()
        rescheduleTimer()

        // Wake from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @objc func handleWake() {
        guard checkOnWake else { return }
        // Small delay to let networking come back up
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.checkSSOStatus()
        }
    }

    func rescheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: TimeInterval(checkInterval.rawValue),
            target: self,
            selector: #selector(checkSSOStatus),
            userInfo: nil,
            repeats: true
        )
    }

    // MARK: - Menu

    func rebuildMenu() {
        let menu = NSMenu()

        // Status
        let statusText = isAuthenticated ? "✅ Authenticated" : "❌ Not Authenticated"
        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        // Identity info
        if isAuthenticated, let info = identityInfo {
            if let user = info["UserId"] {
                let item = NSMenuItem(title: "User: \(user)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            if let account = info["Account"] {
                let item = NSMenuItem(title: "Account: \(account)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            if let arn = info["Arn"] {
                let shortArn = arn.components(separatedBy: "/").suffix(2).joined(separator: "/")
                let item = NSMenuItem(title: "Role: \(shortArn)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            let copyItem = NSMenuItem(title: "Copy Login Details", action: #selector(copyIdentityInfo), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
            menu.addItem(.separator())
        }

        // Actions
        let checkItem = NSMenuItem(title: "Refresh Status", action: #selector(checkSSOStatus), keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)

        if !isAuthenticated {
            let loginItem = NSMenuItem(title: "Login to AWS SSO", action: #selector(performSSOLogin), keyEquivalent: "")
            loginItem.target = self
            menu.addItem(loginItem)
        } else {
            let logoutItem = NSMenuItem(title: "Logout", action: #selector(performSSOLogout), keyEquivalent: "")
            logoutItem.target = self
            menu.addItem(logoutItem)
        }

        menu.addItem(.separator())

        // Settings submenu
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()

        let header = NSMenuItem(title: "On Expiry:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        settingsMenu.addItem(header)

        for action in ExpiryAction.allCases {
            let item = NSMenuItem(title: action.label, action: #selector(toggleExpiryMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            item.state = isExpiryActionEnabled(action) ? .on : .off
            settingsMenu.addItem(item)
        }

        settingsMenu.addItem(.separator())

        let wakeItem = NSMenuItem(title: "Check on wake from sleep", action: #selector(toggleWake), keyEquivalent: "")
        wakeItem.target = self
        wakeItem.state = checkOnWake ? .on : .off
        settingsMenu.addItem(wakeItem)

        settingsMenu.addItem(.separator())

        let intervalHeader = NSMenuItem(title: "Check Interval:", action: nil, keyEquivalent: "")
        intervalHeader.isEnabled = false
        settingsMenu.addItem(intervalHeader)

        for interval in CheckInterval.allCases {
            let item = NSMenuItem(title: interval.label, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval.rawValue
            item.state = checkInterval == interval ? .on : .off
            settingsMenu.addItem(item)
        }

        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Settings actions

    @objc func toggleExpiryMenuItem(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ExpiryAction else { return }
        toggleExpiryAction(action)
    }

    @objc func toggleWake() {
        checkOnWake = !checkOnWake
    }

    @objc func selectInterval(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let interval = CheckInterval(rawValue: raw) else { return }
        checkInterval = interval
    }

    // MARK: - Expiry behavior

    func handleExpiryTransition() {
        // Only fire these when we transition from authenticated -> expired
        guard wasAuthenticated, !isAuthenticated else { return }

        if isExpiryActionEnabled(.notification) {
            showNotification(
                title: "AWS SSO Expired",
                message: "Your SSO session for \(profileName) has expired."
            )
        }
        if isExpiryActionEnabled(.autoLogin) {
            performSSOLogin()
        }
    }

    func applyExpiryVisuals() {
        // Stop any existing pulse
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseVisible = true

        if isAuthenticated {
            updateIcon(state: .active)
        } else if isExpiryActionEnabled(.pulseIcon) {
            startPulsing()
        } else if isExpiryActionEnabled(.redIcon) {
            updateIcon(state: .expired)
        } else {
            updateIcon(state: .inactive)
        }
    }

    func startPulsing() {
        pulseVisible = true
        updateIcon(state: .inactive)
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            Task { @MainActor in
                self.pulseVisible.toggle()
                self.updateIcon(state: self.pulseVisible ? .inactive : .hidden)
            }
        }
    }

    // MARK: - Icon rendering

    enum IconState { case active, inactive, expired, hidden }

    func updateIcon(state: IconState) {
        if let button = statusItem.button {
            button.image = createStatusImage(state: state)
            button.toolTip = isAuthenticated ? "AWS SSO: Active" : "AWS SSO: Not authenticated"
        }
    }

    func createStatusImage(state: IconState) -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let color: NSColor = {
            switch state {
            case .active: return .systemGreen
            case .inactive: return .gray
            case .expired: return NSColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1.0)
            case .hidden: return .clear
            }
        }()
        color.setFill()

        let cloudRect = NSRect(x: 2, y: 6, width: 14, height: 8)
        let path = NSBezierPath()
        path.appendOval(in: NSRect(x: cloudRect.minX, y: cloudRect.minY, width: 5, height: 5))
        path.appendOval(in: NSRect(x: cloudRect.minX + 4, y: cloudRect.minY + 2, width: 6, height: 6))
        path.appendOval(in: NSRect(x: cloudRect.minX + 9, y: cloudRect.minY, width: 5, height: 5))
        path.fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: - Clipboard

    @objc func copyIdentityInfo() {
        guard let info = identityInfo else { return }
        let text = """
        UserId: \(info["UserId"] ?? "")
        Account: \(info["Account"] ?? "")
        Arn: \(info["Arn"] ?? "")
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - SSO commands

    @objc func checkSSOStatus() {
        Task.detached {
            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments = ["bash", "-c", "export PATH=\(self.shellPath); aws sts get-caller-identity --profile \(self.profileName)"]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            task.standardOutput = stdoutPipe
            task.standardError = stderrPipe

            do {
                try task.run()
                task.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let isActive = task.terminationStatus == 0

                var info: [String: String]? = nil
                if isActive, let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: String] {
                    info = json
                }

                let capturedInfo = info
                await MainActor.run {
                    self.wasAuthenticated = self.isAuthenticated
                    self.isAuthenticated = isActive
                    self.identityInfo = capturedInfo
                    self.rebuildMenu()
                    self.applyExpiryVisuals()
                    self.handleExpiryTransition()
                }
            } catch {
                await MainActor.run {
                    self.wasAuthenticated = self.isAuthenticated
                    self.isAuthenticated = false
                    self.identityInfo = nil
                    self.rebuildMenu()
                    self.applyExpiryVisuals()
                    self.handleExpiryTransition()
                }
            }
        }
    }

    @objc func performSSOLogout() {
        Task.detached {
            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments = ["bash", "-c", "export PATH=\(self.shellPath); aws sso logout --profile \(self.profileName)"]

            do {
                try task.run()
                task.waitUntilExit()
                await MainActor.run { self.checkSSOStatus() }
            } catch {
                await MainActor.run {
                    self.showNotification(title: "AWS SSO Logout Failed", message: "Failed to execute logout command")
                }
            }
        }
    }

    @objc func performSSOLogin() {
        Task.detached {
            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments = ["bash", "-c", "export PATH=\(self.shellPath); aws sso login --profile \(self.profileName)"]

            do {
                try task.run()
                task.waitUntilExit()
                await MainActor.run { self.checkSSOStatus() }
            } catch {
                await MainActor.run {
                    self.showNotification(title: "AWS SSO Login Failed", message: "Failed to execute login command")
                }
            }
        }
    }

    // MARK: - Notifications

    func showNotification(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
