import SwiftUI

struct CameraTestTabView: View {
    @Environment(CameraManager.self) var cameraManager
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack {
            Text(cameraManager.faceDetected ? "顔を検出しました" : "顔が検出されていません")
                .foregroundColor(cameraManager.faceDetected ? .green : .red)
                .padding()
            
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
