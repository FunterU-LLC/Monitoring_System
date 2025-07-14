import SwiftUI

struct GroupCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ownerName  = ""
    @State private var groupName  = ""
    @State private var isCreating = false
    @State private var errorMsg:  String?
    
    @AppStorage("currentGroupID") private var currentGroupID = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("グループを作成")
                .font(.title2.bold())

            TextField("オーナー名", text: $ownerName)
            TextField("グループ名", text: $groupName)

            if let err = errorMsg {
                Text(err)
                    .foregroundColor(.red)
            }

            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("作成") {
                    Task { await createGroup() }
                }
                .disabled(!isFormValid)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 400)
    }
    
    private var isFormValid: Bool {
        !ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isCreating
    }

    private func createGroup() async {
        isCreating = true
        defer { isCreating = false }

        do {
            let result = try await CloudKitService.shared
                .createGroup(ownerName: ownerName,
                             groupName: groupName)

            presentShareSheet(url: result.url)

            DispatchQueue.main.async {
                GroupInfoStore.shared.groupInfo = GroupInfo(
                    groupName: groupName,
                    ownerName: ownerName,
                    recordID: result.groupID
                )
                currentGroupID = result.groupID
                dismiss()
            }
        } catch {
            errorMsg = error.localizedDescription
        }
    }
    
    private func presentShareSheet(url: URL) {
        #if os(macOS)
        guard let sheetWindow = NSApp.keyWindow else { return }
        let anchorWindow = sheetWindow.sheetParent ?? sheetWindow

        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: .zero,
                    of: anchorWindow.contentView!,
                    preferredEdge: .minY)
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
    }
}
