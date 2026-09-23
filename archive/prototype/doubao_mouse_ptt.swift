import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

/// MX Master 3S 拇指手势键 → 豆包语音（点一下开始 / 再点一下结束）
/// 按住超过 hold_ms：按下发一次左 Ctrl，松开再发一次。短按忽略，减少误触。

struct Config: Codable {
    var mouseButton: Int64
    var keyCode: UInt16
    var holdMs: Int
    var tapMs: Int
    var stopDelayMs: Int
    var cooldownMs: Int
    var debug: Bool
    var skipBundleIds: [String]

    enum CodingKeys: String, CodingKey {
        case mouseButton = "mouse_button"
        case keyCode = "key_code"
        case holdMs = "hold_ms"
        case tapMs = "tap_ms"
        case stopDelayMs = "stop_delay_ms"
        case cooldownMs = "cooldown_ms"
        case debug
        case skipBundleIds = "skip_bundle_ids"
    }

    static let defaultSkip = [
        "com.apple.finder",
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.bot.pc.doubao",
        "com.work.pc.doubao",
    ]

    static let `default` = Config(
        mouseButton: 4,
        keyCode: 59,
        holdMs: 0,
        tapMs: 50,
        stopDelayMs: 80,
        cooldownMs: 500,
        debug: false,
        skipBundleIds: defaultSkip
    )
}

func loadConfig(path: String) -> Config {
    guard let data = FileManager.default.contents(atPath: path) else { return .default }
    do {
        var c = try JSONDecoder().decode(Config.self, from: data)
        if c.skipBundleIds.isEmpty { c.skipBundleIds = Config.defaultSkip }
        if ProcessInfo.processInfo.arguments.contains("--debug") { c.debug = true }
        return c
    } catch {
        fputs("config parse failed, using defaults: \(error)\n", stderr)
        return .default
    }
}

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    fputs(line, stderr)
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".hermes/logs/doubao-mouse-ptt.err.log").path
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let h = FileHandle(forWritingAtPath: path) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        h.write(Data(line.utf8))
    }
}

func tapKey(_ keyCode: UInt16, tapMs: Int) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
    down?.flags = .maskControl
    up?.flags = []
    down?.post(tap: .cghidEventTap)
    usleep(UInt32(max(tapMs, 10) * 1000))
    up?.post(tap: .cghidEventTap)
}

final class PTT {
    let cfg: Config
    private let queue = DispatchQueue(label: "ai.hermes.doubao-mouse-ptt")
    private var talking = false
    private var work: DispatchWorkItem?
    private var cooldownUntil = Date.distantPast

    init(cfg: Config) { self.cfg = cfg }

    func owns(_ button: Int64) -> Bool { button == cfg.mouseButton }

    func peekTalking() -> Bool {
        queue.sync { talking }
    }

    func shouldSkipFrontmost() -> Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return cfg.skipBundleIds.contains { bid == $0 || bid.hasPrefix($0 + ".") }
    }

    func down(button: Int64) {
        guard owns(button) else { return }
        queue.async {
            if Date() < self.cooldownUntil {
                if self.cfg.debug { log("cooldown, ignore down") }
                return
            }
            self.work?.cancel()
            let start = { [weak self] in
                guard let self, !self.talking else { return }
                self.talking = true
                log("press → Ctrl tap (start)")
                tapKey(self.cfg.keyCode, tapMs: self.cfg.tapMs)
            }
            if self.cfg.holdMs <= 0 {
                start()
                return
            }
            let item = DispatchWorkItem { [weak self] in
                self?.queue.async { start() }
            }
            self.work = item
            self.queue.asyncAfter(
                deadline: .now() + .milliseconds(self.cfg.holdMs),
                execute: item
            )
        }
    }

    func up(button: Int64) {
        guard owns(button) else { return }
        queue.async {
            self.work?.cancel()
            self.work = nil
            guard self.talking else { return }
            self.talking = false
            let stop = { [weak self] in
                guard let self else { return }
                log("release → Ctrl tap (stop)")
                tapKey(self.cfg.keyCode, tapMs: self.cfg.tapMs)
                self.cooldownUntil = Date().addingTimeInterval(Double(self.cfg.cooldownMs) / 1000)
            }
            if self.cfg.stopDelayMs <= 0 {
                stop()
            } else {
                self.queue.asyncAfter(
                    deadline: .now() + .milliseconds(self.cfg.stopDelayMs),
                    execute: DispatchWorkItem(block: stop)
                )
            }
        }
    }
}

func waitTrusted() {
    if AXIsProcessTrusted() { return }
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    log("waiting for Accessibility permission (prompt once, will not re-popup)…")
    while !AXIsProcessTrusted() {
        sleep(5)
    }
    log("Accessibility granted")
}

func runTap(cfg: Config) {
    waitTrusted()
    let ptt = PTT(cfg: cfg)
    let mask: CGEventMask =
        (1 << CGEventType.otherMouseDown.rawValue) |
        (1 << CGEventType.otherMouseUp.rawValue) |
        (1 << CGEventType.otherMouseDragged.rawValue)

    let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let ptt = Unmanaged<PTT>.fromOpaque(refcon).takeUnretainedValue()
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if ptt.cfg.debug {
            log("mouse \(type.rawValue) button=\(button)")
        }
        guard ptt.owns(button) else {
            return Unmanaged.passUnretained(event)
        }
        let skip = ptt.shouldSkipFrontmost() && !ptt.peekTalking()
        if skip {
            if ptt.cfg.debug {
                let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                log("skip \(bid)")
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .otherMouseDown {
            ptt.down(button: button)
        } else if type == .otherMouseUp {
            ptt.up(button: button)
        }
        return nil
    }

    guard let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(ptt).toOpaque())
    ) else {
        log("CGEvent tapCreate failed (Accessibility / Input Monitoring?)")
        exit(1)
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("listening mouse_button=\(cfg.mouseButton) key_code=\(cfg.keyCode) hold_ms=\(cfg.holdMs)")
    withExtendedLifetime(ptt) {
        CFRunLoopRun()
    }
}

let args = ProcessInfo.processInfo.arguments
let cfgPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".hermes/config/doubao-mouse-ptt.json").path
var cfg = loadConfig(path: cfgPath)

if args.contains("--help") {
    fputs("""
    doubao-mouse-ptt — 拇指键长按 = 豆包语音开始，松开 = 结束
      --debug     打印所有 extra mouse button 事件（用来确认 button 号）
      --tap       立刻点一次左 Ctrl，用来验证豆包能否收到模拟按键
      --help

    配置: ~/.hermes/config/doubao-mouse-ptt.json
    """, stderr)
    exit(0)
}

if args.contains("--tap") {
    waitTrusted()
    log("test tap left Ctrl")
    tapKey(cfg.keyCode, tapMs: cfg.tapMs)
    usleep(100_000)
    exit(0)
}

if args.contains("--debug") { cfg.debug = true }
runTap(cfg: cfg)
