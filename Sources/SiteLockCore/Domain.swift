import Foundation

public enum DomainError: Error, Equatable, CustomStringConvertible {
    case empty
    case invalid(String)

    public var description: String {
        switch self {
        case .empty: return "Enter a domain, e.g. instagram.com"
        case .invalid(let s): return "\"\(s)\" is not a valid domain (use ASCII, e.g. instagram.com)"
        }
    }
}

public enum Domain {
    /// Turns user input such as "https://www.YouTube.com/feed" into the host "www.youtube.com".
    /// The host is kept as typed (no "www." stripping): an entry blocks that host and its
    /// subdomains only, so "www.youtube.com" leaves "music.youtube.com" alone while
    /// "youtube.com" blocks both (same rule as the "Domain Blocker" Firefox add-on).
    public static func normalize(_ input: String) throws -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { throw DomainError.empty }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<i]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        while s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("*.") { s.removeFirst(2) }
        guard isValid(s) else { throw DomainError.invalid(input.trimmingCharacters(in: .whitespaces)) }
        return s
    }

    static func isValid(_ s: String) -> Bool {
        guard s.count <= 253 else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard (1...63).contains(label.count),
                  label.allSatisfy({ allowed.contains($0) }),
                  label.first != "-", label.last != "-" else { return false }
        }
        // Top-level label must not be all digits (rejects IPv4 addresses).
        return !labels.last!.allSatisfy(\.isNumber)
    }

    /// Firefox WebsiteFilter match pattern. "*." in a match pattern matches the host itself and
    /// every subdomain of it (never its parent or siblings), on any scheme (http/https/ws/wss).
    public static func blockPattern(for domain: String) -> String {
        "*://*.\(domain)/*"
    }
}
