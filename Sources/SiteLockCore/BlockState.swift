import Foundation

public enum BlockStateError: Error, Equatable, CustomStringConvertible {
    case alreadyBlocked(String)
    case notInList(String)
    case notUnblocked(String)
    case invalidDuration(Int)
    case tooManyDomains(Int)

    public var description: String {
        switch self {
        case .alreadyBlocked(let d): return "\(d) is already in the list"
        case .notInList(let d): return "\(d) is not in the list"
        case .notUnblocked(let d): return "\(d) is not temporarily unblocked"
        case .invalidDuration(let m): return "Unblock duration must be 1–\(BlockState.maxUnblockMinutes) minutes (got \(m))"
        case .tooManyDomains(let n): return "Firefox accepts at most \(n) blocked domains"
        }
    }
}

/// The persisted blocklist plus active temporary unblocks (domain -> expiry).
/// All time-dependent functions take `now` so the timing logic is testable.
public struct BlockState: Codable, Equatable, Sendable {
    public static let maxUnblockMinutes = 24 * 60
    /// Firefox's WebsiteFilter reads at most 1000 patterns per list.
    public static let maxDomains = 1000

    public private(set) var domains: [String]
    public private(set) var unblocks: [String: Date]

    public init(domains: [String] = [], unblocks: [String: Date] = [:]) {
        self.domains = domains.sorted()
        self.unblocks = unblocks
    }

    public mutating func add(_ domain: String) throws {
        guard !domains.contains(domain) else { throw BlockStateError.alreadyBlocked(domain) }
        guard domains.count < Self.maxDomains else { throw BlockStateError.tooManyDomains(Self.maxDomains) }
        domains.append(domain)
        domains.sort()
    }

    public mutating func remove(_ domain: String) throws {
        guard let i = domains.firstIndex(of: domain) else { throw BlockStateError.notInList(domain) }
        domains.remove(at: i)
        unblocks[domain] = nil
    }

    /// Unblocks `domain` until now + minutes. Calling it again replaces the expiry.
    public mutating func unblock(_ domain: String, minutes: Int, now: Date) throws {
        guard domains.contains(domain) else { throw BlockStateError.notInList(domain) }
        guard (1...Self.maxUnblockMinutes).contains(minutes) else { throw BlockStateError.invalidDuration(minutes) }
        unblocks[domain] = now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Ends a temporary unblock early.
    public mutating func reblock(_ domain: String) throws {
        guard unblocks.removeValue(forKey: domain) != nil else { throw BlockStateError.notUnblocked(domain) }
    }

    /// Replaces `old` with `new` (an edit in the list). The edited entry starts blocked: any
    /// temporary unblock of `old` is dropped, because the edit changes what is blocked.
    public mutating func rename(_ old: String, to new: String) throws {
        guard let i = domains.firstIndex(of: old) else { throw BlockStateError.notInList(old) }
        guard new != old else { return }
        guard !domains.contains(new) else { throw BlockStateError.alreadyBlocked(new) }
        domains[i] = new
        domains.sort()
        unblocks[old] = nil
    }

    /// Drops unblocks whose expiry is at or before `now`. Returns true if any were dropped.
    @discardableResult
    public mutating func pruneExpired(now: Date) -> Bool {
        let before = unblocks.count
        unblocks = unblocks.filter { $0.value > now }
        return unblocks.count != before
    }

    public func isTemporarilyUnblocked(_ domain: String, now: Date) -> Bool {
        guard let until = unblocks[domain] else { return false }
        return until > now
    }

    /// Domains Firefox must block right now.
    public func effectiveBlocked(now: Date) -> [String] {
        domains.filter { !isTemporarilyUnblocked($0, now: now) }
    }

    /// Earliest future expiry, i.e. when the policy next has to change.
    public func nextExpiry(now: Date) -> Date? {
        unblocks.values.filter { $0 > now }.min()
    }
}
