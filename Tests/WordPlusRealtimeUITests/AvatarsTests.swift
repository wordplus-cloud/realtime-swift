#if canImport(UIKit)
import UIKit
import XCTest
@testable import WordPlusRealtimeUI

/// The avatars of the call screens (CallsAvatars): an SVG, which UIKit has no decoder for and letter-avatar generators
/// serve, comes out a picture drawn by WebKit with its colours where the SVG put them, known by its type or by its bytes;
/// bytes that are no picture are none; and the initials that stand in for a picture. Run on a simulator, as PiecesTests.
final class AvatarsTests: XCTestCase {
    /// A letter avatar as one such generator writes it: a square of colour, two letters on it.
    private let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="100px" height="100px" \
        viewBox="0 0 100 100" style="user-select: none;"><rect fill="#c86ec8" cx="50" width="100" height="100" cy="50" \
        r="50"/><text x="50%" y="50%" style="color: #fff; line-height: 1;font-family: -apple-system, sans-serif;" \
        alignment-baseline="middle" text-anchor="middle" font-size="50" font-weight="400" dy=".1em" \
        dominant-baseline="middle" fill="#fff">IN</text></svg>
        """

    private func picture( _ data: Data, type: String? ) -> UIImage? {
        let drawn = expectation( description: "the picture is decided" )
        var image: UIImage?

        CallsAvatars.picture( from: data, type: type ) { picture in
            image = picture
            drawn.fulfill()
        }

        wait( for: [ drawn ], timeout: 30 )

        return image
    }

    /// The colour at a point of the picture, as 0–255 red, green and blue.
    private func colour( of image: UIImage, x: Int, y: Int ) -> [ Int ] {
        guard let cg = image.cgImage else { return [] }

        var pixel = [ UInt8 ]( repeating: 0, count: 4 )
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        context.draw( cg, in: CGRect( x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height ) )

        return pixel.prefix( 3 ).map( Int.init )
    }

    private func near( _ seen: [ Int ], _ wanted: [ Int ] ) -> Bool {
        seen.count == 3 && zip( seen, wanted ).allSatisfy { abs( $0 - $1 ) <= 6 }
    }

    func testAnSvgIsDrawnToAPicture() throws {
        let image = try XCTUnwrap( picture( Data( svg.utf8 ), type: "image/svg+xml" ), "an SVG avatar is a picture" )

        XCTAssertEqual( image.cgImage?.width, CallsSvgPictures.side, "drawn as large as the largest avatar on screen" )
        XCTAssertEqual( image.cgImage?.height, CallsSvgPictures.side )
        XCTAssertTrue( near( colour( of: image, x: 4, y: 4 ), [ 200, 110, 200 ] ), "its colour in the corner: \( colour( of: image, x: 4, y: 4 ) )" )

        // The letters are white, somewhere across the middle of it.
        let middle = CallsSvgPictures.side / 2
        let across = stride( from: middle - 60, to: middle + 60, by: 2 ).map { colour( of: image, x: $0, y: middle + 4 ) }
        XCTAssertTrue( across.contains { near( $0, [ 255, 255, 255 ] ) }, "its letters are drawn: \( across )" )
    }

    func testAnSvgIsKnownByItsBytesUnderAnotherType() {
        XCTAssertNotNil( picture( Data( svg.utf8 ), type: "application/octet-stream" ), "a server's other word for it is no matter" )
        XCTAssertNotNil( picture( Data( ( "<?xml version=\"1.0\"?>\n" + svg ).utf8 ), type: nil ), "nor an XML prolog" )
    }

    func testOneSvgAfterAnotherIsEachDrawn() {
        let first = expectation( description: "the first" )
        let second = expectation( description: "the second" )
        var drawn = [ Bool ]()

        CallsAvatars.picture( from: Data( svg.utf8 ), type: "image/svg+xml" ) { drawn.append( $0 != nil ); first.fulfill() }
        CallsAvatars.picture( from: Data( svg.replacingOccurrences( of: "#c86ec8", with: "#3a7bd5" ).utf8 ), type: "image/svg+xml" ) {
            drawn.append( $0 != nil )
            second.fulfill()
        }

        wait( for: [ first, second ], timeout: 30, enforceOrder: true )
        XCTAssertEqual( drawn, [ true, true ], "two avatars asked for at once are both drawn" )
    }

    func testWhatIsNoPictureIsNone() {
        XCTAssertNil( picture( Data( "<html><body>Not found</body></html>".utf8 ), type: "text/html" ), "a page of an error is no avatar" )
        XCTAssertNil( picture( Data(), type: "image/png" ), "nor is nothing" )
        XCTAssertNil( picture( Data( "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect".utf8 ), type: "image/svg+xml" ), "nor an SVG cut short" )
    }

    func testInitials() {
        XCTAssertEqual( CallsAvatars.initials( of: "ann lee" ), "AL" )
        XCTAssertEqual( CallsAvatars.initials( of: "Ann Lee Cole" ), "AL", "two letters at most" )
        XCTAssertEqual( CallsAvatars.initials( of: "Ann" ), "A" )
        XCTAssertEqual( CallsAvatars.initials( of: "" ), "?" )
        XCTAssertEqual( CallsAvatars.initials( of: "  " ), "?" )
    }
}
#endif
