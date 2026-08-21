import AppKit
import SwiftUI

// Raw material for the App Store store frames — NOT finished screenshots.
//
//     scripts/screenshots.sh --states     ->  build/appstore/states/
//
// The designer composites the final 2880x1800 frames; this renders the app
// states they asked for, in light and dark, and nothing else. Deliberately
// different from main.swift in three ways:
//
//   * No canvas, no gradient, no headline copy. Each file is the app artefact
//     alone, so it can be placed rather than cropped out of a composition.
//   * ALPHA IS PRESERVED. main.swift's output is a finished frame; this output
//     is composited by the designer, and the transparency is what lets them do
//     it. Do not "fix" this to opaque — App Store Connect's no-alpha rule binds
//     the finished frame, which is theirs, not this raw material.
//   * Strips render at STRIP_SCALE rather than 2x. StatusItemController.makeIcon
//     returns a dynamic NSImage whose drawing handler re-executes at the
//     destination resolution, so a scaled context re-draws the bars, radii and
//     divider vector-crisp instead of upscaling a bitmap. The hero frame is a
//     magnification of this, so the headroom is the point.
//
// Light and dark are genuinely separate renders, not one inverted: every colour
// here is an AppKit semantic (secondaryLabelColor, systemRed/Orange/Green,
// labelColor) resolved through the appearance current at draw time.

let OUT = ProcessInfo.processInfo.environment["OUT"] ?? "/tmp"

// Magnifications, set by the designer from the size each capture is placed at
// in the composition. Their compositor refuses to upscale, so a capture smaller
// than its slot is simply left small — asking for the right factor costs one
// re-render, resampling costs the vector-crispness that makes this pipeline
// better than a screen capture.
let STRIP_SCALE: CGFloat = 24           // hero, placed ~1250px wide each
let POPOVER_NEAR_SCALE: CGFloat = 9     // cropped to the session chart, blown to ~2400px
let POPOVER_BOTH_SCALE: CGFloat = 6     // placed ~1460px tall
let SETTINGS_SCALE: CGFloat = 6         // placed ~1460px tall
/// The hosted popover renders. 1 is not a placeholder for a bigger number: this
/// path rasterises the hosting view's layer at its backing scale, and every
/// display on this machine reports 1.0, so anything larger would be an upscale
/// wearing a bigger dimension — the trap that once shipped a "9x" capture
/// carrying 1x of detail. Raise it only on Retina hardware, where the same call
/// yields real 2x. See the popover block for why this path exists at all.
let POPOVER_HOSTED_SCALE: CGFloat = 1

/// Keychain service for the harness. NOT the real one.
///
/// `SettingsView.keychainService` defaults to `CredentialsProvider.manualService`
/// — the operator's live slot — and `onAppear` reads it on every render. Left
/// alone this harness reads real credentials each run, and finds none, so the
/// token field renders empty with Save Token disabled: an UNCONFIGURED app, in a
/// set where every other frame shows a working one. Seeding an isolated service
/// fixes both halves. Torn down at the end of the run.
let SHOT_KEYCHAIN = "com.appideas.tokes.screenshotgen"
let SHOT_BOOKMARKS = "com.appideas.tokes.screenshotgen.bookmarks"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let now = Date()

// ---------------------------------------------------------------- fixtures --

func limit(_ id: String, _ label: String, _ pct: Double, session: Bool = false,
           inHours h: Double = 3) -> UsageLimit {
    UsageLimit(id: id, label: label, percent: pct,
               severity: pct >= 85 ? "critical" : pct >= 60 ? "warn" : "ok",
               resetsAt: now.addingTimeInterval(h * 3600), isSession: session)
}

let copilotLimit = UsageLimit(
    id: "copilot_premium", label: "Premium requests", percent: 34, severity: "ok",
    resetsAt: now.addingTimeInterval(11 * 86400), isSession: false,
    provider: .copilot, detail: "612 of 1,800 credits used")

