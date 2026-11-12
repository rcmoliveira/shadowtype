// StatusItemController — menu-bar NSStatusItem (PRD FR-MB-1).
// Template SF Symbol icon + NSMenu: enable/disable, today's word count + cap,
// current model, open settings, pause for current app, quit. LSUIElement set in main.swift.
import Cocoa
import Carbon.HIToolbox   // IsSecureEventInputEnabled() for the "why is it silent?" menu row

// Menu actions are surfaced as NotificationCenter posts so AppDelegate can observe + wire
// without StatusItemController reaching into other components.
// INTEGRATOR-NOTE: observe these in AppDelegate.applicationDidFinishLaunching, e.g.
//   NotificationCenter.default.addObserver(forName: .shadowtypeToggleEnabled, ...) { _ in
//       self.statusItem.setEnabled(self.coordinator.toggleEnabled()) }   // reflect back checkmark
//   .shadowtypeOpenSettings -> self.settings.show()
//   .shadowtypePauseForApp  -> pause completions for NSWorkspace.shared.frontmostApplication?.bundleIdentifier (FR-PA-1)
//   .shadowtypeQuit         -> NSApp.terminate(nil)
// And push live data into the menu via setWordCount(_:), setModelName(_:), setEnabled(_:).
extension Notification.Name {
    static let shadowtypeToggleEnabled = Notification.Name("shadowtype.toggleEnabled")
    static let shadowtypeOpenSettings  = Notification.Name("shadowtype.openSettings")
    static let shadowtypePauseForApp   = Notification.Name("shadowtype.pauseForApp")
    // "Force suggestions here": turn completions on for the focused field even in an auto-idle context
    // (terminal/editor). AppDelegate calls coordinator.forceActivate(). Mirrors the ⌃` global hotkey.
    static let shadowtypeForceActivate = Notification.Name("shadowtype.forceActivate")
    static let shadowtypeQuit          = Notification.Name("shadowtype.quit")
    // Posted AFTER AppRules.shared is mutated from outside the Settings pane (the menu-bar "Pause for
    // current app"), so an open Apps & Domains pane re-reads the live rules instead of showing stale.
    static let shadowtypeAppRulesDidChange = Notification.Name("shadowtype.appRulesDidChange")
    // Posted after AppSettingsStore is mutated (per-app mid-line/autocorrect/Disable-Tab/collect-inputs).
    // Most consumers read the store live on the next keystroke, but the Tab tap caches its per-app
    // disable, so AppDelegate re-pushes it on this signal (a Settings change need not wait for an app-switch).
    static let shadowtypeAppSettingsDidChange = Notification.Name("shadowtype.appSettingsDidChange")
    // Posted by the menu-bar "Disable for app ▸" submenu when a (possibly non-frontmost) running app row
    // is toggled. userInfo["bundleId"] carries the target; AppDelegate flips its permanent AppRules rule.
    static let shadowtypeToggleAppDisabled = Notification.Name("shadowtype.toggleAppDisabled")
    // Posted by the Settings → Context completion-length picker after writing the stored preference
    // (CompletionLength.defaultsKey); AppDelegate re-applies engine.maxWords + coordinator.maxTokens.
    static let shadowtypeCompletionLengthChanged = Notification.Name("shadowtype.completionLengthChanged")
    // Auto-update (UpdateManager). `shadowtypeCheckUpdates` = the menu "Check for Updates…" item (manual,
    // ignores the toggle). `shadowtypeInstallUpdate` = the menu "Install Update…" item (swap + relaunch).
    // `shadowtypeUpdateAvailable` is posted by UpdateManager when a check finds a newer build (object =
    // UpdateManifest); AppDelegate reveals the menu install item + opens the About pane on a manual find.
    static let shadowtypeCheckUpdates    = Notification.Name("shadowtype.checkUpdates")
    static let shadowtypeInstallUpdate   = Notification.Name("shadowtype.installUpdate")
    static let shadowtypeUpdateAvailable = Notification.Name("shadowtype.updateAvailable")
}

