import XCTest
@testable import PhotoSwipe

/// The SigLIP 2 tokenizer, against a small hand-built vocabulary. The real
/// Gemma vocabulary has 256k pieces and ships with the converted model;
/// `SentencePieceParityTests` checks that one against the reference. These
/// cover the mechanics: which pair merges first, byte fallback, what
/// normalisation does and does not do, and the fixed-length output.
final class SentencePieceTokenizerTests: XCTestCase {
    private let pad: Int32 = 0
    private let eos: Int32 = 1
    private let bos: Int32 = 2
    private let unk: Int32 = 3

    func testMergesTheBestRankedPairFirst() throws {
        // Gemma's scores are merge ranks: closer to zero merges earlier.
        let tokenizer = try make(extra: [("a", -1), ("b", -2), ("c", -3), ("ab", -10), ("bc", -4)])
        // "abc" could merge as (ab)c or a(bc). "bc" outranks "ab", and "abc"
        // itself is absent, so merging stops there.
        XCTAssertEqual(body(tokenizer.encode("abc")), [id(for: "a"), id(for: "bc")])
    }

    func testKeepsMergingWhileTheVocabularyAllows() throws {
        let tokenizer = try make(extra: [("a", -1), ("b", -2), ("ab", -10), ("abab", -50)])
        XCTAssertEqual(body(tokenizer.encode("abab")), [id(for: "abab")],
                       "A late merge must still be taken; BPE is not a shortest-path search.")
    }

    func testUnmergeablePairsStayApart() throws {
        let tokenizer = try make(extra: [("a", -1), ("b", -2), ("ab", -10)])
        XCTAssertEqual(body(tokenizer.encode("ba")), [id(for: "b"), id(for: "a")])
    }

    func testSurroundsTheTextWithBeginAndEndTokensAndPadsToLength() throws {
        let tokenizer = try make(extra: [("a", -1)])
        let ids = tokenizer.encode("a")
        XCTAssertEqual(ids.count, 8)
        XCTAssertEqual(ids[0], bos)
        XCTAssertEqual(ids[1], id(for: "a"))
        XCTAssertEqual(ids[2], eos)
        XCTAssertEqual(Array(ids.dropFirst(3)), Array(repeating: pad, count: 5))
    }

    func testTruncationKeepsTheEndToken() throws {
        let tokenizer = try make(extra: [("a", -1)])
        let ids = tokenizer.encode(String(repeating: "a", count: 40))
        XCTAssertEqual(ids.count, 8)
        XCTAssertEqual(ids.last, eos, "A cut-off query must still reach the tower terminated.")
        XCTAssertFalse(ids.contains(pad))
    }

    func testUnknownCharactersFallBackToTheirBytes() throws {
        let tokenizer = try make(extra: [("a", -1)], byteFallback: true)
        // "é" is absent from the vocabulary; its UTF-8 bytes are C3 A9.
        let ids = body(tokenizer.encode("aé"))
        XCTAssertEqual(ids.suffix(2), [id(for: "<0xC3>"), id(for: "<0xA9>")])
        XCTAssertFalse(ids.contains(unk))
    }

    func testUnknownCharactersBecomeUnkWithoutByteFallback() throws {
        let tokenizer = try make(extra: [("a", -1)])
        XCTAssertEqual(body(tokenizer.encode("aé")).suffix(1), [unk])
    }

    func testNormalisationOnlyRewritesSpaces() throws {
        let plain = try make(extra: [("a", -1)])
        let marker = SentencePieceTokenizer.spaceMarker
        // Whitespace is preserved, not collapsed: the reference keeps every
        // space, and the real vocabulary has a "▁▁" piece for two of them.
        XCTAssertEqual(plain.normalized("a  b"), "a\(marker)\(marker)b")
        // And no Unicode normalisation. Compared scalar by scalar on purpose:
        // Swift's == treats the composed and decomposed forms as equal, so it
        // would pass even if normalisation had quietly composed them.
        XCTAssertEqual(Array(plain.normalized("cafe\u{301}").unicodeScalars.map(\.value)),
                       [99, 97, 102, 101, 0x301])

        let prefixed = try make(extra: [("a", -1)], addDummyPrefix: true)
        XCTAssertEqual(prefixed.normalized("ab"), "\(marker)ab")
    }

    func testAVocabularyThatDeclaresByteFallbackWithoutBytesIsRejected() {
        XCTAssertThrowsError(try SentencePieceTokenizer(resources: .init(
            pieces: ["<pad>", "<eos>", "<bos>", "<unk>"], scores: [0, 0, 0, 0],
            unknownID: unk, padID: pad, beginID: bos, endID: eos,
            contextLength: 8, addDummyPrefix: false, byteFallback: true
        )))
    }

    // MARK: - Helpers

    private var pieces: [String] = []

    private func make(extra: [(String, Float)],
                      byteFallback: Bool = false,
                      addDummyPrefix: Bool = false) throws -> SentencePieceTokenizer {
        var pieces = ["<pad>", "<eos>", "<bos>", "<unk>"]
        var scores: [Float] = [0, 0, 0, 0]
        if byteFallback {
            for byte in 0...255 {
                pieces.append(String(format: "<0x%02X>", byte))
                scores.append(0)
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
            contextLength: 8, addDummyPrefix: addDummyPrefix, byteFallback: byteFallback
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
