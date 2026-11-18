import XCTest
@testable import SpeedCamCore

final class AnnouncementFormatterTests: XCTestCase {
    func testSpokenDistance() {
        XCTAssertEqual(AnnouncementFormatter.spokenDistance(296), "300公尺")
        XCTAssertEqual(AnnouncementFormatter.spokenDistance(104), "100公尺")
        XCTAssertEqual(AnnouncementFormatter.spokenDistance(1_000), "1公里")
        XCTAssertEqual(AnnouncementFormatter.spokenDistance(1_540), "1.5公里")
        XCTAssertEqual(AnnouncementFormatter.spokenDistance(3), "10公尺")
    }

    func testDisplayDistance() {
        XCTAssertEqual(AnnouncementFormatter.displayDistance(283), "280m")
        XCTAssertEqual(AnnouncementFormatter.displayDistance(1_234), "1.2km")
    }

    func testCameraAlertText() {
        let cam = Camera(id: "x", type: .fixed, lat: 25, lon: 121, heading: 0, speedLimit: 50)
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: cam, announcedDistance: 300),
                       "前方300公尺，測速照相，速限50")
        let red = Camera(id: "y", type: .redLight, lat: 25, lon: 121, heading: 0, speedLimit: 50)
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: red, announcedDistance: 100),
                       "前方100公尺，闖紅燈照相")
        let up = Camera(id: "e", type: .fixed, lat: 25, lon: 121, speedLimit: 80, level: .elevated)
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: up, announcedDistance: 300),
                       "前方300公尺，高架測速照相，速限80")
        let down = Camera(id: "s", type: .fixed, lat: 25, lon: 121, heading: 90, speedLimit: 40, level: .surface)
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: down, announcedDistance: 100),
                       "前方100公尺，平面測速照相，速限40")
    }

    func testNewCameraTypeSpeechAndEnforcementDetails() {
        let mobile = Camera(id: "m", type: .mobile, lat: 25, lon: 121, speedLimit: 50)
        let noise = Camera(id: "n", type: .noise, lat: 25, lon: 121, speedLimit: 50)
        var tech = Camera(id: "t", type: .tech, lat: 25, lon: 121, speedLimit: 50,
                         enforcementItems: "闖紅燈、未依標線行駛")
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: mobile, announcedDistance: 300),
                       "前方300公尺，常見移動測速")
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: noise, announcedDistance: 300),
                       "前方300公尺，聲音照相")
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: tech, announcedDistance: 300),
                       "前方300公尺，路口科技執法：闖紅燈、未依標線行駛")
        tech.enforcementItems = "超速、闖紅燈"
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: tech, announcedDistance: 300),
                       "前方300公尺，路口科技執法：超速、闖紅燈，速限50")
    }

    func testMixedTechnologyListsKeepDrivingItemsFirstAndRawDetailsIntact() {
        let items = "違規停車、闖紅燈、併排停車、不停讓行人、紅黃線停車"
        let tech = Camera(id: "t", type: .tech, lat: 25, lon: 121, enforcementItems: items)
        let sorted = "闖紅燈、不停讓行人、違規停車、併排停車、紅黃線停車"
        XCTAssertFalse(tech.isParkingOnlyTechnology)
        XCTAssertEqual(tech.enforcementItems, items)
        XCTAssertEqual(tech.enforcementDetail, "取締：" + items)
        XCTAssertEqual(tech.reminderDetail, "取締：" + sorted)
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: tech, announcedDistance: 300),
                       "前方300公尺，路口科技執法：" + sorted)
    }

    func testParkingClassificationKeepsUnknownItemsAndStopSignEnforcement() {
        for items in ["違規停車", "併排停車；紅線違停，黃線停車", "違規臨時停車／違規臨停", "紅黃線停車"] {
            XCTAssertTrue(Camera(id: "t", type: .tech, lat: 25, lon: 121, enforcementItems: items).isParkingOnlyTechnology, items)
        }
        for items in ["違規停車、超速", "違規停車、停車再開", "未依規定停車再開", "違規停車、未知項目", "不停讓行人", ""] {
            XCTAssertFalse(Camera(id: "t", type: .tech, lat: 25, lon: 121, enforcementItems: items).isParkingOnlyTechnology, items)
        }
        XCTAssertFalse(Camera(id: "fixed", type: .fixed, lat: 25, lon: 121,
                              enforcementItems: "違規停車").isParkingOnlyTechnology)
    }

    func testRedLightTechnologyUsesSharedEnforcementItemParsingWithoutInferringOtherSignalViolations() {
        for items in ["闖紅燈", " 闖紅燈及路口淨空 ", "違規停車；\n闖紅燈，未停讓行人",
                      "未停讓行人／闖紅燈", "紅燈右轉,闖紅燈",
                      "路口各項違規(闖紅燈、不依標誌標線號誌行駛等)"] {
            let tech = Camera(id: "t", type: .tech, lat: 25, lon: 121, enforcementItems: items)
            XCTAssertTrue(tech.usesTwoStageAlert, items)
            XCTAssertFalse(tech.enforcesSpeed, items)
            XCTAssertFalse(tech.isParkingOnlyTechnology, items)
            for type in [CameraType.mobile, .noise] {
                var other = tech
                other.type = type
                XCTAssertFalse(other.usesTwoStageAlert, "\(type) \(items)")
            }
        }
        let singleStageItems: [String?] = [
            nil, "", "紅燈右轉", "紅燈越線", "路口淨空", "未依標誌標線號誌行駛",
            "違規停車、紅燈右轉", "違規停車、併排停車",
        ]
        for items in singleStageItems {
            let tech = Camera(id: "t", type: .tech, lat: 25, lon: 121, address: "闖紅燈測試路",
                              enforcementItems: items, conditions: "闖紅燈")
            XCTAssertFalse(tech.usesTwoStageAlert, items ?? "nil")
            XCTAssertFalse(tech.enforcesSpeed, items ?? "nil")
        }
    }

    /// 使用者實測：近距時語音精簡一點，用幾公尺就好。
    func testNearAlertAfterPreOnlySaysDistance() {
        XCTAssertEqual(AnnouncementFormatter.cameraNearAfterPre(announcedDistance: 100), "100公尺")
        XCTAssertEqual(AnnouncementFormatter.cameraNearAfterPre(announcedDistance: 200), "200公尺")
    }

    func testSectionApproachingText() {
        let section = SpeedSection(id: "s", name: "測試", start: GeoPoint(lat: 25, lon: 121),
                                   end: GeoPoint(lat: 25.01, lon: 121), lengthMeters: 1_100, speedLimit: 70)
        XCTAssertEqual(AnnouncementFormatter.sectionApproaching(section: section, announcedDistance: 300),
                       "前方300公尺，進入區間測速，速限70")
    }

    func testRoadLevelDecodingToleratesUnknownValues() throws {
        let json = #"[{"id":"a","type":"fixed","lat":25,"lon":121,"address":"x","level":"elevated"},"#
            + #"{"id":"b","type":"fixed","lat":25,"lon":121,"address":"y","level":"tunnel"},"#
            + #"{"id":"c","type":"fixed","lat":25,"lon":121,"address":"z"}]"#
        let cams = try JSONDecoder().decode([Camera].self, from: Data(json.utf8))
        XCTAssertEqual(cams.map(\.level), [.elevated, .unknown, nil])
        XCTAssertEqual(cams.map(\.displayTypeName), ["高架測速照相", "測速照相", "測速照相"])
    }

    func testSectionTexts() {
        let s = SpeedSection(id: "s", name: "x", start: origin, end: origin, lengthMeters: 3_200, speedLimit: 60)
        XCTAssertEqual(AnnouncementFormatter.sectionEntered(section: s, minimumSeconds: 198),
                       "進入區間測速，全長3.2公里，速限60，至少需要198秒")
        XCTAssertEqual(AnnouncementFormatter.sectionEntered(section: s, minimumSeconds: 238, effectiveLimitKmh: 50),
                       "進入區間測速，全長3.2公里，速限60，至少需要238秒",
                       "計算時速沒有高於速限時不念")
        let bx = SpeedSection(id: "b", name: "北宜", start: origin, end: origin, lengthMeters: 4_100, speedLimit: 40)
        XCTAssertEqual(AnnouncementFormatter.sectionEntered(section: bx, minimumSeconds: 304, effectiveLimitKmh: 50),
                       "進入區間測速，全長4.1公里，速限40，以時速50計算，至少需要304秒")
        XCTAssertEqual(AnnouncementFormatter.sectionOverspeed(threshold: 50), "區間測速，車速超過50")
        XCTAssertEqual(AnnouncementFormatter.sectionRemaining(seconds: 120), "區間測速，還有120秒")
        XCTAssertEqual(AnnouncementFormatter.sectionCompleted(averageKmh: 58.4, withinLimit: true), "區間測速結束，平均時速58")
        XCTAssertEqual(AnnouncementFormatter.sectionRemaining(seconds: 180, suggestedKmh: 45),
                       "區間測速，還有180秒，建議時速45以下")
        XCTAssertEqual(AnnouncementFormatter.sectionRemaining(seconds: 30), "區間測速，還有30秒")
    }

    func testManeuverText() {
        XCTAssertEqual(AnnouncementFormatter.maneuver(instruction: "右轉進入忠孝東路", distance: 500), "500公尺後，右轉進入忠孝東路")
        XCTAssertEqual(AnnouncementFormatter.maneuver(instruction: "右轉進入忠孝東路", distance: nil), "右轉進入忠孝東路")
    }
}

