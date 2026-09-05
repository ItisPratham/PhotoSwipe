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

    func testDirectScrollBarDragCannotOverscrollPastTheContentTop() {
        // `top` is derived from the live adjusted inset, not from wherever the
        // bar happened to be installed, so a bar installed mid-scroll can
        // still be dragged all the way back to the first photo.
        XCTAssertEqual(
            ScrollBarInstaller.correctedDirectDragOffset(-44, top: 0, isDirectScrollbarDrag: true),
            0
        )
        XCTAssertEqual(
            ScrollBarInstaller.correctedDirectDragOffset(-140, top: -96, isDirectScrollbarDrag: true),
            -96,
            "Under a large title the top of the content sits above zero."
        )
        XCTAssertEqual(
            ScrollBarInstaller.correctedDirectDragOffset(-96, top: -96, isDirectScrollbarDrag: true),
            -96
        )
    }

    func testNativeScrollViewBounceIsUnchanged() {
        XCTAssertEqual(
            ScrollBarInstaller.correctedDirectDragOffset(-44, top: 0, isDirectScrollbarDrag: false),
            -44
        )
    }
}
