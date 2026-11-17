import Foundation

/// 只管理本次開啟 App 的快速記點與確認卡；照相點仍由 UserCameraEdits 儲存。
public struct QuickCameraCapture: Equatable, Sendable {
    public struct Capture: Equatable, Sendable {
        public let camera: Camera
        public let isNew: Bool
    }

    public private(set) var confirmationID: String?
    public private(set) var confirmationExpiresAt: Date?
    public private(set) var minimumLockUntil = Date.distantPast
    private var capturedIDs: Set<String> = []

    public init() {}

    public func canCapture(at now: Date) -> Bool {
        confirmationID == nil && now >= minimumLockUntil
    }

    public static func hasCurrentFix(_ fix: VehicleFix?, at now: Date) -> Bool {
        guard let fix, fix.isReliable, fix.speedMps.isFinite else { return false }
        let age = now.timeIntervalSince(fix.timestamp)
        return age >= 0 && age < 2.5
    }

    public mutating func capture(fix: VehicleFix, lastHeadingFix: VehicleFix?,
                                 edits: inout UserCameraEdits, at now: Date,
                                 id: UUID = UUID()) throws -> Capture {
        guard canCapture(at: now) else {
            throw UserCameraEdits.EditError.invalid("請先完成目前的測速點確認，稍後再新增")
        }
        guard Self.hasCurrentFix(fix, at: now) else {
            throw UserCameraEdits.EditError.invalid("目前沒有可靠定位，無法新增測速點")
        }
        let nearby = edits.added.filter { capturedIDs.contains($0.id) }
            .map { ($0, GeoMath.distance(fix.point, $0.point)) }
            .filter { $0.1 <= 50 }
            .min { $0.1 < $1.1 }?.0
        let camera: Camera
        if let nearby {
            camera = nearby
        } else {
            let heading = UserCameraEdits.suggestedHeading(at: fix.point, isCruising: true,
                lastFix: fix, lastHeadingFix: lastHeadingFix)
            camera = UserCameraEdits.newCamera(at: fix.point, speedLimit: nil, heading: heading, id: id)
            try edits.add(camera, on: now)
            capturedIDs.insert(camera.id)
        }
        confirmationID = camera.id
        confirmationExpiresAt = now.addingTimeInterval(8)
        minimumLockUntil = now.addingTimeInterval(3)
        return Capture(camera: camera, isNew: nearby == nil)
    }

    public mutating func dismissConfirmation() {
        confirmationID = nil
        confirmationExpiresAt = nil
    }

    public mutating func expireConfirmation(at now: Date) {
        if let expiry = confirmationExpiresAt, now >= expiry { dismissConfirmation() }
    }

    public mutating func forget(id: String) {
        capturedIDs.remove(id)
        if confirmationID == id { dismissConfirmation() }
    }
}
