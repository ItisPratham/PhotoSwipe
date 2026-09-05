import XCTest
@testable import PhotoSwipe

final class ScrollBarInstallerTests: XCTestCase {
    func testScrollBarIsHiddenForContentThatFits() {
        XCTAssertFalse(ScrollBarInstaller.needsScrollBar(
            contentSize: CGSize(width: 100, height: 100),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 120),
            adjustedContentInset: .zero
        ))
    }

    func testScrollBarAppearsForOverflowingContent() {
        XCTAssertTrue(ScrollBarInstaller.needsScrollBar(
            contentSize: CGSize(width: 100, height: 121),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 120),
            adjustedContentInset: .zero
        ))
    }
}
