import Foundation
import Mecab_Swift
import IPADic
#if canImport(UniDic)
import UniDic
#endif

enum TokenizerDictionary: String, CaseIterable {
    case ipadic = "IPADic"
    case unidic = "UniDic"
}

enum TokenizerFactory {
    /// Returns a Tokenizer using the selected dictionary, falling back to IPADic if UniDic is unavailable.
    static func make(selected: String? = nil) -> Tokenizer? {
        let choice = (selected ?? UserDefaults.standard.string(forKey: "tokenizerDictionary")) ?? TokenizerDictionary.ipadic.rawValue
        #if canImport(UniDic)
        if choice == TokenizerDictionary.unidic.rawValue {
            return try? Tokenizer(dictionary: UniDic())
        }
        #endif
        return try? Tokenizer(dictionary: IPADic())
    }
}
