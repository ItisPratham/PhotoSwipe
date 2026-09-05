import XCTest
@testable import PhotoSwipe

/// The SigLIP 2 tokenizer, exercised against a small hand-built vocabulary.
/// The real Gemma vocabulary has 256k pieces and ships with the converted
/// model; these cover the parts that are ours to get right — the Viterbi
/// choice, byte fallback, normalisation, and the fixed-length output.
final class SentencePieceTokenizerTests: XCTestCase {
    private let pad: Int32 = 0
    private let eos: Int32 = 1
    private let bos: Int32 = 2
    private let unk: Int32 = 3

    func testPrefersTheHigherScoringSegmentation() throws {
        // "▁ab" as one piece beats "▁a" + "b" here...
        let tokenizer = try make(extra: [("\u{2581}a", -3), ("b", -3), ("\u{2581}ab", -1)])
        XCTAssertEqual(body(tokenizer.encode("ab")), [id(for: "\u{2581}ab")])

        // ...and loses when the single piece is made expensive enough.
        let split = try make(extra: [("\u{2581}a", -1), ("b", -1), ("\u{2581}ab", -9)])
        XCTAssertEqual(body(split.encode("ab")), [id(for: "\u{2581}a"), id(for: "b")])
    }

    func testSurroundsTheTextWithBeginAndEndTokensAndPadsToLength() throws {
        let tokenizer = try make(extra: [("\u{2581}a", -1)])
        let ids = tokenizer.encode("a")
        XCTAssertEqual(ids.count, 8)
        XCTAssertEqual(ids[0], bos)
        XCTAssertEqual(ids[1], id(for: "\u{2581}a"))
        XCTAssertEqual(ids[2], eos)
        XCTAssertEqual(Array(ids.dropFirst(3)), Array(repeating: pad, count: 5))
    }

    func testTruncationKeepsTheEndToken() throws {
        let tokenizer = try make(extra: [("\u{2581}a", -1), ("a", -1)])
        let ids = tokenizer.encode(String(repeating: "a ", count: 40))
        XCTAssertEqual(ids.count, 8)
        XCTAssertEqual(ids.last, eos, "A cut-off query must still reach the tower terminated.")
        XCTAssertFalse(ids.contains(pad))
    }

    func testUnknownCharactersFallBackToTheirBytes() throws {
        let tokenizer = try make(extra: [("\u{2581}a", -1)], byteFallback: true)
        // "é" is not in the vocabulary; its UTF-8 bytes are C3 A9.
        let ids = body(tokenizer.encode("aé"))
        XCTAssertEqual(ids.suffix(2), [id(for: "<0xC3>"), id(for: "<0xA9>")])
        XCTAssertFalse(ids.contains(unk))
    }

    func testUnknownCharactersBecomeUnkWithoutByteFallback() throws {
        let tokenizer = try make(extra: [("\u{2581}a", -1)])
        XCTAssertEqual(body(tokenizer.encode("aé")).suffix(1), [unk])
    }

    func testNormalisationCollapsesWhitespaceAndAppliesTheDummyPrefix() {
        let normalize = SentencePieceTokenizer.normalize
        XCTAssertEqual(normalize("a  b", true), "\u{2581}a\u{2581}b")
        XCTAssertEqual(normalize("\ta\nb ", true), "\u{2581}a\u{2581}b")
        XCTAssertEqual(normalize("ab", false), "ab")
        XCTAssertEqual(normalize("   ", true), "")
        // Compatibility composition, as SentencePiece's NFKC step does.
        XCTAssertEqual(normalize("\u{FB01}n", true), "\u{2581}fin")
    }

    func testAVocabularyThatDeclaresByteFallbackWithoutByteseIsRejected() {
        XCTAssertThrowsError(try SentencePieceTokenizer(resources: .init(
            pieces: ["<pad>", "<eos>", "<bos>", "<unk>"], scores: [0, 0, 0, 0],
            unknownID: unk, padID: pad, beginID: bos, endID: eos,
            contextLength: 8, addDummyPrefix: true, byteFallback: true
        )))
    }

    // MARK: - Helpers

    private var pieces: [String] = []

    private func make(extra: [(String, Float)], byteFallback: Bool = false) throws -> SentencePieceTokenizer {
        var pieces = ["<pad>", "<eos>", "<bos>", "<unk>"]
        var scores: [Float] = [0, 0, 0, 0]
        if byteFallback {
            for byte in 0...255 {
                pieces.append(String(format: "<0x%02X>", byte))
                scores.append(-20)
            }
        }
        for (piece, score) in extra {
            pieces.append(piece)
            scores.append(score)
        }
        self.pieces = pieces
        return try SentencePieceTokenizer(resources: .init(
            pieces: pieces, scores: scores,
            unknownID: unk, padID: pad, beginID: bos, endID: eos,
            contextLength: 8, addDummyPrefix: true, byteFallback: byteFallback
        ))
    }

    private func id(for piece: String) -> Int32 {
        Int32(pieces.firstIndex(of: piece) ?? -1)
    }

    /// The ids between the begin and end tokens.
    private func body(_ ids: [Int32]) -> [Int32] {
        Array(ids.drop(while: { $0 == bos }).prefix(while: { $0 != eos }))
    }
}
