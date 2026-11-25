import Foundation

public enum BrowserEngine: Sendable {
    case firefox
    case chromium
    /// SiteLock cannot enforce on this browser; the text tells the user why.
    case unsupported(String)
}

public struct Browser: Hashable, Sendable, Identifiable {
    /// The bundle identifier.
    public let id: String
    public let name: String
    public let engine: BrowserEngine
    /// Exact process name of the main process (for `pkill -x`).
    public let processName: String

    public var isSupported: Bool {
        if case .unsupported = engine { return false }
        return true
    }

    /// Why SiteLock cannot enforce on this browser, nil if it can.
    public var unsupportedReason: String? {
        if case .unsupported(let reason) = engine { return reason }
        return nil
    }

    public static func == (a: Browser, b: Browser) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public static let firefoxID = "org.mozilla.firefox"

    public static let catalog: [Browser] = [
        Browser(id: firefoxID, name: "Firefox", engine: .firefox, processName: "firefox"),
        Browser(id: "com.google.Chrome", name: "Google Chrome", engine: .chromium, processName: "Google Chrome"),
        Browser(id: "com.microsoft.Edge", name: "Microsoft Edge", engine: .chromium, processName: "Microsoft Edge"),
        Browser(id: "com.brave.Browser", name: "Brave", engine: .chromium, processName: "Brave Browser"),
        Browser(id: "com.vivaldi.Vivaldi", name: "Vivaldi", engine: .chromium, processName: "Vivaldi"),
        Browser(id: "org.chromium.Chromium", name: "Chromium", engine: .chromium, processName: "Chromium"),
        Browser(id: "com.apple.Safari", name: "Safari",
                engine: .unsupported("Safari has no site-blocking policy that macOS allows without device management."),
                processName: "Safari"),
        Browser(id: "com.operasoftware.Opera", name: "Opera",
                engine: .unsupported("Opera does not support browser policies."), processName: "Opera"),
        Browser(id: "company.thebrowser.Browser", name: "Arc",
                engine: .unsupported("Arc does not support browser policies."), processName: "Arc"),
    ]

    public static func byID(_ id: String) -> Browser? {
        catalog.first { $0.id == id }
    }
}
