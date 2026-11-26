import Foundation

/// The block SiteLock keeps in /etc/hosts for Safari, which has no site-blocking policy.
///
/// Each blocked host is pointed at 0.0.0.0 and :: together with its `www.` and `m.` forms
/// (other subdomains cannot be covered by a hosts file). Everything outside the
/// BEGIN/END markers is left exactly as it is.
public struct HostsPolicy: Equatable, Sendable {
    public static let path = "/etc/hosts"
    public static let beginMarker = "# BEGIN SiteLock — managed automatically, do not edit"
    public static let endMarker = "# END SiteLock"

    public let hosts: [String]

    public init(blockedDomains: [String]) {
        var names = Set<String>()
        for host in blockedDomains where Domain.isValid(host) {
            names.insert(host)
            if !host.hasPrefix("www.") && !host.hasPrefix("m.") {
                names.insert("www." + host)
                names.insert("m." + host)
            }
        }
        hosts = names.sorted()
    }

    /// The lines of the managed block, empty when nothing is blocked.
    public var blockLines: [String] {
        guard !hosts.isEmpty else { return [] }
        return [Self.beginMarker] + hosts.flatMap { ["0.0.0.0 \($0)", ":: \($0)"] } + [Self.endMarker]
    }

    /// `existing` with the managed block replaced (or appended); other lines are untouched.
    public func apply(to existing: String) -> String {
        var (lines, at) = Self.removingBlocks(from: existing)
        let block = blockLines
        guard !block.isEmpty else { return lines.joined(separator: "\n") }
        if let at {
            lines.insert(contentsOf: block, at: at)
        } else {
            if lines.last == "" { lines.removeLast() }
            lines += block
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// `existing` without the managed block.
    public static func strip(_ existing: String) -> String {
        removingBlocks(from: existing).lines.joined(separator: "\n")
    }

    /// True if `existing` already holds exactly this policy.
    public func isSatisfied(by existing: String) -> Bool {
        apply(to: existing) == existing
    }

    /// True if `existing` holds a SiteLock block.
    public static func hasBlock(_ existing: String) -> Bool {
        removingBlocks(from: existing).at != nil
    }

    /// Removes every BEGIN...END block. A BEGIN pairs only with the next END with no other BEGIN
    /// in between; a stray BEGIN or END is a foreign line and stays; `at` is the line
    /// index where the first one was.
    private static func removingBlocks(from text: String) -> (lines: [String], at: Int?) {
        // Split on the LF byte: Swift treats "\r\n" as one Character, so CRLF files must not be split by Character.
        let lines = text.utf8.split(separator: 10, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var kept: [String] = []
        var at: Int?
        var i = 0
        while i < lines.count {
            if lines[i] == beginMarker,
               let end = lines[(i + 1)...].firstIndex(where: { $0 == endMarker || $0 == beginMarker }),
               lines[end] == endMarker {
                if at == nil { at = kept.count }
                i = end + 1
            } else {
                kept.append(lines[i])
                i += 1
            }
        }
        return (kept, at)
    }
}
