import SwiftUI
import AppKit

enum MainButtonFocus: Int, CaseIterable {
    case additionalReport
    case start
    case management
    case cameraTest
    
    func left() -> MainButtonFocus {
        let newIndex = max(0, rawValue - 1)
        return MainButtonFocus(rawValue: newIndex) ?? .additionalReport
    }
    
    func right() -> MainButtonFocus {
        let newIndex = min(MainButtonFocus.allCases.count - 1, rawValue + 1)
        return MainButtonFocus(rawValue: newIndex) ?? .cameraTest
    }
}

struct KeyboardMonitorView: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = KeyboardHandlingNSView()
        view.onKeyDown = onKeyDown
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        
    }
    
    class KeyboardHandlingNSView: NSView {
        var onKeyDown: ((NSEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            if let responder = window?.firstResponder, responder is NSTextView {
                super.keyDown(with: event)
            } else {
                onKeyDown?(event)
            }
        }
    }

}

struct WindowResizingHelper: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    
    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        
        DispatchQueue.main.async {
            if let window = nsView.window {
                let newSize = NSSize(width: width, height: height)
                window.setContentSize(newSize)
            }
        }
        
        return nsView
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        
    }
}

struct FocusableButtonStyle: ButtonStyle {
    let isFocused: Bool
    let isEnabled: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        let bgColor = !isEnabled
            ? Color.gray.opacity(0.3)
            : (isFocused ? Color.blue : Color.white)
        let fgColor = !isEnabled
            ? Color.gray
            : (isFocused ? Color.white : Color.black)
        
        return configuration.label
            .padding()
            .frame(minWidth: 140, minHeight: 50)
            .background(bgColor)
            .foregroundColor(fgColor)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .shadow(color: isFocused ? .black.opacity(0.4) : .clear,
                    radius: 4, x: 0, y: 2)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .onHover { inside in
                if inside && isEnabled {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

struct HoverPressButtonStyle: ButtonStyle {
    var overrideIsPressed: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect((configuration.isPressed || overrideIsPressed) ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.1),
                       value: (configuration.isPressed || overrideIsPressed))
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}





struct ContentView: View {
    
    @State private var focusedButton: MainButtonFocus = .start
    
    
    @Environment(PopupCoordinator.self) var popupCoordinator
    @Environment(RemindersManager.self) var remindersManager
    @Environment(AppUsageManager.self) var appUsageManager
    @Environment(FaceRecognitionManager.self) var faceRecognitionManager
    @Bindable var bindableCoordinator: PopupCoordinator
    @State private var showManagement = false
    @State private var showCameraTestTab = false
        
    // 初期化時にbindableCoordinatorを受け取る
    init(bindableCoordinator: PopupCoordinator) {
        self.bindableCoordinator = bindableCoordinator
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    AdDummyView(position: "Top")
                        .frame(height: 50)
                    
                    Spacer()
                    
                    AdDummyView(position: "Bottom")
                        .frame(height: 50)
                }
                
                HStack(spacing: 0) {
                    AdDummyView(position: "Left")
                        .frame(width: 50)
                    
                    Spacer()
                    
                    AdDummyView(position: "Right")
                        .frame(width: 50)
                }
                
                VStack {
                    Spacer()
                    Button("作業開始") {
                        popupCoordinator.showTaskStartPopup = true
                    }
                    .disabled(false)
                    .buttonStyle(FocusableButtonStyle(
                        isFocused: (focusedButton == .start),
                        isEnabled: true
                    ))
                    .onHover { inside in
                        if inside {
                            focusedButton = .start
                        }
                    }
                    .font(.title)
                    
                    Spacer()
                    
                    HStack {
                        Button("追加報告") {
                            print("追加報告ボタンをクリック")
                        }
                        .disabled(false)
                        .buttonStyle(FocusableButtonStyle(
                            isFocused: (focusedButton == .additionalReport),
                            isEnabled: true
                        ))
                        .onHover { inside in
                            if inside {
                                focusedButton = .additionalReport
                            }
                        }
                        
                        Spacer()
                        
                        Button("マネジメント") {
                            showManagement = true
                        }
                        .disabled(false)
                        .buttonStyle(FocusableButtonStyle(
                            isFocused: (focusedButton == .management),
                            isEnabled: true
                        ))
                        .onHover { inside in
                            if inside {
                                focusedButton = .management
                            }
                        }
                        
                        Button("カメラテスト") {
                            showCameraTestTab = true
                        }
                        .disabled(false)
                        .buttonStyle(FocusableButtonStyle(
                            isFocused: (focusedButton == .cameraTest),
                            isEnabled: true
                        ))
                        .onHover { inside in
                            if inside {
                                focusedButton = .cameraTest
                            }
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(
                KeyboardMonitorView { event in
                    handleKeyDown(event)
                }
                .allowsHitTesting(false)
            )
        }
        .sheet(isPresented: $bindableCoordinator.showTaskStartPopup) {
            TaskStartPopupView(
                remindersManager: _remindersManager,
                appUsageManager: _appUsageManager,
                popupCoordinator: _popupCoordinator,
                faceRecognitionManager: _faceRecognitionManager
            )
        }
        .sheet(isPresented: $showManagement) {
            ManagementView(appUsageManager: _appUsageManager)
        }
        .sheet(isPresented: $showCameraTestTab) {
            CameraTestTabView()
        }
    }
    
    private func handleKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 123:
            focusedButton = focusedButton.left()
        case 124:
            focusedButton = focusedButton.right()
        case 36, 76:
            triggerAction(for: focusedButton)
        default:
            break
        }
    }
    
    private func triggerAction(for focus: MainButtonFocus) {
        switch focus {
        case .additionalReport:
            print("追加報告ボタンを押下 (キーボード操作)")
        case .start:
            popupCoordinator.showTaskStartPopup = true
        case .management:
            showManagement = true
        case .cameraTest:
            showCameraTestTab = true
        }
    }
}

struct AdDummyView: View {
    let position: String
    var body: some View {
        Rectangle()
            .foregroundColor(.gray.opacity(0.2))
            .overlay(Text("Ad Area (\(position))").foregroundColor(.black))
    }
}

//#if DEBUG
//struct ContentView_Previews: PreviewProvider {
//    static var previews: some View {
//        ContentView()
//            .environment(PopupCoordinator())
//            .frame(width: 800, height: 600)
//    }
//}
//#endif
