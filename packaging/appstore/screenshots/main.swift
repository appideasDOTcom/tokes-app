import AppKit
import SwiftUI

let OUT = ProcessInfo.processInfo.environment["OUT"] ?? "/tmp"
let W: CGFloat = 1440, H: CGFloat = 900          // logical; rendered at 2x = 2880x1800

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
NSApp.appearance = NSAppearance(named: .darkAqua)

// ---------------------------------------------------------------- fixtures --
let now = Date()

func limits(copilot: Bool) -> [UsageLimit] {
    var l = [
        UsageLimit(id: "session", label: "Session (5 hr)", percent: 62, severity: "warn",
                   resetsAt: now.addingTimeInterval(2 * 3600 + 900), isSession: true),
        UsageLimit(id: "weekly_all", label: "Weekly (7 day)", percent: 41, severity: "ok",
                   resetsAt: now.addingTimeInterval(3.5 * 86400), isSession: false),
        UsageLimit(id: "weekly_scoped:Fable", label: "Weekly Fable", percent: 78, severity: "warn",
                   resetsAt: now.addingTimeInterval(3.5 * 86400), isSession: false),
    ]
    if copilot {
        l.append(UsageLimit(id: "copilot_premium", label: "Premium requests", percent: 34,
                            severity: "ok", resetsAt: now.addingTimeInterval(11 * 86400),
                            isSession: false, provider: .copilot,
                            detail: "612 of 1,800 credits used"))
    }
    return l
}

/// Deterministic, plausible-looking history: monotonic drift plus a little shape.
/// No RNG, so re-running produces byte-identical screenshots.
func samples() -> [UsageSample] {
    let step: TimeInterval = 300
    let count = Int(7 * 86400 / step)
    return (0..<count).reversed().map { i in
        let t = now.addingTimeInterval(-Double(i) * step)
        let p = 1 - Double(i) / Double(count)                 // 0 -> 1 over the window
        func curve(_ target: Double, _ wobble: Double, _ phase: Double) -> Double {
            let base = target * (0.15 + 0.85 * p)
            return max(0, min(100, base + wobble * sin(Double(i) / 30 + phase)))
        }
        return UsageSample(t: t, v: [
            "session": curve(62, 6, 0),
            "weekly_all": curve(41, 2.5, 1.1),
            "weekly_scoped:Fable": curve(78, 3.5, 2.2),
            "copilot_premium": curve(34, 2, 0.6),
        ])
    }
}

func state(copilot: Bool) -> AppState {
    let s = AppState()
    s.snapshot = UsageSnapshot(limits: limits(copilot: copilot), fetchedAt: now.addingTimeInterval(-42))
    s.samples = samples()
    return s
}

// ----------------------------------------------------------------- render ---
/// Renders a view at `scale` device pixels per point. `rep.size` in points is
/// what makes the backing store high-resolution rather than merely large.
func render(_ view: NSView, scale: CGFloat) -> NSImage {
    view.layoutSubtreeIfNeeded()
    let bounds = CGRect(origin: .zero, size: view.fittingSize == .zero ? view.bounds.size : view.frame.size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(bounds.width * scale),
                               pixelsHigh: Int(bounds.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = bounds.size
    view.cacheDisplay(in: bounds, to: rep)
    let image = NSImage(size: bounds.size)
    image.addRepresentation(rep)
    return image
}

func hosted<V: View>(_ view: V, width: CGFloat? = nil) -> NSView {
    let c = NSHostingController(rootView: view)
    var size = c.view.fittingSize
    if let width { size.width = width }
    c.view.frame = CGRect(origin: .zero, size: size)
    c.view.layoutSubtreeIfNeeded()
    return c.view
}

// ------------------------------------------------------------------ canvas --
func canvas(_ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// y measured from the top edge, which is how the layouts below are described.
func fromTop(_ y: CGFloat, _ height: CGFloat) -> CGFloat { H - y - height }

func background() {
    // Flat multi-stop vertical gradient. An earlier radial "bloom" left a
    // visible circular seam however it was clipped — on a near-black field
    // there is no way to hide the boundary, so there isn't one.
    let g = NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.125, green: 0.135, blue: 0.175, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.085, green: 0.090, blue: 0.120, alpha: 1), 0.55),
        (NSColor(srgbRed: 0.045, green: 0.048, blue: 0.065, alpha: 1), 1.0))
    g?.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
}

