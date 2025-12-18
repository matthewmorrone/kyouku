//
//  ParsedToken.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import Foundation

struct ParsedToken: Identifiable, Hashable {
    let id = UUID()
    var surface: String
    var reading: String
    var meaning: String?
    // UTF-16 range of this token within the current text context (if known)
    var range: NSRange? = nil
}
