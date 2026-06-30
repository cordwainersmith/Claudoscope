import SwiftUI

extension Color {
    static let cardBackground = Color(
        light: Color(red: 240/255, green: 240/255, blue: 236/255),
        dark: Color(red: 40/255, green: 40/255, blue: 42/255)
    )

    // MARK: - Colorblind-safe chart palette
    //
    // Categorical series use the Okabe-Ito qualitative palette, designed to stay
    // distinguishable under protanopia, deuteranopia, and tritanopia. Raw system
    // colors (.green/.red/.orange together) collapse for ~8% of men, so charts
    // pull from here instead. Reference: Okabe & Ito, "Color Universal Design".

    static let okabeBlue        = Color(hex: 0x0072B2)
    static let okabeOrange      = Color(hex: 0xE69F00)
    static let okabeBluishGreen = Color(hex: 0x009E73)
    static let okabeVermillion  = Color(hex: 0xD55E00)
    static let okabeSkyBlue     = Color(hex: 0x56B4E9)
    static let okabePurple      = Color(hex: 0xCC79A7)
    static let okabeYellow      = Color(hex: 0xF0E442)
    static let okabeGray        = Color(light: Color(hex: 0x6E6E6E), dark: Color(hex: 0x9A9A9A))

    /// Categorical palette ordered most-distinct-first, so small-N charts get the
    /// strongest separations (blue + orange reads cleanly for every kind of color
    /// vision). Index past the end wraps.
    static let chartCategorical: [Color] = [
        .okabeBlue, .okabeOrange, .okabeBluishGreen, .okabeVermillion,
        .okabeSkyBlue, .okabePurple, .okabeYellow, .okabeGray,
    ]

    /// Ordered, colorblind-safe scale for ranked categories (e.g. effort level,
    /// low->high). A cool-to-warm Okabe-Ito sequence whose four steps differ in
    /// BOTH hue and lightness, so adjacent steps stay distinguishable and keep
    /// contrast on light and dark themes. A single-hue luminance ramp was tried
    /// first but its middle steps were too close to tell apart and its dark end
    /// vanished against the dark theme. Safe under protan/deuteran/tritanopia.
    static let scaleLow    = Color.okabeSkyBlue    // light cool
    static let scaleMedium = Color.okabeBlue       // dark cool
    static let scaleHigh   = Color.okabeOrange      // light warm
    static let scaleMax    = Color.okabeVermillion // dark warm

    /// Stable, colorblind-safe color per model family. Replaces the duplicated
    /// maps that used pink/purple/gray, which collide under protanopia.
    static func forModel(_ model: String) -> Color {
        let m = model.lowercased()
        if m.contains("opus")   { return .okabeBlue }
        if m.contains("sonnet") { return .okabeOrange }
        if m.contains("haiku")  { return .okabeBluishGreen }
        if m.contains("fable")  { return .okabePurple }
        return .okabeGray
    }
}

private extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
    }

    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
