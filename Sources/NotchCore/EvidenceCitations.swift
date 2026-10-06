import Foundation

public enum EvidenceCitations {
    /// Validate source identifiers, not the model's factual interpretation of the cited passages.
    public static func validate(_ text: String, allowed: Set<String>) throws {
        let pattern = try NSRegularExpression(pattern: #"\[([A-Za-z0-9-]+)\]"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let identifiers = pattern.matches(in: text, range: range).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        guard !identifiers.isEmpty, identifiers.allSatisfy(allowed.contains) else {
            throw AssistantError("The generated answer did not cite valid session sources. Review the matching passages or retry manually.")
        }
    }
}
