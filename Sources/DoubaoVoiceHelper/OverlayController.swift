import AppKit

enum OverlayTone {
    case listening
    case cancelArmed
    case stopped
    case send
    case notice
}

@MainActor
final class StatusOverlayController {
    private let panel: NSPanel
    private let label: NSTextField
    private let backgroundView: NSView
    private var hideWork: DispatchWorkItem?

    init() {
        label = NSTextField(labelWithString: "")
        backgroundView = NSView(
            frame: NSRect(x: 0, y: 0, width: 280, height: 52)
        )
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.08,
            alpha: 0.9
        ).cgColor
        backgroundView.layer?.cornerRadius = 12
        backgroundView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: backgroundView.leadingAnchor,
                constant: 16
            ),
            label.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor,
                constant: -16
            ),
            label.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
        ])

        panel.contentView = backgroundView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
        ]
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
    }

    func show(_ message: String, tone: OverlayTone = .listening, autoHide: TimeInterval? = nil) {
        hideWork?.cancel()
        label.stringValue = message
        apply(tone)
        reposition()
        panel.orderFrontRegardless()
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in
                self?.hide()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel.orderOut(nil)
    }

    private func apply(_ tone: OverlayTone) {
        let background: NSColor
        let foreground: NSColor
        switch tone {
        case .listening, .notice:
            background = NSColor(calibratedWhite: 0.08, alpha: 0.92)
            foreground = .white
        case .cancelArmed:
            background = NSColor(calibratedRed: 0.45, green: 0.08, blue: 0.08, alpha: 0.94)
            foreground = NSColor(calibratedRed: 1, green: 0.82, blue: 0.82, alpha: 1)
        case .stopped:
            background = NSColor(calibratedWhite: 0.12, alpha: 0.92)
            foreground = NSColor(calibratedWhite: 0.82, alpha: 1)
        case .send:
            background = NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.18, alpha: 0.94)
            foreground = .white
        }
        backgroundView.layer?.backgroundColor = background.cgColor
        label.textColor = foreground
    }

    private func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouse, $0.frame, false)
        } ?? NSScreen.main
        guard let screen else { return }
        let frame = panel.frame
        let origin = NSPoint(
            x: screen.visibleFrame.midX - frame.width / 2,
            y: screen.visibleFrame.minY + 80
        )
        panel.setFrameOrigin(origin)
    }
}
