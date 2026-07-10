// ClaudeUsageBar menu bar app.
//
// An NSStatusItem agent (no Dock icon) that runs a minimal HTTP server bound to
// 127.0.0.1:8787 only. A browser extension POSTs the current Claude.ai usage
// figures to /usage and the app renders them in the menu bar. The server is
// never reachable off the loopback interface.

import Cocoa
import Network
import ServiceManagement
import UserNotifications

// MARK: - Settings keys

private let kShowFiveHour = "showFiveHourInTitle"
private let kShowWeekly = "showWeeklyInTitle"
private let kShowClaudeLabel = "showClaudeLabelInTitle"
private let kShowResetsAtLabel = "showResetsAtLabelInTitle"
private let kShowResetCountdown = "showResetCountdownInTitle"
private let kAlarmAtFiveHourReset = "alarmAtFiveHourReset"
private let kNotificationSound = "notificationSound"
private let kShowCodexFiveHour = "showCodexFiveHourInTitle"
private let kShowCodexWeekly = "showCodexWeeklyInTitle"
private let kClaudeTitleColor = "claudeTitleColor"
private let kCodexTitleColor = "codexTitleColor"

// MARK: - Shared state

/// One usage figure: a short token for the title, a longer detail line, and a
/// reset hint.
private struct Metric {
    var value = ""
    var detail = ""
    var reset = ""
}

/// Usage figures for one provider (Claude or Codex).
private struct ProviderUsage {
    var fiveHour = Metric()
    var weekly = Metric()
    var lastUpdate: Date? // nil until the first figure arrives
}

/// A consistent snapshot for rendering.
private struct Snapshot {
    let claude: ProviderUsage
    let codex: ProviderUsage
    let claudeStale: Bool
    let codexStale: Bool
    let lastUpdate: Date? // most recent update from either provider
}

/// Holds the latest usage figures. All access is serialized so the network
/// callbacks and the main thread never race.
final class UsageState {
    typealias Group = (value: String, detail: String, reset: String)

    private let queue = DispatchQueue(label: "com.claudeusagebar.state")
    private var claude = ProviderUsage()
    private var codex = ProviderUsage()

    /// Applies a Claude usage update. Nil groups are left unchanged. Values are
    /// treated as untrusted: control characters are stripped and length is
    /// capped before they ever reach the menu bar.
    func updateClaude(fiveHour: Group?, weekly: Group?) {
        guard fiveHour != nil || weekly != nil else { return }
        queue.sync {
            if let f = fiveHour { claude.fiveHour = UsageState.metric(f) }
            if let w = weekly { claude.weekly = UsageState.metric(w) }
            claude.lastUpdate = Date()
        }
    }

    /// Applies a Codex usage update.
    func updateCodex(fiveHour: Group?, weekly: Group?) {
        guard fiveHour != nil || weekly != nil else { return }
        queue.sync {
            if let f = fiveHour { codex.fiveHour = UsageState.metric(f) }
            if let w = weekly { codex.weekly = UsageState.metric(w) }
            codex.lastUpdate = Date()
        }
    }

    fileprivate var snapshot: Snapshot {
        queue.sync {
            func stale(_ date: Date?) -> Bool {
                date.map { Date().timeIntervalSince($0) > 600 } ?? false
            }
            let last = [claude.lastUpdate, codex.lastUpdate].compactMap { $0 }.max()
            return Snapshot(claude: claude, codex: codex,
                            claudeStale: stale(claude.lastUpdate),
                            codexStale: stale(codex.lastUpdate),
                            lastUpdate: last)
        }
    }

    private static func metric(_ g: Group) -> Metric {
        Metric(value: sanitize(g.value), detail: sanitize(g.detail), reset: sanitize(g.reset))
    }

    private static func sanitize(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.prefix(120)
        return String(String.UnicodeScalarView(scalars))
    }
}

// MARK: - HTTP request

private struct HTTPRequest {
    let method: String
    let path: String
    let host: String
    let origin: String
    let body: Data
}

