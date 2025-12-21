import Foundation

enum WordsDelimiterChoice: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case comma = ","
    case semicolon = ";"
    case tab = "\t"
    case pipe = "|"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .comma: return ", (comma)"
        case .semicolon: return "; (semicolon)"
        case .tab: return "Tab"
        case .pipe: return "| (pipe)"
        }
    }
    var character: Character? {
        switch self {
        case .auto: return nil
        case .comma: return ","
        case .semicolon: return ";"
        case .tab: return "\t"
        case .pipe: return "|"
        }
    }
}
