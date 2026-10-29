// dontallow — auto-dismisses the macOS "Allow X to find devices on local networks?" prompt.
//
// Event-driven: sleeps until the system dialog host (UserNotificationCenter) creates a window,
// waits a short grace period so a human can still click Allow, then presses "Don't Allow".
// Zero CPU while idle. Single file, no dependencies.

import Foundation
import AppKit
import ApplicationServices

// MARK: - Constants

let version        = "0.1.0"
let hostBundleID   = "com.apple.UserNotificationCenter"
let launchdLabel   = "com.pkgwarden.dontallow"
let denyTitle      = "don't allow"      // compared after apostrophe normalisation
let needle         = "local network"
let defaultGrace   = 0.25                // seconds before pressing; raise via ~/.config/dontallow/grace

let home       = FileManager.default.homeDirectoryForCurrentUser
let configDir  = home.appendingPathComponent(".config/dontallow")
let pauseFile  = configDir.appendingPathComponent("paused-until")
let allowFile  = configDir.appendingPathComponent("allowlist")
let graceFile  = configDir.appendingPathComponent("grace")
let logFile    = home.appendingPathComponent("Library/Logs/dontallow.log")
let plistFile  = home.appendingPathComponent("Library/LaunchAgents/\(launchdLabel).plist")

// MARK: - Logging

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("\(ts) \(s)")
    fflush(stdout)
}

