import Foundation

/// Centralized policy for dictionary lookup key handling.
///
/// Invariants:
/// - `displayKey` is always the exact original selected/entered text.
/// - `lookupKey` is the *only* normalization applied for DB queries.
enum DictionaryKeyPolicy {
    struct Keys: Equatable {
        let displayKey: String
        let lookupKey: String
    }

    nonisolated static func keys(forDisplayKey displayKey: String) -> Keys {
        Keys(displayKey: displayKey, lookupKey: lookupKey(for: displayKey))
    }

    nonisolated static func keys(forRange range: NSRange, inText nsText: NSString) -> Keys {
        let display = nsText.substring(with: range)
        return keys(forDisplayKey: display)
    }

    /// The single, consistent normalization used for DB queries.
    ///
    /// Required by spec: trim + normalizeFullWidthASCII.
    nonisolated static func lookupKey(for displayKey: String) -> String {
        let trimmed = displayKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        return normalizeFullWidthASCII(trimmed)
    }

    // MARK: - Full-width ASCII normalization

    /// Converts full-width ASCII (Ｉ Ａ １ etc.) to regular ASCII equivalents.
    ///
    /// Important: This is intentionally limited to the full-width ASCII block.
    nonisolated static func normalizeFullWidthASCII(_ text: String) -> String {
        guard text.isEmpty == false else { return text }

        var out: String = ""
        out.reserveCapacity(text.count)

        for scalar in text.unicodeScalars {
            // Full-width ASCII range.
            if (0xFF01...0xFF5E).contains(scalar.value) {
                let mapped = UnicodeScalar(scalar.value - 0xFEE0)!
                out.unicodeScalars.append(mapped)
                continue
            }

            // Full-width space.
            if scalar.value == 0x3000 {
                out.unicodeScalars.append(" ")
                continue
            }

            out.unicodeScalars.append(scalar)
        }

        return out
    }
}
