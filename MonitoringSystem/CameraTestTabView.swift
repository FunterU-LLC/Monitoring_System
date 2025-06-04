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
                .frame(width: 400, height: 400)
            
            HStack {
                Button("戻る") {
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
