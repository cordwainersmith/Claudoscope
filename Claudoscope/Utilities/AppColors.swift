import SwiftUI

extension Color {
    static let cardBackground = Color(
        light: Color(red: 240/255, green: 240/255, blue: 236/255),
        dark: Color(red: 40/255, green: 40/255, blue: 42/255)
    )
}

private extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
    }
}
