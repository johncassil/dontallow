// dontallow — auto-dismisses the macOS "Allow X to find devices on local networks?" prompt.
//
// Event-driven: sleeps until the system dialog host (UserNotificationCenter) creates a window,
// waits a short grace period, then presses "Don't Allow". Zero CPU while idle. No dependencies.
// Pure logic lives in Core.swift; this file is the Accessibility glue and the CLI.

import Foundation
import AppKit
import ApplicationServices

// MARK: - Constants and paths

let hostBundleID   = "com.apple.UserNotificationCenter"
let launchdLabel   = "com.pkgwarden.dontallow"
let denyTitle      = "don't allow"      // compared after norm()
let needle         = "local network"
let defaultGrace   = 0.25               // seconds before pressing; raise via ~/.config/dontallow/grace
let retryInterval  = 10.0               // seconds between Accessibility re-attach attempts
let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

let home       = FileManager.default.homeDirectoryForCurrentUser
let configDir  = home.appendingPathComponent(".config/dontallow")
let pauseFile  = configDir.appendingPathComponent("paused-until")
let allowFile  = configDir.appendingPathComponent("allowlist")
let graceFile  = configDir.appendingPathComponent("grace")
let logFile    = home.appendingPathComponent("Library/Logs/dontallow.log")
let plistFile  = home.appendingPathComponent("Library/LaunchAgents/\(launchdLabel).plist")

/// The path this binary was executed as. Keeps Homebrew's stable bin symlink rather than the versioned Cellar path.
let executablePath: String = {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size) + 1)
    _NSGetExecutablePath(&buf, &size)
    return String(cString: buf)
}()

// MARK: - Logging

// Line-buffer stdout so progress shows up promptly even when piped (e.g. inside an installer).
setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(s)")
    fflush(stdout)
}

func fail(_ s: String) -> Never {
    FileHandle.standardError.write("dontallow: \(s)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Config files

func isPaused() -> Bool {
    guard let s = try? String(contentsOf: pauseFile, encoding: .utf8), let until = pauseDeadline(from: s) else { return false }
    if until > Date() { return true }
    try? FileManager.default.removeItem(at: pauseFile)   // expired
    return false
}

func gracePeriod() -> TimeInterval {
    if let s = try? String(contentsOf: graceFile, encoding: .utf8),
       let g = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return max(0, g) }
    return defaultGrace
}

func allowlist() -> [String] {
    parseAllowlist((try? String(contentsOf: allowFile, encoding: .utf8)) ?? "")
}

// MARK: - Accessibility helpers

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func walk(_ el: AXUIElement, depth: Int = 0, texts: inout [String], buttons: inout [AXUIElement]) {
    guard depth < 8 else { return }
    if (attr(el, kAXRoleAttribute) as? String) == (kAXButtonRole as String) { buttons.append(el) }
    for key in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
        if let s = attr(el, key) as? String, !s.isEmpty { texts.append(s) }
    }
    for c in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        walk(c, depth: depth + 1, texts: &texts, buttons: &buttons)
    }
}

/// Fallback for hardened dialogs that refuse AXPress. Returns whether a click was actually posted.
func clickCenter(of el: AXUIElement) -> Bool {
    var posRef: CFTypeRef?, sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success else { return false }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(posRef as! AXValue, .cgPoint, &p), AXValueGetValue(sizeRef as! AXValue, .cgSize, &s) else { return false }
    let c = CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: c, mouseButton: .left) else { return false }
        e.post(tap: .cghidEventTap)
    }
    return true
}

/// Posts a user notification. The body is passed as an argv item, never interpolated into script source.
func notify(_ body: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"dontallow\"", "-e", "end run", body]
    try? p.run()
}

// MARK: - Core: evaluate one dialog window

var dryRun = false
let maxAttempts = 4

