import SwiftUI

@main
struct Clipboard2iOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.resignedActive()
            default: break
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showSignIn = false

    var body: some View {
        TabView {
            CopiesView(showSignIn: $showSignIn)
                .tabItem { Label("Copies", systemImage: "doc.on.clipboard") }
            SavedView()
                .tabItem { Label("Saved", systemImage: "bookmark") }
            AuthView()
                .tabItem { Label("Auth", systemImage: "key") }
            SettingsView(showSignIn: $showSignIn)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.notice)
        .sheet(isPresented: $showSignIn) {
            SignInView()
        }
        .onAppear {
            if !model.isSignedIn || model.needsPassword { showSignIn = true }
        }
    }
}
