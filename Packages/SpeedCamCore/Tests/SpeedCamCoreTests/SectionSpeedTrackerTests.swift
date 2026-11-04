import XCTest
@testable import SpeedCamCore

final class SectionSpeedTrackerTests: XCTestCase {

    /// 區間容許值 0（照表定速限計算），讓既有測試的數字維持不變。
    private func strictSettings() -> AlertSettings {
        var s = AlertSettings()
        s.sectionToleranceKmh = 0
        return s
    }

    /// 從 origin 北方 200 m 開始、往北 3 公里、速限 60 的區間。
    private func section(length: Double = 3_000, limit: Int = 60) -> SpeedSection {
        let start = GeoMath.destination(from: origin, bearing: 0, distance: 200)
        let end = GeoMath.destination(from: start, bearing: 0, distance: length)
        return SpeedSection(id: "s1", name: "測試區間", start: start, end: end,
                            lengthMeters: length, speedLimit: limit)
    }

    func testMilestones() {
        XCTAssertEqual(SectionSpeedTracker.milestones(forMinimumSeconds: 150, finalCountdown: true), [120, 60, 30, 10])
        XCTAssertEqual(SectionSpeedTracker.milestones(forMinimumSeconds: 120, finalCountdown: true), [60, 30, 10])
        XCTAssertEqual(SectionSpeedTracker.milestones(forMinimumSeconds: 185.4, finalCountdown: true), [180, 120, 60, 30, 10])
        XCTAssertEqual(SectionSpeedTracker.milestones(forMinimumSeconds: 45, finalCountdown: true), [30, 10])
        XCTAssertEqual(SectionSpeedTracker.milestones(forMinimumSeconds: 150, finalCountdown: false), [120, 60])
        XCTAssertEqual(SectionSpeedTracker.milestones(forMinimumSeconds: 8, finalCountdown: true), [])
    }

    func testCountdownAnnouncementsAndCompletionWithinLimit() {
        let s = section()
        let tracker = SectionSpeedTracker(sections: [s], settings: strictSettings())
        // 50 km/h：3,000 m 約需 216 秒，比最短 185.4 秒（180 × 1.03）久，倒數會先歸零
        let events = runSections(tracker, straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 260))

        guard case let .entered(_, minSec)? = events.first?.event else {
            return XCTFail("第一個事件應為進入區間：\(events.map { $0.event })")
        }
        XCTAssertEqual(minSec, 186)  // 185.4 無條件進位

        // 起點在北方 200 m，以 13.89 m/s 約 14.4 秒時通過；倒數提醒時間 = 通過時間 + (185.4 - 里程碑)
        let entryTime = 200 / SpeedUnit.mps(fromKmh: 50)
        let remainings = events.compactMap { e -> (Int, TimeInterval)? in
            if case let .remaining(sec) = e.event { return (sec, e.time) }
            return nil
        }
        XCTAssertEqual(remainings.map { $0.0 }, [180, 120, 60, 30, 10])
        for (sec, time) in remainings {
            XCTAssertEqual(time, entryTime + (185.4 - Double(sec)), accuracy: 1.6, "還有 \(sec) 秒的提醒時間不對")
        }

        let zero = events.first { if case .zeroReached = $0.event { return true }; return false }
        XCTAssertNotNil(zero)
        XCTAssertEqual(zero!.time, entryTime + 185.4, accuracy: 1.6)

