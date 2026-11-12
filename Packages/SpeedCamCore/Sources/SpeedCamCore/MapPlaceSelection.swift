import Foundation

public struct MapPlaceSelection: Sendable {
    public enum Mode: Equatable, Sendable {
        case browsing, navigating, previewing
    }

    public enum SelectionError: LocalizedError {
        case invalidCoordinate
        public var errorDescription: String? { "所選位置的座標無效" }
    }

    public struct Place: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let point: GeoPoint
        public var name: String
        public var address: String?
        public var isResolvingAddress: Bool
        public var addressUnavailable: Bool

        public init(point: GeoPoint, name: String, address: String? = nil,
                    isResolvingAddress: Bool = true, addressUnavailable: Bool = false) {
            id = UUID()
            self.point = point
            self.name = name
            self.address = address
            self.isResolvingAddress = isResolvingAddress
            self.addressUnavailable = addressUnavailable
        }

        public var coordinateText: String { String(format: "%.5f, %.5f", point.lat, point.lon) }
    }

    public private(set) var place: Place?

    public init() {}

    @discardableResult
    public mutating func select(point: GeoPoint, name: String?, mode: Mode) throws -> UUID? {
        guard mode == .browsing else { return nil }
        guard point.lat.isFinite, point.lon.isFinite,
              (-90...90).contains(point.lat), (-180...180).contains(point.lon) else {
            throw SelectionError.invalidCoordinate
        }
        let name = Self.nonempty(name) ?? "所選位置"
        let selected = Place(point: point, name: name)
        place = selected
        return selected.id
    }

    /// 舊查詢晚回來時，不得蓋掉新選點；反查地址也不得挪動原本選到的座標。
    @discardableResult
    public mutating func resolveAddress(id: UUID, name: String?, address: String?) -> Bool {
        guard var current = place, current.id == id else { return false }
        if current.name == "所選位置", let name = Self.nonempty(name) { current.name = name }
        current.address = Self.nonempty(address)
        current.isResolvingAddress = false
        current.addressUnavailable = current.address == nil
        place = current
        return true
    }

    public mutating func takeForPreview(mode: Mode) -> Place? {
        guard mode == .browsing else { return nil }
        let selected = place
        place = nil
        return selected
    }

    public mutating func cancel() {
        place = nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
