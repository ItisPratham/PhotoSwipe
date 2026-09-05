import XCTest
@testable import PhotoSwipe

final class CLIPTokenizerTests: XCTestCase {
    func testReferenceSequences() throws {
        let tokenizer = try CLIPTokenizer(bundle: .main)
        let fixture = try fixture()
        XCTAssertEqual(fixture.contextLength, CLIPTokenizer.contextLength)
        XCTAssertEqual(fixture.sequences.count, 20)
        for sequence in fixture.sequences {
            XCTAssertEqual(tokenizer.encode(sequence.text), sequence.ids, sequence.text)
        }
    }

    func testVocabularyAndSpecialTokens() throws {
        let tokenizer = try CLIPTokenizer(bundle: .main)
        XCTAssertEqual(tokenizer.vocabularyCount, 49_408)
        XCTAssertEqual(tokenizer.startToken, 49_406)
        XCTAssertEqual(tokenizer.endToken, 49_407)
    }

    func testTruncationRetainsTheEndToken() throws {
        let fixture = try fixture()
        let overlength = try XCTUnwrap(fixture.sequences.last)
        XCTAssertEqual(overlength.ids.count, CLIPTokenizer.contextLength)
        XCTAssertEqual(overlength.ids.first, 49_406)
        XCTAssertEqual(overlength.ids.last, 49_407)
    }

    /// The reference runs ftfy before tokenizing, so a smart apostrophe or
    /// curly quotes must produce exactly the tokens their straight
    /// equivalents do. Without that, a query typed on an iPhone keyboard
    /// silently searches a different string than the same words pasted in.
    func testSmartPunctuationTokenizesLikeItsStraightEquivalent() throws {
        let tokenizer = try CLIPTokenizer(bundle: .main)
        XCTAssertEqual(tokenizer.encode("don\u{2019}t"), tokenizer.encode("don't"))
        XCTAssertEqual(tokenizer.encode("\u{201C}beach day\u{201D}"), tokenizer.encode("\"beach day\""))
        XCTAssertEqual(tokenizer.encode("mum\u{02BC}s cake"), tokenizer.encode("mum's cake"))
    }

    private func fixture() throws -> Fixture {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "reference-token-sequences", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private struct Fixture: Decodable {
        let contextLength: Int
        let sequences: [Sequence]
    }

    private struct Sequence: Decodable {
        let text: String
        let ids: [Int32]
    }
}
