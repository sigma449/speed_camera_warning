import Foundation

public struct UserCameraExport {
    public let csv: String
    public let json: Data

    public struct ReviewRecord: Codable {
        public let id: String
        public let shortAddress: String?
        public let lat: Double?
        public let lon: Double?
        public let original: Camera?
        public let newValue: Camera?
        public let override: UserCameraOverride?
        public let missingFromDatabase: Bool

        private enum CodingKeys: String, CodingKey {
            case id, shortAddress, lat, lon, original, newValue, override, missingFromDatabase
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(shortAddress, forKey: .shortAddress)
            try c.encode(lat, forKey: .lat)
            try c.encode(lon, forKey: .lon)
            try c.encode(original, forKey: .original)
            try c.encode(newValue, forKey: .newValue)
            try c.encode(override, forKey: .override)
            try c.encode(missingFromDatabase, forKey: .missingFromDatabase)
        }
    }

    public struct Review: Codable {
        public let added: [Camera]
        public let addedOn: [String: String]
        public let speedLimitUnsetIDs: [String]
        public let hidden: [ReviewRecord]
        public let modified: [ReviewRecord]
        public let notes: [String]
    }

    public static let csvHeader = "設置地點,座標緯度,座標經度,拍攝方向,速限,取締項目,縣市,行政區,來源"
    public static let diagonalAxisNote = "CSV 管線僅支援南北／東西雙向；其他軸向匯出為雙向、未指定軸向，精確值保留於 camera_edits.json，正式併入前須人工核對。"
    public static let unsetSpeedLimitNote = "固定測速的空白速限表示速限未設，只提醒不嗶；不可推定為 0 或其他速限。"

    public init(edits: UserCameraEdits, originals: [Camera]) throws {
        try edits.validate()
        var rows = [Self.csvHeader]
        for camera in edits.added {
            let fields = [
                camera.address, UserCameraDirection.decimal(camera.lat), UserCameraDirection.decimal(camera.lon),
                Self.csvDirection(camera), camera.speedLimit.map(String.init) ?? "",
                camera.type.displayName, camera.city ?? "", camera.district ?? "",
                "使用者於 App 自行新增（\(edits.addedOn[camera.id] ?? "日期未記錄")）"
                    + (camera.enforcesSpeed && camera.speedLimit == nil ? "・速限未設" : ""),
            ]
            rows.append(fields.map(Self.escape).joined(separator: ","))
        }
        csv = rows.joined(separator: "\n") + "\n"

        let current = Dictionary(originals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func record(_ id: String, hidden: Bool) -> ReviewRecord {
            let original = current[id] ?? edits.originals[id]
            let override = edits.modified[id]
            return ReviewRecord(id: id, shortAddress: original?.shortAddress, lat: original?.lat,
                lon: original?.lon, original: original,
                newValue: hidden ? nil : original.map { override?.apply(to: $0) ?? $0 },
                override: override, missingFromDatabase: current[id] == nil)
        }
        let review = Review(added: edits.added, addedOn: edits.addedOn,
            speedLimitUnsetIDs: edits.added.filter { $0.enforcesSpeed && $0.speedLimit == nil }.map(\.id),
            hidden: edits.hidden.sorted().map { record($0, hidden: true) },
            modified: edits.modified.keys.sorted().map { record($0, hidden: false) },
            notes: [Self.diagonalAxisNote, Self.unsetSpeedLimitNote])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        json = try encoder.encode(review)
    }

    private static func csvDirection(_ camera: Camera) -> String {
        if let heading = camera.heading {
            let rounded = UserCameraDirection.decimal(heading)
            return "\(rounded == "360" ? "0" : rounded)°"
        }
        switch camera.axis {
        case 0: return "南北雙向"
        case 90: return "東西雙向"
        case let axis?: return "雙向（軸向\(UserCameraDirection.decimal(axis))°；詳 camera_edits.json）"
        default: return ""
        }
    }

    private static func escape(_ text: String) -> String {
        guard text.contains(where: { ",\"\r\n".contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
