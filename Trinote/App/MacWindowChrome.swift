import UIKit

/// Mac window title bar. With a macOS toolbar the tab bar moved into it and macOS placed it at the
/// trailing edge now and then. Without the toolbar and the title, the tab bar floats centered in
/// the window as on iPad.
@MainActor
enum MacWindowChrome {
    static func apply() {
        #if targetEnvironment(macCatalyst)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbar = nil
        }
        #endif
    }
}
