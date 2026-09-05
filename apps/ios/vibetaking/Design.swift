import SwiftUI

enum Design {
    static let primaryColor = Color(.systemIndigo)
    static let negativeColor = Color(.systemRed)
    // System toolbars keep symbol glyphs compact while content text follows Dynamic Type.
    static let controlFont = Font.system(size: 20, weight: .regular)
    static let minimumTarget: CGFloat = 44
    static let readingWidth: CGFloat = 720
}

struct AppAppearance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor
    static func configureNavigationButtons() {
        // iOS 26 doesn't inherit SwiftUI tint for its back chevron. Color the
        // system indicator itself while preserving the native button and mask.
        let defaults = UINavigationBarAppearance()
        let color = UIColor(Design.primaryColor)
        let palette = UIImage.SymbolConfiguration(paletteColors: [color])
        let indicator = defaults.backIndicatorImage.applyingSymbolConfiguration(palette)?
            .withRenderingMode(.alwaysOriginal)
            ?? defaults.backIndicatorImage.withTintColor(color, renderingMode: .alwaysOriginal)
        let navigationBar = UINavigationBar.appearance()
        navigationBar.backIndicatorImage = indicator
        navigationBar.backIndicatorTransitionMaskImage = defaults.backIndicatorTransitionMaskImage
    }

    func body(content: Content) -> some View {
        content
            .tint(Design.primaryColor)
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

/// Glass belongs to the control layer. Keep custom controls opaque when requested.
struct ControlSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var emphasized = false

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                emphasized ? Design.primaryColor : Color(.secondarySystemBackground),
                in: Capsule()
            )
        } else {
            content.glassEffect(
                emphasized ? .regular.tint(Design.primaryColor).interactive() : .regular.interactive(),
                in: Capsule()
            )
        }
    }
}

extension View {
    func controlSurface(emphasized: Bool = false) -> some View {
        modifier(ControlSurface(emphasized: emphasized))
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
