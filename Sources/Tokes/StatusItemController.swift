import AppKit
import Combine
import SwiftUI

/// Appends to /tmp/tokes-debug.log when `defaults write com.appideas.tokes
/// debugLogging -bool true` is set. Unified log redacts our messages as
/// <private>, so a plain file is the practical channel.
enum DebugLog {
    /// Log destination; overridable in tests.
    static var fileURL = URL(fileURLWithPath: "/tmp/tokes-debug.log")

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
    private let statusItem: NSStatusItem
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in self?.updateButton(with: snapshot) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateButton(with: self?.state.snapshot) }
            .store(in: &cancellables)

        updateButton(with: nil)
    }

    // MARK: - Menu bar rendering

    /// Redraws the icon, optional percent label, and tooltip from a snapshot.
    private func updateButton(with snapshot: UsageSnapshot?) {
        guard let button = statusItem.button else { return }
        let limits = snapshot?.limits ?? []
        button.image = Self.makeIcon(limits: limits)
        button.imagePosition = .imageLeading

        let showLabel = UserDefaults.standard.bool(forKey: SettingsKeys.showLabel)
        if showLabel, let top = limits.max(by: { $0.percent < $1.percent }) {
            button.attributedTitle = NSAttributedString(
                string: " \(Int(top.percent.rounded()))%",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                    .baselineOffset: 0.5,
                ])
        } else {
            button.title = ""
        }

        if limits.isEmpty {
            button.toolTip = "Tokes — waiting for Claude usage data"
        } else {
            button.toolTip = "Claude usage — " + limits
                .map { "\($0.label): \(Int($0.percent.rounded()))%" }
                .joined(separator: " · ")
        }
    }

    /// Three vertical bars, one per limit (Session, Weekly, Weekly <model>),
    /// filled bottom-up and colored by severity. Dynamic colors keep it
    /// legible in light and dark menu bars.
    static func makeIcon(limits: [UsageLimit]) -> NSImage {
        let barWidth: CGFloat = 5
        let gap: CGFloat = 3
        let barHeight: CGFloat = 16
        let count = max(limits.count, 3)
        let size = NSSize(
            width: CGFloat(count) * barWidth + CGFloat(count - 1) * gap + 2,
            height: 18)

        let image = NSImage(size: size, flipped: false) { _ in
            for i in 0..<count {
                let x = 1 + CGFloat(i) * (barWidth + gap)
                let trackRect = NSRect(x: x, y: 1, width: barWidth, height: barHeight)
                NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: trackRect, xRadius: 2.5, yRadius: 2.5).fill()

                guard i < limits.count else { continue }
                let percent = max(0, min(100, limits[i].percent))
                let fillRect = NSRect(x: x, y: 1, width: barWidth, height: max(3, barHeight * percent / 100))
                SeverityColor.nsColor(for: percent).setFill()
                NSBezierPath(roundedRect: fillRect, xRadius: 2.5, yRadius: 2.5).fill()
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
        let buttonFrame = buttonWindow.frame
        var frame = window.frame
        let visible = screen.visibleFrame
        frame.origin.y = buttonFrame.minY - frame.height
        frame.origin.x = min(
            max(buttonFrame.midX - frame.width / 2, visible.minX + 8),
            screen.frame.maxX - frame.width - 8)
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
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
            if event.window != popoverWindow && event.window != statusWindow {
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

    // MARK: - Context menu

    /// Shows the right-click menu (Refresh / Settings / Quit) via a transient statusItem.menu.
    private func showContextMenu() {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshAction), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tokes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
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
            window.setContentSize(NSSize(width: 460, height: 440))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
