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
            
            NotesView()
                .tabItem {
                    Label("Notes", systemImage: "note.text")
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

