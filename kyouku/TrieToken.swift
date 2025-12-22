import Foundation

public struct TrieToken: Hashable {
    public let text: String
    public let range: Range<String.Index>
    public let isWord: Bool
}


