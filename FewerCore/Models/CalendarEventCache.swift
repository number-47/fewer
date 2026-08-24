import Foundation

/// 日历事件的有限 LRU 缓存，按查询区间存取已映射的 `CalendarEventItem`。
///
/// 滚动时可见区间不断变化，逐行滚动只移动 7 天，
/// 如果用户在相邻区间来回滚动，缓存命中可避免重复查询 EventKit。
/// 缓存条目数有上限，超出后淘汰最久未访问的条目。
/// 事件库变更（`EKEventStoreChanged`）时通过 `clear()` 全部失效。
public struct CalendarEventCache: Sendable {
    private var entries: [Key: [CalendarEventItem]] = [:]
    private var insertionOrder: [Key] = []
    private let maxEntries: Int

    public init(maxEntries: Int = 8) {
        self.maxEntries = max(1, maxEntries)
    }

    /// 按查询区间存入事件列表。相同区间再次插入会更新并提升为最近访问。
    public mutating func insert(_ events: [CalendarEventItem], for range: DateInterval) {
        let key = Key(range)
        if entries[key] != nil {
            insertionOrder.removeAll { $0 == key }
        }
        entries[key] = events
        insertionOrder.append(key)
        while insertionOrder.count > maxEntries {
            let evicted = insertionOrder.removeFirst()
            entries[evicted] = nil
        }
    }

    /// 按查询区间取缓存事件，命中时返回列表、未命中返回 nil。
    public func events(for range: DateInterval) -> [CalendarEventItem]? {
        entries[Key(range)]
    }

    /// 全部失效（事件库变更、权限变更时调用）。
    public mutating func clear() {
        entries.removeAll()
        insertionOrder.removeAll()
    }

    /// 当前缓存条目数（测试用）。
    public var count: Int {
        insertionOrder.count
    }

    private struct Key: Hashable {
        let start: Date
        let end: Date

        init(_ range: DateInterval) {
            self.start = range.start
            self.end = range.end
        }
    }
}
