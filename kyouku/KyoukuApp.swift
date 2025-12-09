//
//  KyoukuApp.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25
//

import SwiftUI

@main
struct KyoukuApp: App {
    @StateObject var notes = NotesStore()
    @StateObject var store = WordStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(notes)
                .environmentObject(store)
        }
    }
}