func fail(_ s: String) -> Never {
    FileHandle.standardError.write("dontallow: \(s)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Config

func norm(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
}

func pausedUntil() -> Date? {
    guard let s = try? String(contentsOf: pauseFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    if s == "forever" { return .distantFuture }
    if let t = TimeInterval(s) { return Date(timeIntervalSince1970: t) }
    return nil
}

func isPaused() -> Bool {
    guard let until = pausedUntil() else { return false }
    if until > Date() { return true }
    try? FileManager.default.removeItem(at: pauseFile)   // expired
    return false
}

func gracePeriod() -> TimeInterval {
    if let s = try? String(contentsOf: graceFile, encoding: .utf8), let g = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return max(0, g) }
    return defaultGrace
}

func allowlist() -> [String] {
    guard let s = try? String(contentsOf: allowFile, encoding: .utf8) else { return [] }
    return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

func isAllowlisted(_ app: String) -> Bool {
    let a = app.lowercased()
    return allowlist().contains { a.contains($0.lowercased()) }
}

// MARK: - Accessibility helpers

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func walk(_ el: AXUIElement, depth: Int = 0, texts: inout [String], buttons: inout [AXUIElement]) {
    guard depth < 8 else { return }
    if (attr(el, kAXRoleAttribute) as? String) == (kAXButtonRole as String) { buttons.append(el) }
    for key in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
        if let s = attr(el, key) as? String, !s.isEmpty { texts.append(s) }
    }
    for c in children(el) { walk(c, depth: depth + 1, texts: &texts, buttons: &buttons) }
}

/// Extracts the app name from `Allow “Brave Browser” to find devices…`.
func appName(in text: String) -> String {
    let pattern = #"Allow [“"](.+?)[”"] to"#
    if let r = text.range(of: pattern, options: .regularExpression) {
        let m = String(text[r])
        if let open = m.firstIndex(where: { $0 == "“" || $0 == "\"" }),
           let close = m.lastIndex(where: { $0 == "”" || $0 == "\"" }), open < close {
            return String(m[m.index(after: open)..<close])
        }
    }
    return "unknown app"
}

func clickCenter(of el: AXUIElement) {
    var posRef: CFTypeRef?, sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success else { return }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
    let c = CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

func notify(_ body: String) {
    let esc = body.replacingOccurrences(of: "\"", with: "\\\"")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(esc)\" with title \"dontallow\""]
    try? p.run()
}

// MARK: - Core: evaluate one dialog window

var dryRun = false

func evaluate(_ win: AXUIElement, attempt: Int = 0) {
    var texts: [String] = []
    var buttons: [AXUIElement] = []
    walk(win, texts: &texts, buttons: &buttons)
    guard !texts.isEmpty else { return }                         // window already gone
    let blob = texts.joined(separator: " | ")
    guard blob.lowercased().contains(needle) else { return }
    let app = appName(in: blob)
    if buttons.isEmpty && attempt < 4 {                          // dialog still being built; look again shortly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { evaluate(win, attempt: attempt + 1) }
        return
    }

    if isPaused() {
        log("left prompt for \(app) alone (paused)"); return
    }
    if isAllowlisted(app) {
        log("left prompt for \(app) alone (allowlisted)"); return
    }
    guard let deny = buttons.first(where: { norm(attr($0, kAXTitleAttribute) as? String ?? "") == denyTitle }) else {
        log("prompt for \(app) matched but no Don't Allow button found"); return
    }
    if dryRun {
        log("DRY RUN: would dismiss prompt for \(app)"); return
    }
    let r = AXUIElementPerformAction(deny, kAXPressAction as CFString)
    if r != .success {
        log("AXPress failed (\(r.rawValue)) for \(app); using synthetic click")
        clickCenter(of: deny)
    }
    log("dismissed Local Network prompt for \(app)")
    notify("Dismissed Local Network prompt for \(app). To let apps ask: dontallow pause")
}

func scheduleEvaluate(_ win: AXUIElement) {
    DispatchQueue.main.asyncAfter(deadline: .now() + gracePeriod()) { evaluate(win) }
}

func scanExistingWindows(pid: pid_t) {
    let appEl = AXUIElementCreateApplication(pid)
    for w in (attr(appEl, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { scheduleEvaluate(w) }
}

// MARK: - Observer lifecycle

var observer: AXObserver?
var observedPID: pid_t = 0

let axCallback: AXObserverCallback = { _, element, _, _ in
    scheduleEvaluate(element)
}

func attach(to app: NSRunningApplication) {
    detach()
    let pid = app.processIdentifier
    var obs: AXObserver?
    guard AXObserverCreate(pid, axCallback, &obs) == .success, let o = obs else {
        log("could not create AX observer for pid \(pid)"); return
    }
    let appEl = AXUIElementCreateApplication(pid)
    let r = AXObserverAddNotification(o, appEl, kAXWindowCreatedNotification as CFString, nil)
    guard r == .success else {
        if r == .apiDisabled {
            log("Accessibility is not granted to this binary; will retry every \(Int(retryInterval))s. Grant it in System Settings > Privacy & Security > Accessibility.")
            requestAccessibility()
        } else {
            log("could not subscribe to window events (\(r.rawValue)); retrying in \(Int(retryInterval))s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
            if observer == nil, let a = NSRunningApplication.runningApplications(withBundleIdentifier: hostBundleID).first { attach(to: a) }
        }
        return
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(o), .defaultMode)
    observer = o; observedPID = pid
    log("watching dialog host pid \(pid)")
    scanExistingWindows(pid: pid)
}

func detach() {
    if let o = observer {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(o), .defaultMode)
    }
    observer = nil; observedPID = 0
}

let retryInterval = 10.0
var promptedForAccessibility = false

func requestAccessibility() {
    guard !promptedForAccessibility else { return }
    promptedForAccessibility = true
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}

func runDaemon() {
    if !AXIsProcessTrusted() {
        log("Accessibility permission not granted. Add this binary in System Settings > Privacy & Security > Accessibility.")
        requestAccessibility()
    }
    log("dontallow \(version) started (dryRun=\(dryRun), grace=\(gracePeriod())s)")

    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.bundleIdentifier == hostBundleID { attach(to: app) }
    }
    nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == observedPID { detach(); log("dialog host exited") }
    }
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: hostBundleID).first {
        attach(to: app)
    } else {
        log("dialog host not running yet; will attach when it launches")
    }
    RunLoop.main.run()
}

// MARK: - launchd install / uninstall

func shell(_ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}

func domain() -> String { "gui/\(getuid())" }

func install() {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>\(launchdLabel)</string>
      <key>ProgramArguments</key><array><string>\(exe)</string><string>run</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>StandardOutPath</key><string>\(logFile.path)</string>
      <key>StandardErrorPath</key><string>\(logFile.path)</string>
    </dict></plist>
    """
    try? FileManager.default.createDirectory(at: plistFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    do { try plist.write(to: plistFile, atomically: true, encoding: .utf8) } catch { fail("could not write \(plistFile.path): \(error)") }
    _ = shell(["bootout", "\(domain())/\(launchdLabel)"])
    let (code, out) = shell(["bootstrap", domain(), plistFile.path])
    guard code == 0 else { fail("launchctl bootstrap failed: \(out)") }
    print("installed launch agent \(launchdLabel) running \(exe)")
    print("If this is the first install, grant Accessibility when prompted (or add the binary manually), then run: dontallow restart")
}

func uninstall() {
    _ = shell(["bootout", "\(domain())/\(launchdLabel)"])
    try? FileManager.default.removeItem(at: plistFile)
    print("removed launch agent. Remove the binary from Privacy & Security > Accessibility if you like.")
}

func restart() {
    let (code, out) = shell(["kickstart", "-k", "\(domain())/\(launchdLabel)"])
    print(code == 0 ? "restarted" : "restart failed: \(out)")
}

// MARK: - pause / resume / status

func parseDuration(_ s: String) -> TimeInterval? {
    if s == "forever" { return nil }
    let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
    guard let u = s.last, let mult = units[u], let n = Double(s.dropLast()) else { return nil }
    return n * mult
}

func pause(_ arg: String?) {
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let a = arg ?? "1h"
    if a == "forever" {
        try? "forever".write(to: pauseFile, atomically: true, encoding: .utf8)
        print("paused until you run: dontallow resume"); return
    }
    guard let d = parseDuration(a) else { fail("bad duration '\(a)'; use e.g. 30m, 2h, 1d, forever") }
    let until = Date().addingTimeInterval(d)
    try? String(until.timeIntervalSince1970).write(to: pauseFile, atomically: true, encoding: .utf8)
    print("paused until \(until.formatted(date: .omitted, time: .shortened)); prompts will be left for you to answer")
}

func resume() {
    try? FileManager.default.removeItem(at: pauseFile)
    // Re-attach so any prompt that appeared while paused is re-evaluated now.
    _ = shell(["kickstart", "-k", "\(domain())/\(launchdLabel)"])
    print("resumed")
}

func status() {
    let (code, out) = shell(["print", "\(domain())/\(launchdLabel)"])
    if code == 0, let line = out.split(separator: "\n").first(where: { $0.contains("pid = ") }) {
        print("agent:    running (\(line.trimmingCharacters(in: .whitespaces)))")
    } else {
        print("agent:    not installed or not running  (dontallow install)")
    }
    if let until = pausedUntil(), until > Date() {
        print("paused:   yes, until \(until == .distantFuture ? "resumed manually" : until.formatted())")
    } else {
        print("paused:   no")
    }
    let al = allowlist()
    print("allowlist: \(al.isEmpty ? "(empty)  \(allowFile.path)" : al.joined(separator: ", "))")
    if let s = try? String(contentsOf: logFile, encoding: .utf8) {
        let lines = s.split(separator: "\n").filter { $0.contains("dismissed") || $0.contains("left prompt") }.suffix(5)
        if !lines.isEmpty { print("recent:"); lines.forEach { print("  \($0)") } }
    }
}

// MARK: - rules: decode the system's Local Network rule store (read-only)

func rules() {
    let store = "/Library/Preferences/com.apple.networkextension.plist"
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
    p.arguments = ["-convert", "xml1", "-o", "-", store]
    let pipe = Pipe(); p.standardOutput = pipe
    do { try p.run() } catch { fail("cannot run plutil: \(error)") }
    var xml = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; p.waitUntilExit()
    // Keyed-archive references come back as opaque UID objects; turn them into plain "uid:N" strings first.
    xml = xml.replacingOccurrences(of: #"<dict>\s*<key>CF\$UID</key>\s*<integer>(\d+)</integer>\s*</dict>"#,
                                   with: "<string>uid:$1</string>", options: .regularExpression)
    guard let data = xml.data(using: .utf8),
          let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let objs = root["$objects"] as? [Any], let top = root["$top"] as? [String: Any] else { fail("cannot parse \(store)") }

    func res(_ x: Any) -> Any {
        if let s = x as? String, s.hasPrefix("uid:"), let uid = Int(s.dropFirst(4)), uid < objs.count { return res(objs[uid]) }
        if let d = x as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in d where k != "$class" { out[k] = res(v) }
            return out
        }
        if let a = x as? [Any] { return a.map(res) }
        return x
    }
    struct Rule { let id: String; let path: String?; let denyMulticast: Bool }
    var found: [Rule] = []
    func walk(_ o: Any) {
        if let d = o as? [String: Any] {
            if let id = d["SigningIdentifier"] as? String, d["Path"] != nil {
                let path = d["Path"] as? String
                found.append(Rule(id: id, path: path == "$null" ? nil : path, denyMulticast: (d["DenyMulticast"] as? Bool) ?? false))
            }
            d.values.forEach(walk)
        } else if let a = o as? [Any] { a.forEach(walk) }
    }
    walk(res(top))
    let fm = FileManager.default
    print(String(format: "%-8@ %-10@ %@", "STATE", "KEY", "IDENTIFIER / PATH"))
    for r in found.sorted(by: { $0.id < $1.id }) {
        let state = r.denyMulticast ? "denied" : "allowed"
        if let path = r.path {
            let orphan = !fm.fileExists(atPath: path)
            print(String(format: "%-8@ %-10@ %@  %@%@", state, "path", r.id, path, orphan ? "  [orphan: path no longer exists]" : ""))
        } else {
            print(String(format: "%-8@ %-10@ %@", state, "bundle", r.id))
        }
    }
    let orphans = found.filter { $0.path.map { !fm.fileExists(atPath: $0) } ?? false }.count
    print("\n\(found.count) rules, \(orphans) orphaned. Rows in System Settings > Local Network map to these; duplicates are per-path rules.")
}

// MARK: - CLI

func usage() {
    print("""
    dontallow \(version) — auto-dismiss the macOS "find devices on local networks?" prompt

    usage: dontallow <command>

      install          install and start the background agent (launchd, survives reboots)
      uninstall        stop and remove the agent
      restart          restart the agent (after granting Accessibility)
      status           show agent state, pause state, allowlist, recent dismissals
      pause [1h]       leave prompts alone for a while (e.g. 30m, 2h, 1d, forever)
      resume           start dismissing again
      rules            show the system's Local Network rules, including orphaned entries
      run [--dry-run]  run in the foreground (what the agent runs)

    files: \(configDir.path)/{allowlist,paused-until,grace}   log: \(logFile.path)
    allowlist: one app name per line; prompts for those apps are never dismissed.
    grace:     seconds to wait before pressing, so you can still click Allow (default \(defaultGrace)).
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "run":
    dryRun = args.contains("--dry-run")
    runDaemon()
case "install":   install()
case "uninstall": uninstall()
case "restart":   restart()
case "status":    status()
case "pause":     pause(args.count > 1 ? args[1] : nil)
case "resume":    resume()
case "rules":     rules()
case "version", "--version": print(version)
default:          usage()
}