final class CameraAnnouncementPolicyTests: XCTestCase {
    private func speech(distance: Double, afterPre: Bool = true, over: Bool = true, limit: Int? = 50,
                        started: Bool = false, targetID: String = "cam", type: CameraType = .fixed) -> [SpokenAnnouncement] {
        let camera = Camera(id: "cam", type: type, lat: origin.lat, lon: origin.lon, speedLimit: limit)
        var target = camera
        target.id = targetID
        var events: [CameraAlertEvent] = [.nearAlert(camera: camera, distance: distance, afterPre: afterPre)]
        if started { events.append(.overspeedStarted(limit: limit ?? 50, speedKmh: 90)) }
        let result = CameraAlertResult(events: events,
            target: CameraTarget(camera: target, distance: distance, phase: .near, isOverspeed: over))
        return CameraAnnouncementPolicy.speech(for: result, speedKmh: 90, settings: AlertSettings())
    }

    func testOngoingOverspeedWithoutNewStartedEventIsIncludedInNearSpeech() {
        XCTAssertEqual(speech(distance: 89), [SpokenAnnouncement(text: "100公尺，超速", urgent: true)])
    }

    func testSimultaneousNearAndOverspeedHaveOnlyOneUrgentSentence() {
        XCTAssertEqual(speech(distance: 89, started: true), [SpokenAnnouncement(text: "100公尺，超速", urgent: true)])
    }

