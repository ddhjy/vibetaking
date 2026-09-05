import SwiftUI

enum AppToolbarIdentity {
    static let moreButton = "app-toolbar-more-button"
}

struct AppToolbarMoreLabel: View {
    var isLoading = false

    var body: some View {
        if isLoading {
            ProgressView()
                .accessibilityLabel("正在处理")
        } else {
            Image(systemName: "ellipsis")
                .font(.body)
        }
    }
}
