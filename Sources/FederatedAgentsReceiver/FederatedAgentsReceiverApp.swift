import AppKit
import SwiftUI

@main
struct FederatedAgentsReceiverApp: App {
    @StateObject private var model = ReceiverAppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ReceiverRootView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