    func testFirstNearStillKeepsFullSentenceAndSeparateOverspeed() {
        XCTAssertEqual(speech(distance: 91, afterPre: false, started: true).map(\.text),
                       ["前方100公尺，測速照相，速限50", "您已超速，速限50"])
    }

    func testNearUsesActualFastThresholdAndShortDistance() {
        XCTAssertEqual(speech(distance: 184, limit: 80).first?.text, "200公尺，超速")
        XCTAssertEqual(speech(distance: 25).first?.text, "30公尺，超速")
        XCTAssertEqual(speech(distance: 89, over: false).first?.text, "100公尺")
    }

    func testAnotherTargetOrNonSpeedCameraCannotSupplyOverspeed() {
        XCTAssertEqual(speech(distance: 89, targetID: "other").first?.text, "100公尺")
        XCTAssertEqual(speech(distance: 184, limit: nil).first?.text, "200公尺")
        XCTAssertEqual(speech(distance: 89, type: .redLight).first?.text, "100公尺")
    }

    func testRedLightNearSpeechKeepsDistanceOnlyDespiteStaleOverspeedFlag() {
        for type in [CameraType.redLight, .tech] {
            let camera = Camera(id: "red", type: type, lat: 25, lon: 121, speedLimit: 80,
                                enforcementItems: type == .tech ? "闖紅燈及路口淨空" : nil)
            for (distance, text) in [(184.0, "200公尺"), (25.0, "30公尺")] {
                let result = CameraAlertResult(events: [.nearAlert(camera: camera, distance: distance, afterPre: true)],
                    target: CameraTarget(camera: camera, distance: distance, phase: .near, isOverspeed: true))
                XCTAssertEqual(CameraAnnouncementPolicy.speech(for: result, speedKmh: 100,
                    settings: AlertSettings()), [SpokenAnnouncement(text: text, urgent: true)])
            }
        }
    }
}

