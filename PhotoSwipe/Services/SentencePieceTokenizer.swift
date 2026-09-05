import Foundation

/// The SentencePiece **BPE** tokenizer SigLIP 2 uses — Gemma's 256k
/// vocabulary. The counterpart to `CLIPTokenizer`: the converter exports the
/// vocabulary and its merge scores, this reproduces the reference
/// segmentation on device, and `SearchEmbedder` picks whichever tokenizer the
/// installed model family needs.
///
/// SentencePiece can hold either a Unigram or a BPE model, and Gemma's is BPE:
/// the per-piece "scores" are merge ranks, not log probabilities. So this
/// merges greedily by rank rather than searching for a best-scoring
/// segmentation. Getting that wrong is not a crash — it silently produces
/// different tokens and therefore different search results, which is why the
/// converter re-tokenizes twenty reference strings and refuses to finish if
/// this implementation disagrees with the reference.
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
        /// SentencePiece's `add_dummy_prefix`. False for Gemma, which is why
        /// it is read from the model rather than assumed.
        var addDummyPrefix: Bool
        /// True when the vocabulary carries the 256 `<0xNN>` pieces.
        var byteFallback: Bool
    }

    static let spaceMarker = "\u{2581}"  // "▁", SentencePiece's visible space

    let contextLength: Int
    let vocabularyCount: Int
    /// Keyed by UTF-8 bytes, not by `String`. Swift compares strings by
    /// canonical equivalence, so "café" and "cafe" + U+0301 would collide as
    /// dictionary keys — and the reference tokenizer treats them as different
    /// pieces with different ids. Bytes keep them apart.
    private let ids: [[UInt8]: Int32]
    private let scores: [[UInt8]: Float]
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

        var ids: [[UInt8]: Int32] = [:]
        var scores: [[UInt8]: Float] = [:]
        ids.reserveCapacity(resources.pieces.count)
        scores.reserveCapacity(resources.pieces.count)
        for (index, piece) in resources.pieces.enumerated() {
            let key = Array(piece.utf8)
            guard ids[key] == nil else { continue }
            // The first spelling wins, matching SentencePiece's own id order.
            ids[key] = Int32(index)
            scores[key] = resources.scores[index]
        }
        if resources.byteFallback {
            let missing = (0...255).first { ids[Array(Self.bytePiece(UInt8($0)).utf8)] == nil }
            if let missing {
                throw Error.invalidVocabulary("byte fallback declared but <0x\(String(format: "%02X", missing))> is absent")
            }
        }

        self.ids = ids
        self.scores = scores
        vocabularyCount = resources.pieces.count
        contextLength = resources.contextLength
        self.resources = resources
    }

    /// Returns exactly `contextLength` ids, padded and truncated the way the
    /// reference processor does (`padding="max_length"`, `truncation=True`).
    func encode(_ text: String) -> [Int32] {
        var tokens: [Int32] = []
        if let begin = resources.beginID { tokens.append(begin) }
        tokens.append(contentsOf: merge(symbols(in: normalized(text))))
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

    /// Spaces become "▁" and nothing else changes.
    ///
    /// Deliberately no Unicode normalisation and no whitespace collapsing: the
    /// reference applies neither, and NFC or NFKC would rewrite decomposed
    /// input such as "cafe\u{301}" into different tokens. Verified against all
    /// twenty reference strings during conversion.
    func normalized(_ text: String) -> String {
        let prefixed = resources.addDummyPrefix ? " " + text : text
        return prefixed.replacingOccurrences(of: " ", with: Self.spaceMarker)
    }

    /// One symbol per Unicode scalar, not per grapheme cluster: the reference
    /// works in code points, so a family emoji is several symbols joined by
    /// zero-width joiners rather than one. Anything the vocabulary cannot
    /// spell becomes its UTF-8 bytes.
    private func symbols(in text: String) -> [[UInt8]] {
        text.unicodeScalars.flatMap { scalar -> [[UInt8]] in
            let bytes = Array(String(scalar).utf8)
            if ids[bytes] != nil { return [bytes] }
            guard resources.byteFallback else { return [bytes] }
            return bytes.map { Array(Self.bytePiece($0).utf8) }
        }
    }

    /// Greedy BPE: merge the adjacent pair with the best rank, repeat.
    private func merge(_ initial: [[UInt8]]) -> [Int32] {
        var symbols = initial
        // ponytail: rescans every pair after each merge, O(n^2) on query-length
        // text. A pair heap only pays off on documents, which never reach here.
        while symbols.count > 1 {
            var bestIndex = -1
            var bestScore = -Float.infinity
            for index in 0..<(symbols.count - 1) {
                guard let score = scores[symbols[index] + symbols[index + 1]], score > bestScore else { continue }
                bestScore = score
                bestIndex = index
            }
            guard bestIndex >= 0 else { break }
            symbols[bestIndex].append(contentsOf: symbols[bestIndex + 1])
            symbols.remove(at: bestIndex + 1)
        }
        return symbols.map { ids[$0] ?? resources.unknownID }
    }

    private static func bytePiece(_ byte: UInt8) -> String {
        String(format: "<0x%02X>", byte)
    }
}
