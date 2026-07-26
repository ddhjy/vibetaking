import SwiftUI

enum AppToolbarIdentity {
    static let moreButton = "app-toolbar-more-button"
}

struct AppToolbarMoreLabel: View {
    var isLoading = false

    var body: some View {
        if isLoading {
            ProgressView()
                .scaleEffect(0.8)
        } else {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .regular))
        }
    }
}
