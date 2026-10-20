import Foundation

/// One line of a call's account: to the call's trace on the relay while a call is up (`sink`, set by the session), and
/// to the console in a debug build. Never a key, a token, SDP, an address or a name.
enum CallLog {
    private static let lock = NSLock()
    private static var sink: ((String) -> Void)?
    private static var webrtcMinute = 0
    private static var webrtcLines = 0

    /// Where the lines of the call that is up go, or nil once it ends.
    static func setSink(_ handler: ((String) -> Void)?) {
        lock.lock()
        sink = handler
        lock.unlock()
    }

    static func write(_ line: String) {
        #if DEBUG
        print("[calls] " + line)
        #endif
        lock.lock()
        let handler = sink
        lock.unlock()
        handler?(line)
    }

    /// libwebrtc's own warnings: at most twenty a minute, since a stack gone wrong writes one per frame.
    static func webrtc(_ message: String) {
        let minute = Int(Date().timeIntervalSince1970 / 60)
        lock.lock()
        if minute != webrtcMinute {
            webrtcMinute = minute
            webrtcLines = 0
        }
        webrtcLines += 1
        let keep = webrtcLines <= 20
        lock.unlock()
        if keep { write("webrtc: " + message.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
