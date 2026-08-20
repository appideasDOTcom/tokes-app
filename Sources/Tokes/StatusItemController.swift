import AppKit
import Combine
import SwiftUI

/// Appends to a log file when `defaults write com.appideas.tokes debugLogging
/// -bool true` is set. Unified log redacts our messages as <private>, so a plain
/// file is the practical channel.
///
/// The destination is /tmp for the direct build; the sandbox denies writes there,
/// so the App Store build logs inside its container — see `Capabilities`.
enum DebugLog {
    /// Log destination; overridable in tests.
    static var fileURL = Capabilities.debugLogURL()

    /// Appends a timestamped line to the log file if debug logging is enabled.
    static func log(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "debugLogging") else { return }
        let line = "\(Date()) \(message)\n"
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// Owns the menu bar item: draws the three-bar icon, opens the popover on
/// hover (click pins it), and provides the right-click menu and Settings window.
final class StatusItemController: NSObject {
    private let state: AppState
    private let poller: UsagePoller
    /// Internal (not private) so tests can reach the real button and remove
    /// the item from the bar when they finish.
    let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private var pinned = false
    private var hoverInButton = false
    private var hoverInPopover = false
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var clickMonitors: [Any] = []

    /// Builds the status item, popover, and state subscriptions.
    init(state: AppState, poller: UsagePoller) {
        self.state = state
        self.poller = poller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        }

