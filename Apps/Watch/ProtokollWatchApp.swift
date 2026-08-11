import SwiftUI

/// watchOS app entry (M6 foundation). A lean recorder that sends the finished
/// audio to the paired iPhone via WatchConnectivity (ADR-6); the iPhone writes
/// it into the container. Reuses SharedKit's models unchanged.
@main
struct ProtokollWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRecordView()
        }
    }
}