final class AlertAnnouncementPolicyTests: XCTestCase {
    private final class Utterance {}

    func testBatchKeepsNearAheadOfSectionAndHotspotEvenWithHotspotFirst() {
        let camera = Camera(id: "c", type: .fixed, lat: 25, lon: 121, speedLimit: 50)
        let hotspot = Camera(id: "m", type: .mobile, lat: 25, lon: 121)
        let section = SpeedSection(id: "s", name: "區間", start: origin, end: origin,
                                   lengthMeters: 1_000, speedLimit: 50)
        let speeches = AlertAnnouncementPolicy.speech(
            camera: CameraAlertResult(events: [.preAlert(camera: hotspot, distance: 300),
                .nearAlert(camera: camera, distance: 90, afterPre: true)],
                target: CameraTarget(camera: camera, distance: 90, phase: .near, isOverspeed: true)),
            section: SectionResult(events: [.entered(section: section, minimumSeconds: 100)], status: nil),
            speedKmh: 72, settings: AlertSettings(), suggestedKmh: nil, cameraOverspeedActive: true)
        XCTAssertEqual(speeches.map(\.priority), [.critical, .section, .preAlert])
        XCTAssertEqual(speeches.first?.text, "100公尺，超速")
        XCTAssertEqual(speeches.map(\.urgent), [true, true, false])
    }

    func testLowerPriorityUrgentSectionCannotInterruptNear() {
        var state = SpeechPlaybackState()
        let near = Utterance(), section = Utterance()
        XCTAssertFalse(state.submit(ObjectIdentifier(near), priority: .critical, urgent: true, isSpeaking: false))
        XCTAssertFalse(state.submit(ObjectIdentifier(section), priority: .section, urgent: true, isSpeaking: true))
    }

    func testHigherPriorityReplacesPendingLowerBeforeSpeakingAndIgnoresOldCancellation() {
        var state = SpeechPlaybackState()
        let navigation = Utterance(), near = Utterance(), section = Utterance()
        XCTAssertFalse(state.submit(ObjectIdentifier(navigation), priority: .navigation, urgent: false, isSpeaking: false))
        XCTAssertTrue(state.submit(ObjectIdentifier(near), priority: .critical, urgent: true, isSpeaking: false))
        state.finish(ObjectIdentifier(navigation))
        XCTAssertFalse(state.submit(ObjectIdentifier(section), priority: .section, urgent: true, isSpeaking: true))
    }

    func testSamePriorityUrgentAndNonUrgentInterruptionRulesArePreserved() {
        var state = SpeechPlaybackState()
        let first = Utterance(), second = Utterance(), normal = Utterance(), latest = Utterance()
        XCTAssertFalse(state.submit(ObjectIdentifier(first), priority: .critical, urgent: true, isSpeaking: false))
        XCTAssertFalse(state.submit(ObjectIdentifier(second), priority: .critical, urgent: true, isSpeaking: false))
        XCTAssertFalse(state.submit(ObjectIdentifier(normal), priority: .section, urgent: false, isSpeaking: true))
        XCTAssertTrue(state.submit(ObjectIdentifier(latest), priority: .critical, urgent: true, isSpeaking: true))
    }