func shadowed(_ image: NSImage, at origin: NSPoint, scale: CGFloat = 1, radius: CGFloat = 12) {
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let rect = NSRect(origin: origin, size: size)
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowBlurRadius = 42
    s.shadowOffset = NSSize(width: 0, height: -14)
    s.shadowColor = NSColor.black.withAlphaComponent(0.55)
    s.set()
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

/// Draws `string` and returns the height it occupied, so callers can stack
/// blocks instead of guessing fixed offsets (which collide the moment a
/// headline wraps).
@discardableResult
/// Composites a titlebar above `content` so a cropped form reads as a real
/// window rather than a clipped image.
func windowed(_ content: NSImage, title: String, cropBottom: CGFloat = 0) -> NSImage {
    let bar: CGFloat = 28
    let visible = content.size.height - cropBottom
    let size = NSSize(width: content.size.width, height: visible + bar)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1).setFill()
    NSRect(x: 0, y: visible, width: size.width, height: bar).fill()
    // Drawn below the origin so the crop takes from the bottom, keeping the top.
    content.draw(in: NSRect(x: 0, y: -cropBottom, width: content.size.width, height: content.size.height))

    let lights: [NSColor] = [NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
                             NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
                             NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)]
    for (i, colour) in lights.enumerated() {
        colour.setFill()
        NSBezierPath(ovalIn: NSRect(x: 14 + CGFloat(i) * 20, y: visible + bar / 2 - 6,
                                    width: 12, height: 12)).fill()
    }
    let t = NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
    t.draw(at: NSPoint(x: (size.width - t.size().width) / 2,
                       y: visible + (bar - t.size().height) / 2))
    image.unlockFocus()
    return image
}

func text(_ string: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = .white, width: CGFloat = 660) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = size * 0.18
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ]
    let a = NSAttributedString(string: string, attributes: attrs)
    let h = a.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                           options: [.usesLineFragmentOrigin]).height
    a.draw(with: NSRect(x: point.x, y: fromTop(point.y, h), width: width, height: h),
           options: [.usesLineFragmentOrigin])
    return h
}

/// A headline plus body, stacked and vertically centred on `centerY`.
func textBlock(_ headline: String, _ body: String, centerY: CGFloat, x: CGFloat = 104) {
    let width: CGFloat = 660
    func height(_ s: String, _ size: CGFloat, _ w: NSFont.Weight) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = size * 0.18
        return NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: w), .paragraphStyle: style,
        ]).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin]).height
    }
    let gap: CGFloat = 26
    let total = height(headline, 52, .bold) + gap + height(body, 22, .regular)
    var y = centerY - total / 2
    y += text(headline, at: NSPoint(x: x, y: y), size: 52, weight: .bold, width: width) + gap
    text(body, at: NSPoint(x: x, y: y), size: 22,
         color: NSColor.white.withAlphaComponent(0.62), width: width)
}

/// The macOS menu bar, drawn just convincingly enough to place the status item.
func menuBar(_ statusIcon: NSImage, label: String?, uiScale: CGFloat = 1) {
    let barHeight: CGFloat = 26 * uiScale
    let rect = NSRect(x: 0, y: H - barHeight, width: W, height: barHeight)
    NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 0.96).setFill()
    rect.fill()

    var x = W - 24 * uiScale
    let clock = NSAttributedString(string: "Tue 9:41", attributes: [
        .font: NSFont.systemFont(ofSize: 12.5 * uiScale, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92)])
    x -= clock.size().width
    clock.draw(at: NSPoint(x: x, y: H - barHeight + (barHeight - clock.size().height) / 2))

    x -= 22 * uiScale
    if let label {
        let t = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5 * uiScale, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)])
        x -= t.size().width
        t.draw(at: NSPoint(x: x, y: H - barHeight + (barHeight - t.size().height) / 2))
        x -= 6 * uiScale
    }
    let iconSize = NSSize(width: statusIcon.size.width * uiScale, height: statusIcon.size.height * uiScale)
    x -= iconSize.width
    statusIcon.draw(in: NSRect(x: x, y: H - barHeight + (barHeight - iconSize.height) / 2,
                               width: iconSize.width, height: iconSize.height))
    statusItemCenterX = x + iconSize.width / 2
}
var statusItemCenterX: CGFloat = W - 120

