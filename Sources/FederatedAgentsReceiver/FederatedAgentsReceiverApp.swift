import SwiftUI

@main
struct FederatedAgentsReceiverApp: App {
    @StateObject private var model = ReceiverAppModel()

    var body: some Scene {
        WindowGroup {
            ReceiverRootView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowResizability(.contentMinSize)
    }
}
