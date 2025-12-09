import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            PasteView()
                .tabItem {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
            
            SavedWordsView()
                .tabItem {
                    Label("Words", systemImage: "book")
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}
