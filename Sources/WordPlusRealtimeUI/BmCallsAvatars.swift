import UIKit

/// Faces for the people with their cameras off.
///
/// Small, because the alternative is a whole image library for one square
/// picture per person. It is cached by URL and fetched once: a call redraws its
/// grid on every active-speaker change, and re-fetching an avatar each time
/// would be a request every few hundred milliseconds.
enum BmCallsAvatars {
    private static let cache = NSCache<NSString, UIImage>()
    private static var waiting: [String: [(UIImage?) -> Void]] = [:]
    private static let lock = NSLock()

    static func load(_ url: String, done: @escaping (UIImage?) -> Void) {
        guard !url.isEmpty, let parsed = URL(string: url) else {
            done(nil)
            return
        }

        if let cached = cache.object(forKey: url as NSString) {
            done(cached)
            return
        }

        // Two tiles asking for the same avatar at once is normal — the grid
        // rebinds every tile on every roster change, and two people can share
        // a picture. They all wait on the one request and all get the answer:
        // dropping the second caller leaves that tile showing a letter for the
        // rest of the call.
        lock.lock()
        let first = waiting[url] == nil
        waiting[url, default: []].append(done)
        lock.unlock()

        guard first else { return }

        var request = URLRequest(url: parsed)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { data, _, _ in
            let image = data.flatMap { UIImage(data: $0) }

            if let image = image { cache.setObject(image, forKey: url as NSString) }

            lock.lock()
            let callbacks = waiting.removeValue(forKey: url) ?? []
            lock.unlock()

            // No avatar is a letter in a circle, which is a perfectly good
            // tile. It must never be a broken call.
            DispatchQueue.main.async { callbacks.forEach { $0(image) } }
        }.resume()
    }
}
