import SwiftUI
import SharedKit

/// iOS app entry (F11/F12): a Record tab and a Library tab. Reuses SharedKit and
/// the shared String Catalog unchanged.
@main
struct ProtokolliOSApp: App {
    @State private var model = IOSAppModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                RecordView().tabItem { Label("ios.tab.record", systemImage: "mic.circle") }
                LibraryListView().tabItem { Label("ios.tab.library", systemImage: "books.vertical") }
            }
            .environment(model)
            .task { await model.bootstrap() }
        }
    }
}
