import Foundation

/// 把事件轉成要念出來的中文句子（台灣用語）。放在 Core 裡，方便寫單元測試。
public enum AnnouncementFormatter {

    /// 距離的口語說法：1000 公尺以上用「公里」，以下四捨五入到 10 公尺。
    public static func spokenDistance(_ meters: Double) -> String {
        if meters >= 1_000 {
            let km = (meters / 100).rounded() / 10
            if km == km.rounded() { return "\(Int(km))公里" }
            return String(format: "%.1f公里", km)
        }
        let rounded = Int((meters / 10).rounded()) * 10
        return "\(max(10, rounded))公尺"
    }

    /// 畫面顯示用的距離（例如「280m」「1.2km」）。
    public static func displayDistance(_ meters: Double) -> String {
        if meters >= 1_000 {
            return String(format: "%.1fkm", meters / 1_000)
        }
        return "\(Int((meters / 10).rounded()) * 10)m"
    }

    /// 預告與近距播報時使用門檻距離（300、100…），比念實際的 296 公尺自然。
    public static func cameraAlert(camera: Camera, announcedDistance: Double) -> String {
        var text = "前方\(spokenDistance(announcedDistance))，\(camera.alertDescription)"
        if let limit = camera.speedLimit, camera.enforcesSpeed {
            text += "，速限\(limit)"
        }
        return text
    }

    /// 已預告的近距提醒：讀當下狀態合成一句，避免兩句緊急語音互切。
    public static func cameraNearAfterPre(announcedDistance: Double, isOverspeed: Bool = false) -> String {
        spokenDistance(announcedDistance) + (isOverspeed ? "，超速" : "")
    }

    public static func announcedDistance(_ distance: Double, threshold: Double) -> Double {
        distance >= threshold - 40 ? threshold : distance
    }

    /// 接近區間起點的預告。
    public static func sectionApproaching(section: SpeedSection, announcedDistance: Double) -> String {
        "前方\(spokenDistance(announcedDistance))，進入區間測速，速限\(section.speedLimit)"
    }

    public static func overspeed(limit: Int) -> String {
        "您已超速，速限\(limit)"
    }

    /// effectiveLimitKmh：計算倒數用的時速（速限＋區間容許值）；比速限高時會一併念出來。
    public static func sectionEntered(section: SpeedSection, minimumSeconds: Int,
                                      effectiveLimitKmh: Double? = nil) -> String {
        let km = section.lengthMeters / 1_000
        let kmText = km == km.rounded() ? "\(Int(km))" : String(format: "%.1f", km)
        var text = "進入區間測速，全長\(kmText)公里，速限\(section.speedLimit)"
        if let eff = effectiveLimitKmh, Int(eff.rounded()) > section.speedLimit {
            text += "，以時速\(Int(eff.rounded()))計算"
        }
        return text + "，至少需要\(minimumSeconds)秒"
    }

    public static func sectionOverspeed(threshold: Int) -> String {
        "區間測速，車速超過\(threshold)"
    }

    /// suggestedKmh：依剩餘距離算出的建議時速（剩下的路照這個時速以下開，平均就不會超過速限＋容許值）。
    public static func sectionRemaining(seconds: Int, suggestedKmh: Int? = nil) -> String {
        var text = "區間測速，還有\(seconds)秒"
        if let kmh = suggestedKmh, kmh > 0 {
            text += "，建議時速\(kmh)以下"
        }
        return text
    }

    public static let sectionZero = "區間時間已到，可依速限行駛"

    public static func sectionCompleted(averageKmh: Double, withinLimit: Bool) -> String {
        let avg = Int(averageKmh.rounded())
        return withinLimit ? "區間測速結束，平均時速\(avg)" : "區間測速結束，平均時速\(avg)，可能超速"
    }

    public static func maneuver(instruction: String, distance: Int?) -> String {
        guard let d = distance else { return instruction }
        return "\(spokenDistance(Double(d)))後，\(instruction)"
    }

    public static let arrived = "已抵達目的地"
    public static let rerouting = "已偏離路線，重新規劃中"
}
