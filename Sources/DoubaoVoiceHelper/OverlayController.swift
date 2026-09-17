import AppKit

@MainActor
final class StatusOverlayController {
    private let panel: NSPanel
    private let label: NSTextField

    init() {
        label = NSTextField(labelWithString: "")
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 52)
        )
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.08,
            alpha: 0.9
        ).cgColor
        contentView.layer?.cornerRadius = 12
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        panel.contentView = contentView
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

    func show(_ message: String) {
        label.stringValue = message
        guard let screen = NSScreen.main else {
            panel.orderFrontRegardless()
            return
        }
        let frame = panel.frame
        let origin = NSPoint(
            x: screen.visibleFrame.midX - frame.width / 2,
            y: screen.visibleFrame.minY + 80
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
