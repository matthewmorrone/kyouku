//
//  WordStore.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import Foundation
import SwiftUI
import Combine

final class WordStore: ObservableObject {
    @Published private(set) var words: [Word] = []
    
    private let fileName = "words.json"
    
    init() {
        load()
    }
    
    func add(from token: ParsedToken) {
        if words.contains(where: { $0.surface == token.surface && $0.reading == token.reading }) {
            return
        }
        
        let word = Word(
            surface: token.surface,
            reading: token.reading,
            meaning: token.meaning ?? ""
        )
        words.append(word)
        save()
    }
    
    func delete(at offsets: IndexSet) {
        words.remove(atOffsets: offsets)
        save()
    }
    
    func delete(_ offsets: IndexSet) {
        delete(at: offsets)
    }
    
    func randomWord() -> Word? {
        words.randomElement()
    }
    
    // MARK: - File I/O
    
    private func documentsURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    
    private func fileURL() -> URL? {
        documentsURL()?.appendingPathComponent(fileName)
    }
    
    private func load() {
        guard let url = fileURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([Word].self, from: data)
            self.words = decoded
        } catch {
            print("Failed to load words: \(error)")
        }
    }
    
    private func save() {
        guard let url = fileURL() else {
            return
        }
        do {
            let data = try JSONEncoder().encode(words)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save words: \(error)")
        }
    }
}