    func testSectionOverspeedSuppressionAndCountdownSuggestedSpeedRemainIntact() {
        let result = SectionResult(events: [.overspeedStarted(threshold: 50), .remaining(seconds: 60)], status: nil)
        let suppressed = AlertAnnouncementPolicy.speech(camera: nil, section: result, speedKmh: 60,
            settings: AlertSettings(), suggestedKmh: 45, cameraOverspeedActive: true)
        XCTAssertEqual(suppressed.map(\.text), [AnnouncementFormatter.sectionRemaining(seconds: 60, suggestedKmh: 45)])
        let audible = AlertAnnouncementPolicy.speech(camera: nil, section: result, speedKmh: 60,
            settings: AlertSettings(), suggestedKmh: 45, cameraOverspeedActive: false)
        XCTAssertEqual(audible.map(\.priority), [.critical, .section])
        XCTAssertEqual(audible.first?.text, AnnouncementFormatter.sectionOverspeed(threshold: 50))
    }

    func testFinishedAndStoppedSpeechCannotLeaveStalePriorityProtection() {
        var state = SpeechPlaybackState()
        let near = Utterance(), navigation = Utterance(), section = Utterance()
        _ = state.submit(ObjectIdentifier(near), priority: .critical, urgent: true, isSpeaking: false)
        _ = state.submit(ObjectIdentifier(navigation), priority: .navigation, urgent: false, isSpeaking: true)
        state.finish(ObjectIdentifier(near))
        XCTAssertTrue(state.submit(ObjectIdentifier(section), priority: .section, urgent: true, isSpeaking: true))
        state.reset()
        XCTAssertTrue(state.submit(ObjectIdentifier(navigation), priority: .navigation, urgent: true, isSpeaking: true))
    }

    func testCriticalSpeechKeepsBeepDuckedUntilAllCriticalUtterancesFinishOrStop() {
        var state = SpeechPlaybackState()
        let near = Utterance(), overspeed = Utterance(), navigation = Utterance()
        _ = state.submit(ObjectIdentifier(near), priority: .critical, urgent: true, isSpeaking: false)
        _ = state.submit(ObjectIdentifier(overspeed), priority: .critical, urgent: false, isSpeaking: true)
        _ = state.submit(ObjectIdentifier(navigation), priority: .navigation, urgent: false, isSpeaking: true)
        XCTAssertTrue(state.hasCriticalSpeech)
        state.finish(ObjectIdentifier(near))
        XCTAssertTrue(state.hasCriticalSpeech)
        state.finish(ObjectIdentifier(overspeed))
        XCTAssertFalse(state.hasCriticalSpeech)
        _ = state.submit(ObjectIdentifier(near), priority: .critical, urgent: true, isSpeaking: true)
        XCTAssertTrue(state.hasCriticalSpeech)
        state.reset()
        XCTAssertFalse(state.hasCriticalSpeech)
    }
}

final class ToneGeneratorTests: XCTestCase {
    func testActualOverspeedWavIsShorterThanHalfSecondAndLoopsHaveExactSilentGaps() {
        let tone = ToneGenerator.overspeedBeep()
        func uint32(_ data: Data, at offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
        }
        let rate = uint32(tone, at: 24)
        let frames = uint32(tone, at: 40) / 2
        let duration = Double(frames) / Double(rate)
        XCTAssertEqual(duration, 0.18, accuracy: 0.00001)
        XCTAssertLessThan(duration, AlertSettings.overspeedBeepIntervalRange.lowerBound)
        for interval in [0.5, 1, 1.5, 3, 5, 10] {
            let loop = ToneGenerator.repeatingOverspeedBeep(interval: interval)
            XCTAssertEqual(Double(uint32(loop, at: 40) / 2) / Double(rate), interval)
            XCTAssertEqual(uint32(loop, at: 4), loop.count - 8)
            XCTAssertEqual(loop[44..<tone.count], tone[44...])
            XCTAssertTrue(loop[tone.count...].allSatisfy { $0 == 0 })
        }
    }

