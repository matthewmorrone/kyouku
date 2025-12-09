import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Word-of-the-Day notifications coming next.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
