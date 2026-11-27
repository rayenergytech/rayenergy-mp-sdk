import Foundation

// Only used by run-client-contract-tests.sh. Network, MpClient and RuleContext remain real;
// platform identity and Keychain persistence require the separate iOS simulator/device suite.
public final class MpTracker {
    public static let shared = MpTracker()
    public var isStarted = true
    func cancelStartupIdentity() {}
    public var runtimeFields: [String: Any] = [:]
    public let collectionEndpoint = "https://mp-client.invalid"
    private var collectionTokenProvider: (() -> String?)?
    public func setCollectionTokenProvider(_ provider: (() -> String?)?) { collectionTokenProvider = provider }
    public func collectionAccessToken() -> String? { collectionTokenProvider?() }
    public func reportCollection(_ events: [[String: Any]], completion: @escaping (Bool) -> Void) {
        Reporter(endpoint: collectionEndpoint, tokenProvider: collectionTokenProvider)
            .report(appKey: "contract-app", deviceId: "contract-installation", events: events, completion: completion)
    }
    private let rules = RuleContext()
    func ruleContextSnapshot() -> [String: String] { rules.snapshot(deviceLanguage: nil) }
    func setRuleContext(_ fields: [String: Any]) { rules.patch(fields) }
}
final class DeviceInfo {
    static let shared = DeviceInfo()
    let versionCode = 1
    let deviceId = "contract-installation"
    let sessionScope = "contract-scope"
}
final class MpSessionStore {
    private static var values: [String: String] = [:]
    private let key: String
    init(scope: [String]) { key = scope.joined(separator: "|") }
    func read() throws -> String? { Self.values[key] }
    func write(_ token: String?) throws { Self.values[key] = token }
}