/// All green — nothing near a threshold.
let healthy = [limit("session", "Session (5 hr)", 12, session: true),
               limit("weekly_all", "Weekly (7 day)", 28, inHours: 84),
               limit("weekly_scoped:Fable", "Weekly Fable", 41, inHours: 84)]

/// Mixed, one bar past the 60 threshold into orange.
let working = [limit("session", "Session (5 hr)", 62, session: true),
               limit("weekly_all", "Weekly (7 day)", 34, inHours: 84),
               limit("weekly_scoped:Fable", "Weekly Fable", 47, inHours: 84)]

/// One bar past 85 into red.
let nearLimit = [limit("session", "Session (5 hr)", 91, session: true, inHours: 1.4),
                 limit("weekly_all", "Weekly (7 day)", 44, inHours: 84),
                 limit("weekly_scoped:Fable", "Weekly Fable", 33, inHours: 84)]

/// Claude's three plus the divider plus GitHub Copilot.
let bothSources = working + [copilotLimit]

// Candidate hero sets, values chosen by the designer so every fill clears the
// ~40% floor below which a bar reads as a dot rather than a bar. See the
// `strip` doc comment for why that floor exists.
//
//   A — full colour vocabulary including red; the app at the moment it earns
//       its place ("one of your limits is nearly gone").
//   B — the same picture with no alarm state in the shopfront.
func copilot(_ pct: Double, _ detail: String) -> UsageLimit {
    UsageLimit(id: "copilot_premium", label: "Premium requests", percent: pct,
               severity: pct >= 85 ? "critical" : pct >= 60 ? "warn" : "ok",
               resetsAt: now.addingTimeInterval(11 * 86400), isSession: false,
               provider: .copilot, detail: detail)
}

// APPROVED HERO, Costmo 2026-08-20. The alarm sits on the SESSION bucket, not
// the model-scoped weekly: only session can carry "you are about to be cut off"
// and have it be true, because a weekly resets 3d out. 88% with ~1h remaining is
// the ordinary shape of that state — high-and-late is a normal afternoon,
// high-and-early is arithmetically impossible.
let setA = [limit("session", "Session (5 hr)", 88, session: true, inHours: 1.2),
            limit("weekly_all", "Weekly (7 day)", 46, inHours: 84),
            limit("weekly_scoped:Fable", "Weekly Fable", 62, inHours: 84),
            copilot(57, "1,026 of 1,800 credits used")]

// RETIRED 2026-08-20 — the no-alarm alternative, not chosen. Kept as the record
// of what was compared, deliberately no longer rendered.
// let setB = session 48 · weekly 41 · model-scoped 66 · Copilot 52

/// Set A's Claude buckets alone, for the Copilot-off popover. Every frame in
/// the set MUST come from one fixture: competitors change their figures between
/// screenshots and it reads as mocked up (designer's decisions/0012).
let setAClaude = Array(setA.prefix(3))



/// Monotonic 0…1 ramp with visible plateaus — usage arrives in bursts, not at a
/// constant rate, and a straight line reads as a mock rather than a machine.
func staircase(_ u: Double, steps: Double = 3.5) -> Double {
    let s = max(0, min(1, u)) * steps
    let whole = s.rounded(.down)
    let frac = s - whole
    return (whole + frac * frac * (3 - 2 * frac)) / steps   // smoothstep per tread
}

