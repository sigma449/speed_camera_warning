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
        // 短的區間：進入的語音還沒念完，不要馬上接「還有 30 秒」
        XCTAssertEqual(SectionSpeedTracker.milestones(forMinimumSeconds: 31, finalCountdown: true), [10])
        XCTAssertEqual(SectionSpeedTracker.milestones(forMinimumSeconds: 15, finalCountdown: true), [])
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

    func testOverspeedInsideSectionBeepsEveryFifteenSeconds() {
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
        XCTAssertEqual(beeps.count, 2, "開始與第 15 秒各一聲")
        XCTAssertEqual(beeps[1].time - beeps[0].time, 15, accuracy: 0.01)
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

    // MARK: - 預告（實測：自強隧道、台64 都是進去之後才提醒）

    private func approachEvents(_ events: [TimedEvent<SectionEvent>]) -> [(time: TimeInterval, distance: Double)] {
        events.compactMap { e in
            if case let .approaching(_, d) = e.event { return (e.time, d) }
            return nil
        }
    }

    /// 起點在 origin 北方 1 km、往北的區間。
    private func distantSection(limit: Int = 60) -> SpeedSection {
        let start = GeoMath.destination(from: origin, bearing: 0, distance: 1_000)
        return SpeedSection(id: "far", name: "測試區間", start: start,
                            end: GeoMath.destination(from: start, bearing: 0, distance: 3_000),
                            lengthMeters: 3_000, speedLimit: limit)
    }

    func testApproachAnnouncedOnceBeforeEnteringAt300Meters() {
        let tracker = SectionSpeedTracker(sections: [distantSection()], settings: strictSettings())
        let events = runSections(tracker, straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 120),
                                 includeApproach: true)
        let approach = approachEvents(events)
        XCTAssertEqual(approach.count, 1, "只預告一次")
        XCTAssertEqual(approach[0].distance, 300, accuracy: 15)
        guard let entered = events.first(where: { if case .entered = $0.event { return true }; return false }) else {
            return XCTFail("應該要進入區間")
        }
        // 50 km/h = 13.9 m/s：預告到進入約 300 m ≈ 21 秒
        XCTAssertEqual(entered.time - approach[0].time, 21.6, accuracy: 2)
    }

    func testApproachUsesLongerDistanceOnFastRoads() {
        let tracker = SectionSpeedTracker(sections: [distantSection(limit: 90)], settings: strictSettings())
        let events = runSections(tracker, straightTrack(from: origin, bearing: 0, speedKmh: 90, seconds: 60),
                                 includeApproach: true)
        XCTAssertEqual(approachEvents(events).first?.distance ?? 0, 600, accuracy: 30)
    }

    func testApproachStatusShownUntilEntered() {
        let tracker = SectionSpeedTracker(sections: [distantSection()], settings: strictSettings())
        var approaches: [SectionApproach] = []
        var statusSeen = false
        for f in straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 100) {
            let r = tracker.process(f)
            if let a = r.approach {
                XCTAssertFalse(statusSeen, "進入區間之後就不該再顯示接近中")
                approaches.append(a)
            }
            if r.status != nil { statusSeen = true }
        }
        XCTAssertGreaterThan(approaches.count, 10)
        XCTAssertLessThan(approaches.last!.distance, approaches.first!.distance)
        XCTAssertEqual(approaches.first!.asCameraTarget.camera.speedLimit, 60)
    }

    func testNoApproachFromOppositeOrCrossDirection() {
        let s = distantSection()
        // 反方向：從區間裡面往南開，經過起點
        let beyond = GeoMath.destination(from: s.start, bearing: 0, distance: 400)
        let opposite = runSections(SectionSpeedTracker(sections: [s], settings: strictSettings()),
                                   straightTrack(from: beyond, bearing: 180, speedKmh: 50, seconds: 60), includeApproach: true)
        XCTAssertTrue(approachEvents(opposite).isEmpty)
        // 橫向：從起點西邊 400 m 往東開，橫越起點
        let west = GeoMath.destination(from: s.start, bearing: 270, distance: 400)
        let cross = runSections(SectionSpeedTracker(sections: [s], settings: strictSettings()),
                                straightTrack(from: west, bearing: 90, speedKmh: 50, seconds: 60), includeApproach: true)
        XCTAssertTrue(approachEvents(cross).isEmpty)
    }

    func testApproachClearedAfterTurningAway() {
        let tracker = SectionSpeedTracker(sections: [distantSection()], settings: strictSettings())
        // 往北開到離起點約 200 m，然後右轉離開
        var last: SectionApproach?
        var seen = false
        for f in segmentedTrack(from: origin, segments: [(0, 36, 80), (90, 36, 60)]) {
            let r = tracker.process(f)
            if r.approach != nil { seen = true }
            last = r.approach
            XCTAssertTrue(r.events.allSatisfy { if case .entered = $0 { return false }; return true })
        }
        XCTAssertTrue(seen)
        XCTAssertNil(last, "轉彎離開之後不該還顯示接近區間")
    }

    // MARK: - 沒有經過起點的判定範圍

    /// 匝道在起點之後才併入：第一筆定位就已經在區間裡，一樣算進入，開始時間往回推。
    func testEntersWhenFirstSeenShortlyAfterStart() {
        let s = distantSection()
        // 從起點東邊的匝道往西北併入，到起點北方 150 m
        let onPath = GeoMath.destination(from: s.start, bearing: 0, distance: 150)
        let ramp = GeoMath.destination(from: onPath, bearing: 90, distance: 300)
        let fixes = segmentedTrack(from: ramp, segments: [(270, 50, 21), (0, 50, 30)])
        let tracker = SectionSpeedTracker(sections: [s], settings: strictSettings())
        var startTime: Date?
        for f in fixes {
            if let st = tracker.process(f).status, startTime == nil { startTime = st.startTime }
        }
        let start = try! XCTUnwrap(startTime, "應該要算進入區間")
        // 併入點是第 21 秒左右，往回推約 150 m ≈ 11 秒
        XCTAssertLessThan(start.timeIntervalSince(t0), 21)
    }

    /// GPS 從起點前 150 m 直接跳到起點後 100 m（隧道口常見），沒有定位落在 60 m 判定範圍裡。
    func testEntersWhenGpsJumpsOverGate() {
        let s = distantSection()
        let tracker = SectionSpeedTracker(sections: [s], settings: strictSettings())
        var entered = false
        let before = GeoMath.destination(from: s.start, bearing: 180, distance: 150)
        let after = GeoMath.destination(from: s.start, bearing: 0, distance: 100)
        let mps = SpeedUnit.mps(fromKmh: 50)
        for (i, p) in [before, after].enumerated() {
            let f = VehicleFix(point: p, speedMps: mps, course: 0, timestamp: t0.addingTimeInterval(Double(i) * 18))
            entered = entered || tracker.process(f).events.contains { if case .entered = $0 { return true }; return false }
        }
        XCTAssertTrue(entered)
    }

    func testDoesNotEnterMidSection() {
        // 離起點 1 km 才上路（交流道從區間中段上來）：照相機沒拍到起點，不算進入
        let s = distantSection()
        let mid = GeoMath.destination(from: s.start, bearing: 0, distance: 1_000)
        let events = runSections(SectionSpeedTracker(sections: [s], settings: strictSettings()),
                                 straightTrack(from: mid, bearing: 0, speedKmh: 50, seconds: 30))
        XCTAssertFalse(events.contains { if case .entered = $0.event { return true }; return false })
    }

    // MARK: - 隧道裡沒有定位

    /// 定位在隧道口前 100 m 中斷：依車速推算經過起點的時間，倒數和語音繼續，出隧道後接回定位。
    func testTunnelWithoutGpsKeepsCountingDown() {
        // 900 m 隧道，速限 50（容許值 0）：900 ÷ 13.89 × 1.03 = 66.7 秒
        let start = GeoMath.destination(from: origin, bearing: 0, distance: 500)
        let end = GeoMath.destination(from: start, bearing: 0, distance: 900)
        let s = SpeedSection(id: "tunnel-f", name: "隧道（往北）", start: start, end: end, lengthMeters: 900, speedLimit: 50)
        let tracker = SectionSpeedTracker(sections: [s], settings: strictSettings())
        let mps = SpeedUnit.mps(fromKmh: 50)
        let all = straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 110)
        var events: [TimedEvent<SectionEvent>] = []
        var statuses: [SectionStatus] = []
        for (i, f) in all.enumerated() {
            let along = mps * Double(i)
            let now = f.timestamp
            // 隧道口前 100 m 到隧道口後 30 m 沒有定位
            if along > 400 && along < 1_430 {
                if let r = tracker.tick(now: now) {
                    for e in r.events { events.append(TimedEvent(time: now.timeIntervalSince(t0), event: e)) }
                    if let st = r.status { statuses.append(st) }
                }
                continue
            }
            let r = tracker.process(f)
            for e in r.events { events.append(TimedEvent(time: now.timeIntervalSince(t0), event: e)) }
        }
        guard let entered = events.first(where: { if case .entered = $0.event { return true }; return false }) else {
            return XCTFail("沒有定位也要進入區間：\(events.map { $0.event })")
        }
        XCTAssertEqual(entered.time, 500 / mps, accuracy: 2, "應該在經過隧道口的時間進入")
        XCTAssertFalse(statuses.isEmpty, "隧道裡畫面的倒數要繼續")
        XCTAssertEqual(statuses.last!.remainingMeters, max(0, 900 - mps * statuses.last!.elapsed), accuracy: 30)
        let remaining = events.compactMap { e -> Int? in
            if case let .remaining(sec) = e.event { return sec }
            return nil
        }
        XCTAssertEqual(remaining, [60, 30, 10])
        XCTAssertTrue(events.contains { $0.event == .zeroReached })
    }

    func testTickDoesNothingWhileGpsIsFine() {
        let tracker = SectionSpeedTracker(sections: [section()], settings: strictSettings())
        for f in straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 30) {
            _ = tracker.process(f)
            XCTAssertNil(tracker.tick(now: f.timestamp.addingTimeInterval(1)))
        }
    }

    func testTickDoesNotEnterWhenStopped() {
        let start = GeoMath.destination(from: origin, bearing: 0, distance: 200)
        let s = SpeedSection(id: "t", name: "t", start: start,
                             end: GeoMath.destination(from: start, bearing: 0, distance: 900),
                             lengthMeters: 900, speedLimit: 50)
        let tracker = SectionSpeedTracker(sections: [s], settings: strictSettings())
        _ = tracker.process(VehicleFix(point: origin, speedMps: 10, course: 0, timestamp: t0))
        // 塞車停在隧道口前：沒有車速就不推算
        _ = tracker.process(VehicleFix(point: origin, speedMps: 0, course: 0, timestamp: t0.addingTimeInterval(1)))
        let result = tracker.tick(now: t0.addingTimeInterval(60))
        XCTAssertFalse(result?.events.contains { if case .entered = $0 { return true }; return false } ?? false)
    }

    func testShortNameDropsAdministrativePrefix() {
        func named(_ name: String) -> SpeedSection {
            SpeedSection(id: "n", name: name, start: origin, end: origin, lengthMeters: 1, speedLimit: 50)
        }
        XCTAssertEqual(named("新北市中和區 台64線 1.6K–5.4K（往西）").shortName, "台64線 1.6K–5.4K")
        XCTAssertEqual(named("臺北市 自強隧道（往北）").shortName, "自強隧道")
        XCTAssertEqual(named("北宜 19K–23.1K（往宜蘭）").shortName, "北宜 19K–23.1K")
    }

    func testSafetyMarginIsConfigurable() {
        var settings = strictSettings()
        settings.sectionSafetyMargin = 0
        let tracker = SectionSpeedTracker(sections: [section()], settings: settings)
        let events = runSections(tracker, straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 30))
        guard case let .entered(_, minSec)? = events.first?.event else { return XCTFail() }
        XCTAssertEqual(minSec, 180)
    }

    private func mappedSection(length: Double = 3_000) -> SpeedSection {
        var s = section(length: length, limit: 40)
        s.path = [s.start, s.end]
        return s
    }

    func testReturnPastStartAbortsOnceAndClearsOverspeed() {
        let s = mappedSection()
        let tracker = SectionSpeedTracker(sections: [s])
        let fixes = segmentedTrack(from: origin, segments: [(0, 60, 60), (180, 60, 65)])
        let events = runSections(tracker, fixes)
        let aborted = events.filter { if case .aborted = $0.event { return true }; return false }
        XCTAssertEqual(aborted.count, 1)
        XCTAssertFalse(tracker.isActive)
        XCTAssertTrue(events.contains { $0.event == .overspeedEnded })
        XCTAssertFalse(events.contains { $0.time > aborted[0].time && $0.event == .overspeedBeep })
        XCTAssertFalse(events.contains { if case .completed = $0.event { return true }; return false })
        XCTAssertLessThan(aborted[0].time, 100, "應在段內持續後退時就中止，不必等退回門架")
    }

    func testReturnPastStartWithoutPathAlsoAborts() {
        let tracker = SectionSpeedTracker(sections: [section(limit: 40)])
        let events = runSections(tracker, segmentedTrack(from: origin, segments: [(0, 60, 35), (180, 60, 45)]))
        XCTAssertEqual(events.filter { if case .aborted = $0.event { return true }; return false }.count, 1)
        XCTAssertFalse(tracker.isActive)
    }

    func testReentryAfterAbortCanStartAgainWithoutFiveMinuteCooldown() {
        let tracker = SectionSpeedTracker(sections: [mappedSection()])
        let events = runSections(tracker, segmentedTrack(from: origin,
            segments: [(0, 60, 60), (180, 60, 60), (0, 60, 40)]))
        XCTAssertEqual(events.filter { if case .entered = $0.event { return true }; return false }.count, 2)
        XCTAssertEqual(events.filter { if case .aborted = $0.event { return true }; return false }.count, 1)
        XCTAssertTrue(tracker.isActive)
    }

    func testForwardHairpinDoesNotAbort() {
        let a = origin
        let b = GeoMath.destination(from: a, bearing: 90, distance: 1_000)
        let c = GeoMath.destination(from: b, bearing: 0, distance: 80)
        let d = GeoMath.destination(from: c, bearing: 270, distance: 1_000)
        let e = GeoMath.destination(from: d, bearing: 0, distance: 1_000)
        let path = [a, b, c, d, e]
        let s = SpeedSection(id: "hairpin", name: "髮夾彎", start: a, end: e,
                             lengthMeters: 3_080, speedLimit: 40, startHeading: 90, path: path)
        let tracker = SectionSpeedTracker(sections: [s])
        var events: [SectionEvent] = []
        for i in 0...280 {
            let point = RoadSnapping.point(along: path, at: Double(i) * 10)
            let ahead = RoadSnapping.point(along: path, at: Double(i) * 10 + 5)
            let fix = VehicleFix(point: point, speedMps: 10, course: GeoMath.bearing(from: point, to: ahead),
                                 timestamp: t0.addingTimeInterval(Double(i)))
            events += tracker.process(fix).events
        }
        XCTAssertTrue(events.contains { if case .entered = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .aborted = $0 { return true }; return false })
        XCTAssertTrue(tracker.isActive)
    }

    func testSingleAccurateGpsJumpDoesNotAbort() {
        let tracker = SectionSpeedTracker(sections: [mappedSection()])
        var fixes = straightTrack(from: origin, bearing: 0, speedKmh: 60, seconds: 100)
        fixes[50].point = GeoMath.destination(from: fixes[49].point, bearing: 180, distance: 400)
        fixes[50].course = 180
        let events = runSections(tracker, fixes)
        XCTAssertFalse(events.contains { if case .aborted = $0.event { return true }; return false })
        XCTAssertTrue(tracker.isActive)
    }

    func testForwardHairpinNearStartAfterGpsGapDoesNotAbort() {
        let a = origin
        let b = GeoMath.destination(from: a, bearing: 0, distance: 600)
        let c = GeoMath.destination(from: b, bearing: 90, distance: 15)
        let d = GeoMath.destination(from: c, bearing: 180, distance: 900)
        let e = GeoMath.destination(from: d, bearing: 90, distance: 600)
        let path = [a, b, c, d, e]
        let s = SpeedSection(id: "near-start-hairpin", name: "回到起點旁的髮夾彎", start: a, end: e,
                             lengthMeters: 2_115, speedLimit: 40, startHeading: 0, path: path)
        let tracker = SectionSpeedTracker(sections: [s])
        _ = runSections(tracker, straightTrack(from: a, bearing: 0, speedKmh: 36, seconds: 60))
        _ = tracker.tick(now: t0.addingTimeInterval(126))
        for i in 0...8 {
            let point = RoadSnapping.point(along: path, at: 1_265 + Double(i) * 10)
            let result = tracker.process(VehicleFix(point: point, speedMps: 10, course: 180,
                horizontalAccuracy: 5, timestamp: t0.addingTimeInterval(127 + Double(i))))
            XCTAssertFalse(result.events.contains { if case .aborted = $0 { return true }; return false })
        }
        XCTAssertTrue(tracker.isActive)
    }

    func testUnreliableFixDoesNotAbortOrReplaceReliableHeading() {
        let tracker = SectionSpeedTracker(sections: [mappedSection()])
        let track = straightTrack(from: origin, bearing: 0, speedKmh: 60, seconds: 40)
        _ = runSections(tracker, track)
        let last = track.last!
        for i in 1...8 {
            let point = GeoMath.destination(from: last.point, bearing: 180, distance: Double(i) * 30)
            let result = tracker.process(VehicleFix(point: point, speedMps: 16.7, course: 180,
                horizontalAccuracy: 200, timestamp: last.timestamp.addingTimeInterval(Double(i))))
            XCTAssertFalse(result.events.contains { if case .aborted = $0 { return true }; return false })
        }
        XCTAssertTrue(tracker.isActive)
    }

    func testGpsGapDoesNotContributeReverseEvidence() {
        let tracker = SectionSpeedTracker(sections: [mappedSection()])
        let track = straightTrack(from: origin, bearing: 0, speedKmh: 60, seconds: 40)
        _ = runSections(tracker, track)
        let last = track.last!
        for i in 1...30 {
            let result = tracker.tick(now: last.timestamp.addingTimeInterval(Double(i)))
            XCTAssertFalse(result?.events.contains { if case .aborted = $0 { return true }; return false } ?? false)
        }
        let point = GeoMath.destination(from: last.point, bearing: 180, distance: 200)
        let resumed = tracker.process(VehicleFix(point: point, speedMps: 16.7, course: 180,
                                                 timestamp: last.timestamp.addingTimeInterval(31)))
        XCTAssertFalse(resumed.events.contains { if case .aborted = $0 { return true }; return false })
        XCTAssertTrue(tracker.isActive)
    }

    func testSnappedPathUpdatePreservesActiveCountdown() throws {
        let s = mappedSection()
        let tracker = SectionSpeedTracker(sections: [s])
        var status: SectionStatus?
        for f in straightTrack(from: origin, bearing: 0, speedKmh: 45, seconds: 40) {
            status = tracker.process(f).status
        }
        let before = try XCTUnwrap(status)
        let middle = GeoMath.destination(from: s.start, bearing: 0, distance: 1_500)
        tracker.updatePath([s.start, middle, s.end], forSectionID: s.id)
        let fix = VehicleFix(point: GeoMath.destination(from: origin, bearing: 0, distance: 512.5),
                             speedMps: 12.5, course: 0, timestamp: t0.addingTimeInterval(41))
        let after = try XCTUnwrap(tracker.process(fix).status)
        XCTAssertEqual(after.startTime, before.startTime)
        XCTAssertEqual(after.section.path, [s.start, middle, s.end])
        XCTAssertLessThan(after.remainingSeconds, before.remainingSeconds)
    }

    func testFortyNineFiftyOneJitterKeepsIndependentVoiceAndBeepCooldowns() {
        let tracker = SectionSpeedTracker(sections: [mappedSection(length: 5_000)])
        var distance = 0.0
        var events: [TimedEvent<SectionEvent>] = []
        for i in 0...180 {
            let speed = i.isMultiple(of: 2) ? 49.0 : 51.0
            let fix = VehicleFix(point: GeoMath.destination(from: origin, bearing: 0, distance: distance),
                                 speedMps: speed / 3.6, course: 0, timestamp: t0.addingTimeInterval(Double(i)))
            let result = tracker.process(fix)
            if let status = result.status { XCTAssertEqual(status.isOverspeed, speed > 50) }
            events += result.events.map { TimedEvent(time: Double(i), event: $0) }
            distance += speed / 3.6
        }
        let voices = events.filter { if case .overspeedStarted = $0.event { return true }; return false }
        let beeps = events.filter { $0.event == .overspeedBeep }
        XCTAssertGreaterThan(voices.count, 3)
        XCTAssertGreaterThan(beeps.count, 8)
        for (a, b) in zip(voices, voices.dropFirst()) { XCTAssertGreaterThanOrEqual(b.time - a.time, 30) }
        for (a, b) in zip(beeps, beeps.dropFirst()) { XCTAssertGreaterThanOrEqual(b.time - a.time, 15) }
    }

    func testSectionBeepSettingDoesNotUseFixedCameraInterval() {
        var settings = AlertSettings()
        settings.sectionOverspeedBeepInterval = 20
        settings.overspeedBeepInterval = 1
        let events = runSections(SectionSpeedTracker(sections: [mappedSection()], settings: settings),
                                 straightTrack(from: origin, bearing: 0, speedKmh: 60, seconds: 90))
        let beeps = events.filter { $0.event == .overspeedBeep }
        XCTAssertGreaterThan(beeps.count, 2)
        for (a, b) in zip(beeps, beeps.dropFirst()) { XCTAssertEqual(b.time - a.time, 20, accuracy: 0.01) }
    }

    func testZeroWhileOverspeedEndsStateAndDoesNotRestartWhileContinuingForward() throws {
        let s = mappedSection()
        let tracker = SectionSpeedTracker(sections: [s])
        let point = GeoMath.destination(from: s.start, bearing: 0, distance: 100)
        let first = tracker.process(VehicleFix(point: point, speedMps: 60 / 3.6, course: 0, timestamp: t0))
        let initial = try XCTUnwrap(first.status)
        XCTAssertTrue(initial.isOverspeed)
        let zeroTime = t0.addingTimeInterval(initial.remainingSeconds + 1)
        let zero = tracker.process(VehicleFix(point: point, speedMps: 60 / 3.6, course: 0, timestamp: zeroTime))
        XCTAssertTrue(zero.events.contains(.zeroReached))
        XCTAssertTrue(zero.events.contains(.overspeedEnded))
        XCTAssertFalse(zero.events.contains(.overspeedBeep))
        XCTAssertEqual(zero.status?.isOverspeed, false)
        for i in 1...30 {
            let onward = GeoMath.destination(from: point, bearing: 0, distance: Double(i) * 60 / 3.6)
            let result = tracker.process(VehicleFix(point: onward, speedMps: 60 / 3.6, course: 0,
                                                    timestamp: zeroTime.addingTimeInterval(Double(i))))
            XCTAssertFalse(result.events.contains { if case .overspeedStarted = $0 { return true }; return $0 == .overspeedBeep })
            XCTAssertEqual(result.status?.isOverspeed, false)
        }
        let cameraPoint = GeoMath.destination(from: point, bearing: 0, distance: 200)
        let camera = Camera(id: "fixed", type: .fixed, lat: cameraPoint.lat, lon: cameraPoint.lon,
                            heading: 0, speedLimit: 50)
        let fixed = CameraAlertEngine(index: SpatialIndex(cameras: [camera]))
        XCTAssertEqual(fixed.process(VehicleFix(point: point, speedMps: 60 / 3.6, course: 0,
                                               timestamp: zeroTime)).target?.isOverspeed, true)
    }

    func testTickZeroAlsoClearsOverspeed() throws {
        let tracker = SectionSpeedTracker(sections: [mappedSection()])
        let track = straightTrack(from: origin, bearing: 0, speedKmh: 60, seconds: 40)
        var status: SectionStatus?
        for fix in track { status = tracker.process(fix).status }
        let before = try XCTUnwrap(status)
        let result = try XCTUnwrap(tracker.tick(now: before.earliestExit.addingTimeInterval(1)))
        XCTAssertTrue(result.events.contains(.zeroReached))
        XCTAssertTrue(result.events.contains(.overspeedEnded))
        XCTAssertEqual(result.status?.isOverspeed, false)
        XCTAssertFalse(result.events.contains(.overspeedBeep))
    }

    func testOfficialGateCrossingStartsBothDirectionsWithinSixtyMeters() {
        let gates: [(String, GeoPoint, GeoPoint, Double, Double)] = [
            ("beiyi-2-f", GeoPoint(lat: 24.9504174, lon: 121.6477995), GeoPoint(lat: 24.9429879, lon: 121.6708659), 134, 5835.3),
            ("beiyi-2-r", GeoPoint(lat: 24.9430715, lon: 121.6708954), GeoPoint(lat: 24.9503516, lon: 121.6478697), 15, 5830.5),
        ]
        for (id, start, end, heading, length) in gates {
            let s = SpeedSection(id: id, name: "官方門架", start: start, end: end,
                                 lengthMeters: length, speedLimit: 40, startHeading: heading)
            let tracker = SectionSpeedTracker(sections: [s])
            let before = GeoMath.destination(from: start, bearing: heading + 180, distance: 300)
            var entered = 0
            for fix in straightTrack(from: before, bearing: heading, speedKmh: 60, seconds: 35) {
                for event in tracker.process(fix).events {
                    if case let .entered(section, _) = event {
                        entered += 1
                        XCTAssertEqual(section.groupID, "beiyi-2")
                        XCTAssertEqual(section.lengthMeters, length)
                        XCTAssertLessThanOrEqual(GeoMath.distance(fix.point, start), 60)
                    }
                }
            }
            XCTAssertEqual(entered, 1, id)
        }
    }
}
