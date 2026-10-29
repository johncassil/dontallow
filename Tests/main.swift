// Minimal test harness: builds with plain swiftc against Core.swift, no XCTest or SwiftPM needed.
import Foundation

var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ name: String, file: String = #file, line: Int = #line) {
    if cond() { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)  (\(file):\(line))") }
}

// norm
check(norm("Don’t Allow") == "don't allow", "norm folds curly apostrophe and case")
check(norm("Allow") == "allow", "norm leaves plain text")

// appName
let dialog = "alert | Allow “Brave Browser” to find devices on local networks? | This will allow the app… | Don’t Allow | Allow"
check(appName(in: dialog) == "Brave Browser", "appName extracts curly-quoted name")
check(appName(in: "Allow \"My App\" to find devices") == "My App", "appName accepts straight quotes")
check(appName(in: "Allow “x\\\" & do shell script \"id\"” to find") == "x\\\" & do shell script \"id\"", "appName returns hostile names verbatim (caller must not interpolate)")
check(appName(in: "Something unrelated") == nil, "appName nil when no match")

// parseDuration
check(parseDuration("30m") == 1800, "30m")
check(parseDuration("2h") == 7200, "2h")
check(parseDuration("1d") == 86400, "1d")
check(parseDuration("45s") == 45, "45s")
check(parseDuration("forever") == nil, "forever is not a duration")
check(parseDuration("0m") == nil, "zero rejected")
check(parseDuration("abc") == nil, "garbage rejected")
check(parseDuration("") == nil, "empty rejected")

// pauseDeadline
check(pauseDeadline(from: "forever\n") == .distantFuture, "forever → distantFuture")
check(pauseDeadline(from: "1700000000") == Date(timeIntervalSince1970: 1700000000), "epoch parsed")
check(pauseDeadline(from: "nope") == nil, "garbage → nil")

// allowlist
let list = parseAllowlist("# comment\nBrother\n\n  Orca  \n")
check(list == ["Brother", "Orca"], "parseAllowlist trims, skips blanks and comments")
check(isAllowlisted("Brother iPrint&Scan", in: list), "substring, case-insensitive match")
check(isAllowlisted("orca", in: list), "case-insensitive")
check(!isAllowlisted("Google Chrome", in: list), "non-member")
check(!isAllowlisted("anything", in: []), "empty list matches nothing")

// launchd plist round-trips through the serializer with hostile paths
let dict = launchdPlist(label: "x.y", executable: "/Users/me/Tools & Apps/<bin>/dontallow", logPath: "/tmp/a&b.log")
if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0),
   let back = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
    check((back["ProgramArguments"] as? [String]) == ["/Users/me/Tools & Apps/<bin>/dontallow", "run"], "plist escapes & and < in paths")
    check((back["KeepAlive"] as? Bool) == true, "plist KeepAlive")
} else { failures += 1; print("FAIL plist serialization") }

// rules decoder on a synthetic keyed archive: one bundle rule, one path rule, one cycle
let fixture = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>$archiver</key><string>NSKeyedArchiver</string>
  <key>$objects</key><array>
    <string>$null</string>
    <dict><key>Rules</key><array><dict><key>CF$UID</key><integer>2</integer></dict><dict><key>CF$UID</key><integer>5</integer></dict></array>
          <key>Self</key><dict><key>CF$UID</key><integer>1</integer></dict></dict>
    <dict><key>SigningIdentifier</key><dict><key>CF$UID</key><integer>3</integer></dict>
          <key>Path</key><dict><key>CF$UID</key><integer>0</integer></dict>
          <key>DenyMulticast</key><true/></dict>
    <string>com.example.bundle</string>
    <string>/Applications/Example.app/Contents/MacOS/Example</string>
    <dict><key>SigningIdentifier</key><dict><key>CF$UID</key><integer>3</integer></dict>
          <key>Path</key><dict><key>CF$UID</key><integer>4</integer></dict>
          <key>DenyMulticast</key><false/></dict>
  </array>
  <key>$top</key><dict><key>root</key><dict><key>CF$UID</key><integer>1</integer></dict></dict>
  <key>$version</key><integer>100000</integer>
</dict></plist>
"""
if let rules = decodeLocalNetworkRules(xml: fixture) {
    check(rules.count == 2, "two rules decoded despite self-referencing archive (got \(rules.count): \(rules))")
    check(rules.contains(LocalNetworkRule(identifier: "com.example.bundle", path: nil, denyMulticast: true)), "bundle rule, denied")
    check(rules.contains(LocalNetworkRule(identifier: "com.example.bundle", path: "/Applications/Example.app/Contents/MacOS/Example", denyMulticast: false)), "path rule, allowed")
} else { failures += 1; print("FAIL rules decoder returned nil") }
check(decodeLocalNetworkRules(xml: "not a plist") == nil, "decoder returns nil on garbage")

print(failures == 0 ? "\nall tests passed" : "\n\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
