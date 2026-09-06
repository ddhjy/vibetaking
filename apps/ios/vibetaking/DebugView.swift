import SwiftUI

struct DebugView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: showFlexExplorer) {
                        Label("打开 FLEX", systemImage: "hammer")
                    }
                    .disabled(!InAppDebugger.canShowExplorer)
                } footer: {
                    Text(InAppDebugger.canShowExplorer
                         ? "打开 FLEX 悬浮工具条，查看界面层级、网络请求和运行时对象。"
                         : "FLEX 仅在 Debug 构建中可用。")
                }
            }
            .listStyle(.insetGrouped)
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

    private func showFlexExplorer() {
        InAppDebugger.showExplorer()
    }
}

#Preview {
    DebugView()
}