func samples(for limits: [UsageLimit]) -> [UsageSample] {
    let step: TimeInterval = 300
    let count = Int(7 * 86400 / step)
    return (0..<count).reversed().map { i in
        let p = 1 - Double(i) / Double(count)
        let hoursAgo = Double(i) * step / 3600
        var v: [String: Double] = [:]
        for (n, l) in limits.enumerated() {
            if l.isSession {
                // Anchored to the REAL session start, derived from resetsAt, so
                // the chart agrees with the "resets in 1h 12m" text beside it.
                // A 5 hr window resetting in r hours began 5-r hours ago; before
                // that boundary the previous window is still on screen, so the
                // series shows its tail and the reset itself rather than
                // pretending history began when this session did.
                let r = (l.resetsAt?.timeIntervalSince(now) ?? 0) / 3600
                let sessionAge = max(0.25, 5 - r)        // hours since it began
                if hoursAgo <= sessionAge {
                    v[l.id] = l.percent * staircase(1 - hoursAgo / sessionAge)
                } else {
                    let d = hoursAgo - sessionAge
                    let elapsedPrev = 5 - d.truncatingRemainder(dividingBy: 5)
                    v[l.id] = 0.72 * l.percent * staircase(elapsedPrev / 5)
                }
            } else {
                let base = l.percent * (0.15 + 0.85 * p)
                v[l.id] = max(0, min(100, base + 4 * sin(Double(i) / 30 + Double(n))))
            }
        }
        return UsageSample(t: now.addingTimeInterval(-Double(i) * step), v: v)
    }
}

func appState(_ limits: [UsageLimit]) -> AppState {
    let s = AppState()
    s.snapshot = UsageSnapshot(limits: limits, fetchedAt: now.addingTimeInterval(-42))
    s.samples = samples(for: limits)
    return s
}

// ------------------------------------------------------------------ render --

var manifest: [String] = []

func writePNG(_ rep: NSBitmapImageRep, _ name: String) {
    let url = URL(fileURLWithPath: "\(OUT)/\(name)")
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("  !! \(name) failed to encode"); return
    }
    try? data.write(to: url)
    manifest.append(String(format: "  %-38s %5dx%-5d", (name as NSString).utf8String!,
                           rep.pixelsWide, rep.pixelsHigh))
    print("  \(name)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
}

/// A transparent-backed bitmap whose logical size is in points, so drawing into
/// it is scaled and dynamic images re-render at the higher resolution.
func bitmap(_ size: NSSize, scale: CGFloat, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: Int((size.width * scale).rounded()),
                              pixelsHigh: Int((size.height * scale).rounded()),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Raises the backing-store resolution of every layer in the tree.
///
/// THIS IS THE WHOLE REASON THE HIGH SCALE FACTORS WORK. `cacheDisplay` does not
/// re-render a SwiftUI view at the destination resolution: the hosting view
/// rasterises into its layer at the layer's `contentsScale`, which is 1.0 for a
/// view that has never belonged to a window, and `cacheDisplay` then scales that
/// bitmap up. Ask for 9x without this and you get a 1x rasterisation blown up
/// nine times — text with visibly doubled pixels, exactly the mush the high
/// factor was requested to avoid, while every dimension in the manifest still
/// reads correct.
func setContentsScale(_ view: NSView, _ scale: CGFloat) {
    view.wantsLayer = true
    view.layer?.contentsScale = scale
    view.layer?.rasterizationScale = scale
    for sub in view.subviews { setContentsScale(sub, scale) }
}

func render(_ view: NSView, scale: CGFloat) -> NSBitmapImageRep {
    // A hosting view with no window rasterises at backing scale 1.0. Attaching
    // it to an off-screen borderless window MAY inherit the main screen's scale
    // — it is never ordered front and never made key, so nothing is raised and
    // no focus is taken.
    if view.window == nil {
        let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000,
                                             width: max(1, view.frame.width),
                                             height: max(1, view.frame.height)),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        // MEASURED 2026-08-20: this yields no gain on THIS machine, because all
        // three attached displays report backingScaleFactor 1.0 — there is no
        // 2x anywhere to inherit, on-screen or off. Kept because on a Retina
        // display it would double Settings' real detail, and because the
        // alternative (ImageRenderer) renders SettingsView blank.
    }
    setContentsScale(view, scale)
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let bounds = CGRect(origin: .zero, size: view.frame.size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: Int(bounds.width * scale),
                              pixelsHigh: Int(bounds.height * scale),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = bounds.size
    view.cacheDisplay(in: bounds, to: rep)
    return rep
}

/// First NSScrollView in the hierarchy — SwiftUI's grouped Form builds one.
func firstScrollView(_ v: NSView) -> NSScrollView? {
    if let s = v as? NSScrollView { return s }
    for sub in v.subviews { if let s = firstScrollView(sub) { return s } }
    return nil
}

/// Scrolls a hosted view's form to the bottom.
///
/// SettingsView is a hard `.frame(width: 460, height: 620)`, and with Copilot
/// enabled the grouped Form is taller than that — so the real app scrolls and no
/// single frame can show both the credential sections and Behavior/footer.
/// This renders what the user sees after scrolling, rather than inventing a
/// taller window that the app cannot produce.
func scrollToBottom(_ view: NSView) {
    // SwiftUI does not size a scroll view's document view for a hosting
    // controller that has never belonged to a window: doc.frame.height reads 0,
    // maxY clamps to 0, and the scroll is a silent no-op that renders as an
    // unscrolled duplicate. A borderless window placed far offscreen forces the
    // real layout. It is never ordered front and never made key, so nothing is
    // raised and no focus is taken — that matters, this machine runs parallel
    // sessions.
    let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000,
                                         width: view.frame.width, height: view.frame.height),
                     styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = view
    w.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    guard let sv = firstScrollView(view), let doc = sv.documentView else { return }
    let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
    sv.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? maxY : 0))
    sv.reflectScrolledClipView(sv.contentView)
    view.layoutSubtreeIfNeeded()
}

