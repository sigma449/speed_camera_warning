import Foundation

public struct UserCameraDirection: Codable, Hashable, Sendable {
    public var heading: Double?
    public var axis: Double?

    public init(heading: Double? = nil, axis: Double? = nil) {
        self.heading = heading
        self.axis = axis
    }

    public init(camera: Camera) {
        heading = camera.heading
        axis = camera.heading == nil ? camera.axis : nil
    }

    public var description: String {
        if let heading, heading.isFinite {
            let names = ["北", "東北", "東", "東南", "南", "西南", "西", "西北"]
            let index = Int((GeoMath.normalize(heading) + 22.5) / 45) % 8
            return "往\(names[index])（\(Self.decimal(heading))°）"
        }
        switch axis {
        case 0: return "南北雙向"
        case 45: return "東北–西南雙向"
        case 90: return "東西雙向"
        case 135: return "西北–東南雙向"
        case let value? where value.isFinite: return "雙向（軸向 \(Self.decimal(value))°）"
        default: return "不確定"
        }
    }

    public func apply(to camera: inout Camera) {
        camera.heading = heading
        camera.axis = axis
    }

    static func decimal(_ value: Double) -> String {
        if value == 0 { return "0" }
        var text = String(format: "%.10f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}

public struct UserCameraOverride: Codable, Equatable, Sendable {
    /// nil 表示不覆寫；不確定方向以 direction 的空 heading／axis 表達。
    public var speedLimit: Int?
    public var direction: UserCameraDirection?

    public init(speedLimit: Int? = nil, direction: UserCameraDirection? = nil) {
        self.speedLimit = speedLimit
        self.direction = direction
    }

    public func apply(to original: Camera) -> Camera {
        guard original.type != .section else { return original }
        var camera = original
        if original.enforcesSpeed, let speedLimit { camera.speedLimit = speedLimit }
        direction?.apply(to: &camera)
        return camera
    }
}

public struct UserCameraEdits: Codable, Equatable, Sendable {
    public var added: [Camera]
    public var hidden: [String]
    public var modified: [String: UserCameraOverride]
    public var addedOn: [String: String]
    /// 資料更新後 id 消失時，仍可匯出當初核對的原值。
    public var originals: [String: Camera]

    public init(added: [Camera] = [], hidden: [String] = [],
                modified: [String: UserCameraOverride] = [:],
                addedOn: [String: String] = [:], originals: [String: Camera] = [:]) {
        self.added = added
        self.hidden = hidden
        self.modified = modified
        self.addedOn = addedOn
        self.originals = originals
    }

    private enum CodingKeys: String, CodingKey { case added, hidden, modified, addedOn, originals }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        added = try c.decode([Camera].self, forKey: .added)
        hidden = try c.decode([String].self, forKey: .hidden)
        modified = try c.decode([String: UserCameraOverride].self, forKey: .modified)
        addedOn = try c.decodeIfPresent([String: String].self, forKey: .addedOn) ?? [:]
        originals = try c.decodeIfPresent([String: Camera].self, forKey: .originals) ?? [:]
    }

    public var isEmpty: Bool { added.isEmpty && hidden.isEmpty && modified.isEmpty }

    public func apply(to cameras: [Camera]) -> [Camera] {
        guard !isEmpty else { return cameras }
        let hiddenIDs = Set(hidden)
        let official = cameras.compactMap { camera -> Camera? in
            guard camera.type != .section else { return camera }
            guard !hiddenIDs.contains(camera.id) else { return nil }
            return modified[camera.id]?.apply(to: camera) ?? camera
        }
        return official + added.filter { !hiddenIDs.contains($0.id) }
    }

    public mutating func add(_ camera: Camera, on date: Date = Date()) throws {
        guard !added.contains(where: { $0.id == camera.id }) else {
            throw EditError.invalid("自行新增的照相點 id 重複")
        }
        try Self.validateAdded(camera)
        added.append(camera)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        addedOn[camera.id] = formatter.string(from: date)
    }

    public mutating func updateAdded(_ camera: Camera) throws {
        guard let index = added.firstIndex(where: { $0.id == camera.id }) else {
            throw EditError.invalid("找不到要修改的自行新增照相點")
        }
        try Self.validateAdded(camera)
        added[index] = camera
    }

    @discardableResult
    public mutating func resolveAddedAddress(id: String, point: GeoPoint, address: String) throws -> Bool {
        guard var camera = added.first(where: { $0.id == id && $0.point == point }),
              camera.address == Self.coordinateAddress(point) else { return false }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return false }
        camera.address = address
        try updateAdded(camera)
        return true
    }

    public mutating func modify(_ original: Camera, speedLimit: Int?,
                                direction: UserCameraDirection) throws {
        guard original.type != .section else { throw EditError.invalid("區間照相點不可修改") }
        var override = UserCameraOverride()
        if original.enforcesSpeed, speedLimit != original.speedLimit {
            guard let speedLimit, Self.speedLimits.contains(speedLimit) else {
                throw EditError.invalid("速限須為 30～110，每 10 一格")
            }
            override.speedLimit = speedLimit
        }
        if direction != UserCameraDirection(camera: original) { override.direction = direction }
        try Self.validateDirection(direction)
        if override == UserCameraOverride() {
            restoreOriginal(id: original.id)
        } else {
            modified[original.id] = override
            originals[original.id] = original
        }
    }

    public mutating func hide(_ original: Camera) throws {
        guard original.type != .section else { throw EditError.invalid("區間照相點不可隱藏") }
        guard !added.contains(where: { $0.id == original.id }) else {
            throw EditError.invalid("自行新增的照相點請使用刪除")
        }
        if !hidden.contains(original.id) { hidden.append(original.id) }
        originals[original.id] = original
    }

    public mutating func unhide(id: String) {
        hidden.removeAll { $0 == id }
        discardUnusedOriginal(id: id)
    }

    public mutating func restoreOriginal(id: String) {
        modified[id] = nil
        discardUnusedOriginal(id: id)
    }

    public mutating func deleteAdded(id: String) {
        added.removeAll { $0.id == id }
        addedOn[id] = nil
    }

    private mutating func discardUnusedOriginal(id: String) {
        if modified[id] == nil && !hidden.contains(id) { originals[id] = nil }
    }

    public static let speedLimits = Array(stride(from: 30, through: 110, by: 10))
    public static let unknownDirectionExplanation = "未知方向依正前方 30° 判斷，已追蹤且距離小於 30 公尺時放寬。"
    public static let unsetSpeedLimitDescription = "速限未設・只提醒不嗶"

    public static func coordinateAddress(_ point: GeoPoint) -> String {
        String(format: "自行新增（%.5f, %.5f）", point.lat, point.lon)
    }

    public static func newCamera(at point: GeoPoint, address: String? = nil, speedLimit: Int? = 50,
                                 heading: Double? = nil, id: UUID = UUID()) -> Camera {
        Camera(id: "user-\(id.uuidString)", type: .fixed, lat: point.lat, lon: point.lon,
               heading: heading, speedLimit: speedLimit, address: address ?? coordinateAddress(point),
               source: "自行新增", positionMethod: "user")
    }

    public static func suggestedHeading(at point: GeoPoint, isCruising: Bool,
                                        lastFix: VehicleFix?, lastHeadingFix: VehicleFix?) -> Double? {
        guard isCruising, let lastFix, lastFix.isReliable,
              let headingFix = lastHeadingFix, headingFix.isReliable,
              headingFix.speedMps.isFinite, headingFix.speedKmh >= 8,
              let heading = headingFix.course, heading.isFinite, heading >= 0,
              GeoMath.distance(lastFix.point, point) <= 150 else { return nil }
        return GeoMath.normalize(heading)
    }

    public func validate() throws {
        guard Set(added.map(\.id)).count == added.count else {
            throw EditError.invalid("自行新增的照相點 id 重複")
        }
        guard Set(hidden).count == hidden.count,
              !hidden.contains(where: \.isEmpty), !modified.keys.contains(where: \.isEmpty) else {
            throw EditError.invalid("隱藏或修改清單的 id 無效")
        }
        for camera in added { try Self.validateAdded(camera) }
        for override in modified.values {
            if let limit = override.speedLimit, !Self.speedLimits.contains(limit) {
                throw EditError.invalid("覆寫速限無效")
            }
            if let direction = override.direction { try Self.validateDirection(direction) }
        }
        for (id, camera) in originals {
            guard id == camera.id else { throw EditError.invalid("原始照相點 id 不一致") }
            try Self.validatePoint(camera.point)
        }
    }

    private static func validateAdded(_ camera: Camera) throws {
        guard camera.id.hasPrefix("user-"), UUID(uuidString: String(camera.id.dropFirst(5))) != nil,
              [.fixed, .redLight].contains(camera.type),
              camera.source == "自行新增", camera.positionMethod == "user",
              !camera.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              camera.enforcementItems == nil,
              (camera.type == .fixed ? camera.speedLimit.map(speedLimits.contains) ?? true : camera.speedLimit == nil)
        else { throw EditError.invalid("自行新增的照相點格式無效") }
        try validatePoint(camera.point)
        try validateDirection(UserCameraDirection(heading: camera.heading, axis: camera.axis))
    }

    private static func validatePoint(_ point: GeoPoint) throws {
        guard point.lat.isFinite, point.lon.isFinite,
              (-90...90).contains(point.lat), (-180...180).contains(point.lon) else {
            throw EditError.invalid("照相點座標無效")
        }
    }

    private static func validateDirection(_ direction: UserCameraDirection) throws {
        guard direction.heading == nil || direction.axis == nil,
              direction.heading.map({ $0.isFinite && (0..<360).contains($0) }) ?? true,
              direction.axis.map({ $0.isFinite && (0..<180).contains($0) }) ?? true else {
            throw EditError.invalid("取締方向無效")
        }
    }

    public enum EditError: LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case let .invalid(message): return message }
        }
    }
}
