import AppKit
import SwiftUI

struct MenuBarIcon: View {
    let imageName: String
    let fallbackSystemName: String

    var body: some View {
        Group {
            if let image = Self.image(named: imageName) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: fallbackSystemName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            }
        }
        .accessibilityLabel("豆包语音助手")
    }

    private static func image(named name: String) -> NSImage? {
        guard let image = NSImage(named: name) else {
            return nil
        }

        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}
