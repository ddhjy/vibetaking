import Cocoa

enum StatusBarIcon {
    static func make() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "随心记")?
            .withSymbolConfiguration(config) else {
            return NSImage()
        }
        image.isTemplate = true
        return image
    }
}
