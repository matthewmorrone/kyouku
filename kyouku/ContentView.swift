//
//  ContentView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

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
//
//// Temporary stub views so the app compiles.
//// We’ll replace these with real implementations step by step.
//
//struct PasteView: View {
//    var body: some View {
//        NavigationStack {
//            Text("Paste Japanese text here (coming soon)")
//                .padding()
//                .navigationTitle("Paste")
//        }
//    }
//}
//
//struct SavedWordsView: View {
//    var body: some View {
//        NavigationStack {
//            Text("Saved words will appear here")
//                .padding()
//                .navigationTitle("Words")
//        }
//    }
//}
//
//struct SettingsView: View {
//    var body: some View {
//        NavigationStack {
//            Text("Settings (MeCab + WotD later)")
//                .padding()
//                .navigationTitle("Settings")
//        }
//    }
//}