func evaluate(_ win: AXUIElement, attempt: Int = 0) {
    var texts: [String] = []
    var buttons: [AXUIElement] = []
    walk(win, texts: &texts, buttons: &buttons)
    let blob = texts.joined(separator: " | ")
    // Dialog may still be under construction right after the window-created event; look again briefly.
    if (texts.isEmpty || buttons.isEmpty) && attempt < maxAttempts {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { evaluate(win, attempt: attempt + 1) }
        return
    }
    guard !texts.isEmpty, blob.lowercased().contains(needle) else { return }
    let app = appName(in: blob) ?? "unknown app"

    if isPaused()                       { log("left prompt for \(app) alone (paused)"); return }
    if isAllowlisted(app, in: allowlist()) { log("left prompt for \(app) alone (allowlisted)"); return }
    guard let deny = buttons.first(where: { norm(attr($0, kAXTitleAttribute) as? String ?? "") == denyTitle }) else {
        log("prompt for \(app) matched but no Don't Allow button found"); return
    }
    if dryRun { log("DRY RUN: would dismiss prompt for \(app)"); return }

    var pressed = AXUIElementPerformAction(deny, kAXPressAction as CFString) == .success
    if !pressed {
        log("AXPress refused for \(app); trying a synthetic click")
        pressed = clickCenter(of: deny)
    }
    guard pressed else { log("could not press Don't Allow for \(app)"); return }
    log("dismissed Local Network prompt for \(app)")
    notify("Dismissed Local Network prompt for \(app). To let apps ask, run: dontallow pause 10m")
}

func scheduleEvaluate(_ win: AXUIElement) {
    DispatchQueue.main.asyncAfter(deadline: .now() + gracePeriod()) { evaluate(win) }
}

// MARK: - Observer lifecycle

var observer: AXObserver?
var observedPID: pid_t = 0
var promptedForAccessibility = false

let axCallback: AXObserverCallback = { _, element, _, _ in scheduleEvaluate(element) }

func requestAccessibility() {
    guard !promptedForAccessibility else { return }
    promptedForAccessibility = true
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
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
            log("Accessibility not granted to \(executablePath); retrying every \(Int(retryInterval))s")
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
    for w in (attr(appEl, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { scheduleEvaluate(w) }
}

func detach() {
    if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(o), .defaultMode) }
    observer = nil; observedPID = 0
}

func runDaemon() {
    log("dontallow \(version) started (dryRun=\(dryRun), grace=\(gracePeriod())s, exe=\(executablePath))")
    if !AXIsProcessTrusted() {
        log("Accessibility not granted to \(executablePath)")
        requestAccessibility()
    }
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

// MARK: - launchd

func launchctl(_ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}

func domain() -> String { "gui/\(getuid())" }
func agentRunning() -> Bool { launchctl(["print", "\(domain())/\(launchdLabel)"]).1.contains("pid = ") }

/// Reads the agent log and reports whether the running agent has Accessibility, based on its last status line.
enum AgentHealth { case watching, needsAccessibility, unknown }
func agentHealth() -> AgentHealth {
    guard let s = try? String(contentsOf: logFile, encoding: .utf8) else { return .unknown }
    for line in s.split(separator: "\n").reversed() {
        if line.contains("watching dialog host") { return .watching }
        if line.contains("Accessibility not granted") { return .needsAccessibility }
    }
    return .unknown
}

func printGrantInstructions() {
    print("""

      dontallow needs Accessibility access to press the button for you.
      System Settings > Privacy & Security > Accessibility is opening now.
      If dontallow is not listed, click +, press Cmd+Shift+G, paste this path, click Open:

          \(executablePath)

      then make sure its toggle is on. The agent picks it up automatically within 10 seconds.

      If dontallow IS listed and already on, the row is stale (this happens after every rebuild or
      upgrade): select it, click −, then add it again with + as above.
    """)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [accessibilityPane]
    try? p.run()
}

func install() {
    try? FileManager.default.createDirectory(at: plistFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let dict = launchdPlist(label: launchdLabel, executable: executablePath, logPath: logFile.path)
    do {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plistFile)
    } catch { fail("could not write \(plistFile.path): \(error)") }
    _ = launchctl(["bootout", "\(domain())/\(launchdLabel)"])
    let (code, out) = launchctl(["bootstrap", domain(), plistFile.path])
    guard code == 0 else { fail("launchctl bootstrap failed: \(out)") }
    print("installed launch agent \(launchdLabel) → \(executablePath)")

    // Give the agent a moment to start and report, then walk the user through the grant if needed.
    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.25)
        if agentHealth() != .unknown { break }
    }
    switch agentHealth() {
    case .watching:
        print("Accessibility is granted. dontallow is active.")
    case .needsAccessibility:
        printGrantInstructions()
        print("  Waiting for the grant (Ctrl-C to stop waiting; the agent keeps retrying on its own)...")
        for _ in 0..<240 {                      // up to 60 s
            Thread.sleep(forTimeInterval: 0.25)
            if agentHealth() == .watching { print("  Granted. dontallow is active."); return }
        }
        print("  Still waiting. Run `dontallow status` later to check.")
    case .unknown:
        print(agentRunning() ? "Agent started; run `dontallow status` to check it." : "Agent did not start; see \(logFile.path)")
    }
}

