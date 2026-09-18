import SwiftUI

@main
struct TideLibraryApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryRootView()
                .preferredColorScheme(.dark)
        }
    }
}