final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?

    private let enableItem  = NSMenuItem(title: "Enable Shadowtype", action: nil, keyEquivalent: "")
    private let wordsItem   = NSMenuItem(title: "Words today: 0", action: nil, keyEquivalent: "")
    private let modelItem   = NSMenuItem(title: "Model: —", action: nil, keyEquivalent: "")
    // "Why is it silent?" row. IsSecureEventInputEnabled() is system-wide, so one other process
    // (loginwindow after a lock, a password manager, a parked sudo) suppresses suggestions in EVERY
    // app — the top cause of "it stopped working". Shown only while that is actually true, and it
    // names the holder (SecureInputOwner) so the user has something to act on.
    private let secureInputItem = NSMenuItem(title: "Paused: secure input active", action: nil, keyEquivalent: "")
    private let pauseItem   = NSMenuItem(title: "Pause for current app", action: nil, keyEquivalent: "")
    // "Disable for app ▸": its submenu is rebuilt live (NSMenuDelegate) from running visible apps.
    private let disableForAppItem = NSMenuItem(title: "Disable for app", action: nil, keyEquivalent: "")
    // Identity of the app submenu, so menuNeedsUpdate(_:) can tell it apart from the main menu (both
    // delegate to self). Without this the main menu would be wiped and rebuilt as an app list.
    private weak var appListSubmenu: NSMenu?
    // Auto-update: a persistent "Check for Updates…" item, plus an "Install Update…" item revealed only
    // once UpdateManager has a staged/available build.
    private let checkUpdatesItem  = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    private let installUpdateItem = NSMenuItem(title: "Install Update…", action: nil, keyEquivalent: "")
    // M1: Local API server toggle. Title flips to show on/off state + port. AppDelegate calls
    // `setLocalAPI(on:port:available:)` from its .shadowtypeLocalAPIDidChange observer.
    private let localAPIItem = NSMenuItem(title: "Local API: Off", action: nil, keyEquivalent: "")
    private let copyAPIURLItem = NSMenuItem(title: "Copy API URL", action: nil, keyEquivalent: "")
    private var currentLocalAPIURL: String?

    private var isEnabled = true

    // Last pushed meter state (today's accepted-word count), shown in the menu.
    private var lastCount = 0

    // General → menu-bar presentation toggles (mirrored from @AppStorage by AppDelegate.syncToggles).
    // showWordCount draws today's accepted-word count next to the glyph; iconStyle picks a monochrome
    // (template, auto light/dark) or a brand-tinted (accent-filled) caret.
    private var showWordCount = false
    private var iconStyle = "mono"

    // Brand periwinkle for the tinted icon style — matches OBTheme.accent (0x7c9cff) without bridging a
    // SwiftUI Color into AppKit drawing.
    private static let tintColor = NSColor(srgbRed: 0x7c / 255.0, green: 0x9c / 255.0,
                                           blue: 0xff / 255.0, alpha: 1)

    override init() { super.init() }

    /// The logo I-beam caret as a menu-bar template image. Polygon mirrors the silhouette in
    /// web/assets/logo.svg (model space 196×460, vertically/horizontally symmetric); template
    /// mode means only alpha matters, so macOS tints it for light/dark automatically.
    private static func makeGlyph(tinted: Bool = false) -> NSImage {
        let h: CGFloat = 16                     // glyph height inside the ~22pt menu bar
        let scale = h / 460                     // model is 460 tall
        let w = (196 * scale).rounded(.up) + 2  // 196 wide + 1px padding each side
        // Centred polygon in SVG model coords.
        let pts: [(CGFloat, CGFloat)] = [
            (-98, -230), (98, -230), (98, -180), (26, -180), (26, 180), (98, 180),
            (98, 230), (-98, 230), (-98, 180), (-26, 180), (-26, -180), (-98, -180),
        ]
        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let path = NSBezierPath()
            for (i, p) in pts.enumerated() {
                let pt = NSPoint(x: w / 2 + p.0 * scale, y: h / 2 + p.1 * scale)
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            path.close()
            (tinted ? tintColor : NSColor.black).setFill()
            path.fill()
            return true
        }
        // Template (mono) auto-tints for light/dark; the tinted style keeps its own accent color.
        image.isTemplate = !tinted
        return image
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Template image -> auto light/dark menu-bar tinting. Custom I-beam matches the
            // app logo (web/assets/logo.svg) rather than the generic SF "text.cursor" symbol.
            button.image = StatusItemController.makeGlyph()
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        enableItem.target = self
        enableItem.action = #selector(toggleEnabled)
        setEnabled(isEnabled)   // sync title + checkmark with the initial enabled state
        menu.addItem(enableItem)

        menu.addItem(.separator())

        // Informational, non-clickable rows.
        wordsItem.isEnabled = false
        modelItem.isEnabled = false
        secureInputItem.isEnabled = false
        secureInputItem.isHidden = true
        menu.addItem(wordsItem)
        menu.addItem(modelItem)
        menu.addItem(secureInputItem)
        // Refreshed on every open (menuWillOpen): the secure-input state is transient and must never
        // be cached — it flips the moment a lock/unlock or password-manager action ends.
        menu.delegate = self

        menu.addItem(.separator())

        // Auto-update: "Install Update…" is revealed once a newer build is available/staged; the
        // persistent "Check for Updates…" always works (manual, bypasses the auto-check toggle).
        installUpdateItem.target = self
        installUpdateItem.action = #selector(installUpdate)
        installUpdateItem.isHidden = true
        menu.addItem(installUpdateItem)

        checkUpdatesItem.target = self
        checkUpdatesItem.action = #selector(checkUpdates)
        menu.addItem(checkUpdatesItem)

        let settingsItem = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // M1: Local API toggle + copy URL. Both hidden by default; AppDelegate reveals them once the
        // server is available (always, since the app is free).
        localAPIItem.target = self
        localAPIItem.action = #selector(toggleLocalAPI)
        localAPIItem.isHidden = true
        menu.addItem(localAPIItem)
        copyAPIURLItem.target = self
        copyAPIURLItem.action = #selector(copyLocalAPIURL)
        copyAPIURLItem.isHidden = true
        menu.addItem(copyAPIURLItem)

        pauseItem.target = self
        pauseItem.action = #selector(pauseForApp)
        menu.addItem(pauseItem)

        // "Disable for app ▸": directly silence any open visible app, not just the frontmost one. The
        // submenu is empty here and (re)populated on demand by menuNeedsUpdate(_:) from running apps.
        let disableSub = NSMenu()
        disableSub.delegate = self
        disableForAppItem.submenu = disableSub
        appListSubmenu = disableSub
        menu.addItem(disableForAppItem)

        // The old "Force suggestions here" item is gone: ⌃` now TEACHES the app permanently (first press
        // in an auto-idle app writes AppSettingsStore.suggestHere = .on), so a per-visit menu override
        // no longer exists to offer. The .shadowtypeForceActivate notification stays for the hotkey path.

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Shadowtype", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    // MARK: - Live data setters (call from AppDelegate when state changes)

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        enableItem.state = enabled ? .on : .off
        enableItem.title = enabled ? "Disable Shadowtype" : "Enable Shadowtype"
    }

    func setWordCount(_ count: Int) {
        lastCount = count
        refreshWordsTitle()
        if showWordCount { refreshButton() }   // keep the live menu-bar count in step
    }

    // General → "Show today's word count in menu bar".
    func setShowWordCount(_ show: Bool) {
        guard showWordCount != show else { return }
        showWordCount = show
        refreshButton()
    }

    // General → "Menu-bar icon style" ("mono" | "tinted").
    func setIconStyle(_ style: String) {
        guard iconStyle != style else { return }
        iconStyle = style
        refreshButton()
    }

    // Redraw the status-item button image (mono/tinted) and the optional count label.
    private func refreshButton() {
        guard let button = statusItem?.button else { return }
        button.image = StatusItemController.makeGlyph(tinted: iconStyle == "tinted")
        if showWordCount {
            button.title = " \(lastCount)"
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    private func refreshWordsTitle() {
        wordsItem.title = "Words today: \(lastCount)"
    }

    // Auto-update: reveal "Install Update vX…" once a newer build is available/staged (nil hides it).
    func setUpdateAvailable(version: String?) {
        if let version {
            installUpdateItem.title = "Install Update \(version)…"
            installUpdateItem.isHidden = false
        } else {
            installUpdateItem.isHidden = true
        }
    }

    func setModelName(_ name: String) {
        modelItem.title = "Model: \(name)"
    }

    func setPausedApp(_ appName: String?) {
        if let appName {
            pauseItem.title = "Resume for \(appName)"
            pauseItem.state = .on
        } else {
            pauseItem.title = "Pause for current app"
            pauseItem.state = .off
        }
    }

    // MARK: - Actions (post for AppDelegate to observe)

    // M1: Local API menu plumbing. setLocalAPI is called by AppDelegate when the server's state
    // changes (toggle/sleep-wake re-bind). The Local API is free, so `available` is always true;
    // `available=false` simply hides both rows (kept for completeness / tests).
    func setLocalAPI(on: Bool, port: Int?, available: Bool) {
        if !available {
            localAPIItem.isHidden = true
            copyAPIURLItem.isHidden = true
            currentLocalAPIURL = nil
            return
        }
        localAPIItem.isHidden = false
        if on, let port {
            localAPIItem.title = "Local API: On (port \(port))"
            localAPIItem.state = .on
            copyAPIURLItem.isHidden = false
            currentLocalAPIURL = "http://127.0.0.1:\(port)/v1"
        } else {
            localAPIItem.title = "Enable Local API…"
            localAPIItem.state = .off
            copyAPIURLItem.isHidden = true
            currentLocalAPIURL = nil
        }
    }

    @objc private func toggleLocalAPI() {
        // Flip the persisted toggle + post the .shadowtypeToggleLocalAPI signal. AppDelegate's
        // applyLocalAPIToggle() reconciles (checks license, starts/stops the server, refreshes the
        // menu via this controller's setLocalAPI).
        let wasOn = UserDefaults.standard.bool(forKey: "shadowtype.serverEnabled")
        UserDefaults.standard.set(!wasOn, forKey: "shadowtype.serverEnabled")
        NotificationCenter.default.post(name: .shadowtypeToggleLocalAPI, object: nil)
    }

    @objc private func copyLocalAPIURL() {
        // The URL contains no secret (the Bearer key is separate and copied from the settings
        // panel), so this is safe to put in the system pasteboard.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(currentLocalAPIURL ?? "http://127.0.0.1:5666/v1", forType: .string)
    }

    @objc private func toggleEnabled() {
        // Optimistic local flip; AppDelegate may reflect authoritative state via setEnabled(_:).
        setEnabled(!isEnabled)
        NotificationCenter.default.post(name: .shadowtypeToggleEnabled, object: nil,
                                        userInfo: ["enabled": isEnabled])
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .shadowtypeOpenSettings, object: nil)
    }

    @objc private func pauseForApp() {
        NotificationCenter.default.post(name: .shadowtypePauseForApp, object: nil)
    }

    @objc private func quit() {
        NotificationCenter.default.post(name: .shadowtypeQuit, object: nil)
    }

    @objc private func checkUpdates() {
        NotificationCenter.default.post(name: .shadowtypeCheckUpdates, object: nil)
    }

    @objc private func installUpdate() {
        NotificationCenter.default.post(name: .shadowtypeInstallUpdate, object: nil)
    }

    // Posts the bundle id of the chosen running app; AppDelegate flips its permanent rule.
    @objc private func toggleAppDisabled(_ sender: NSMenuItem) {
        guard let bundleId = sender.representedObject as? String else { return }
        NotificationCenter.default.post(name: .shadowtypeToggleAppDisabled, object: nil,
                                        userInfo: ["bundleId": bundleId])
    }
}