func uninstall() {
    _ = launchctl(["bootout", "\(domain())/\(launchdLabel)"])
    try? FileManager.default.removeItem(at: plistFile)
    print("removed launch agent. You can also remove dontallow from Privacy & Security > Accessibility.")
}

func restart() {
    let (code, out) = launchctl(["kickstart", "-k", "\(domain())/\(launchdLabel)"])
    print(code == 0 ? "restarted" : "restart failed: \(out)")
}

// MARK: - pause / resume / status / rules

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
    _ = launchctl(["kickstart", "-k", "\(domain())/\(launchdLabel)"])   // re-scan any prompt left open while paused
    print("resumed")
}

func status() {
    if agentRunning() {
        switch agentHealth() {
        case .watching:           print("agent:     running, Accessibility granted")
        case .needsAccessibility: print("agent:     running but Accessibility NOT granted → see below"); printGrantInstructions()
        case .unknown:            print("agent:     running")
        }
    } else {
        print("agent:     not installed or not running  (run: dontallow install)")
    }
    if let s = try? String(contentsOf: pauseFile, encoding: .utf8), let until = pauseDeadline(from: s), until > Date() {
        print("paused:    yes, until \(until == .distantFuture ? "you run dontallow resume" : until.formatted())")
    } else {
        print("paused:    no")
    }
    let al = allowlist()
    print("allowlist: \(al.isEmpty ? "(empty)  \(allowFile.path)" : al.joined(separator: ", "))")
    print("grace:     \(gracePeriod())s")
    if let s = try? String(contentsOf: logFile, encoding: .utf8) {
        let lines = s.split(separator: "\n").filter { $0.contains("dismissed") || $0.contains("left prompt") }.suffix(5)
        if !lines.isEmpty { print("recent:"); lines.forEach { print("  \($0)") } }
    }
}

func rules() {
    let store = "/Library/Preferences/com.apple.networkextension.plist"
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
    p.arguments = ["-convert", "xml1", "-o", "-", store]
    let pipe = Pipe(); p.standardOutput = pipe
    do { try p.run() } catch { fail("cannot run plutil: \(error)") }
    let xml = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; p.waitUntilExit()
    guard let found = decodeLocalNetworkRules(xml: xml) else { fail("cannot parse \(store)") }
    let fm = FileManager.default
    print(String(format: "%-8@ %-7@ %@", "STATE", "KEY", "IDENTIFIER / PATH"))
    var orphans = 0
    for r in found.sorted(by: { $0.identifier < $1.identifier }) {
        let state = r.denyMulticast ? "denied" : "allowed"
        if let path = r.path {
            let orphan = !fm.fileExists(atPath: path); if orphan { orphans += 1 }
            print(String(format: "%-8@ %-7@ %@  %@%@", state, "path", r.identifier, path, orphan ? "  [orphan: path no longer exists]" : ""))
        } else {
            print(String(format: "%-8@ %-7@ %@", state, "bundle", r.identifier))
        }
    }
    print("\n\(found.count) rules, \(orphans) orphaned. Rows in System Settings > Local Network map to these; duplicates are per-path rules.")
}

// MARK: - CLI

func usage() {
    print("""
    dontallow \(version) — auto-dismiss the macOS "find devices on local networks?" prompt

    usage: dontallow <command>

      install          install and start the background agent (launchd, survives reboots)
      uninstall        stop and remove the agent
      restart          restart the agent
      status           agent state, Accessibility state, pause state, allowlist, recent dismissals
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
case "run":       dryRun = args.contains("--dry-run"); runDaemon()
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
