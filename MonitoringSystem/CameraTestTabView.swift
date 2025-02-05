import SwiftUI

struct CameraTestTabView: View {
    // @Environment に変更
    @Environment(CameraManager.self) var cameraManager
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack {
            Text(cameraManager.faceDetected ? "顔を検出しました" : "顔が検出されていません")
                .foregroundColor(cameraManager.faceDetected ? .green : .red)
                .padding()
            
            // CameraManager を明示的に渡す
            CameraPreviewView(cameraManager: cameraManager)
                .frame(width: 400, height: 300)
            
            HStack {
                Button("セッション開始") {
                    cameraManager.startSession()
                }
                .padding()
                
                Button("セッション停止") {
                    cameraManager.stopSession()
                    presentationMode.wrappedValue.dismiss()
                }
                .padding()
            }
        }
        .onAppear {
            cameraManager.startSession()
        }
        .onDisappear {
            cameraManager.stopSession()
        }
    }
}

#if DEBUG
struct CameraTestTabView_Previews: PreviewProvider {
    static var previews: some View {
        CameraTestTabView()
            .environment(CameraManager())
            .frame(width: 500, height: 400)
    }
}
#endif

