import Foundation

public struct UserCameraEditsFile {
    public let url: URL

    public init(url: URL) { self.url = url }

    public struct LoadResult {
        public let edits: UserCameraEdits
        public let warning: String?
        public let preservedURL: URL?
    }

    public func load() throws -> LoadResult {
        do {
            let edits = try JSONDecoder().decode(UserCameraEdits.self, from: Data(contentsOf: url))
            try edits.validate()
            return LoadResult(edits: edits, warning: nil, preservedURL: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return LoadResult(edits: UserCameraEdits(), warning: nil, preservedURL: nil)
        } catch {
            let preserved = url.deletingLastPathComponent()
                .appendingPathComponent("userCameraEdits.v1.corrupt-\(UUID().uuidString).json")
            do {
                try FileManager.default.moveItem(at: url, to: preserved)
            } catch let preservationError {
                throw UserCameraEdits.EditError.invalid(
                    "我的照相點讀取失敗，且無法保留原檔；暫停編輯以免覆蓋。讀取：\(error.localizedDescription)；保留：\(preservationError.localizedDescription)")
            }
            return LoadResult(edits: UserCameraEdits(),
                warning: "我的照相點讀取失敗，已改名保留原檔（\(preserved.lastPathComponent)）。本次先用原始資料，可重新新增。原因：\(error.localizedDescription)",
                preservedURL: preserved)
        }
    }

    public func save(_ edits: UserCameraEdits) throws {
        try edits.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(edits)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
