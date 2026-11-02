// Ready-made visual-verify harness. Copy to <scratchpad>/demo/main.swift and
// compile per SKILL.md ("Compiling a harness"); run as `VisualVerify <out-dir>`.
//
// What it renders, driven by the app's real views and a synthetic snapshot:
//   popover-session-{on,off}.png   PopoverView via ImageRenderer @3x (header
//                                  plates expected — see SKILL.md)
//   icon-session-{on,off}.png      makeIcon output at 8x on white
//   settings-behavior.png          SettingsView hosted + cacheDisplay @1x,
//                                  scrolled to the Behavior section
// and prints each MenuBarContent (width, tracks, tooltip) to stdout.
//
// It flips SettingsKeys.showSession as the example; swap the key/limits for
// whatever the change under test touches. It writes only the harness's own
// defaults domain (VisualVerify / VisualVerify-bookmarks) and removes what it
// set; the real com.appideas.tokes domain is never touched. Measured
// 2026-11-01: a windowless NSHostingController exposes 0 NSPopUpButtons after
// 0.5 s, so the picker-options assertion in SKILL.md needs a window; the unit
// tests (MenuBarLabel.available) already pin those options — prefer them.
import AppKit
import SwiftUI

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let defaults = UserDefaults.standard
let scratchDefaults = UserDefaults(suiteName: "VisualVerify-bookmarks")!

func limits() -> [UsageLimit] {
    [UsageLimit(id: "session", label: "Session (5 hr)", percent: 24, severity: "normal",
                resetsAt: Date().addingTimeInterval(3600), isSession: true),
     UsageLimit(id: "weekly_all", label: "Weekly (7 day)", percent: 41, severity: "normal",
                resetsAt: Date().addingTimeInterval(3 * 86400), isSession: false),
     UsageLimit(id: "weekly_scoped:Fable", label: "Weekly Fable", percent: 63, severity: "normal",
                resetsAt: Date().addingTimeInterval(3 * 86400), isSession: false)]
}

func writePNG(_ image: NSImage?, _ name: String) {
    guard let image, let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("FAILED \(name)"); return }
    try! png.write(to: out.appendingPathComponent(name))
    print("wrote \(name) \(Int(rep.pixelsWide))x\(Int(rep.pixelsHigh))")
}

func writeCG(_ cg: CGImage?, _ name: String) {
    guard let cg else { print("FAILED \(name)"); return }
    writePNG(NSImage(cgImage: cg, size: .zero), name)
}

MainActor.assumeIsolated {
    for showSession in [true, false] {
        defaults.set(showSession, forKey: SettingsKeys.showSession)
        defaults.set(true, forKey: SettingsKeys.showScopedWeekly)
        let state = AppState()
        state.snapshot = UsageSnapshot(limits: limits(), fetchedAt: Date())
        let view = PopoverView(state: state, onHoverChanged: { _ in }, onSettings: {},
                               onRefresh: {}, onQuit: {})
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        writeCG(renderer.cgImage, "popover-session-\(showSession ? "on" : "off").png")

        let content = StatusItemController.content(
            for: state.snapshot, showScopedWeekly: true, showSession: showSession)
        let icon = StatusItemController.makeIcon(limits: content.limits, claudeTracks: content.claudeTracks)
        print("icon session=\(showSession): width \(icon.size.width) tracks \(content.claudeTracks) tooltip: \(content.toolTip)")
        let big = NSImage(size: NSSize(width: icon.size.width * 8, height: icon.size.height * 8), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            icon.draw(in: rect); return true
        }
        writePNG(big, "icon-session-\(showSession ? "on" : "off").png")
    }

    // Settings, Behavior section, with the session hidden.
    defaults.set(false, forKey: SettingsKeys.showSession)
    defaults.set(MenuBarLabel.weeklyAll.rawValue, forKey: SettingsKeys.menuBarLabel)
    let settings = SettingsView(onCredentialsChanged: {},
                                keychainService: "com.appideas.tokes.tests",
                                bookmarkDefaults: scratchDefaults,
                                setLaunchAtLogin: { _ in }, launchAtLoginStatus: { false })
    let hosting = NSHostingController(rootView: settings)
    hosting.view.frame = NSRect(x: 0, y: 0, width: 460, height: 620)
    hosting.view.layoutSubtreeIfNeeded()
    func scrollViews(_ v: NSView) -> [NSScrollView] {
        (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews)
    }
    func popUps(_ v: NSView) -> [NSPopUpButton] {
        (v as? NSPopUpButton).map { [$0] } ?? [] + v.subviews.flatMap(popUps)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        hosting.view.layoutSubtreeIfNeeded()
        if let scroll = scrollViews(hosting.view).first, let doc = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.frame.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        hosting.view.layoutSubtreeIfNeeded()
        let rep = hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds)!
        hosting.view.cacheDisplay(in: hosting.view.bounds, to: rep)
        let img = NSImage(size: hosting.view.bounds.size); img.addRepresentation(rep)
        writePNG(img, "settings-behavior.png")
        let popups = popUps(hosting.view)
        print("popups: \(popups.count)")
        // Picker option titles are only populated once the menu is built; read the menu items instead.
        for (i, p) in popups.enumerated() { print("popup \(i): \(p.menu?.items.map(\.title).joined(separator: " | ") ?? "nil")") }
        for key in [SettingsKeys.showSession, SettingsKeys.showScopedWeekly, SettingsKeys.menuBarLabel] {
            defaults.removeObject(forKey: key)
        }
        scratchDefaults.removePersistentDomain(forName: "VisualVerify-bookmarks")
        app.terminate(nil)
    }
    app.run()
}
