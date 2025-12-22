//
//  DictionaryLookupView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/21/25.
//


import SwiftUI
import Combine

struct DictionaryLookupView: View {
    let term: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = DictionaryLookupViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Dictionary")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                }
        }
        .task(id: term) {
            await vm.load(term: term)
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking up \(vm.query)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else if let msg = vm.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                Text("Lookup failed")
                    .font(.headline)
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
        } else if vm.results.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                Text("No matches")
                    .font(.headline)
                Text("No entries for: \(vm.query)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else {
            List(vm.results) { e in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(e.kanji.isEmpty ? e.reading : e.kanji)
                            .font(.headline)

                        if !e.reading.isEmpty && e.reading != e.kanji {
                            Text(e.reading)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !e.gloss.isEmpty {
                        Text(e.gloss)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}