import SwiftUI
#if os(macOS)
import AppKit
#endif

struct OnboardingView: View {
    @State private var showSheet = false
    @State private var animateGradient = false
    @State private var showContent = false
    @State private var floatingAnimation = false
    @State private var buttonHovering = false
    @State private var floatingCircles: [FloatingCircle] = [
        FloatingCircle(relativeX: 0.1, relativeY: 0.2, size: 80, animationDuration: 4.0, animationDelay: 0.0),
        FloatingCircle(relativeX: 0.8, relativeY: 0.3, size: 100, animationDuration: 5.0, animationDelay: 0.5),
        FloatingCircle(relativeX: 0.3, relativeY: 0.7, size: 60, animationDuration: 3.5, animationDelay: 1.0),
        FloatingCircle(relativeX: 0.9, relativeY: 0.8, size: 90, animationDuration: 4.5, animationDelay: 1.5),
        FloatingCircle(relativeX: 0.5, relativeY: 0.5, size: 70, animationDuration: 6.0, animationDelay: 2.0)
    ]
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 255/255, green: 224/255, blue: 153/255).opacity(0.15),
                    Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.1),
                    Color(red: 255/255, green: 184/255, blue: 77/255).opacity(0.05)
                ],
                startPoint: animateGradient ? .topLeading : .bottomTrailing,
                endPoint: animateGradient ? .bottomTrailing : .topLeading
            )
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                    animateGradient.toggle()
                }
            }
            
            GeometryReader { geometry in
                ForEach(floatingCircles.indices, id: \.self) { index in
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.3),
                                    Color(red: 255/255, green: 224/255, blue: 153/255).opacity(0.2)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: floatingCircles[index].size, height: floatingCircles[index].size)
                        .blur(radius: 10)
                        .position(
                            x: floatingCircles[index].relativeX * geometry.size.width,
                            y: floatingCircles[index].relativeY * geometry.size.height + floatingCircles[index].offsetY
                        )
                        .onAppear {
                            withAnimation(
                                .easeInOut(duration: floatingCircles[index].animationDuration)
                                .repeatForever(autoreverses: true)
                                .delay(floatingCircles[index].animationDelay)
                            ) {
                                floatingCircles[index].offsetY = floatingAnimation ? -20 : 20
                            }
                        }
                }
            }
            .drawingGroup()
            
            VStack(spacing: 30) {
                VStack(spacing: 20) {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .shadow(color: Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.5), radius: 20, x: 0, y: 10)
                    } else {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 255/255, green: 204/255, blue: 102/255),
                                            Color(red: 255/255, green: 184/255, blue: 77/255)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 100, height: 100)
                                .shadow(color: Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.5), radius: 20, x: 0, y: 10)
                            
                            Image(systemName: "eye.fill")
                                .font(.system(size: 50))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.white, .white.opacity(0.9)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                    }
                    
                    VStack(spacing: 6) {
                        Text("RemoVision")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: colorScheme == .dark ? [
                                        Color(red: 255/255, green: 224/255, blue: 153/255),
                                        Color(red: 255/255, green: 214/255, blue: 143/255)
                                    ] : [
                                        Color(red: 92/255, green: 64/255, blue: 51/255),
                                        Color(red: 92/255, green: 64/255, blue: 51/255).opacity(0.8)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )

                        Text("チームの生産性を可視化")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(colorScheme == .dark ? .white.opacity(0.9) : .secondary)
                    }
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)
                }
                
                HStack(spacing: 15) {
                    FeatureCard(
                        icon: "person.3.fill",
                        title: "チーム管理",
                        description: "メンバーの作業状況をリアルタイムで共有",
                        color: Color(red: 255/255, green: 204/255, blue: 102/255)
                    )
                    
                    FeatureCard(
                        icon: "chart.bar.fill",
                        title: "分析機能",
                        description: "タスクごとの時間配分を詳細に分析",
                        color: Color(red: 255/255, green: 184/255, blue: 77/255)
                    )
                    
                    FeatureCard(
                        icon: "camera.fill",
                        title: "自動検知",
                        description: "顔認識による在席状況の自動記録",
                        color: Color(red: 255/255, green: 164/255, blue: 51/255)
                    )
                }
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 40)
                
                VStack(spacing: 14) {
                    Text("始めましょう")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(colorScheme == .dark ?
                            Color(red: 255/255, green: 224/255, blue: 153/255) :
                            Color(red: 92/255, green: 64/255, blue: 51/255))

                    Text("グループを作成するか、招待URLから参加してください")
                        .font(.system(size: 15))
                        .foregroundColor(colorScheme == .dark ? .white.opacity(0.8) : .secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 350)
                    
                    Button {
                        showSheet = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18))
                            Text("グループを作成")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(Color(red: 92/255, green: 64/255, blue: 51/255))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 255/255, green: 204/255, blue: 102/255),
                                    Color(red: 255/255, green: 184/255, blue: 77/255)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(12)
                        .shadow(color: buttonHovering ? Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.5) : Color(red: 255/255, green: 204/255, blue: 102/255).opacity(0.4), radius: buttonHovering ? 15 : 10, x: 0, y: buttonHovering ? 8 : 5)
                        .scaleEffect(buttonHovering ? 1.05 : 1)
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(showContent ? 1 : 0.9)
                    .opacity(showContent ? 1 : 0)
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            buttonHovering = hovering
                        }
                    }
                }
            }
            .frame(minWidth: 650, minHeight: 600)
            .sheet(isPresented: $showSheet) {
                GroupCreationSheet()
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                showContent = true
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .sheet(isPresented: $showSheet) {
            GroupCreationSheet()
        }
    }
}

struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(0.2),
                                color.opacity(0.1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color, color.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(colorScheme == .dark ?
                        Color(red: 255/255, green: 224/255, blue: 153/255) :
                        Color(red: 92/255, green: 64/255, blue: 51/255))
                            
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(colorScheme == .dark ? .white.opacity(0.8) : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 180, height: 145)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    color.opacity(0.2),
                                    color.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(
                    color: color.opacity(0.1),
                    radius: 10,
                    x: 0,
                    y: 5
                )
        )
    }
}

struct FloatingCircle: Identifiable {
    let id = UUID()
    var relativeX: CGFloat
    var relativeY: CGFloat
    var size: CGFloat
    var animationDuration: Double
    var animationDelay: Double
    var offsetY: CGFloat = 0
}
