import XCTest
@testable import PhotoSwipe

/// Checks the Swift tokenizer against the reference tokenizer's own output.
///
/// `SentencePieceTokenizerTests` proves the algorithm on a vocabulary I wrote;
/// this proves the shipped 256k Gemma vocabulary produces exactly the ids
/// `transformers` produced during conversion. It is the test that would catch
/// a port that looks right and searches wrong.
///
/// Skips unless SigLIP 2 is the installed family, so it costs nothing in a
/// MobileCLIP build or a model-free checkout.
final class SentencePieceParityTests: XCTestCase {
    private struct Vocabulary: Decodable {
        struct Sequence: Decodable {
            let text: String
            let ids: [Int32]
        }
        let contextLength: Int
        let referenceSequences: [Sequence]?
    }

    func testTheShippedVocabularyReproducesTheReferenceTokenization() throws {
        let bundle = Bundle.main
        let url = try XCTUnwrap(
            bundle.url(forResource: "siglip2-vocab", withExtension: "json"),
            "SigLIP 2 is not installed in this build."
        )
        let data = try Data(contentsOf: url)
        let vocabulary = try JSONDecoder().decode(Vocabulary.self, from: data)
        let sequences = try XCTUnwrap(
            vocabulary.referenceSequences,
            "This vocabulary predates reference sequences; re-run scripts/convert_siglip2.py."
        )
        XCTAssertEqual(sequences.count, 20)

        let tokenizer = try SentencePieceTokenizer(data: data)
        XCTAssertEqual(tokenizer.contextLength, vocabulary.contextLength)
        for sequence in sequences {
            XCTAssertEqual(tokenizer.encode(sequence.text), sequence.ids, sequence.text)
        }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            SearchModelSpec.installed(in: .main)?.family == .sigLIP2,
            "SigLIP 2 is not the installed search model; nothing to compare."
        )
    }
}
