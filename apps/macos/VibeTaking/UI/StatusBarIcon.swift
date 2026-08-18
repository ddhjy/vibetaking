import Cocoa

enum StatusBarIcon {
    static func make(autoSend: Bool) -> NSImage {
        let symbolName: String
        if autoSend {
            symbolName = "doc.on.clipboard.fill"
        } else {
            symbolName = "doc.on.clipboard"
        }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "随心记")?
            .withSymbolConfiguration(config) else {
            return NSImage()
        }
        image.isTemplate = true
        return image
    }
}
