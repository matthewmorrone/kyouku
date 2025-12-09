import SwiftUI

@main
struct KyoukuApp: App {
    @StateObject private var store = WordStore()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
