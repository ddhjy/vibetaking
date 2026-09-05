import SwiftUI

struct AppTitleWordmark: View {
    let height: CGFloat

    // Pixel bounds of the approved artwork, including a 2 px safety margin.
    // Keep the source image intact and crop only its presentation.
    private static let sourceSize = CGSize(width: 1774, height: 887)
    private static let letteringBounds = CGRect(x: 253, y: 237, width: 1297, height: 387)

    var body: some View {
        let scale = height / Self.letteringBounds.height

        Color.primary
            .frame(width: Self.letteringBounds.width * scale, height: height)
            .mask(alignment: .topLeading) {
                Image(decorative: "AppTitleWordmark")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Self.sourceSize.width * scale, height: Self.sourceSize.height * scale)
                    // Convert the white-backed source into an ink mask so the
                    // same artwork follows the system's light and dark colors.
                    .contrast(1.2)
                    .colorInvert()
                    .luminanceToAlpha()
                    .offset(x: -Self.letteringBounds.minX * scale, y: -Self.letteringBounds.minY * scale)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("随心记")
            .accessibilityAddTraits(.isHeader)
    }
}