func write(_ rep: NSBitmapImageRep, _ name: String) {
    let url = URL(fileURLWithPath: "\(OUT)/\(name)")
    try? rep.representation(using: .png, properties: [:])!.write(to: url)
    print("  \(name)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
}

// ------------------------------------------------------------------- shots --
DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: SettingsKeys.showScopedWeekly)
    defaults.set(true, forKey: SettingsKeys.copilotEnabled)
    defaults.set(MenuBarLabel.highest.rawValue, forKey: SettingsKeys.menuBarLabel)
    defaults.set(CredentialSource.manual.rawValue, forKey: SettingsKeys.credentialSource)
    defaults.set(CopilotCredentialSource.importedFile.rawValue, forKey: SettingsKeys.copilotCredentialSource)

    let full = limits(copilot: true)
    let icon = StatusItemController.makeIcon(limits: full)
    let title = StatusItemController.makeTitle(limits: full, selection: .highest, hasError: false)

    let popoverView = hosted(PopoverView(state: state(copilot: true), onHoverChanged: { _ in },
                                         onSettings: {}, onRefresh: {}, onQuit: {}))
    let popover = render(popoverView, scale: 3)
    print("popover logical size: \(popover.size)")

    // 1 — the product in situ: menu bar item plus the popover it opens.
    write(canvas {
        background()
        let ui: CGFloat = 1.22
        menuBar(icon, label: title?.string, uiScale: ui)
        let pw = popover.size.width * ui, ph = popover.size.height * ui
        let px = min(W - pw - 70, statusItemCenterX - pw / 2)
        shadowed(popover, at: NSPoint(x: px, y: fromTop(26 * ui + 14, ph)), scale: ui, radius: 14)
        textBlock("Every limit, at a glance.",
                  "Session, weekly, model-scoped and Copilot quotas — live in your menu bar, "
                  + "colour-coded the moment one starts running hot.",
                  centerY: 26 * ui + 14 + ph / 2)
    }, "01-menu-bar-and-popover.png")

    // 2 — the popover on its own, larger, so the charts are legible.
    write(canvas {
        background()
        let scale: CGFloat = 1.45
        let size = NSSize(width: popover.size.width * scale, height: popover.size.height * scale)
        shadowed(popover, at: NSPoint(x: W - size.width - 120, y: (H - size.height) / 2), scale: scale, radius: 16)
        textBlock("History the API doesn't keep.",
                  "The usage endpoint only reports this instant. Tokes records every poll on "
                  + "your Mac, so you get a trend line instead of a number.",
                  centerY: H / 2)
    }, "02-usage-history.png")

    // 3 — Settings, in the App Store build's configuration. Copilot is switched
    // off here purely so the whole form fits the fixed 620pt window without the
    // Behavior section being sliced in half.
    defaults.set(false, forKey: SettingsKeys.copilotEnabled)
    defaults.set(CredentialSource.importedFile.rawValue, forKey: SettingsKeys.credentialSource)
    let settingsView = hosted(SettingsView(onCredentialsChanged: {}))
    let settings = windowed(render(settingsView, scale: 3), title: "Settings", cropBottom: 22)
    write(canvas {
        background()
        let scale: CGFloat = 1.1
        let size = NSSize(width: settings.size.width * scale, height: settings.size.height * scale)
        shadowed(settings, at: NSPoint(x: W - size.width - 130, y: (H - size.height) / 2), scale: scale, radius: 14)
        textBlock("Your credentials stay yours.",
                  "Paste a token, or point Tokes at a file you pick yourself. It is kept in "
                  + "your keychain and sent nowhere but the service it belongs to.",
                  centerY: H / 2)
    }, "03-settings.png")

    exit(0)
}
app.run()