// MARK: - "Disable for app ▸" live population

extension StatusItemController: NSMenuDelegate {
    // Main menu about to open: show why suggestions are suppressed, when they are. Secure input is a
    // system-wide switch, so a lock screen, password manager or parked sudo silences every app —
    // naming the holder turns "it stopped working" into something the user can act on.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu !== appListSubmenu else { return }
        if IsSecureEventInputEnabled() {
            secureInputItem.title = "Paused — secure input held by \(SecureInputOwner.describe())"
            secureInputItem.isHidden = false
        } else {
            secureInputItem.isHidden = true
        }
    }

    // Rebuild the submenu just before it opens: one row per running visible (.regular) app, checkmarked
    // when Shadowtype is currently disabled there. Reads AppRules.shared directly (same as the Settings
    // pane); the row posts a toggle that AppDelegate applies + persists.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // The MAIN menu also delegates to self (for the secure-input row in menuWillOpen), and this
        // method starts with removeAllItems() — running it against the main menu would delete the
        // whole menu and replace it with app rows. Only the app submenu may be rebuilt here.
        guard menu === appListSubmenu else { return }
        menu.removeAllItems()
        let ownBundleId = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != ownBundleId }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "")
                == .orderedAscending }
        guard !apps.isEmpty else {
            let empty = NSMenuItem(title: "No visible apps", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for app in apps {
            guard let bundleId = app.bundleIdentifier else { continue }
            let item = NSMenuItem(title: app.localizedName ?? bundleId,
                                  action: #selector(toggleAppDisabled(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bundleId
            item.state = AppRules.shared.isEnabled(bundleId: bundleId, domain: nil) ? .off : .on
            menu.addItem(item)
        }
    }
}
