import Foundation

/// 搜尋與候選選取共用世代；相同文字重新搜尋或重新開啟畫面，也不能接回舊結果。
public struct SearchRequestState: Sendable {
    public struct Request: Equatable, Sendable {
        public let id: UUID
        public let query: String
    }

    public private(set) var isPresented = false
    private var query = ""
    private var request: Request?

    public init() {}

    public mutating func present(query: String) {
        isPresented = true
        self.query = query
        request = nil
    }

    @discardableResult
    public mutating func updateQuery(_ value: String) -> Bool {
        guard query != value else { return false }
        query = value
        request = nil
        return true
    }

    public mutating func begin(query: String) -> Request? {
        guard isPresented else { return nil }
        self.query = query
        let next = Request(id: UUID(), query: query)
        request = next
        return next
    }

    public func accepts(_ candidate: Request, currentQuery: String) -> Bool {
        isPresented && request == candidate && candidate.query == query && query == currentQuery
    }

    @discardableResult
    public mutating func finish(_ candidate: Request) -> Bool {
        guard isPresented, request == candidate else { return false }
        request = nil
        return true
    }

    public mutating func invalidate() {
        request = nil
    }

    public mutating func dismiss() {
        isPresented = false
        invalidate()
    }
}
