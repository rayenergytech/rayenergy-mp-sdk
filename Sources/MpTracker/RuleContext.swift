import Foundation

/// Country and attribution are host supplied. Missing language uses the existing device language.
final class RuleContext {
    static let eventKeys = ["country": "country_code", "language": "device_language", "channel": "channel", "adGroup": "adgroup", "adCreative": "creative"]
    private var values: [String: String] = [:]
    private static func value(_ raw: Any) -> String? {
        if raw is NSNull { return nil }
        guard let text = raw as? String else { preconditionFailure("Rule context values must be strings or null") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
    func patch(_ fields: [String: Any]) {
        var next = values
        for (key, raw) in fields {
            precondition(Self.eventKeys[key] != nil, "Unsupported rule context field: \(key)")
            next[key] = Self.value(raw)
        }
        values = next
    }
    func replaceCommon(_ fields: [String: Any]) -> [String: Any] {
        var next: [String: String] = [:]
        var common = fields
        for (key, eventKey) in Self.eventKeys {
            if let raw = common.removeValue(forKey: eventKey) { next[key] = Self.value(raw) }
        }
        values = next
        return common
    }
    func snapshot(deviceLanguage: String?) -> [String: String] {
        var context = values
        guard let channel = try? AcquisitionChannel.normalize(context["channel"]) else { preconditionFailure("Invalid channel") }
        context["channel"] = channel
        if context["language"] == nil, let language = deviceLanguage, !language.isEmpty { context["language"] = language }
        return context
    }
}
