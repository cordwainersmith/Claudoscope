import SwiftUI

func loadAppIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "logo-c-t", withExtension: "png"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = false
    return img
}
