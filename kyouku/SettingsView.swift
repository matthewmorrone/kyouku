//
//  SettingsView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

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
