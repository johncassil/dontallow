// Core.swift — pure logic with no Accessibility or process dependencies, so it can be unit-tested.

import Foundation

public let version = "0.1.1"

/// Normalise curly vs straight apostrophes and case: macOS titles the button “Don’t Allow” (U+2019).
public func norm(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
}

/// Extracts the app name from `Allow “Brave Browser” to find devices…`. Returns nil if the text doesn't match.
public func appName(in text: String) -> String? {
    let pattern = #"Allow [“"](.+?)[”"] to "#
    guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
    let m = String(text[r])
    guard let open = m.firstIndex(where: { $0 == "“" || $0 == "\"" }),
          let close = m.lastIndex(where: { $0 == "”" || $0 == "\"" }), open < close else { return nil }
    return String(m[m.index(after: open)..<close])
}

/// "30m", "2h", "1d", "45s" → seconds. "forever" and malformed input → nil.
public func parseDuration(_ s: String) -> TimeInterval? {
    let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
    guard let u = s.last, let mult = units[u], let n = Double(s.dropLast()), n > 0 else { return nil }
    return n * mult
}

/// Contents of the pause file → date the pause ends, or nil if the file is malformed.
public func pauseDeadline(from contents: String) -> Date? {
    let s = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    if s == "forever" { return .distantFuture }
    if let t = TimeInterval(s) { return Date(timeIntervalSince1970: t) }
    return nil
}

/// One entry per non-empty, non-comment line.
public func parseAllowlist(_ text: String) -> [String] {
    text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// Case-insensitive substring match against the allowlist.
public func isAllowlisted(_ app: String, in list: [String]) -> Bool {
    let a = app.lowercased()
    return list.contains { a.contains($0.lowercased()) }
}

/// launchd agent plist as a dictionary (serialised by the caller, so paths are escaped correctly).
public func launchdPlist(label: String, executable: String, logPath: String) -> [String: Any] {
    [
        "Label": label,
        "ProgramArguments": [executable, "run"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardOutPath": logPath,
        "StandardErrorPath": logPath,
    ]
}

// MARK: - Local Network rule store decoding

public struct LocalNetworkRule: Equatable {
    public let identifier: String
    public let path: String?          // nil for bundle-id rules
    public let denyMulticast: Bool
    public init(identifier: String, path: String?, denyMulticast: Bool) {
        self.identifier = identifier; self.path = path; self.denyMulticast = denyMulticast
    }
}

/// Decodes the NSKeyedArchiver-format XML of /Library/Preferences/com.apple.networkextension.plist
/// (as produced by `plutil -convert xml1`) into the per-app rules it contains. Read-only; no private API.
public func decodeLocalNetworkRules(xml: String) -> [LocalNetworkRule]? {
    // Keyed-archive references deserialise as opaque UID objects; rewrite them to plain "uid:N" strings first.
    let rewritten = xml.replacingOccurrences(
        of: #"<dict>\s*<key>CF\$UID</key>\s*<integer>(\d+)</integer>\s*</dict>"#,
        with: "<string>uid:$1</string>", options: .regularExpression)
    guard let data = rewritten.data(using: .utf8),
          let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let objs = root["$objects"] as? [Any], let top = root["$top"] as? [String: Any] else { return nil }

    // Resolve references with a depth cap so a cyclic archive can't recurse forever.
    func res(_ x: Any, depth: Int) -> Any {
        guard depth < 64 else { return "$cycle" }
        if let s = x as? String, s.hasPrefix("uid:"), let uid = Int(s.dropFirst(4)), uid < objs.count {
            return res(objs[uid], depth: depth + 1)
        }
        if let d = x as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in d where k != "$class" { out[k] = res(v, depth: depth + 1) }
            return out
        }
        if let a = x as? [Any] { return a.map { res($0, depth: depth + 1) } }
        return x
    }
    var found: [LocalNetworkRule] = []
    func walk(_ o: Any) {
        if let d = o as? [String: Any] {
            if let id = d["SigningIdentifier"] as? String, id != "$cycle", d["Path"] != nil {
                let p = d["Path"] as? String
                found.append(LocalNetworkRule(identifier: id, path: p == "$null" ? nil : p,
                                              denyMulticast: (d["DenyMulticast"] as? Bool) ?? false))
            }
            d.values.forEach(walk)
        } else if let a = o as? [Any] { a.forEach(walk) }
    }
    walk(res(top, depth: 0))
    // A cyclic archive repeats subtrees up to the depth cap; keep each rule once.
    var seen = Set<String>(), unique: [LocalNetworkRule] = []
    for r in found where seen.insert("\(r.identifier)|\(r.path ?? "")|\(r.denyMulticast)").inserted { unique.append(r) }
    return unique
}
