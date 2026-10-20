// The API demo as an iOS app: sign in as Ann (support), Ben (a customer) or Cara (the warehouse), then watch the order of
// Ben move on, see who is in the shop and who is online, and chat with typing. The same rooms as the shop web pages,
// so the app and a browser signed in as someone else see each other.
import SwiftUI
import WordPlusRealtimeCalls

/// Calls as the phone knows them (SystemCalls): started at launch, as a call's push may have woken the app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The connection of the person signed in, for a call that rings the app closed: nil when nobody is.
        SystemCalls.start(.init(name: "API demo")) { await Shop.shared.connection() }
        // A call tapped in Recents or asked of Siri: the shop places it once it is connected.
        SystemCalls.onCallBack { back in
            Task { @MainActor in
                guard await Shop.shared.connection() != nil else { return }
                if let user = back.user { Shop.shared.startCall(to: user) } else { Shop.shared.joinMeeting() }
            }
        }
        return true
    }
}

@main
struct ExampleShopApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var shop = Shop.shared

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(shop)
                // The activity Recents and Siri hand the app for a call.
                .onContinueUserActivity("INStartCallIntent") { SystemCalls.handle($0) }
                .onContinueUserActivity("INStartAudioCallIntent") { SystemCalls.handle($0) }
                .onContinueUserActivity("INStartVideoCallIntent") { SystemCalls.handle($0) }
        }
    }
}
