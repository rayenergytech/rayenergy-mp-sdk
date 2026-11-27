import Foundation

/// 批量上报器（URLSession）。成功（HTTP 200 且 code==0）回调 true。
final class Reporter {

    private let endpoint: String
    private let tokenProvider: (() -> String?)?

    init(endpoint: String, tokenProvider: (() -> String?)? = nil) {
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
    }

    func report(appKey: String,
                deviceId: String,
                events: [[String: Any]],
                completion: @escaping (Bool) -> Void) {

        let trimmed = endpoint.hasSuffix("/")
            ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: trimmed + "/api/v1/track/collect") else {
            completion(false); return
        }

        let payload: [String: Any] = [
            "appKey": appKey,
            "deviceId": deviceId,
            "events": events
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Platform")
        if let token = tokenProvider?(), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !token.contains("\r"), !token.contains("\n") {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = json["code"] as? Int else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            DispatchQueue.main.async { completion(code == 0) }
        }
        task.resume()
    }
}
