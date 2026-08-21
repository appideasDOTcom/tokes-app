import Combine

/// Test hook for ViewInspector: a view that owns one of these and forwards
/// `notice` through `.onReceive` lets a hosted test visit its *live* body —
/// the only way to press a button whose enablement depends on `@State`.
///
/// The app never sends through `notice`, so in production this is a single
/// dormant Combine subscription per Settings window. The conformance that
/// makes it useful (`InspectionEmissary`) lives in the test target; this
/// target never imports ViewInspector.
@MainActor
final class Inspection<V> {
    let notice = PassthroughSubject<UInt, Never>()
    var callbacks: [UInt: (V) -> Void] = [:]

    func visit(_ view: V, _ line: UInt) {
        if let callback = callbacks.removeValue(forKey: line) {
            callback(view)
        }
    }
}
