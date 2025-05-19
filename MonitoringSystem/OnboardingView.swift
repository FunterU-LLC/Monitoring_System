import SwiftUI
#if os(macOS)
import AppKit
#endif

struct OnboardingView: View {
    @AppStorage("currentGroupID") private var currentGroupID = ""
    @State private var showSheet = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 24) {
                Text("MonitoringSystem")
                    .font(.largeTitle.bold())

                Text("グループを作成するか、オーナーから届いた招待URLを開いて既存グループに参加してください。")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button("グループを作成") {
                    showSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(minWidth: 480, minHeight: 320)
            .sheet(isPresented: $showSheet) {
                GroupCreationSheet()
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private func presentShareSheet(for url: URL) {
    #if os(macOS)
        guard let window = NSApp.keyWindow ?? NSApplication.shared.windows.first else {
            print("❗️ window not found"); return
        }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: .zero,
                    of: window.contentView!,
                    preferredEdge: .minY)
    #endif
    }
}
