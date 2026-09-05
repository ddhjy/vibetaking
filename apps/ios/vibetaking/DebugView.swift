import SwiftUI

struct DebugView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ContentUnavailableView("暂无调试选项", systemImage: "wrench.and.screwdriver", description: Text("当前版本没有可调整的调试选项。"))
            .navigationTitle("调试模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview {
    DebugView()
}
