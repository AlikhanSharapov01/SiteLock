import Foundation

/// What an import did, for the app to show ("Added 12 · 3 already in the list · 1 invalid").
public struct ImportReport: Codable, Equatable, Sendable {
    public static let maxInvalidListed = 20

    public var added: Int
    public var alreadyInList: Int
    public var invalid: Int
    /// The first `maxInvalidListed` invalid entries as written in the file.
    public var invalidEntries: [String]
    /// Valid new entries that did not fit under `BlockState.maxDomains`.
    public var overLimit: Int

    public init(added: Int = 0, alreadyInList: Int = 0, invalid: Int = 0, invalidEntries: [String] = [],
                overLimit: Int = 0) {
        self.added = added
        self.alreadyInList = alreadyInList
        self.invalid = invalid
        self.invalidEntries = invalidEntries
        self.overLimit = overLimit
    }

    public var summary: String {
        var parts = ["Added \(added)"]
        if alreadyInList > 0 { parts.append("\(alreadyInList) already in the list") }
        if invalid > 0 { parts.append("\(invalid) invalid") }
        if overLimit > 0 { parts.append("\(overLimit) over the limit of \(BlockState.maxDomains)") }
        return parts.joined(separator: " · ")
    }
}

extension BlockState {
    /// Adds every valid, new entry in one change. Blank lines and lines starting with "#" are
    /// ignored (not counted). Entries beyond `maxDomains` are skipped and counted in `overLimit`.
    public mutating func importDomains(_ entries: [String]) -> ImportReport {
        var report = ImportReport()
        var seen = Set(domains)
        var fresh: [String] = []
        for raw in entries {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let domain = try? Domain.normalize(line) else {
                report.invalid += 1
                if report.invalidEntries.count < ImportReport.maxInvalidListed { report.invalidEntries.append(line) }
                continue
            }
            guard seen.insert(domain).inserted else { report.alreadyInList += 1; continue }
            if domains.count + fresh.count >= Self.maxDomains { report.overLimit += 1; continue }
            fresh.append(domain)
        }
        for domain in fresh { try? add(domain) }
        report.added = fresh.count
        return report
    }
}