/// Renders SwiftUI content at `scale` by re-drawing it, not by scaling a bitmap.
///
/// `cacheDisplay` cannot do this: AppKit rasterises the hosting view's layer at
/// the layer's backing scale (1.0 with no window; at most the display's scale
/// with one) and any larger destination is an upscale. Setting `contentsScale`
/// on the layer tree does not change it either — measured, both produce visibly
/// pixel-doubled text at 9x. `ImageRenderer` re-runs the SwiftUI draw at the
/// requested scale, which is the only way to get real resolution out of these
/// views.
@MainActor
func renderSwiftUI<V: View>(_ content: V, scale: CGFloat, dark: Bool) -> NSBitmapImageRep? {
    let renderer = ImageRenderer(
        content: content.environment(\.colorScheme, dark ? .dark : .light))
    renderer.scale = scale
    guard let cg = renderer.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: cg)
}

func hosted<V: View>(_ view: V, appearance: NSAppearance) -> NSView {
    let c = NSHostingController(rootView: view)
    c.view.appearance = appearance
    c.view.frame = CGRect(origin: .zero, size: c.view.fittingSize)
    c.view.layoutSubtreeIfNeeded()
    return c.view
}

// ------------------------------------------------------------------- strip --

/// The menu bar strip, cropped tight around the item with `pad` points of bar
/// either side. The bar ground is drawn so it reads as a menu bar; it is a flat
/// fill, not a translucency — nothing here samples a desktop.
func strip(_ limits: [UsageLimit], claudeTracks: Int = 3, label: Bool,
           dark: Bool, pad: CGFloat = 14) -> NSBitmapImageRep {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let barHeight: CGFloat = 24

    var icon = NSImage()
    var title: NSAttributedString?
    appearance.performAsCurrentDrawingAppearance {
        icon = StatusItemController.makeIcon(limits: limits, claudeTracks: claudeTracks)
        if label {
            title = StatusItemController.makeTitle(limits: limits, selection: .highest,
                                                   hasError: false)
        }
    }

    let titleWidth = title?.size().width ?? 0
    let size = NSSize(width: pad * 2 + icon.size.width + titleWidth, height: barHeight)

    return bitmap(size, scale: STRIP_SCALE) {
        appearance.performAsCurrentDrawingAppearance {
            (dark ? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)
                  : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()

            icon.draw(in: NSRect(x: pad, y: (barHeight - icon.size.height) / 2,
                                 width: icon.size.width, height: icon.size.height))
            if let title {
                title.draw(at: NSPoint(x: pad + icon.size.width,
                                       y: (barHeight - title.size().height) / 2))
            }
        }
    }
}

