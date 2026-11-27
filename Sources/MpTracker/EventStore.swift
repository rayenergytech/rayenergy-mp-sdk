import Foundation

/// 离线事件队列：持久化到 UserDefaults；失败保留、成功删除。
final class EventStore {

    private let key = "mp_track_queue"
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func add(_ event: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        var arr = load()
        arr.append(event)
        save(arr)
    }

    func bindStartup(_ ids: Set<String>, userId: String) {
        lock.lock(); defer { lock.unlock() }
        let events = load().map { event -> [String: Any] in
            guard let id = event["event_id"] as? String, ids.contains(id) else { return event }
            var result = event
            var fields = event["common_fields"] as? [String: Any] ?? [:]
            if (fields["user_id"] as? String ?? "").isEmpty { fields["user_id"] = userId; result["common_fields"] = fields }
            return result
        }
        save(events)
    }

    func peek(_ max: Int) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let arr = load()
        return Array(arr.prefix(max))
    }

    func remove(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        var arr = load()
        if count <= arr.count {
            arr.removeFirst(count)
        } else {
            arr.removeAll()
        }
        save(arr)
    }

    func size() -> Int {
        lock.lock(); defer { lock.unlock() }
        return load().count
    }

    private func load() -> [[String: Any]] {
        (defaults.array(forKey: key) as? [[String: Any]]) ?? []
    }
    private func save(_ arr: [[String: Any]]) {
        defaults.set(arr, forKey: key)
    }
}
