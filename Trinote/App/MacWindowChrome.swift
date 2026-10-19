import UIKit

/// Mac window title bar. With a macOS toolbar the tab bar moved into it and macOS placed it at the
/// trailing edge now and then. Without the toolbar and the title, the tab bar floats centered in
/// the window as on iPad.
@MainActor
enum MacWindowChrome {
    #if targetEnvironment(macCatalyst)
    private static var observer: NSObjectProtocol?
    #endif

    static func apply() {
        #if targetEnvironment(macCatalyst)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            style(scene)
        }
        // Windows opened later (File › New Window) get the same title bar.
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            guard let scene = note.object as? UIWindowScene else { return }
            MainActor.assumeIsolated { style(scene) }
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private static func style(_ scene: UIWindowScene) {
        scene.titlebar?.titleVisibility = .hidden
        scene.titlebar?.toolbar = nil
    }
    #endif
}
