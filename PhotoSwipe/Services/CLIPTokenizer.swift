import Foundation

/// MobileCLIP's 77-token OpenCLIP-compatible BPE tokenizer. The vocabulary and
/// merges are Apple-provided resources; initialization validates them once so
/// an unavailable or mismatched search bundle is reported before inference.
struct CLIPTokenizer {
    enum Error: LocalizedError {
        case missingResource(String)
        case invalidVocabulary
        case invalidMerges

        var errorDescription: String? {
            switch self {
            case .missingResource(let name): "Missing tokenizer resource: \(name)"
            case .invalidVocabulary: "The CLIP vocabulary is invalid."
            case .invalidMerges: "The CLIP BPE merges are invalid."
            }
        }
    }

    static let contextLength = 77
    private static let mergeCount = 49_152 - 256 - 2

    let startToken: Int32
    let endToken: Int32
    let vocabularyCount: Int
    private let vocabulary: [String: Int32]
    private let ranks: [Pair: Int]
    private let byteEncoder: [UInt8: String]

    init(bundle: Bundle = .main) throws {
        guard let vocabularyURL = bundle.url(forResource: "clip-vocab", withExtension: "json"),
              let mergeURL = bundle.url(forResource: "clip-merges", withExtension: "txt") else {
            throw Error.missingResource("clip-vocab.json or clip-merges.txt")
        }
        try self.init(vocabularyData: Data(contentsOf: vocabularyURL),
                      merges: String(contentsOf: mergeURL, encoding: .utf8))
    }

    init(vocabularyData: Data, merges: String) throws {
        let decoded = try JSONDecoder().decode([String: Int].self, from: vocabularyData)
        guard decoded.count == 49_408,
              decoded.values.min() == 0,
              decoded.values.max() == 49_407,
              let start = decoded["<|startoftext|>"],
              let end = decoded["<|endoftext|>"] else {
            throw Error.invalidVocabulary
        }
        let parsedMerges = merges
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .prefix(Self.mergeCount)
            .compactMap { line -> Pair? in
                let tokens = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard tokens.count == 2 else { return nil }
                return Pair(tokens[0], tokens[1])
            }
        guard parsedMerges.count == Self.mergeCount else { throw Error.invalidMerges }

        vocabulary = Dictionary(uniqueKeysWithValues: decoded.map { ($0.key, Int32($0.value)) })
        ranks = Dictionary(uniqueKeysWithValues: parsedMerges.enumerated().map { ($0.element, $0.offset) })
        startToken = Int32(start)
        endToken = Int32(end)
        vocabularyCount = decoded.count
        byteEncoder = Self.makeByteEncoder()
    }

    /// Returns exactly 77 Int32 token IDs. It preserves OpenCLIP's start/end
    /// tokens, zero padding, and end-token-preserving truncation.
    func encode(_ text: String) -> [Int32] {
        var tokens = [startToken]
        for match in Self.tokenMatches(in: Self.clean(text)) {
            let byteEncoded = match.utf8.compactMap { byteEncoder[$0] }.joined()
            for piece in bpe(byteEncoded).split(separator: " ") {
                guard let id = vocabulary[String(piece)] else {
                    preconditionFailure("CLIP tokenizer vocabulary and merges do not match")
                }
                tokens.append(id)
            }
        }
        tokens.append(endToken)
        if tokens.count > Self.contextLength {
            tokens = Array(tokens.prefix(Self.contextLength))
            tokens[Self.contextLength - 1] = endToken
        }
        tokens.append(contentsOf: repeatElement(0, count: Self.contextLength - tokens.count))
        return tokens
    }

    // MARK: - Reference text cleaning

    private static func clean(_ text: String) -> String {
        // OpenCLIP uses ftfy.fix_text(), then two HTML unescapes, whitespace
        // normalization, and Unicode lowercasing. Canonical composition covers
        // the composed/decomposed Unicode cases in the shipped parity vectors.
        let unescaped = htmlUnescape(htmlUnescape(text)).precomposedStringWithCanonicalMapping
        return unescaped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func htmlUnescape(_ text: String) -> String {
        let pattern = "&(?:#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: range).reversed()
        var result = text
        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            let entity = String(result[range])
            let replacement: String?
            switch entity {
            case "&amp;": replacement = "&"
            case "&lt;": replacement = "<"
            case "&gt;": replacement = ">"
            case "&quot;": replacement = "\""
            case "&apos;": replacement = "'"
            case "&nbsp;": replacement = "\u{00A0}"
            default:
                let value: UInt32?
                if entity.hasPrefix("&#x") {
                    value = UInt32(entity.dropFirst(3).dropLast(), radix: 16)
                } else if entity.hasPrefix("&#") {
                    value = UInt32(entity.dropFirst(2).dropLast())
                } else {
                    value = nil
                }
                replacement = value.flatMap(UnicodeScalar.init).map(String.init)
            }
            if let replacement { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }

    private static func tokenMatches(in text: String) -> [String] {
        let pattern = "'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: - Byte pair encoding

    private func bpe(_ token: String) -> String {
        let scalars = token.unicodeScalars.map(String.init)
        guard let last = scalars.last else { return "" }
        var word = Array(scalars.dropLast()) + [last + "</w>"]
        var pairs = Self.pairs(in: word)
        while let pair = pairs.min(by: { (ranks[$0] ?? .max) < (ranks[$1] ?? .max) }),
              ranks[pair] != nil {
            var merged: [String] = []
            var index = 0
            while index < word.count {
                if index + 1 < word.count, word[index] == pair.first, word[index + 1] == pair.second {
                    merged.append(pair.first + pair.second)
                    index += 2
                } else {
                    merged.append(word[index])
                    index += 1
                }
            }
            word = merged
            guard word.count > 1 else { break }
            pairs = Self.pairs(in: word)
        }
        return word.joined(separator: " ")
    }

    private static func pairs(in word: [String]) -> Set<Pair> {
        Set(zip(word, word.dropFirst()).map { Pair($0.0, $0.1) })
    }

    private static func makeByteEncoder() -> [UInt8: String] {
        var bytes = Array(UInt8(33)...UInt8(126)) + Array(UInt8(161)...UInt8(172)) + Array(UInt8(174)...UInt8(255))
        var scalars = bytes.map { UInt32($0) }
        var next: UInt32 = 256
        for byte in UInt8.min...UInt8.max where !bytes.contains(byte) {
            bytes.append(byte)
            scalars.append(next)
            next += 1
        }
        return Dictionary(uniqueKeysWithValues: zip(bytes, scalars).compactMap { byte, scalar in
            UnicodeScalar(scalar).map { (byte, String($0)) }
        })
    }

    private struct Pair: Hashable {
        let first: String
        let second: String
        init(_ first: String, _ second: String) {
            self.first = first
            self.second = second
        }
    }
}
