import XCTest
@testable import SpeedCamCore

final class SectionSpeedTrackerTests: XCTestCase {

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
        let tracker = SectionSpeedTracker(sections: [s])
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
        let tracker = SectionSpeedTracker(sections: [section()])
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
        let tracker = SectionSpeedTracker(sections: [s])
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

    func testOppositeDirectionDoesNotEnter() {
        let s = section()
        // 從終點北方往南開，經過起點時方向相反
        let startPoint = GeoMath.destination(from: s.start, bearing: 0, distance: 300)
        let events = runSections(SectionSpeedTracker(sections: [s]),
                                 straightTrack(from: startPoint, bearing: 180, speedKmh: 50, seconds: 60))
        XCTAssertFalse(events.contains { if case .entered = $0.event { return true }; return false })
    }

    func testWindingRoadUsesStartHeading() {
        // 山路：起點往東出發，但終點在正北方（直線方向 0°）。
        // 沒有 startHeading 時，往東進入會因為跟直線方向差 90° 以上而無法開始計時；有 startHeading（90°）就能正常開始。
        let start = GeoMath.destination(from: origin, bearing: 90, distance: 200)
        let end = GeoMath.destination(from: start, bearing: 315, distance: 3_000)
        let track = straightTrack(from: origin, bearing: 90, speedKmh: 40, seconds: 40)

        let straightOnly = SpeedSection(id: "w1", name: "山路", start: start, end: end, lengthMeters: 4_000, speedLimit: 40)
        let e1 = runSections(SectionSpeedTracker(sections: [straightOnly]), track)
        XCTAssertFalse(e1.contains { if case .entered = $0.event { return true }; return false })

        let withHeading = SpeedSection(id: "w2", name: "山路", start: start, end: end, lengthMeters: 4_000,
                                       speedLimit: 40, startHeading: 90)
        let e2 = runSections(SectionSpeedTracker(sections: [withHeading]), track)
        XCTAssertTrue(e2.contains { if case .entered = $0.event { return true }; return false })
    }

    func testLeavingSectionAborts() {
        let tracker = SectionSpeedTracker(sections: [section()])
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
        let strict = SectionSpeedTracker(sections: [s])
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
        var settings = AlertSettings()
        settings.sectionSafetyMargin = 0
        let tracker = SectionSpeedTracker(sections: [section()], settings: settings)
        let events = runSections(tracker, straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 30))
        guard case let .entered(_, minSec)? = events.first?.event else { return XCTFail() }
        XCTAssertEqual(minSec, 180)
    }
}
