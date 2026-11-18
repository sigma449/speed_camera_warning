import Foundation

public struct UserCameraEditsFile {
    public let url: URL
    private let read: (URL) throws -> Data

    /// read 只給測試模擬「檔案在但讀不到」（例如重開機後尚未解鎖、資料保護中）。
    public init(url: URL, read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.url = url
        self.read = read
    }

    public struct LoadResult {
        public let edits: UserCameraEdits
        public let warning: String?
        public let preservedURL: URL?
    }

    public func load() throws -> LoadResult {
        let data: Data
        do {
            data = try read(url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return LoadResult(edits: UserCameraEdits(), warning: nil, preservedURL: nil)
        }
        // 讀不到（權限、資料保護、暫時性 I/O）不是壞檔：上面直接丟出，App 會暫停編輯，
        // 不改名也不覆蓋；只有讀到內容卻無法解碼或驗證時，才把原檔改名保留。
        do {
            let edits = try JSONDecoder().decode(UserCameraEdits.self, from: data)
            try edits.validate()
            return LoadResult(edits: edits, warning: nil, preservedURL: nil)
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