    func testWavHeaderAndLength() {
        let data = ToneGenerator.wavData(frequency: 1_000, duration: 0.1, sampleRate: 8_000)
        XCTAssertEqual(data.count, 44 + 800 * 2)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
    }

    func testDoubleBeepIsLongerThanSingle() {
        XCTAssertGreaterThan(ToneGenerator.doubleBeep(sampleRate: 8_000).count,
                             ToneGenerator.wavData(duration: 0.09, sampleRate: 8_000).count)
    }
}

final class DatabaseTests: XCTestCase {
    func testBeepIntervalClampsAssignmentsAndDecodedValuesWithoutLosingOtherSettings() throws {
        for (input, expected) in [(0.0, 0.5), (-5, 0.5), (0.49, 0.5), (10.01, 10), (99, 10)] {
            var settings = AlertSettings()
            settings.overspeedBeepInterval = input
            XCTAssertEqual(settings.overspeedBeepInterval, expected)
            let json = #"{"overspeedBeepInterval":\#(input),"generalPreDistance":350,"sectionOverspeedBeepInterval":15}"#
            let decoded = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.overspeedBeepInterval, expected)
            XCTAssertEqual(decoded.generalPreDistance, 350)
            XCTAssertEqual(decoded.sectionOverspeedBeepInterval, 15)
        }
        for value in [Double.nan, .infinity, -.infinity] {
            var settings = AlertSettings()
            settings.overspeedBeepInterval = value
            XCTAssertEqual(settings.overspeedBeepInterval, 5)
            XCTAssertNoThrow(try JSONEncoder().encode(settings))
        }
        for raw in ["NaN", "Infinity", "-Infinity"] {
            let json = #"{"overspeedBeepInterval":"\#(raw)","voiceEnabled":false}"#
            let decoded = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.overspeedBeepInterval, 5)
            XCTAssertFalse(decoded.voiceEnabled)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(AlertSettings.self,
            from: Data(#"{"overspeedBeepInterval":"three"}"#.utf8)))
    }

    func testRevisedIntegerAndHalfSecondIntervalsRoundTripAndDisplayUnits() throws {
        for value in [0.5] + (1...10).map(Double.init) {
            let json = #"{"overspeedBeepInterval":\#(value),"overspeedBeepIntervalRevision":2}"#
            let settings = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.overspeedBeepInterval, value)
            XCTAssertEqual(try JSONDecoder().decode(AlertSettings.self,
                from: JSONEncoder().encode(settings)), settings)
            XCTAssertEqual(settings.overspeedBeepIntervalText, value == 0.5 ? "每 0.5 秒" : "每 \(Int(value)) 秒")
        }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        XCTAssertEqual(try decoder.decode(AlertSettings.self,
            from: Data(#"{"overspeedBeepInterval":"NaN"}"#.utf8)).overspeedBeepInterval, 5)
    }

    func testLegacyBeepIntervalMigratesOnlyThreeSecondsAndEncodesCurrentRevision() throws {
        for (value, expected) in [(3.0, 5.0), (4.0, 4.0), (0.5, 0.5), (10.0, 10.0), (0.2, 0.5)] {
            let json = #"{"overspeedBeepInterval":\#(value),"voiceEnabled":false,"sectionToleranceKmh":15}"#
            let settings = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.overspeedBeepInterval, expected)
            XCTAssertFalse(settings.voiceEnabled)
            XCTAssertEqual(settings.sectionToleranceKmh, 15)
            let encoded = try JSONEncoder().encode(settings)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(fields["overspeedBeepIntervalRevision"] as? Int, 2)
            XCTAssertEqual(try JSONDecoder().decode(AlertSettings.self, from: encoded), settings)
        }
        XCTAssertEqual(try JSONDecoder().decode(AlertSettings.self, from: Data("{}".utf8)).overspeedBeepInterval, 5)
    }

    func testAnyStoredBeepRevisionPreservesExplicitThreeSecondsOnRoundTrip() throws {
        for revision in [1, 2, 99] {
            let json = #"{"overspeedBeepInterval":3,"overspeedBeepIntervalRevision":\#(revision)}"#
            let settings = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.overspeedBeepInterval, 3)
            XCTAssertEqual(settings.overspeedBeepIntervalText, "每 3 秒")
            let encoded = try JSONEncoder().encode(settings)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(fields["overspeedBeepIntervalRevision"] as? Int, 2)
            XCTAssertEqual(try JSONDecoder().decode(AlertSettings.self, from: encoded), settings)
        }
    }

    func testRetiredHotspotVoiceDistanceIsIgnoredWithoutLosingOtherSettings() throws {
        let json = #"{"mobileHotspotVoiceDistance":750,"mobileHotspotsEnabled":false,"generalPreDistance":420,"sectionToleranceKmh":15}"#
        let settings = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.mobileHotspotsEnabled)
        XCTAssertEqual(settings.generalPreDistance, 420)
        XCTAssertEqual(settings.sectionToleranceKmh, 15)
        let encoded = try JSONEncoder().encode(settings)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(fields["mobileHotspotVoiceDistance"])
        XCTAssertEqual(try JSONDecoder().decode(AlertSettings.self, from: encoded), settings)
    }

