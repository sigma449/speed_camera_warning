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

    func testLeavingSectionAborts() {
        let tracker = SectionSpeedTracker(sections: [section()])
        // 通過起點後 30 秒轉向東邊離開
        let fixes = segmentedTrack(from: origin, segments: [(0, 50, 45), (90, 50, 400)])
        let events = runSections(tracker, fixes)
        XCTAssertTrue(events.contains { if case .entered = $0.event { return true }; return false })
        XCTAssertTrue(events.contains { if case .aborted = $0.event { return true }; return false })
        XCTAssertFalse(events.contains { if case .completed = $0.event { return true }; return false })
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
