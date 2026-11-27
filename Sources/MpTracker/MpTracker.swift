import Foundation
import UIKit

/// MP 埋点 SDK（iOS / Swift）。
/// 协议：POST {endpoint}/api/v1/track/collect
@objcMembers
public final class MpTracker: NSObject {

    public struct Config {
        public let appKey: String
        public let endpoint: String
        public let flushInterval: TimeInterval
        public let maxBatchSize: Int
        public let commonFields: [String: Any]
        public let onError: ((Error) -> Void)?

        public init(appKey: String,
                    endpoint: String,
                    flushInterval: TimeInterval = 10,
                    maxBatchSize: Int = 100,
                    commonFields: [String: Any] = [:],
                    onError: ((Error) -> Void)? = nil) {
            self.appKey = appKey
            self.endpoint = endpoint
            self.flushInterval = flushInterval
            self.maxBatchSize = maxBatchSize
            self.commonFields = commonFields
            self.onError = onError
        }
    }

    public static let shared = MpTracker()

    public var isStarted: Bool { config != nil }
    public var deviceId: String? { isStarted ? DeviceInfo.shared.deviceId : nil }
    public var collectionEndpoint: String? { config?.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    private var collectionTokenProvider: (() -> String?)?

    internal func cancelStartupIdentity() { startupIds = nil }

    /// Optional send-time credential. The event store never receives this provider or its token.
    public func setCollectionTokenProvider(_ provider: (() -> String?)?) {
        precondition(Thread.isMainThread)
        collectionTokenProvider = provider
    }
    private var config: Config?
    private let store = EventStore()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var sending = false
    private var isForeground = true
    private var startupIds: Set<String>? = []
    private var startupDeadline = ProcessInfo.processInfo.systemUptime + 60
    internal var runtimeFields: [String: Any] = [:] {
        didSet {
            if let user = runtimeFields["user_id"] as? String, !user.isEmpty {
                if let ids = startupIds, ProcessInfo.processInfo.systemUptime < startupDeadline { store.bindStartup(ids, userId: user) }
                startupIds = nil
            }
        }
    }
    private var commonFields: [String: Any] = [:]
    private let ruleContext = RuleContext()

    /// 初始化 SDK（建议在 didFinishLaunching 调用）。
    public func start(_ config: Config) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.start(config) }
            return
        }
        guard self.config == nil, config.maxBatchSize > 0, config.maxBatchSize <= 100, config.flushInterval > 0 else { return }
        do { try DeviceInfo.shared.prepare() }
        catch { config.onError?(error); return }
        do {
            _ = try AcquisitionChannel.normalize(config.commonFields["channel"])
        }catch{config.onError?(error);return}
        self.config = config
        startupDeadline = ProcessInfo.processInfo.systemUptime + 60
        self.commonFields = ruleContext.replaceCommon(config.commonFields)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: config.flushInterval, repeats: true) { [weak self] _ in
            self?.flush()
        }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        let installedKey = "mp_installed_" + config.appKey
        if !UserDefaults.standard.bool(forKey: installedKey) {
            if DeviceInfo.shared.isNewInstall { track("app_install") }
            UserDefaults.standard.set(true, forKey: installedKey)
        }
        isForeground = true
        track("app_launch")
        AutoPageTracking.start()
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isForeground else { return }
            self.isForeground = false
            self.track("app_exit")
            self.flush()
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.isForeground else { return }
            self.isForeground = true
            self.track("app_launch")
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isForeground else { return }
            self.isForeground = false
            self.track("app_exit")
            self.flush()
        })
    }

    /// 上报事件；params 可空。
    public func track(_ eventName: String, params: [String: Any] = [:]) {
        if !Thread.isMainThread { DispatchQueue.main.async { self.track(eventName, params: params) }; return }
        guard let config = config else { return }
        var event = DeviceInfo.shared.event(appKey: config.appKey,
                                           eventName: eventName,
                                           params: params)
        let context = ruleContextSnapshot()
        var fields = commonFields.merging(runtimeFields) { _, new in new }
        for (key, eventKey) in RuleContext.eventKeys {
            if key == "adGroup" || key == "adCreative" { fields[eventKey] = context[key] }
            else { event[eventKey] = context[key] }
        }
        event["common_fields"] = fields
        if ProcessInfo.processInfo.systemUptime < startupDeadline, (runtimeFields["user_id"] as? String ?? "").isEmpty, ["app_install", "app_launch", "page_view"].contains(eventName), let id = event["event_id"] as? String { startupIds?.insert(id) }
        store.add(event)
        if store.size() >= config.maxBatchSize { flush() }
    }

    public struct AdImpression {
        fileprivate let appKey: String
        fileprivate let template: [String: Any]
        fileprivate let fields: [String: String]
    }
    /// Invoke once per real impression, before a later paid callback. Each banner refresh is a new impression.
    public func beginAdImpression(inventoryId: String, adNetwork: String, adUnitId: String, impressionId: String = UUID().uuidString) -> AdImpression? {
        if !Thread.isMainThread { return DispatchQueue.main.sync { self.beginAdImpression(inventoryId: inventoryId, adNetwork: adNetwork, adUnitId: adUnitId, impressionId: impressionId) } }
        guard let config = config, [inventoryId, adNetwork, adUnitId, impressionId].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 128 && !$0.unicodeScalars.contains(where: { $0.value < 32 }) }) else { return nil }
        var event = DeviceInfo.shared.event(appKey: config.appKey, eventName: "ad_impression_revenue", params: [:])
        var fields = commonFields.merging(runtimeFields) { _, new in new }
        let context = ruleContextSnapshot()
        for (key, eventKey) in RuleContext.eventKeys {
            if key == "adGroup" || key == "adCreative" { fields[eventKey] = context[key] }
            else { event[eventKey] = context[key] }
        }
        event["common_fields"] = fields
        return AdImpression(appKey: config.appKey, template: event, fields: ["ad_inventory_id": inventoryId, "ad_revenue_network": adNetwork, "ad_revenue_unit_id": adUnitId, "ad_impression_id": impressionId])
    }
    @discardableResult
    public func reportAdRevenue(_ impression: AdImpression, value: String, unit: String, currency: String, precision: String = "estimated") -> Bool {
        if !Thread.isMainThread { return DispatchQueue.main.sync { self.reportAdRevenue(impression, value: value, unit: unit, currency: currency, precision: precision) } }
        guard let config = config, impression.appKey == config.appKey,
              value.range(of: "^[0-9]{1,12}(\\.[0-9]{1,12})?$", options: .regularExpression) != nil,
              ["per_impression", "micros", "ecpm", "bid_cpm"].contains(unit),
              currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
              ["exact", "estimated", "publisher_defined", "unknown"].contains(precision),
              !["ecpm", "bid_cpm"].contains(unit) || precision == "estimated" else { return false }
        let fraction = String(value.split(separator: ".").dropFirst().first ?? "").replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        guard fraction.count <= (unit == "micros" ? 6 : (["ecpm", "bid_cpm"].contains(unit) ? 9 : 12)) else { return false }
        var event = impression.template
        var params: [String: Any] = impression.fields
        params["ad_impression_time_ms"] = event["event_time"]
        params["ad_revenue_value"] = value; params["ad_revenue_unit"] = unit; params["ad_revenue_currency"] = currency; params["ad_revenue_precision"] = precision
        event["event_id"] = UUID().uuidString; event["params"] = params
        store.add(event)
        if store.size() >= config.maxBatchSize { flush() }
        return true
    }

    /// 设置额外公共字段，之后每个事件自动携带。
    public func setCommonFields(_ fields: [String: Any]) {
        if !Thread.isMainThread { DispatchQueue.main.async { self.setCommonFields(fields) }; return }
        commonFields = ruleContext.replaceCommon(fields)
    }

    /// Patch the same fields used by event collection and the next rule request.
    public func setRuleContext(_ fields: [String: Any]) {
        if !Thread.isMainThread { DispatchQueue.main.async { self.setRuleContext(fields) }; return }
        ruleContext.patch(fields)
    }
    internal func ruleContextSnapshot() -> [String: String] {
        return ruleContext.snapshot(deviceLanguage: Locale.current.identifier)
    }

    /// 立即上报。
    public func flush() {
        if !Thread.isMainThread { DispatchQueue.main.async { self.flush() }; return }
        guard !sending, let config = config, store.size() > 0 else { return }
        if let ids = startupIds, !ids.isEmpty {
            if ProcessInfo.processInfo.systemUptime < startupDeadline { return }
            startupIds = nil
        }
        sending = true
        let batch = store.peek(config.maxBatchSize)
        Reporter(endpoint: config.endpoint, tokenProvider: collectionTokenProvider)
            .report(appKey: config.appKey,
                    deviceId: DeviceInfo.shared.deviceId,
                    events: batch) { [weak self] ok in
                if ok { self?.store.remove(batch.count) }
                self?.sending = false
            }
    }
}
