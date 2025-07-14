import SwiftUI
import AVFoundation

struct CameraPreviewView: NSViewRepresentable {
    var cameraManager: CameraManager
    
    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        
        let layer = AVCaptureVideoPreviewLayer(session: cameraManager.captureSession)
        layer.videoGravity = .resizeAspectFill
        nsView.wantsLayer = true
        nsView.layer = layer
        
        cameraManager.startSession()
        return nsView
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        
    }
}
