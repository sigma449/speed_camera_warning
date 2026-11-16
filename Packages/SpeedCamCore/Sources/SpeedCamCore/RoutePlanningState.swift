import Foundation

/// 把非同步規劃及可採用的路線綁到同一車種與請求，取消後的舊結果不能重新變成可用。
public struct RoutePlanningState: Sendable {
    public struct Request: Equatable, Sendable {
        public let id: UUID
        public let mode: VehicleMode
    }

    public private(set) var request: Request?
    public private(set) var isCalculating = false
    private var isReady = false

    public init() {}

    @discardableResult
    public mutating func begin(mode: VehicleMode) -> Request {
        let next = Request(id: UUID(), mode: mode)
        request = next
        isCalculating = true
        isReady = false
        return next
    }

    public func accepts(_ candidate: Request, currentMode: VehicleMode) -> Bool {
        isCalculating && request == candidate && candidate.mode == currentMode
    }

    @discardableResult
    public mutating func complete(_ candidate: Request, currentMode: VehicleMode) -> Bool {
        guard accepts(candidate, currentMode: currentMode) else { return false }
        isCalculating = false
        isReady = true
        return true
    }

    @discardableResult
    public mutating func fail(_ candidate: Request, currentMode: VehicleMode) -> Bool {
        guard accepts(candidate, currentMode: currentMode) else { return false }
        isCalculating = false
        isReady = false
        return true
    }

    public func canStart(currentMode: VehicleMode) -> Bool {
        isReady && !isCalculating && request?.mode == currentMode
    }

    public mutating func cancel() {
        request = nil
        isCalculating = false
        isReady = false
    }
}
