import UIKit
import WebKit

/// Faces for the people with their cameras off.
///
/// Small, because the alternative is a whole image library for one square
/// picture per person. It is cached by URL and fetched once: a call redraws its
/// grid on every active-speaker change, and re-fetching an avatar each time
/// would be a request every few hundred milliseconds.
enum CallsAvatars {
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

        URLSession.shared.dataTask(with: request) { data, response, _ in
            picture(from: data, type: response?.mimeType) { image in
                if let image = image { cache.setObject(image, forKey: url as NSString) }

                lock.lock()
                let callbacks = waiting.removeValue(forKey: url) ?? []
                lock.unlock()

                // No avatar is initials on a disc, which is a perfectly good
                // tile. It must never be a broken call.
                DispatchQueue.main.async { callbacks.forEach { $0(image) } }
            }
        }.resume()
    }

    /// The picture in an avatar's bytes, on any thread.
    ///
    /// A photo decodes as it is. An SVG, which is what letter-avatar
    /// generators serve for a site's every member, has no decoder in UIKit and
    /// came back as no picture at all: initials where the web shows the
    /// avatar. WebKit draws it instead (`CallsSvgPictures`).
    static func picture(from data: Data?, type: String?, done: @escaping (UIImage?) -> Void) {
        guard let data = data, !data.isEmpty else { return done(nil) }

        if let image = UIImage(data: data) { return done(image) }

        guard isSvg(data, type: type) else { return done(nil) }

        DispatchQueue.main.async { CallsSvgPictures.shared.draw(data, done: done) }
    }

    /// An SVG by its type, or by its first kilobyte where a server calls it
    /// something else (`text/xml`, `application/octet-stream`).
    static func isSvg(_ data: Data, type: String?) -> Bool {
        if type?.lowercased().hasPrefix("image/svg") == true { return true }

        return String(decoding: data.prefix(1024), as: UTF8.self).lowercased().contains("<svg")
    }

    /// What stands in for a picture: the first letters of the first two words
    /// of the name, on every avatar of the call screens.
    static func initials(of name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }.map { String($0).uppercased() }

        return letters.isEmpty ? "?" : letters.joined()
    }
}

/// SVG avatars drawn to pictures by one web view kept off screen, on the main
/// thread, one at a time.
///
/// The web view draws the SVG on a canvas, as the web's call screens show it,
/// and hands back a PNG. It is made for the first SVG and let go a little
/// after the last, so a call with no SVG avatars carries none of it.
final class CallsSvgPictures: NSObject, WKNavigationDelegate {
    static let shared = CallsSvgPictures()

    /// Pixels on a side: the largest avatar on screen, the 108-point disc of a
    /// call with one person, at three pixels to the point.
    static let side = 324

    /// How long the web view is kept after its last picture.
    private static let keep: TimeInterval = 15

    private static let script = """
        const picture = new Image();
        await new Promise((resolve, reject) => {
            setTimeout(() => reject(new Error('timeout')), 5000);
            picture.onload = resolve;
            picture.onerror = () => reject(new Error('undrawable'));
            picture.src = 'data:image/svg+xml;base64,' + svg;
        });
        const width = picture.naturalWidth || side, height = picture.naturalHeight || side;
        const scale = Math.max(side / width, side / height);
        const canvas = document.createElement('canvas');
        canvas.width = side;
        canvas.height = side;
        canvas.getContext('2d').drawImage(picture, (side - width * scale) / 2, (side - height * scale) / 2, width * scale, height * scale);
        return canvas.toDataURL('image/png').split(',')[1];
        """

    private var view: WKWebView?
    private var ready = false
    private var jobs: [(svg: Data, done: (UIImage?) -> Void)] = []
    private var current: ((UIImage?) -> Void)?
    private var release: DispatchWorkItem?

    func draw(_ svg: Data, done: @escaping (UIImage?) -> Void) {
        jobs.append((svg, done))
        release?.cancel()
        release = nil

        guard view == nil else { return next() }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        web.navigationDelegate = self
        view = web
        ready = false
        web.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === view else { return }

        ready = true
        next()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail(webView)
    }

    /// The web view is gone: everyone waiting gets initials, and the next SVG
    /// makes a new one.
    private func fail(_ webView: WKWebView) {
        guard webView === view else { return }

        let waiting = jobs.map(\.done) + [current].compactMap { $0 }
        jobs = []
        current = nil
        drop()
        waiting.forEach { $0(nil) }
    }

    private func next() {
        guard ready, current == nil, let web = view else { return }

        guard !jobs.isEmpty else { return keepForAWhile() }

        let job = jobs.removeFirst()
        current = job.done

        web.callAsyncJavaScript(
            Self.script,
            arguments: ["svg": job.svg.base64EncodedString(), "side": Self.side],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            guard let self = self, web === self.view, let done = self.current else { return }

            var image: UIImage?

            if case .success(let value) = result, let encoded = value as? String, let png = Data(base64Encoded: encoded) {
                image = UIImage(data: png)
            }

            self.current = nil
            done(image)
            self.next()
        }
    }

    private func keepForAWhile() {
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.jobs.isEmpty, self.current == nil else { return }

            self.drop()
        }

        release = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keep, execute: item)
    }

    private func drop() {
        release?.cancel()
        release = nil
        view?.navigationDelegate = nil
        view?.stopLoading()
        view = nil
        ready = false
    }
}
