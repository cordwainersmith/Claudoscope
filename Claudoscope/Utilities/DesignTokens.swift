import SwiftUI

enum Typography {
    static let displayLarge  = Font.system(size: 22, weight: .medium, design: .monospaced)
    static let displaySmall  = Font.system(size: 16, weight: .medium, design: .monospaced)
    static let panelTitle    = Font.system(size: 18, weight: .medium)
    static let sectionTitle  = Font.system(size: 14, weight: .semibold)
    static let detailTitle   = Font.system(size: 13, weight: .semibold)
    static let body          = Font.system(size: 13)
    static let bodyMedium    = Font.system(size: 13, weight: .medium)
    static let caption       = Font.system(size: 11, weight: .medium)
    static let micro         = Font.system(size: 10, weight: .medium)
    static let sectionLabel  = Font.system(size: 11, weight: .medium)
    static let code          = Font.system(size: 12, design: .monospaced)
    static let codeSmall     = Font.system(size: 11, design: .monospaced)
}

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum Radius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 6
    static let lg: CGFloat = 8
}

enum Motion {
    static let quick: Double = 0.15
    static let standard: Double = 0.25
}