        popover.animates = false
        popover.behavior = .applicationDefined
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            state: state,
            onHoverChanged: { [weak self] inside in self?.popoverHoverChanged(inside) },
            onSettings: { [weak self] in self?.openSettings() },
            onRefresh: { [weak self] in self?.poller.refreshNow() },
            onQuit: { NSApp.terminate(nil) }))

        state.$snapshot
            .combineLatest(state.$errorMessage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot, error in
                self?.updateButton(with: snapshot, hasError: error != nil)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateButton(with: self.state.snapshot,
                                  hasError: self.state.errorMessage != nil)
            }
            .store(in: &cancellables)

        updateButton(with: nil, hasError: false)
    }

    // MARK: - Menu bar rendering

    /// Everything the menu bar draws for a snapshot, computed with no AppKit
    /// involved so the composition can be asserted directly. `makeIcon` and
    /// `makeTitle` were already testable in isolation; this is the part that
    /// decides *what they are given*, which is where the scoped-weekly setting
    /// actually takes effect.
    struct MenuBarContent: Equatable {
        /// Limits to draw, after the scoped-weekly setting has filtered them.
        let limits: [UsageLimit]
        /// Bar slots the Claude section reserves, so the item's width does not
        /// jitter as buckets appear. Moves with the same setting that filters.
        let claudeTracks: Int
        let toolTip: String
    }

    /// Resolves a snapshot and the scoped-weekly setting into what the button
    /// should show.
    static func content(for snapshot: UsageSnapshot?, showScopedWeekly: Bool) -> MenuBarContent {
        let limits = (snapshot?.limits ?? []).filter { showScopedWeekly || !$0.isScopedWeekly }
        let toolTip: String
        if limits.isEmpty {
            toolTip = "Tokes — waiting for usage data"
        } else {
            let prefix = limits.contains { $0.provider == .copilot } ? "Usage — " : "Claude usage — "
            toolTip = prefix + limits
                .map { "\($0.label): \(Int($0.percent.rounded()))%" }
                .joined(separator: " · ")
        }
        return MenuBarContent(limits: limits,
                              claudeTracks: showScopedWeekly ? 3 : 2,
                              toolTip: toolTip)
    }

    /// Reads the scoped-weekly setting, defaulting to on when never set.
    static func showScopedWeekly(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: SettingsKeys.showScopedWeekly) as? Bool ?? true
    }

    /// Redraws the icon, optional percent label, and tooltip from a snapshot.
    /// Label color signals state: red when a limit is exhausted (blocking
    /// further queries), orange while polls are failing (numbers may be
    /// stale), normal otherwise.
    private func updateButton(with snapshot: UsageSnapshot?, hasError: Bool) {
        guard let button = statusItem.button else { return }
        let content = Self.content(for: snapshot, showScopedWeekly: Self.showScopedWeekly())
        button.image = Self.makeIcon(limits: content.limits, claudeTracks: content.claudeTracks)
        button.imagePosition = .imageLeading

        if let title = Self.makeTitle(limits: content.limits, selection: .current(),
                                      hasError: hasError) {
            button.attributedTitle = title
        } else {
            button.title = ""
        }
        button.toolTip = content.toolTip
    }

    /// The percent text beside the icon for the selected measurement, or nil
    /// when nothing should be drawn — the selection is Off, or the measurement
    /// is absent (Copilot off, a plan without a model-scoped weekly, nothing
    /// polled yet). Showing nothing beats showing a different limit's number
    /// under the name the user chose.
    static func makeTitle(limits: [UsageLimit], selection: MenuBarLabel,
                          hasError: Bool) -> NSAttributedString? {
        guard let shown = selection.limit(in: limits) else { return nil }
        // Clamped the same way `makeIcon` clamps its bar heights. Two
        // renderers reading one value used to disagree: a server answer of 420
        // drew a full red bar next to the text " 420%", which reads as a Tokes
        // bug rather than as a value at its limit.
        let percent = max(0, min(100, shown.percent))
        let labelColor: NSColor = percent >= 100 ? .systemRed
            : hasError ? .systemOrange
            : .labelColor
        return NSAttributedString(
            string: " \(Int(percent.rounded()))%",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: labelColor,
                .baselineOffset: 0.5,
            ])
    }

    /// Vertical bars, one per limit, filled bottom-up and colored by severity.
    /// Claude reserves `claudeTracks` tracks (three, or two when the scoped
    /// weekly limit is hidden); Copilot bars sit behind a thin divider so the
    /// provider groups read separately at a glance.
    static func makeIcon(limits: [UsageLimit], claudeTracks: Int = 3) -> NSImage {
        let barWidth: CGFloat = 5
        let gap: CGFloat = 3
        let barHeight: CGFloat = 16
        let dividerBand: CGFloat = 7  // gap + 1pt line + gap

        let claude = limits.filter { $0.provider == .claude }
        let copilot = limits.filter { $0.provider == .copilot }
        let claudeSlots: [UsageLimit?] = (0..<max(claude.count, claudeTracks)).map { $0 < claude.count ? claude[$0] : nil }

        func sectionWidth(_ n: Int) -> CGFloat { CGFloat(n) * barWidth + CGFloat(n - 1) * gap }
        let width = 2 + sectionWidth(claudeSlots.count)
            + (copilot.isEmpty ? 0 : dividerBand + sectionWidth(copilot.count))
        let size = NSSize(width: width, height: 18)

        let image = NSImage(size: size, flipped: false) { _ in
            func drawSlot(_ limit: UsageLimit?, at x: CGFloat) {
                let trackRect = NSRect(x: x, y: 1, width: barWidth, height: barHeight)
                NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: trackRect, xRadius: 2.5, yRadius: 2.5).fill()
                guard let limit else { return }
                let percent = max(0, min(100, limit.percent))
                let fillRect = NSRect(x: x, y: 1, width: barWidth, height: max(3, barHeight * percent / 100))
                SeverityColor.nsColor(for: percent).setFill()
                NSBezierPath(roundedRect: fillRect, xRadius: 2.5, yRadius: 2.5).fill()
            }

            var x: CGFloat = 1
            for slot in claudeSlots {
                drawSlot(slot, at: x)
                x += barWidth + gap
            }
            if !copilot.isEmpty {
                x -= gap  // the section ends without a trailing gap
                NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
                NSRect(x: x + 3, y: 3, width: 1, height: 12).fill()
                x += dividerBand
                for limit in copilot {
                    drawSlot(limit, at: x)
                    x += barWidth + gap
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Hover show/hide

    // Explicit selector names: on an NSObject owner (not NSResponder) Swift
    // would otherwise export these as mouseEnteredWith:/mouseExitedWith: and
    // the tracking area's messages would be dropped silently.
    /// Pointer entered the status item: open the popover after a short delay.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        DebugLog.log("Tokes: pointer entered status item")
        hoverInButton = true
        hideWork?.cancel()
        guard !popover.isShown else { return }
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showPopover() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Pointer left the status item: schedule a close.
    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        hoverInButton = false
        showWork?.cancel()
        scheduleHide()
    }

    /// Pointer entered/left the popover: cancel or schedule the close.
    private func popoverHoverChanged(_ inside: Bool) {
        hoverInPopover = inside
        if inside {
            hideWork?.cancel()
            // The pointer entering the popover signals intent to interact.
            // An inactive accessory app never routes the first click to
            // SwiftUI controls, so activate now; closePopover() hands focus
            // back.
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
                popover.contentViewController?.view.window?.makeKey()
            }
        } else {
            scheduleHide()
        }
    }

    /// Closes the popover after a grace period unless pinned or still hovered.
    private func scheduleHide() {
        guard !pinned else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pinned, !self.hoverInButton, !self.hoverInPopover else { return }
            self.closePopover()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Shows the popover under the status item, refreshing stale data first.
    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        DebugLog.log("Tokes: showing popover")
        poller.refreshIfStale()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        repositionPopoverWindow()
        // The app is an inactive accessory; without key status the popover's
        // controls would swallow the first click.
        popover.contentViewController?.view.window?.makeKey()
    }

    /// macOS 26 can place a status item popover with its top edge above the
    /// screen. Anchor it explicitly: centered under the status item, top
    /// flush with the bottom of the menu bar.
    private func repositionPopoverWindow() {
        guard let window = popover.contentViewController?.view.window,
              let buttonWindow = statusItem.button?.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let frame = Self.popoverFrame(current: window.frame,
                                      buttonWindowFrame: buttonWindow.frame,
                                      screenFrame: screen.frame,
                                      visibleFrame: screen.visibleFrame)
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }

    /// Where the popover window belongs: centered under the status item, top
    /// flush with the bottom of the menu bar, clamped to the screen with an
    /// 8pt margin on either side. Pure geometry, so the macOS 26 workaround
    /// above is assertable without putting a popover on screen.
    static func popoverFrame(current: NSRect, buttonWindowFrame: NSRect,
                             screenFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        var frame = current
        frame.origin.y = buttonWindowFrame.minY - frame.height
        frame.origin.x = min(
            max(buttonWindowFrame.midX - frame.width / 2, visibleFrame.minX + 8),
            screenFrame.maxX - frame.width - 8)
        return frame
    }

    /// Closes the popover, removes click monitors, and hands focus back.
    private func closePopover() {
        pinned = false
        removeClickMonitors()
        showWork?.cancel()
        hideWork?.cancel()
        if popover.isShown { popover.close() }
        // Hand focus back to whatever app the user was in, unless we opened
        // one of our own windows (e.g. Settings).
        if NSApp.isActive && settingsWindow?.isVisible != true {
            NSApp.deactivate()
        }
    }

    // MARK: - Click handling

    /// Left click pins/unpins the popover; right click shows the context menu.
    @objc private func statusButtonClicked() {
        DebugLog.log("Tokes: status item clicked (event: \(NSApp.currentEvent?.type.rawValue.description ?? "none"))")
        // currentEvent is nil for accessibility (AXPress) activation;
        // treat that like a left click.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            if pinned {
                closePopover()
                return
            }
            pinned = true
        } else {
            pinned = true
            showPopover()
        }
        installClickMonitors()
        // A deliberate click means interaction: make popover controls
        // clickable right away.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// While pinned, a click anywhere outside the popover closes it.
    private func installClickMonitors() {
        removeClickMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.closePopover()
        }) {
            clickMonitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            let popoverWindow = self.popover.contentViewController?.view.window
            let statusWindow = self.statusItem.button?.window
            if Self.isOutsideClick(eventWindow: event.window,
                                   popoverWindow: popoverWindow,
                                   statusWindow: statusWindow) {
                self.closePopover()
            }
            return event
        }
        if let local { clickMonitors.append(local) }
    }

    /// Removes the outside-click monitors.
    private func removeClickMonitors() {
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors.removeAll()
    }

    /// Whether a monitored click landed outside both the popover and the
    /// status item — the condition that closes a pinned popover. A nil event
    /// window (a click in another app, which is all the global monitor ever
    /// delivers) is outside by definition.
    static func isOutsideClick(eventWindow: NSWindow?, popoverWindow: NSWindow?,
                               statusWindow: NSWindow?) -> Bool {
        eventWindow != popoverWindow && eventWindow != statusWindow
    }

    // MARK: - Context menu

    /// The right-click menu: Refresh / Settings / Quit. Built apart from
    /// `showContextMenu` so its wiring is assertable without popping a menu.
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshAction), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tokes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    /// Shows the right-click menu via a transient statusItem.menu.
    private func showContextMenu() {
        statusItem.menu = contextMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Context-menu action: poll now.
    @objc private func refreshAction() {
        poller.refreshNow()
    }

    /// Context-menu action: open Settings.
    @objc private func settingsAction() {
        openSettings()
    }

    // MARK: - Settings window

    /// Opens the Settings window, creating it on first use.
    func openSettings() {
        closePopover()
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                onCredentialsChanged: { [weak self] in self?.poller.credentialsChanged() }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Tokes Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            // Size before centering — SwiftUI hasn't laid out yet, and
            // center() on the initial 1pt frame parks the window off-center.
            window.setContentSize(NSSize(width: 460, height: 560))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
