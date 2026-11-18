import UIKit

/// Remove and Ban from Calls, as the web's call screen asks it (realtime-ui's ban-dialog.tsx, Better Messages' form):
/// for how long, a number and Minutes, Hours or Days, an hour by default, and Ban. A ban is never longer than `most`
/// minutes, the realtime server's longest (7 days). The person leaves the call at once, and their joins are refused
/// until the ban ends. Offered where the call offers `ban` (CallsEngine.onBan).
enum CallsBan {
    /// The longest ban the realtime server keeps, in minutes.
    static let most = 7 * 24 * 60

    /// The minutes a number of a unit (1, 60 or 1440 minutes) means: at least one of it, at most `most`.
    static func minutes( amount: Int, unit: Int ) -> Int {
        min( max( 1, amount ) * max( 1, unit ), most )
    }

    /// Asks over the call, then bans: a refusal is shown on the call.
    static func ask( _ person: CallsRoomParticipant, from screen: CallsScreen ) {
        screen.closePopover()

        let form = Form()
        let confirm = CallsConfirm(
            title: CallsTheme.string( "ban_title", fallback: "Remove and Ban from Calls" ),
            message: CallsHostToasts.plain( person.name ),
            confirm: CallsTheme.string( "ban", fallback: "Ban" ),
            danger: true,
            note: CallsTheme.string( "ban_note", fallback: "They leave the call now and cannot join it again until the ban ends." ),
            extra: form
        ) { [weak screen, weak form] yes in
            guard yes, let minutes = form?.minutes else { return }

            CallsEngine.shared.ban( identity: person.identity, minutes: minutes ) { ok in
                guard !ok else { return }

                screen?.showError( CallsTheme.string( "moderation_failed", fallback: "The call server could not do this. Please try again." ) )
            }
        }

        screen.showConfirm( confirm )
    }

    /// For how long: the number and its unit.
    final class Form: UIStackView, UITextFieldDelegate {
        let amount = UITextField()
        let unit = UISegmentedControl( items: [
            CallsTheme.string( "minutes", fallback: "Minutes" ),
            CallsTheme.string( "hours", fallback: "Hours" ),
            CallsTheme.string( "days", fallback: "Days" ),
        ] )

        static let units = [ 1, 60, 60 * 24 ]

        /// The ban's minutes as the form says them now.
        var minutes: Int {
            CallsBan.minutes( amount: Int( amount.text ?? "" ) ?? 1, unit: Self.units[ max( 0, unit.selectedSegmentIndex ) ] )
        }

        init() {
            super.init( frame: .zero )

            axis = .vertical
            spacing = 8

            let label = UILabel()
            label.text = CallsTheme.string( "ban_for", fallback: "Ban from calls for" )
            label.font = .systemFont( ofSize: 12.5, weight: .medium )
            label.textColor = UIColor( white: 1, alpha: 0.7 )

            amount.text = "1"
            amount.keyboardType = .numberPad
            amount.textColor = .white
            amount.font = .systemFont( ofSize: 15 )
            amount.textAlignment = .center
            amount.backgroundColor = UIColor( white: 1, alpha: 0.08 )
            amount.layer.cornerRadius = 8
            amount.accessibilityLabel = label.text
            amount.delegate = self
            amount.translatesAutoresizingMaskIntoConstraints = false
            amount.widthAnchor.constraint( equalToConstant: 64 ).isActive = true
            amount.heightAnchor.constraint( equalToConstant: 34 ).isActive = true

            unit.selectedSegmentIndex = 1
            unit.accessibilityLabel = label.text

            let row = UIStackView( arrangedSubviews: [ amount, unit ] )
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .center

            addArrangedSubview( label )
            addArrangedSubview( row )
        }

        required init( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

        /// Digits alone, four at most, as the web's field takes 1 to 9999.
        func textField( _ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String ) -> Bool {
            let next = ( ( textField.text ?? "" ) as NSString ).replacingCharacters( in: range, with: string )

            return next.count <= 4 && next.allSatisfy( \.isNumber )
        }
    }
}
