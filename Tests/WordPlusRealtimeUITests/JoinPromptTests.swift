#if canImport(UIKit)
import UIKit
import XCTest
@testable import WordPlusRealtimeUI

/// The notice of a group call's join, as the web's JoinPrompt draws it: Do Not Show Again beside Preview where the host
/// keeps the user's choice, and none where it keeps none. Run on a simulator, as RecordingTests.
@MainActor
final class JoinPromptTests: XCTestCase {
    private func pills( _ view: UIView ) -> [ CallsDevicePill ] {
        view.subviews.flatMap { ( $0 as? CallsDevicePill ).map { [ $0 ] } ?? pills( $0 ) }
    }

    /// A tap's actions, run as UIKit would: the tests have no application to send them through.
    private func press( _ control: UIControl ) {
        for target in control.allTargets {
            for action in control.actions( forTarget: target, forControlEvent: .touchUpInside ) ?? [] {
                _ = ( target as NSObject ).perform( Selector( action ) )
            }
        }
    }

    func testDoNotShowAgainOnlyWhereTheHostKeepsTheChoice() {
        XCTAssertEqual( pills( CallsJoinPrompt( video: true ) ).map { $0.accessibilityLabel }, [ "Preview" ] )
        XCTAssertEqual( pills( CallsJoinPrompt( video: false ) ).map { $0.accessibilityLabel }, [ "Test Microphone" ] )

        let prompt = CallsJoinPrompt( video: true, never: true )
        XCTAssertEqual( pills( prompt ).map { $0.accessibilityLabel }, [ "Preview", "Do Not Show Again" ] )

        var never = 0
        var preview = 0
        prompt.onNever = { never += 1 }
        prompt.onPreview = { preview += 1 }
        pills( prompt ).last.map( press )
        XCTAssertEqual( never, 1 )
        XCTAssertEqual( preview, 0 )
    }

    func testTheButtonsStayInsideANarrowCard() {
        let host = UIView( frame: CGRect( x: 0, y: 0, width: 320, height: 640 ) )
        let dock = UIView()
        dock.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview( dock )
        NSLayoutConstraint.activate( [
            dock.leadingAnchor.constraint( equalTo: host.leadingAnchor ),
            dock.trailingAnchor.constraint( equalTo: host.trailingAnchor ),
            dock.bottomAnchor.constraint( equalTo: host.bottomAnchor ),
            dock.heightAnchor.constraint( equalToConstant: 80 ),
        ] )

        let prompt = CallsJoinPrompt( video: false, never: true )
        prompt.place( in: host, above: dock )
        host.layoutIfNeeded()

        for pill in pills( prompt ) {
            let frame = pill.convert( pill.bounds, to: prompt )
            XCTAssertLessThanOrEqual( frame.maxX, prompt.bounds.maxX, "\( pill.accessibilityLabel ?? "" ) runs out of the card" )
        }
    }
}
#endif
