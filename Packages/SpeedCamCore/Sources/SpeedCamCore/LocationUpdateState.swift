import Foundation

/// 定位工作退出後至少等五秒；停止需求或失去權限時不重新啟動。
public struct LocationUpdateState: Sendable {
    public private(set) var isRequested = false
    public private(set) var generation: UUID?
    private var nextStart = Date.distantPast

    public init() {}

    public mutating func request() {
        isRequested = true
    }

    public mutating func beginIfNeeded(now: Date, isAuthorized: Bool) -> UUID? {
        guard isRequested, isAuthorized, generation == nil, now >= nextStart else { return nil }
        let next = UUID()
        generation = next
        return next
    }

    @discardableResult
    public mutating func finish(_ candidate: UUID, now: Date) -> Bool {
        guard generation == candidate else { return false }
        generation = nil
        nextStart = now.addingTimeInterval(5)
        return true
    }

    public mutating func stop() {
        isRequested = false
        generation = nil
        nextStart = .distantPast
    }
}
