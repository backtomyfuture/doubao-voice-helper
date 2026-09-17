import AppKit
import CoreGraphics
import Foundation
import DoubaoVoiceHelperCore

enum MouseEventKind {
    case down
    case up
}

struct MouseButtonEvent {
    let button: Int64
    let kind: MouseEventKind
    let bundleIdentifier: String?
    let processIdentifier: pid_t
}

enum MouseEventMonitorError: Error {
    case alreadyStarted
    case eventTapCreationFailed
}

final class MouseEventMonitor {
    struct Configuration {
        var button: Int64
        var excludedBundleIDs: [String]
        var paused: Bool
        var capturing: Bool
    }

    private let callbackHandler: (MouseButtonEvent) -> Void
    private let lock = NSLock()
    private var configuration: Configuration
    private var eventTap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    init(
        configuration: Configuration,
        callbackHandler: @escaping (MouseButtonEvent) -> Void
    ) {
        self.configuration = configuration
        self.callbackHandler = callbackHandler
    }

    deinit {
        stop()
    }

    func update(configuration: Configuration) {
        lock.lock()
        self.configuration = configuration
        lock.unlock()
    }

    func start() throws {
        guard eventTap == nil else {
            throw MouseEventMonitorError.alreadyStarted
        }

        let mask =
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: UnsafeMutableRawPointer(
                Unmanaged.passUnretained(self).toOpaque()
            )
        ) else {
            throw MouseEventMonitorError.eventTapCreationFailed
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            tap,
            0
        )
        thread = Thread { [weak self] in
            guard let self else { return }
            let currentRunLoop = CFRunLoopGetCurrent()
            self.runLoop = currentRunLoop
            CFRunLoopAddSource(
                currentRunLoop,
                source,
                .commonModes
            )
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread?.name = "com.jarod.doubao-voice-helper.mouse-events"
        thread?.start()
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        eventTap = nil
        runLoop = nil
        thread = nil
    }

    private func currentConfiguration() -> Configuration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    private static let eventTapCallback: CGEventTapCallBack = {
        _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<MouseEventMonitor>
            .fromOpaque(refcon)
            .takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = monitor.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .otherMouseDown || type == .otherMouseUp else {
            return Unmanaged.passUnretained(event)
        }

        let configuration = monitor.currentConfiguration()
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let application = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = application?.bundleIdentifier
        let processIdentifier = application?.processIdentifier ?? 0

        if configuration.capturing {
            if type == .otherMouseDown {
                monitor.callbackHandler(
                    MouseButtonEvent(
                        button: button,
                        kind: .down,
                        bundleIdentifier: bundleIdentifier,
                        processIdentifier: processIdentifier
                    )
                )
            }
            return Unmanaged.passUnretained(event)
        }

        guard !configuration.paused, button == configuration.button else {
            return Unmanaged.passUnretained(event)
        }

        let excluded = configuration.excludedBundleIDs.contains {
            guard let bundleIdentifier else { return false }
            return bundleIdentifier == $0 ||
                bundleIdentifier.hasPrefix($0 + ".")
        }
        guard !excluded else {
            return Unmanaged.passUnretained(event)
        }

        monitor.callbackHandler(
            MouseButtonEvent(
                button: button,
                kind: type == .otherMouseDown ? .down : .up,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier
            )
        )
        return nil
    }
}