    func testMultiSourceCameraAndNewSettingsRoundTrip() throws {
        let json = #"{"id":"osm-node-1","type":"fixed","lat":25,"lon":121,"address":"測速照相","source":"osm","sourceID":"node/1","sourceURL":"https://www.openstreetmap.org/node/1","enforcementItems":"超速","conditions":"小型車","positionMethod":"osm-node"}"#
        let camera = try JSONDecoder().decode(Camera.self, from: Data(json.utf8))
        XCTAssertEqual(camera.source, "osm")
        XCTAssertTrue(camera.enforcesSpeed)
        XCTAssertNil(camera.speedLimit)
        XCTAssertEqual(try JSONDecoder().decode(Camera.self, from: JSONEncoder().encode(camera)), camera)
        var settings = try JSONDecoder().decode(AlertSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.mobileHotspotsEnabled && settings.nonSpeedTechEnabled && settings.noiseCamerasEnabled)
        settings.mobileHotspotsEnabled = false
        settings.nonSpeedTechEnabled = false
        settings.noiseCamerasEnabled = false
        XCTAssertEqual(try JSONDecoder().decode(AlertSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testDecodeSampleDatabase() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample_db", withExtension: "json", subdirectory: "Fixtures"))
        let db = try CameraDatabase.decode(from: Data(contentsOf: url))
        XCTAssertEqual(db.cameras.count, 3)
        XCTAssertEqual(db.cameras[0].type, .fixed)
        XCTAssertNil(db.cameras[2].heading)
        XCTAssertEqual(db.sections.count, 1)
        XCTAssertEqual(db.sections[0].speedLimit, 90)
        XCTAssertFalse(db.sources.isEmpty)
    }

    /// Python 資料處理腳本產生的檔案（data-pipeline/build_cameras.py）必須能被 App 解碼。
    func testDecodePipelineOutput() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "pipeline_output", withExtension: "json", subdirectory: "Fixtures"))
        let db = try CameraDatabase.decode(from: Data(contentsOf: url))
        XCTAssertEqual(db.cameras.count, 11)
        XCTAssertTrue(db.cameras.contains { $0.type == .redLightSpeed })
        XCTAssertTrue(db.cameras.contains { $0.type == .section && $0.axis == 0 && $0.heading == nil })
        XCTAssertTrue(db.cameras.contains { $0.heading == nil })
        XCTAssertEqual(db.sections.map(\.id), ["s1-f", "s1-r"])
        XCTAssertEqual(db.sections.first?.lengthEstimated, false)
        XCTAssertEqual(db.sections.first?.startHeading, 5)
        XCTAssertEqual(db.sections.last?.startHeading, 185)
        XCTAssertEqual(db.sections.first?.end, db.sections.last?.start)
        XCTAssertEqual(Set(db.cameras.map(\.id)).count, db.cameras.count)
        // 沿路座標：有 path 的照著畫，沒有的畫起終點直線
        XCTAssertEqual(db.sections.first?.path?.count, 3)
        XCTAssertEqual(db.sections.first?.displayPath[1], GeoPoint(lat: 25.015, lon: 121.502))
        XCTAssertNil(db.sections.last?.path)
        XCTAssertEqual(db.sections.last?.displayPath, [GeoPoint(lat: 25.03, lon: 121.5), GeoPoint(lat: 25.0, lon: 121.5)])
    }

    func testSectionPathRoundTripsAsCompactArrays() throws {
        let path = [GeoPoint(lat: 24.9, lon: 121.6), GeoPoint(lat: 24.91, lon: 121.61), GeoPoint(lat: 24.92, lon: 121.6)]
        let section = SpeedSection(id: "p", name: "路形", start: path[0], end: path[2], lengthMeters: 2_500,
                                   speedLimit: 40, path: path)
        let data = try JSONEncoder().encode(section)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("[24.91,121.61]"), json)
        XCTAssertEqual(try JSONDecoder().decode(SpeedSection.self, from: data), section)
        // 壞掉的 path（少於兩點）視為沒有
        let broken = #"{"id":"b","name":"x","start":{"lat":25,"lon":121},"end":{"lat":25.01,"lon":121},"lengthMeters":1000,"speedLimit":50,"path":[[25,121]]}"#
        let decoded = try JSONDecoder().decode(SpeedSection.self, from: Data(broken.utf8))
        XCTAssertNil(decoded.path)
        XCTAssertFalse(decoded.lengthEstimated)
        XCTAssertEqual(decoded.displayPath.count, 2)
    }

    func testSettingsDecodeWithMissingKeysUsesDefaults() throws {
        let json = #"{"generalPreDistance": 350, "vehicleMode": "motorcycle"}"#
        let s = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.generalPreDistance, 350)
        XCTAssertEqual(s.vehicleMode, .motorcycleWhite)
        XCTAssertEqual(s.fastPreDistance, 600)
        XCTAssertEqual(s.overspeedBeepInterval, 5)
        XCTAssertEqual(s.sectionOverspeedBeepInterval, 15)
        XCTAssertEqual(s.sectionOverspeedVoiceInterval, 30)
        XCTAssertEqual(s.sectionToleranceKmh, 10)
        XCTAssertEqual(s.sectionEffectiveLimit(40), 50)
        XCTAssertEqual(s.sectionToleranceOverrides, [:])
        // 往返編碼
        let again = try JSONDecoder().decode(AlertSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again, s)
    }

    func testToleranceOverridesDecodeAndClamp() throws {
        let json = #"{"sectionToleranceKmh": 10, "sectionToleranceOverrides": {"beiyi-1": 20, "bad": 99}}"#
        let s = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.sectionTolerance(forGroup: "beiyi-1"), 20)
        XCTAssertEqual(s.sectionTolerance(forGroup: "bad"), 20, "超過上限 20 會被夾住")
        XCTAssertEqual(s.sectionTolerance(forGroup: "none"), 10)
        XCTAssertEqual(s.sectionTolerance(forGroup: nil), 10)
    }

    func testThresholdSelection() {
        let s = AlertSettings()
        XCTAssertEqual(s.thresholds(speedLimit: 50, currentSpeedKmh: 100).pre, 300)
        XCTAssertEqual(s.thresholds(speedLimit: 80, currentSpeedKmh: 30).pre, 600)
        XCTAssertEqual(s.thresholds(speedLimit: nil, currentSpeedKmh: 85).near, 200)
        XCTAssertEqual(s.thresholds(speedLimit: nil, currentSpeedKmh: 60).near, 100)
    }
}
