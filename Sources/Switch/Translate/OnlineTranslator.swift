import Foundation

/// Google Translate's public web endpoint, used only when Settings → Translate → Online is on
/// (the text is sent to Google). Anything unexpected returns nil and the caller falls back to
/// translating on this Mac.
enum OnlineTranslator {
    struct Answer: Equatable {
        let text: String
        /// Source language Google detected ("en").
        let detected: String?
    }

    private static let timeout: TimeInterval = 8

    static func translate(_ text: String, from source: String?, to target: String) async -> Answer? {
        var parts = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        parts.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source ?? "auto"),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    /// `[[["Xin chào ","Hello ",…],…],null,"en"]` → "Xin chào …", "en".
    static func parse(_ data: Data) -> Answer? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any] else { return nil }
        let text = segments.compactMap { ($0 as? [Any])?.first as? String }.joined()
        guard !text.isEmpty else { return nil }
        let detected = root.count > 2 ? root[2] as? String : nil
        return Answer(text: text, detected: detected)
    }
}