private enum ParseResult {
    case incomplete       // need more bytes
    case ready(HTTPRequest)
    case bad              // malformed or out of bounds, close with 400
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let state = UsageState()
    private let port: NWEndpoint.Port = 8787
    private let netQueue = DispatchQueue(label: "com.claudeusagebar.http")

    // Title turns orange at this percent, red at the higher one. A notification
    // fires once each time a figure crosses the red line upward.
    private let warnPercent = 75
    private let critPercent = 90
    private let resetAlarmIdentifier = "five-hour-reset-alarm"
    private let notificationSounds = [
        "Default", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    // Title colours per provider. "Brand" is the provider's own colour, "System"
    // is the plain menu bar colour. Warn/crit colouring still overrides these.
    private static let claudeBrandColor = NSColor(srgbRed: 217/255, green: 119/255, blue: 87/255, alpha: 1)  // #D97757
    private static let codexBrandColor = NSColor(srgbRed: 16/255, green: 163/255, blue: 127/255, alpha: 1)   // #10A37F
    private let colorChoices: [(name: String, color: NSColor?)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
        ("Green", .systemGreen), ("Mint", .systemMint), ("Teal", .systemTeal),
        ("Cyan", .systemCyan), ("Blue", .systemBlue), ("Indigo", .systemIndigo),
        ("Purple", .systemPurple), ("Pink", .systemPink), ("Brown", .systemBrown),
        ("Gray", .systemGray)
    ]

    private var notificationsAuthorized = false
    private var scheduledResetAlarm = ""
    private var lastFivePercent: Int? // nil until the first reading, to avoid
    private var lastWeeklyPercent: Int? // notifying on launch for an existing high
    private var lastCodexFivePercent: Int?
    private var lastCodexWeeklyPercent: Int?

    // Hardening limits and allow lists.
    private let maxBodyBytes = 65536
    private let maxRequestBytes = 65536 + 8192 // body cap plus header slack
    private let allowedHosts: Set<String> = ["127.0.0.1:8787", "localhost:8787"]
    private let allowedOrigins: Set<String> = ["https://claude.ai", "https://chatgpt.com"]
    private let defaultOrigin = "https://claude.ai"

    private var statusItem: NSStatusItem!
    private var fiveDetailItem: NSMenuItem!
    private var fiveResetItem: NSMenuItem!
    private var weeklyDetailItem: NSMenuItem!
    private var weeklyResetItem: NSMenuItem!
    private var codexFiveDetailItem: NSMenuItem!
    private var codexFiveResetItem: NSMenuItem!
    private var codexWeeklyDetailItem: NSMenuItem!
    private var codexWeeklyResetItem: NSMenuItem!
    private var updatedItem: NSMenuItem!
    private var showFiveItem: NSMenuItem!
    private var showWeeklyItem: NSMenuItem!
    private var showCodexFiveItem: NSMenuItem!
    private var showCodexWeeklyItem: NSMenuItem!
    private var showClaudeItem: NSMenuItem!
    private var claudeColorMenu: NSMenu!
    private var codexColorMenu: NSMenu!
    private var showResetsAtItem: NSMenuItem!
    private var showResetCountdownItem: NSMenuItem!
    private var resetAlarmItem: NSMenuItem!
    private var notificationSoundItems: [NSMenuItem] = []
    private var previewedSoundItem: NSMenuItem?
    private var startAtLoginItem: NSMenuItem!
    private var listener: NWListener?
    private var timer: Timer?
    private var renderTimerInterval: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            kShowFiveHour: true,
            kShowWeekly: false,
            kShowCodexFiveHour: false,
            kShowCodexWeekly: false,
            kShowClaudeLabel: true,
            kShowResetsAtLabel: true,
            kShowResetCountdown: false,
            kAlarmAtFiveHourReset: false,
            kNotificationSound: "Default",
            kClaudeTitleColor: "Brand",
            kCodexTitleColor: "Brand"
        ])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        setupNotifications()
        render()
        startServer()
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Sync usage with Claude.ai", action: #selector(openClaude), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let openChatGPT = NSMenuItem(title: "Sync usage with ChatGPT", action: #selector(openChatGPTUsage), keyEquivalent: "")
        openChatGPT.target = self
        menu.addItem(openChatGPT)

        menu.addItem(.separator())

        // Display-only lines. Passing action: nil leaves them auto-disabled.
        fiveDetailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(fiveDetailItem)
        fiveResetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(fiveResetItem)

        menu.addItem(.separator())

        weeklyDetailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(weeklyDetailItem)
        weeklyResetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(weeklyResetItem)

        menu.addItem(.separator())

        codexFiveDetailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(codexFiveDetailItem)
        codexFiveResetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(codexFiveResetItem)
        codexWeeklyDetailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(codexWeeklyDetailItem)
        codexWeeklyResetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(codexWeeklyResetItem)

        menu.addItem(.separator())

        updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(updatedItem)

        menu.addItem(.separator())

        // Settings submenu: choose what appears in the menu bar title.
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        showFiveItem = NSMenuItem(title: "Show Claude 5-hour in title", action: #selector(toggleFiveHour), keyEquivalent: "")
        showFiveItem.target = self
        submenu.addItem(showFiveItem)
        showWeeklyItem = NSMenuItem(title: "Show Claude weekly in title", action: #selector(toggleWeekly), keyEquivalent: "")
        showWeeklyItem.target = self
        submenu.addItem(showWeeklyItem)
        showCodexFiveItem = NSMenuItem(title: "Show Codex 5-hour in title", action: #selector(toggleCodexFiveHour), keyEquivalent: "")
        showCodexFiveItem.target = self
        submenu.addItem(showCodexFiveItem)
        showCodexWeeklyItem = NSMenuItem(title: "Show Codex weekly in title", action: #selector(toggleCodexWeekly), keyEquivalent: "")
        showCodexWeeklyItem.target = self
        submenu.addItem(showCodexWeeklyItem)

        showClaudeItem = NSMenuItem(title: "Show provider labels", action: #selector(toggleClaudeLabel), keyEquivalent: "")
        showClaudeItem.target = self
        submenu.addItem(showClaudeItem)

        showResetsAtItem = NSMenuItem(title: "Show \"Resets at\" label", action: #selector(toggleResetsAtLabel), keyEquivalent: "")
        showResetsAtItem.target = self
        submenu.addItem(showResetsAtItem)

        showResetCountdownItem = NSMenuItem(title: "Show reset countdown", action: #selector(toggleResetCountdown), keyEquivalent: "")
        showResetCountdownItem.target = self
        submenu.addItem(showResetCountdownItem)

        resetAlarmItem = NSMenuItem(title: "Alarm at 5-hour reset", action: #selector(toggleResetAlarm), keyEquivalent: "")
        resetAlarmItem.target = self
        submenu.addItem(resetAlarmItem)

        let claudeColorItem = NSMenuItem(title: "Claude color", action: nil, keyEquivalent: "")
        claudeColorMenu = buildColorMenu(brand: AppDelegate.claudeBrandColor, action: #selector(selectClaudeColor))
        claudeColorItem.submenu = claudeColorMenu
        submenu.addItem(claudeColorItem)

        let codexColorItem = NSMenuItem(title: "Codex color", action: nil, keyEquivalent: "")
        codexColorMenu = buildColorMenu(brand: AppDelegate.codexBrandColor, action: #selector(selectCodexColor))
        codexColorItem.submenu = codexColorMenu
        submenu.addItem(codexColorItem)

        let soundItem = NSMenuItem(title: "Notification sound", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        soundMenu.delegate = self
        for sound in notificationSounds {
            let item = NSMenuItem(title: sound, action: #selector(selectNotificationSound), keyEquivalent: "")
            item.target = self
            item.representedObject = sound
            soundMenu.addItem(item)
            notificationSoundItems.append(item)
        }
        soundItem.submenu = soundMenu
        submenu.addItem(soundItem)

        // Start at login. Only offered on macOS 13+, where SMAppService exists.
        if #available(macOS 13.0, *) {
            submenu.addItem(.separator())
            startAtLoginItem = NSMenuItem(title: "Start at login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
            startAtLoginItem.target = self
            submenu.addItem(startAtLoginItem)
        }

        settings.submenu = submenu
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// One palette submenu: the provider's brand colour, the plain system
    /// colour, then the named system colours. Each item carries a swatch.
    private func buildColorMenu(brand: NSColor, action: Selector) -> NSMenu {
        let menu = NSMenu()
        func add(_ name: String, _ color: NSColor?, title: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.image = swatchImage(color)
            menu.addItem(item)
        }
        add("Brand", brand, title: "Brand default")
        add("System", nil, title: "System")
        menu.addItem(.separator())
        for choice in colorChoices { add(choice.name, choice.color, title: choice.name) }
        return menu
    }

    private func swatchImage(_ color: NSColor?) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            (color ?? .labelColor).setFill()
            path.fill()
            NSColor.tertiaryLabelColor.setStroke()
            path.stroke()
            return true
        }
    }

    /// The stored title colour for a provider: nil means the plain system colour.
    private func providerColor(forKey key: String, brand: NSColor) -> NSColor? {
        let name = UserDefaults.standard.string(forKey: key) ?? "Brand"
        if name == "System" { return nil }
        if name == "Brand" { return brand }
        return colorChoices.first(where: { $0.name == name })?.color ?? brand
    }

    private func updateColorMenuChecks(menu: NSMenu, key: String) {
        let selected = UserDefaults.standard.string(forKey: key) ?? "Brand"
        for item in menu.items {
            guard let name = item.representedObject as? String else { continue }
            item.state = name == selected ? .on : .off
        }
    }

    private func render() {
        let s = state.snapshot
        let defaults = UserDefaults.standard
        let showFive = defaults.bool(forKey: kShowFiveHour)
        let showWeekly = defaults.bool(forKey: kShowWeekly)
        let showCodexFive = defaults.bool(forKey: kShowCodexFiveHour)
        let showCodexWeekly = defaults.bool(forKey: kShowCodexWeekly)
        let showLabels = defaults.bool(forKey: kShowClaudeLabel)
        let showResetsAt = defaults.bool(forKey: kShowResetsAtLabel)
        let showResetCountdown = defaults.bool(forKey: kShowResetCountdown)
        let resetAlarmEnabled = defaults.bool(forKey: kAlarmAtFiveHourReset)
        let codex = s.codex

        // Title: one segment per provider, joined with a dot. A stale provider
        // shows "(stale)" without dragging the other one down with it. Each
        // segment gets its provider's colour; warn/crit colouring overrides it
        // per segment based on that provider's own figures.
        var claudePercents: [Int] = []

        var claudeParts: [String] = []
        if !s.claudeStale {
            if showFive, !s.claude.fiveHour.value.isEmpty {
                if let fivePercent = percent(s.claude.fiveHour.value), fivePercent >= 100, !s.claude.fiveHour.reset.isEmpty {
                    let resetValue = showResetCountdown
                        ? resetCountdown(toClock: s.claude.fiveHour.reset) ?? s.claude.fiveHour.reset
                        : s.claude.fiveHour.reset
                    claudeParts.append(showResetsAt ? "Resets at \(resetValue)" : resetValue)
                } else {
                    claudeParts.append(s.claude.fiveHour.value)
                }
                if let p = percent(s.claude.fiveHour.value) { claudePercents.append(p) }
            }
            if showWeekly, !s.claude.weekly.value.isEmpty {
                claudeParts.append(s.claude.weekly.value + (showFive ? "" : " wk"))
                if let p = percent(s.claude.weekly.value) { claudePercents.append(p) }
            }
        }

        var codexPercents: [Int] = []
        var codexParts: [String] = []
        if !s.codexStale {
            if showCodexFive, !codex.fiveHour.value.isEmpty {
                codexParts.append(codex.fiveHour.value)
                if let p = percent(codex.fiveHour.value) { codexPercents.append(p) }
            }
            if showCodexWeekly, !codex.weekly.value.isEmpty {
                codexParts.append(codex.weekly.value + (showCodexFive ? "" : " wk"))
                if let p = percent(codex.weekly.value) { codexPercents.append(p) }
            }
        }

        func segment(label: String, parts: [String], stale: Bool, anyShown: Bool) -> String? {
            guard anyShown else { return nil }
            let prefix = showLabels ? label + " " : ""
            if stale { return prefix + "(stale)" }
            if parts.isEmpty { return prefix + "--" }
            return prefix + parts.joined(separator: " / ")
        }

        let claudeColor = providerColor(forKey: kClaudeTitleColor, brand: AppDelegate.claudeBrandColor)
        let codexColor = providerColor(forKey: kCodexTitleColor, brand: AppDelegate.codexBrandColor)

        var segments: [(text: String, color: NSColor?)] = []
        if let text = segment(label: "Claude", parts: claudeParts, stale: s.claudeStale, anyShown: showFive || showWeekly) {
            segments.append((text, warnColor(forPercent: claudePercents.max()) ?? claudeColor))
        }
        if let text = segment(label: "Codex", parts: codexParts, stale: s.codexStale, anyShown: showCodexFive || showCodexWeekly) {
            segments.append((text, warnColor(forPercent: codexPercents.max()) ?? codexColor))
        }

        if segments.isEmpty {
            statusItem.button?.title = showLabels ? "Claude --" : "--"
        } else {
            let title = NSMutableAttributedString()
            for (index, seg) in segments.enumerated() {
                if index > 0 { title.append(NSAttributedString(string: " · ")) }
                var attrs: [NSAttributedString.Key: Any] = [:]
                if let color = seg.color { attrs[.foregroundColor] = color }
                title.append(NSAttributedString(string: seg.text, attributes: attrs))
            }
            statusItem.button?.attributedTitle = title
        }

        // Fire a notification if any figure just crossed the red line.
        checkThresholds(s)
        updateResetAlarm(reset: s.claude.fiveHour.reset, enabled: resetAlarmEnabled)

        // Detail lines.
        fiveDetailItem.title = s.claude.fiveHour.detail.isEmpty ? "Claude 5-hour: no data yet" : "Claude 5-hour: \(s.claude.fiveHour.detail)"
        fiveResetItem.title = resetLine(s.claude.fiveHour.reset, clock: true)
        weeklyDetailItem.title = s.claude.weekly.detail.isEmpty ? "Claude weekly: no data yet" : "Claude weekly: \(s.claude.weekly.detail)"
        weeklyResetItem.title = resetLine(s.claude.weekly.reset, clock: false)
        codexFiveDetailItem.title = codex.fiveHour.detail.isEmpty ? "Codex 5-hour: no data yet" : "Codex 5-hour: \(codex.fiveHour.detail)"
        codexFiveResetItem.title = resetLine(codex.fiveHour.reset, clock: true)
        codexWeeklyDetailItem.title = codex.weekly.detail.isEmpty ? "Codex weekly: no data yet" : "Codex weekly: \(codex.weekly.detail)"
        codexWeeklyResetItem.title = resetLine(codex.weekly.reset, clock: false)
        updatedItem.title = "Updated " + ago(s.lastUpdate)

        // Settings checkmarks.
        showFiveItem.state = showFive ? .on : .off
        showWeeklyItem.state = showWeekly ? .on : .off
        showCodexFiveItem.state = showCodexFive ? .on : .off
        showCodexWeeklyItem.state = showCodexWeekly ? .on : .off
        showClaudeItem.state = showLabels ? .on : .off
        updateColorMenuChecks(menu: claudeColorMenu, key: kClaudeTitleColor)
        updateColorMenuChecks(menu: codexColorMenu, key: kCodexTitleColor)
        showResetsAtItem.state = showResetsAt ? .on : .off
        showResetCountdownItem.state = showResetCountdown ? .on : .off
        resetAlarmItem.state = resetAlarmEnabled ? .on : .off
        let selectedSound = defaults.string(forKey: kNotificationSound) ?? "Default"
        for item in notificationSoundItems {
            item.state = item.representedObject as? String == selectedSound ? .on : .off
        }
        if #available(macOS 13.0, *), let item = startAtLoginItem {
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        configureRenderTimer()
    }

    private func configureRenderTimer() {
        let defaults = UserDefaults.standard
        let fivePercent = percent(state.snapshot.claude.fiveHour.value) ?? 0
        let countdownVisible = defaults.bool(forKey: kShowResetCountdown)
            && defaults.bool(forKey: kShowFiveHour)
            && fivePercent >= 100
        let interval: TimeInterval = countdownVisible ? 1 : 15
        guard interval != renderTimerInterval else { return }

        timer?.invalidate()
        renderTimerInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.render()
        }
    }

    /// Builds a "Resets ..." line, adding a countdown when the reset is a clock time.
    private func resetLine(_ reset: String, clock: Bool) -> String {
        guard !reset.isEmpty else { return "Resets: unknown" }
        var line = "Resets \(reset)"
        if clock, let countdown = countdown(toClock: reset) {
            line += " (\(countdown))"
        }
        return line
    }

    /// Parses a clock time like "3:00 PM" or "15:00" and returns "in 2h 14m"
    /// until its next occurrence, or nil if it cannot be parsed.
    private func countdown(toClock reset: String) -> String? {
        guard let next = nextDate(forClock: reset) else { return nil }
        let diff = Int(next.timeIntervalSinceNow)
        guard diff > 0 else { return nil }
        let hours = diff / 3600
        let minutes = (diff % 3600) / 60
        return hours > 0 ? "in \(hours)h \(minutes)m" : "in \(minutes)m"
    }

    private func resetCountdown(toClock reset: String) -> String? {
        guard let next = nextDate(forClock: reset) else { return nil }
        let seconds = max(0, Int(next.timeIntervalSinceNow))
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func nextDate(forClock reset: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let trimmed = reset.trimmingCharacters(in: .whitespaces)
        for format in ["h:mm a", "H:mm"] {
            formatter.dateFormat = format
            guard let time = formatter.date(from: trimmed) else { continue }
            let calendar = Calendar.current
            let comps = calendar.dateComponents([.hour, .minute], from: time)
            return calendar.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime)
        }
        return nil
    }

    /// A coarse "12s ago" / "3m ago" string for the last update.
    private func ago(_ date: Date?) -> String {
        guard let date = date else { return "never" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    /// Parses the leading integer out of a value like "42%". Returns nil when the
    /// value has no number (for example "" or "--").
    private func percent(_ value: String) -> Int? {
        let digits = value.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// The title colour for a percentage: red when critical, orange when high,
    /// nil (default colour) otherwise.
    private func warnColor(forPercent pct: Int?) -> NSColor? {
        guard let pct = pct else { return nil }
        if pct >= critPercent { return .systemRed }
        if pct >= warnPercent { return .systemOrange }
        return nil
    }

    // MARK: Notifications

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.notificationsAuthorized = granted
                self?.render()
            }
        }
    }

    private func updateResetAlarm(reset: String, enabled: Bool) {
        let center = UNUserNotificationCenter.current()
        guard enabled else {
            center.removePendingNotificationRequests(withIdentifiers: [resetAlarmIdentifier])
            scheduledResetAlarm = ""
            return
        }
        guard notificationsAuthorized, !reset.isEmpty, let date = nextDate(forClock: reset) else {
            return
        }
        guard scheduledResetAlarm != reset else { return }

        center.removePendingNotificationRequests(withIdentifiers: [resetAlarmIdentifier])
        let content = UNMutableNotificationContent()
        content.title = "Claude 5-hour limit reset"
        content.body = "Your 5-hour usage limit has reset."
        content.sound = notificationSound()
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: resetAlarmIdentifier, content: content, trigger: trigger)
        center.add(request)
        scheduledResetAlarm = reset
    }

    /// Notifies once when a figure crosses the critical line upward. The first
    /// reading only establishes a baseline so a relaunch at an already-high figure
    /// does not spam a notification.
    private func checkThresholds(_ s: Snapshot) {
        maybeNotify(provider: "Claude", label: "5-hour", pct: percent(s.claude.fiveHour.value), last: &lastFivePercent)
        maybeNotify(provider: "Claude", label: "Weekly", pct: percent(s.claude.weekly.value), last: &lastWeeklyPercent)
        maybeNotify(provider: "Codex", label: "5-hour", pct: percent(s.codex.fiveHour.value), last: &lastCodexFivePercent)
        maybeNotify(provider: "Codex", label: "Weekly", pct: percent(s.codex.weekly.value), last: &lastCodexWeeklyPercent)
    }

    private func maybeNotify(provider: String, label: String, pct: Int?, last: inout Int?) {
        guard let pct = pct else { return }
        defer { last = pct }
        guard let prev = last else { return } // baseline only on first reading
        if prev < critPercent && pct >= critPercent {
            postNotification(title: "\(provider) usage high",
                             body: "\(provider) \(label) limit at \(pct)% used.")
        }
    }

    private func postNotification(title: String, body: String) {
        guard notificationsAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = notificationSound()
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func notificationSound() -> UNNotificationSound {
        let sound = UserDefaults.standard.string(forKey: kNotificationSound) ?? "Default"
        guard sound != "Default" else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: "\(sound).aiff"))
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let item = item, notificationSoundItems.contains(where: { $0 === item }) else {
            previewedSoundItem = nil
            return
        }
        guard previewedSoundItem !== item, let sound = item.representedObject as? String else { return }
        previewedSoundItem = item
        previewSound(named: sound)
    }

    private func previewSound(named sound: String) {
        if sound == "Default" {
            NSSound.beep()
        } else {
            NSSound(named: NSSound.Name(sound))?.play()
        }
    }

    /// Show banners even though the app is a background agent.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    @objc private func openClaude() {
        if let url = URL(string: "https://claude.ai/new#settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openChatGPTUsage() {
        if let url = URL(string: "https://chatgpt.com/codex/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleCodexFiveHour() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: kShowCodexFiveHour), forKey: kShowCodexFiveHour)
        render()
    }

    @objc private func toggleCodexWeekly() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: kShowCodexWeekly), forKey: kShowCodexWeekly)
        render()
    }

    @objc private func selectClaudeColor(_ sender: NSMenuItem) {
        setTitleColor(sender, key: kClaudeTitleColor)
    }

    @objc private func selectCodexColor(_ sender: NSMenuItem) {
        setTitleColor(sender, key: kCodexTitleColor)
    }

    private func setTitleColor(_ sender: NSMenuItem, key: String) {
        guard let name = sender.representedObject as? String else { return }
        UserDefaults.standard.set(name, forKey: key)
        render()
    }

    @objc private func toggleFiveHour() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: kShowFiveHour), forKey: kShowFiveHour)
        render()
    }

    @objc private func toggleWeekly() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: kShowWeekly), forKey: kShowWeekly)
        render()
    }

    @objc private func toggleClaudeLabel() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: kShowClaudeLabel), forKey: kShowClaudeLabel)
        render()
    }

    @objc private func toggleResetsAtLabel() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: kShowResetsAtLabel), forKey: kShowResetsAtLabel)
        render()
    }

    @objc private func toggleResetCountdown() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: kShowResetCountdown), forKey: kShowResetCountdown)
        render()
    }

    @objc private func toggleResetAlarm() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: kAlarmAtFiveHourReset), forKey: kAlarmAtFiveHourReset)
        render()
    }

    @objc private func selectNotificationSound(_ sender: NSMenuItem) {
        guard let sound = sender.representedObject as? String else { return }
        UserDefaults.standard.set(sound, forKey: kNotificationSound)
        scheduledResetAlarm = ""
        render()
    }

    /// Toggles the app's launch-at-login registration via SMAppService. The state
    /// lives in the system login items, so no local persistence is needed.
    @available(macOS 13.0, *)
    @objc private func toggleStartAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("ClaudeUsageBar: start-at-login toggle failed: \(error)")
        }
        render()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: HTTP server

    private func startServer() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Force the bind to loopback only. The socket is never exposed off 127.0.0.1.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        guard let listener = try? NWListener(using: params) else {
            NSLog("ClaudeUsageBar: failed to bind 127.0.0.1:\(port)")
            return
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            connection.start(queue: self.netQueue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: netQueue)
    }

    /// Reads from a connection until a complete request is buffered, then handles it.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }

            switch self.parse(buffer) {
            case .ready(let request):
                self.handle(request, on: connection)
            case .bad:
                self.send(status: "400 Bad Request", body: "bad request", on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    /// Splits on the \r\n\r\n boundary, parses the request line and headers, and
    /// returns .incomplete until the body reaches Content-Length. Rejects
    /// malformed requests, oversized requests, and out of range Content-Length.
    private func parse(_ data: Data) -> ParseResult {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxRequestBytes ? .bad : .incomplete
        }
        let headerData = data.subdata(in: data.startIndex..<separator.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return .bad }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .bad }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .bad }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        var host = ""
        var origin = ""
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if key == "content-length" {
                // Reject negative or oversized lengths to avoid a crash or unbounded buffering.
                guard let n = Int(value), n >= 0, n <= maxBodyBytes else { return .bad }
                contentLength = n
            } else if key == "host" {
                host = value
            } else if key == "origin" {
                origin = value
            }
        }

        let bodyStart = separator.upperBound
        let available = data.endIndex - bodyStart
        if available < contentLength { return .incomplete } // body not complete yet
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return .ready(HTTPRequest(method: method, path: path, host: host, origin: origin, body: body))
    }

    /// Routes the request and writes a response. Requests with an unexpected Host
    /// header are rejected to block DNS rebinding from other origins.
    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        guard allowedHosts.contains(request.host.lowercased()) else {
            send(status: "403 Forbidden", body: "forbidden", origin: request.origin, on: connection)
            return
        }

        switch (request.method, request.path) {
        case ("OPTIONS", _):
            send(status: "204 No Content", body: "", origin: request.origin, on: connection)
        case ("GET", "/health"):
            send(status: "200 OK", body: "ok", origin: request.origin, on: connection)
        case ("POST", "/usage"):
            if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
                func group(_ node: Any?) -> UsageState.Group? {
                    guard let d = node as? [String: Any] else { return nil }
                    return (d["value"] as? String ?? "", d["detail"] as? String ?? "", d["reset"] as? String ?? "")
                }
                let provider = (json["provider"] as? String) ?? "claude"
                let fiveHour = group(json["five_hour"])
                let weekly = group(json["weekly"])
                var rendered = false
                if provider == "codex" {
                    if fiveHour != nil || weekly != nil {
                        state.updateCodex(fiveHour: fiveHour, weekly: weekly)
                        rendered = true
                    }
                } else if provider == "claude" {
                    if fiveHour != nil || weekly != nil {
                        state.updateClaude(fiveHour: fiveHour, weekly: weekly)
                        rendered = true
                    }
                }
                if rendered {
                    DispatchQueue.main.async { [weak self] in self?.render() }
                }
            }
            send(status: "200 OK", body: "ok", origin: request.origin, on: connection)
        default:
            send(status: "404 Not Found", body: "", origin: request.origin, on: connection)
        }
    }

    /// Writes a response and closes the connection. CORS is locked to the known
    /// provider origins so other web origins cannot drive the local server from
    /// a page: the request Origin is echoed back only when it is allow-listed.
    private func send(status: String, body: String, origin: String = "", on connection: NWConnection) {
        let corsOrigin = allowedOrigins.contains(origin) ? origin : defaultOrigin
        let bodyData = Data(body.utf8)
        let head = """
        HTTP/1.1 \(status)\r
        Access-Control-Allow-Origin: \(corsOrigin)\r
        Access-Control-Allow-Methods: POST, GET, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type\r
        Content-Type: text/plain\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """
        var response = Data(head.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar agent, no Dock icon
app.run()
