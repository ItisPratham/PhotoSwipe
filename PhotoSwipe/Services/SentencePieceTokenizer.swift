import Foundation

/// The SentencePiece **Unigram** tokenizer SigLIP 2 uses (the Gemma
/// vocabulary, 256k pieces). It is the counterpart to `CLIPTokenizer`: the
/// converter exports the vocabulary and its scores as JSON, this reproduces
/// the reference segmentation on device, and `SearchEmbedder` picks whichever
/// tokenizer the installed model family needs.
///
/// Unigram is not BPE. Rather than replaying merges, it scores every way the
/// text could be cut into known pieces and keeps the highest-scoring path
/// (Viterbi over the piece lattice). Byte-fallback pieces (`<0x41>`) cover
/// anything the vocabulary cannot spell, which is what keeps emoji and unusual
/// scripts from collapsing into a single unknown token.
struct SentencePieceTokenizer {
    enum Error: LocalizedError {
        case missingResource(String)
        case invalidVocabulary(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name): "Missing tokenizer resource: \(name)"
            case .invalidVocabulary(let detail): "The SigLIP 2 vocabulary is invalid: \(detail)"
            }
        }
    }

    /// Written by `scripts/convert_siglip2.py` straight from the reference
    /// tokenizer, so the two cannot drift apart silently.
    struct Resources: Decodable {
        var pieces: [String]
        var scores: [Float]
        var unknownID: Int32
        var padID: Int32
        var beginID: Int32?
        var endID: Int32?
        var contextLength: Int
        /// SentencePiece's `add_dummy_prefix`: the reference prefixes a space
        /// so a leading word is tokenized like a mid-sentence one.
        var addDummyPrefix: Bool
        /// True when the vocabulary contains `<0xNN>` pieces.
        var byteFallback: Bool
    }

    static let spaceMarker = "\u{2581}"  // "▁", SentencePiece's visible space

    let contextLength: Int
    let vocabularyCount: Int
    private let ids: [String: Int32]
    private let scores: [String: Float]
    private let byteIDs: [UInt8: Int32]
    private let maxPieceLength: Int
    private let resources: Resources

    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "siglip2-vocab", withExtension: "json") else {
            throw Error.missingResource("siglip2-vocab.json")
        }
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        try self.init(resources: JSONDecoder().decode(Resources.self, from: data))
    }

    init(resources: Resources) throws {
        guard !resources.pieces.isEmpty else { throw Error.invalidVocabulary("no pieces") }
        guard resources.pieces.count == resources.scores.count else {
            throw Error.invalidVocabulary("pieces and scores disagree")
        }
        guard resources.contextLength > 1 else { throw Error.invalidVocabulary("context length") }
        guard resources.unknownID >= 0, Int(resources.unknownID) < resources.pieces.count else {
            throw Error.invalidVocabulary("unknown-token id out of range")
        }

        var ids: [String: Int32] = [:]
        var scores: [String: Float] = [:]
        var byteIDs: [UInt8: Int32] = [:]
        ids.reserveCapacity(resources.pieces.count)
        scores.reserveCapacity(resources.pieces.count)
        var longest = 0
        for (index, piece) in resources.pieces.enumerated() {
            let id = Int32(index)
            // The first spelling wins, matching SentencePiece's own id order.
            if ids[piece] == nil {
                ids[piece] = id
                scores[piece] = resources.scores[index]
            }
            longest = max(longest, piece.utf8.count)
            if resources.byteFallback, let byte = Self.byteValue(of: piece) {
                byteIDs[byte] = id
            }
        }
        guard longest > 0 else { throw Error.invalidVocabulary("empty pieces") }
        if resources.byteFallback, byteIDs.count != 256 {
            throw Error.invalidVocabulary("byte fallback declared but \(byteIDs.count) byte pieces present")
        }

        self.ids = ids
        self.scores = scores
        self.byteIDs = byteIDs
        maxPieceLength = longest
        vocabularyCount = resources.pieces.count
        contextLength = resources.contextLength
        self.resources = resources
    }

    /// Returns exactly `contextLength` ids, padded and truncated the way the
    /// reference processor does (`padding="max_length"`, `truncation=True`).
    func encode(_ text: String) -> [Int32] {
        var tokens: [Int32] = []
        if let begin = resources.beginID { tokens.append(begin) }
        tokens.append(contentsOf: pieces(in: Self.normalize(text, addDummyPrefix: resources.addDummyPrefix)))
        if let end = resources.endID { tokens.append(end) }

        if tokens.count > contextLength {
            tokens = Array(tokens.prefix(contextLength))
            // Keep the end token when the text is cut, so the tower still sees
            // a terminated sequence.
            if let end = resources.endID { tokens[contextLength - 1] = end }
        }
        tokens.append(contentsOf: repeatElement(resources.padID, count: contextLength - tokens.count))
        return tokens
    }

    /// Viterbi over the piece lattice: `best[i]` is the score of the best way
    /// to cover the first `i` bytes.
    private func pieces(in text: String) -> [Int32] {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return [] }
        let count = bytes.count

        var best = [Float](repeating: -.infinity, count: count + 1)
        var backStart = [Int](repeating: 0, count: count + 1)
        var backToken = [Int32](repeating: resources.unknownID, count: count + 1)
        best[0] = 0

        for end in 1...count {
            let earliest = max(0, end - maxPieceLength)
            for start in earliest..<end where best[start] > -.infinity {
                // ponytail: substring per candidate span. Queries are short, so
                // this stays well under a millisecond; switch to a byte trie if
                // it ever runs over long text.
                let piece = String(decoding: bytes[start..<end], as: UTF8.self)
                guard let id = ids[piece], let score = scores[piece] else { continue }
                let candidate = best[start] + score
                if candidate > best[end] {
                    best[end] = candidate
                    backStart[end] = start
                    backToken[end] = id
                }
            }
            guard best[end] == -.infinity else { continue }
            // Nothing in the vocabulary ends here: fall back to this single
            // byte, heavily penalised so it is never preferred to a real piece.
            let start = end - 1
            guard best[start] > -.infinity else { continue }
            best[end] = best[start] - 10
            backStart[end] = start
            backToken[end] = byteIDs[bytes[start]] ?? resources.unknownID
        }

        guard best[count] > -.infinity else { return [resources.unknownID] }
        var output: [Int32] = []
        var cursor = count
        while cursor > 0 {
            output.append(backToken[cursor])
            cursor = backStart[cursor]
        }
        return output.reversed()
    }

    /// SentencePiece's NMT_NFKC normalisation, as far as it affects real
    /// queries: compatibility composition, control characters dropped, runs of
    /// whitespace collapsed, and spaces written as "▁".
    static func normalize(_ text: String, addDummyPrefix: Bool) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
        let collapsed = folded
            .unicodeScalars
            .map { scalar -> String in
                // Whitespace first: tab and newline are control characters
                // too, and dropping them would run adjacent words together.
                if scalar.properties.isWhitespace { return " " }
                return scalar.properties.generalCategory.isDiscarded ? "" : String(scalar)
            }
            .joined()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        let prefixed = addDummyPrefix ? " " + collapsed : collapsed
        return prefixed.replacingOccurrences(of: " ", with: spaceMarker)
    }

    /// `<0x41>` -> 0x41.
    private static func byteValue(of piece: String) -> UInt8? {
        guard piece.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">") else { return nil }
        return UInt8(piece.dropFirst(3).dropLast(), radix: 16)
    }
}

private extension Unicode.GeneralCategory {
    /// Control and format characters the reference normaliser removes.
    /// Whitespace is mapped to a space before this filter runs.
    var isDiscarded: Bool {
        self == .control || self == .format || self == .surrogate || self == .privateUse
    }
}