        guard let last = events.last, case let .completed(_, avg, within) = last.event else {
            return XCTFail("最後應為通過終點：\(events.map { $0.event })")
        }
        XCTAssertEqual(avg, 50, accuracy: 1.5)
        XCTAssertTrue(within)
    }

    func testTooFastNeverReachesZeroAndReportsOverLimit() {
        let tracker = SectionSpeedTracker(sections: [section()], settings: strictSettings())
        let events = runSections(tracker, straightTrack(from: origin, bearing: 0, speedKmh: 80, seconds: 160))
        XCTAssertFalse(events.contains { if case .zeroReached = $0.event { return true }; return false })
        guard let last = events.last, case let .completed(_, avg, within) = last.event else {
            return XCTFail("應該要有通過終點事件")
        }
        XCTAssertEqual(avg, 80, accuracy: 2)
        XCTAssertFalse(within)
    }

    func testStatusShowsCountdownAndSuggestedSpeed() {
        let s = section()
        let tracker = SectionSpeedTracker(sections: [s], settings: strictSettings())
        var statuses: [SectionStatus] = []
        for f in straightTrack(from: origin, bearing: 0, speedKmh: 70, seconds: 100) {
            if let st = tracker.process(f).status { statuses.append(st) }
        }
        XCTAssertFalse(statuses.isEmpty)
        let mid = statuses[statuses.count / 2]
        XCTAssertGreaterThan(mid.remainingSeconds, 0)
        XCTAssertLessThan(mid.suggestedMaxKmh, 60, "開太快之後，建議車速應低於速限")
        XCTAssertEqual(mid.averageKmh, 70, accuracy: 3)
        XCTAssertEqual(mid.earliestExit, mid.startTime.addingTimeInterval(mid.minimumSeconds))
        // 倒數應單調遞減
        let remaining = statuses.map { $0.remainingSeconds }
        XCTAssertEqual(remaining, remaining.sorted(by: >))
    }

    /// 建議時速 = 剩餘距離 ÷ 剩餘最短秒數，以「速限＋容許值」計算，照著開剛好在倒數歸零時到終點。
    func testSuggestedSpeedUsesToleranceAndRemainingDistance() {
        let s = section(length: 3_000, limit: 60)
        let tracker = SectionSpeedTracker(sections: [s], settings: AlertSettings())   // 預設容許值 +10 → 以 70 計算
        var statuses: [SectionStatus] = []
        for f in straightTrack(from: origin, bearing: 0, speedKmh: 85, seconds: 80) {
            if let st = tracker.process(f).status { statuses.append(st) }
        }
        let st = try! XCTUnwrap(statuses.last)
        XCTAssertEqual(st.effectiveLimitKmh, 70)
        let expected = SpeedUnit.kmh(fromMps: st.remainingMeters / st.remainingSeconds)
        XCTAssertEqual(st.suggestedMaxKmh, expected, accuracy: 0.01)
        XCTAssertLessThan(st.suggestedMaxKmh, 70, "開 85 之後，剩下的路要比 70 慢")
        XCTAssertEqual(st.suggestedWholeKmh, Int(expected.rounded(.down)))
        // 照建議時速開完剩下的路，所需時間剛好等於剩餘秒數
        XCTAssertEqual(st.remainingMeters / SpeedUnit.mps(fromKmh: st.suggestedMaxKmh), st.remainingSeconds, accuracy: 0.5)
    }

    func testSuggestedSpeedNeverExceedsEffectiveLimit() {
        let s = section(length: 3_000, limit: 60)
        let tracker = SectionSpeedTracker(sections: [s], settings: AlertSettings())
        var statuses: [SectionStatus] = []
        // 開很慢：剩下的時間不多、距離還很長，算出來會超過 70，但建議不能超過「速限＋容許值」
        for f in straightTrack(from: origin, bearing: 0, speedKmh: 30, seconds: 150) {
            if let st = tracker.process(f).status { statuses.append(st) }
        }
        XCTAssertTrue(statuses.allSatisfy { $0.suggestedMaxKmh <= 70 + 1e-9 })
    }

    func testOppositeDirectionDoesNotEnter() {
        let s = section()
        // 從終點北方往南開，經過起點時方向相反
        let startPoint = GeoMath.destination(from: s.start, bearing: 0, distance: 300)
        let events = runSections(SectionSpeedTracker(sections: [s], settings: strictSettings()),
                                 straightTrack(from: startPoint, bearing: 180, speedKmh: 50, seconds: 60))
        XCTAssertFalse(events.contains { if case .entered = $0.event { return true }; return false })
    }

    func testDefaultToleranceIsTen() {
        // 不指定設定時，預設以「速限＋10」計算：3,000 m ÷ 70 km/h = 154.3 秒 × 1.03 = 158.9 → 159
        let events = runSections(SectionSpeedTracker(sections: [section()]),
                                 straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 30))
        guard case let .entered(_, sec)? = events.first?.event else { return XCTFail() }
        XCTAssertEqual(sec, 159)
    }

    func testPerSectionOverrideAppliesToBothDirections() {
        let start = GeoMath.destination(from: origin, bearing: 0, distance: 200)
        let end = GeoMath.destination(from: start, bearing: 0, distance: 4_100)
        let fwd = SpeedSection(id: "beiyi-1-f", name: "北宜 19K–23.1K（往宜蘭）", start: start, end: end,
                               lengthMeters: 4_100, speedLimit: 40)
        let rev = SpeedSection(id: "beiyi-1-r", name: "北宜 19K–23.1K（往台北）", start: end, end: start,
                               lengthMeters: 4_100, speedLimit: 40)
        XCTAssertEqual(fwd.groupID, "beiyi-1")
        XCTAssertEqual(rev.groupID, "beiyi-1")
        XCTAssertEqual(fwd.displayGroupName, "北宜 19K–23.1K")

        var settings = AlertSettings()          // 預設 +10
        settings.sectionToleranceOverrides = ["beiyi-1": 20]
        XCTAssertEqual(settings.sectionEffectiveLimit(40, sectionID: "beiyi-1"), 60)
        XCTAssertEqual(settings.sectionEffectiveLimit(40, sectionID: "other"), 50)

        // 往宜蘭：4,100 m ÷ 60 km/h = 246 秒 × 1.03 = 253.38 → 254
        let up = runSections(SectionSpeedTracker(sections: [fwd, rev], settings: settings),
                             straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 30))
        guard case let .entered(s1, sec1)? = up.first?.event else { return XCTFail() }
        XCTAssertEqual(s1.id, "beiyi-1-f")
        XCTAssertEqual(sec1, 254)

        // 往台北：同一個群組，同樣以 60 計算
        let beyond = GeoMath.destination(from: end, bearing: 0, distance: 200)
        let down = runSections(SectionSpeedTracker(sections: [fwd, rev], settings: settings),
                               straightTrack(from: beyond, bearing: 180, speedKmh: 50, seconds: 30))
        guard case let .entered(s2, sec2)? = down.first?.event else { return XCTFail() }
        XCTAssertEqual(s2.id, "beiyi-1-r")
        XCTAssertEqual(sec2, 254)
    }

    func testWindingRoadUsesStartHeading() {
        // 山路：起點往東出發，但終點在正北方（直線方向 0°）。
        // 沒有 startHeading 時，往東進入會因為跟直線方向差 90° 以上而無法開始計時；有 startHeading（90°）就能正常開始。
        let start = GeoMath.destination(from: origin, bearing: 90, distance: 200)
        let end = GeoMath.destination(from: start, bearing: 315, distance: 3_000)
        let track = straightTrack(from: origin, bearing: 90, speedKmh: 40, seconds: 40)

        let straightOnly = SpeedSection(id: "w1", name: "山路", start: start, end: end, lengthMeters: 4_000, speedLimit: 40)
        let e1 = runSections(SectionSpeedTracker(sections: [straightOnly], settings: strictSettings()), track)
        XCTAssertFalse(e1.contains { if case .entered = $0.event { return true }; return false })

        let withHeading = SpeedSection(id: "w2", name: "山路", start: start, end: end, lengthMeters: 4_000,
                                       speedLimit: 40, startHeading: 90)
        let e2 = runSections(SectionSpeedTracker(sections: [withHeading], settings: strictSettings()), track)
        XCTAssertTrue(e2.contains { if case .entered = $0.event { return true }; return false })
    }

    func testLeavingSectionAborts() {
        let tracker = SectionSpeedTracker(sections: [section()], settings: strictSettings())
        // 通過起點後 30 秒轉向東邊離開
        let fixes = segmentedTrack(from: origin, segments: [(0, 50, 45), (90, 50, 400)])
        let events = runSections(tracker, fixes)
        XCTAssertTrue(events.contains { if case .entered = $0.event { return true }; return false })
        XCTAssertTrue(events.contains { if case .aborted = $0.event { return true }; return false })
        XCTAssertFalse(events.contains { if case .completed = $0.event { return true }; return false })
    }

    func testSectionToleranceShortensCountdownAndRaisesSuggestedCap() {
        // 北宜型態：表定 40、容許 +10 → 以 50 計算
        var settings = AlertSettings()
        settings.sectionToleranceKmh = 10
        let s = section(length: 4_100, limit: 40)
        let tracker = SectionSpeedTracker(sections: [s], settings: settings)
        var entered: Int?
        var status: SectionStatus?
        for f in straightTrack(from: origin, bearing: 0, speedKmh: 40, seconds: 60) {
            let r = tracker.process(f)
            for e in r.events { if case let .entered(_, sec) = e { entered = sec } }
            if let st = r.status { status = st }
        }
        // 4,100 m ÷ 50 km/h = 295.2 秒，× 1.03 = 304.1 → 305
        XCTAssertEqual(entered, 305)
        XCTAssertEqual(status?.effectiveLimitKmh, 50)
        XCTAssertLessThanOrEqual(status!.suggestedMaxKmh, 50)

        // 容許值 0：以 40 計算 → 4,100 ÷ 40 km/h = 369 秒 × 1.03 = 380.07 → 381
        let strict = SectionSpeedTracker(sections: [s], settings: strictSettings())
        let events = runSections(strict, straightTrack(from: origin, bearing: 0, speedKmh: 40, seconds: 40))
        guard case let .entered(_, sec)? = events.first?.event else { return XCTFail() }
        XCTAssertEqual(sec, 381)
    }

    func testOverspeedInsideSectionBeepsEveryThreeSeconds() {
        var settings = AlertSettings()
        settings.sectionToleranceKmh = 10   // 門檻 50
        let s = section(length: 3_000, limit: 40)
        // 先 45 km/h 進入（不超過 50），之後加速到 60 開 20 秒，再降回 45
        let fixes = segmentedTrack(from: origin, segments: [(0, 45, 40), (0, 60, 20), (0, 45, 20)])
        let events = runSections(SectionSpeedTracker(sections: [s], settings: settings), fixes)
        let started = events.filter { if case .overspeedStarted(50) = $0.event { return true }; return false }
        let beeps = events.filter { $0.event == .overspeedBeep }
        let ended = events.filter { $0.event == .overspeedEnded }
        XCTAssertEqual(started.count, 1)
        XCTAssertTrue((5...7).contains(beeps.count), "beeps=\(beeps.count)")
        XCTAssertEqual(ended.count, 1)
        XCTAssertGreaterThan(ended[0].time, started[0].time)
    }

    func testNoSectionBeepWithinTolerance() {
        var settings = AlertSettings()
        settings.sectionToleranceKmh = 10
        let events = runSections(SectionSpeedTracker(sections: [section(length: 3_000, limit: 40)], settings: settings),
                                 straightTrack(from: origin, bearing: 0, speedKmh: 48, seconds: 120))
        XCTAssertFalse(events.contains { if case .overspeedStarted = $0.event { return true }; return false })
    }

    func testSafetyMarginIsConfigurable() {
        var settings = strictSettings()
        settings.sectionSafetyMargin = 0
        let tracker = SectionSpeedTracker(sections: [section()], settings: settings)
        let events = runSections(tracker, straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 30))
        guard case let .entered(_, minSec)? = events.first?.event else { return XCTFail() }
        XCTAssertEqual(minSec, 180)
    }
}
