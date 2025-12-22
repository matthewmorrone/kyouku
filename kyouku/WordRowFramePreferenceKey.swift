//
//  WordRowFramePreferenceKey.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/21/25.
//


import SwiftUI

struct WordRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