// ------------------------------------------------------------------- shots --

/// SettingsView wired to the harness's own keychain and bookmark store rather
/// than the operator's live ones.
func settingsView() -> SettingsView {
    var v = SettingsView(onCredentialsChanged: {})
    v.keychainService = SHOT_KEYCHAIN
    v.bookmarkDefaults = UserDefaults(suiteName: SHOT_BOOKMARKS) ?? .standard
    return v
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
    let defaults = UserDefaults.standard

    // Seed the isolated slots so Settings renders as a CONFIGURED app: the
    // SecureField shows dots and Save Token is enabled. Lengths are realistic;
    // the values are obvious placeholders and never leave this process.
    _ = CredentialsProvider.saveManualToken(
        "sk-ant-oat01-PLACEHOLDER-FOR-SCREENSHOTS-NOT-A-REAL-TOKEN",
        service: SHOT_KEYCHAIN)
    _ = CredentialsProvider.saveManualToken(
        "gho_PLACEHOLDERFORSCREENSHOTSNOTAREALTOKEN",
        service: SHOT_KEYCHAIN, account: CopilotCredentialsProvider.manualAccount)
    defaults.set(true, forKey: SettingsKeys.showScopedWeekly)
    defaults.set(MenuBarLabel.highest.rawValue, forKey: SettingsKeys.menuBarLabel)

    for (suffix, dark) in [("light", false), ("dark", true)] {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance

        // -- strips, tight crop --------------------------------------------
        writePNG(strip(healthy, label: true, dark: dark), "strip-healthy-\(suffix).png")
        writePNG(strip(working, label: true, dark: dark), "strip-working-\(suffix).png")
        writePNG(strip(nearLimit, label: true, dark: dark), "strip-near-limit-\(suffix).png")
        writePNG(strip(bothSources, label: true, dark: dark), "strip-both-sources-\(suffix).png")
        // Pre-poll: no limits at all. Three slots still reserve their width, so
        // this draws three bare tracks and no Copilot section. No percent label
        // either — makeTitle returns nil with nothing to show.
        writePNG(strip([], label: false, dark: dark), "strip-pre-poll-\(suffix).png")

        // Designer's two hero candidates. Every fill clears 40% so nothing
        // renders as a dot; A carries a red bar, B does not.
        // The approved hero. One file, no dead twin a hand's breadth away.
        writePNG(strip(setA, label: true, dark: dark), "strip-a-\(suffix).png")

        // -- popover --------------------------------------------------------
        defaults.set(false, forKey: SettingsKeys.copilotEnabled)
        let nearContent = PopoverView(state: appState(setAClaude), onHoverChanged: { _ in },
                                      onSettings: {}, onRefresh: {}, onQuit: {})
        if let rep = renderSwiftUI(nearContent, scale: POPOVER_NEAR_SCALE, dark: dark) {
            writePNG(rep, "popover-near-limit-\(suffix).png")
        } else {
            print("  !! ImageRenderer returned nil for popover-near-limit")
        }

        // The same state through the hosting path, which is what an NSPopover
        // actually uses. ImageRenderer draws `Image(systemName:)` inside a
        // `.buttonStyle(.borderless)` button as the unresolvable-image
        // placeholder — three yellow plates in the header of every file above.
        // The app is not affected and the operator ruled that `.borderless`
        // stays (docs/FOLLOW-UPS.md), so these two paths are the whole menu:
        // crisp with plates in the header, or correct chrome at 1x. Rendered as
        // a pair so a consumer can choose per placement instead of taking the
        // trade on trust.
        writePNG(render(hosted(nearContent, appearance: appearance),
                        scale: POPOVER_HOSTED_SCALE),
                 "popover-near-limit-hosted-\(suffix).png")

        defaults.set(true, forKey: SettingsKeys.copilotEnabled)
        let bothContent = PopoverView(state: appState(setA), onHoverChanged: { _ in },
                                      onSettings: {}, onRefresh: {}, onQuit: {})
        if let rep = renderSwiftUI(bothContent, scale: POPOVER_BOTH_SCALE, dark: dark) {
            writePNG(rep, "popover-both-sources-\(suffix).png")
        }
        writePNG(render(hosted(bothContent, appearance: appearance),
                        scale: POPOVER_HOSTED_SCALE),
                 "popover-both-sources-hosted-\(suffix).png")

        // -- Settings, as the App Store build presents it --------------------
        // Both credential paths the submitted build offers. The automatic
        // readers are compiled out under -DTOKES_APP_STORE, so these two are
        // the whole menu — that is the feature, not a degraded variant.
        //
        // Copilot stays ON. Every toggle and selection visible in a Settings
        // frame is an assertion about the state the other frames show, and the
        // hero strip carries a Copilot bar at 57%. A frame showing Copilot
        // disabled contradicts the set — the same class of error as the popover
        // fixtures disagreeing with the strip. Each shot also pairs like with
        // like: the manual-token frame selects the manual source on BOTH
        // services, the imported-file frame selects the file source on both.
        defaults.set(true, forKey: SettingsKeys.copilotEnabled)
        for (mode, claude, copilotSource) in [
                ("manual-token", CredentialSource.manual, CopilotCredentialSource.manual),
                ("imported-file", CredentialSource.importedFile, CopilotCredentialSource.importedFile)] {
            defaults.set(claude.rawValue, forKey: SettingsKeys.credentialSource)
            defaults.set(copilotSource.rawValue, forKey: SettingsKeys.copilotCredentialSource)
            // NOT ImageRenderer. It returns a BLANK page for SettingsView — the
            // grouped Form's AppKit-backed controls (SecureField, Toggle,
            // Picker) draw nothing through it, while PopoverView, which is
            // plain SwiftUI drawing, renders perfectly. So Settings is stuck on
            // cacheDisplay and its real resolution is the rasterisation scale,
            // not SETTINGS_SCALE. Magnifying a Settings crop far will show it.
            let view = hosted(settingsView(), appearance: appearance)
            writePNG(render(view, scale: SETTINGS_SCALE), "settings-\(mode)-\(suffix).png")

            // Same window, scrolled down. With Copilot on, Behavior and the
            // "Tokes <version> (App Store)" footer are below the fold.
            //
            // This one CANNOT use ImageRenderer — there is no way to scroll
            // SwiftUI content it renders — so it stays on the cacheDisplay path
            // and is effectively a 1x rasterisation scaled up. Do not magnify it
            // far. No approved frame uses it; it exists so the below-the-fold
            // half of the window can be seen at all.
            let scrolled = hosted(settingsView(), appearance: appearance)
            scrollToBottom(scrolled)
            writePNG(render(scrolled, scale: SETTINGS_SCALE),
                     "settings-\(mode)-scrolled-\(suffix).png")
        }
    }

    // Tear down the harness's keychain slots and read back to prove it. A
    // cleanup that is not read back is a cleanup that silently did not happen.
    CredentialsProvider.deleteManualToken(service: SHOT_KEYCHAIN)
    CredentialsProvider.deleteManualToken(service: SHOT_KEYCHAIN,
                                          account: CopilotCredentialsProvider.manualAccount)
    UserDefaults.standard.removePersistentDomain(forName: SHOT_BOOKMARKS)
    let leftover = [CredentialsProvider.readManualToken(service: SHOT_KEYCHAIN),
                    CredentialsProvider.readManualToken(
                        service: SHOT_KEYCHAIN,
                        account: CopilotCredentialsProvider.manualAccount)].compactMap { $0 }
    print(leftover.isEmpty ? "\nharness keychain slots cleared (verified empty)"
                           : "\nWARNING: \(leftover.count) harness keychain slot(s) survived cleanup")

    print("\n--- manifest ---")
    manifest.forEach { print($0) }
    print("\nAll files carry an alpha channel by design — the designer flattens.")
    exit(0)
}
app.run()
