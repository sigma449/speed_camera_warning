import SpeedCamCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppPreferences.autoStartCruiseKey) private var autoStartCruise = true
    @State private var mapLanguage = MapLanguage.selected
    @State private var showRestartNotice = false

    /// 改了語言但還沒重新開啟 App。
    private var languagePending: Bool { mapLanguage != MapLanguage.atLaunch }

    var body: some View {
        AdaptiveNavigationStack {
            Form {
                Section {
                    Picker("搜尋與導航語言", selection: $mapLanguage) {
                        ForEach([MapLanguage.traditionalChinese, .english, .system]) { language in
                            Text(language.shortName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    if languagePending {
                        Button {
                            restartForLanguage()
                        } label: {
                            Label("立即重新開啟 App，改用「\(mapLanguage.displayName)」", systemImage: "arrow.clockwise")
                        }
                    }
                } header: {
                    Text("搜尋與導航語言")
                } footer: {
                    Text("地圖上的地名、搜尋結果、導航的轉彎指示都會用這個語言，不必改整支手機的語言。App 本身的文字一律是中文。iOS 規定要重新開啟 App 才會生效。目前使用：\(MapLanguage.active)")
                }

                Section {
                    Picker("車種", selection: $model.settings.vehicleMode) {
                        ForEach(VehicleMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("車種")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("紅黃牌機車：避開國道和收費道路，可以走快速道路和市區高架。白牌機車：只走平面道路。機車路線仍是用汽車的路網規劃，不知道哪些路段禁行機車，請依現場標誌行駛。")
                        if !LegacySupport.supportsRoutePreferences {
                            Text("這支 iPhone 的 iOS 太舊，不能要求 Apple 避開高速或收費，機車路線幾乎都會跳提醒，也可能走到快速道路或高架，和 iOS 16 以上的手機不一樣。")
                        }
                    }
                }

                Section {
                    Toggle("開啟 App 時自動開始巡航", isOn: $autoStartCruise)
                } header: {
                    Text("巡航")
                } footer: {
                    Text("開啟後，打開 App 就會開始偵測測速照相，不用再按 ▶︎。")
                }


                Section {
                    distanceStepper("一般道路・預告", value: $model.settings.generalPreDistance, range: 100...800)
                    distanceStepper("一般道路・近距", value: $model.settings.generalNearDistance, range: 50...300)
                    distanceStepper("快速道路・預告", value: $model.settings.fastPreDistance, range: 300...1_500)
                    distanceStepper("快速道路・近距", value: $model.settings.fastNearDistance, range: 100...600)
                } header: {
                    Text("提醒距離")
                } footer: {
                    Text("照相點速限 \(model.settings.fastRoadSpeedLimit) 以上視為快速道路或高速公路。法規規定警告標誌設在照相點前：一般道路 100～300 公尺、快速道路與高速公路 300～1,000 公尺。")
                }

                Section {
                    Stepper(value: $model.settings.overspeedToleranceKmh, in: 0...20, step: 1) {
                        LabeledValue("超速容許值", value: "+\(Int(model.settings.overspeedToleranceKmh)) km/h")
                    }
                    Stepper(value: $model.settings.overspeedBeepInterval, in: 1...10, step: 1) {
                        LabeledValue("嗶聲間隔", value: "\(Int(model.settings.overspeedBeepInterval)) 秒")
                    }
                } header: {
                    Text("超速警示")
                } footer: {
                    Text("接近照相點時，車速超過「速限＋容許值」會每隔設定秒數嗶一聲，直到降速或通過照相點。")
                }

                Section {
                    Stepper(value: $model.settings.sectionToleranceKmh, in: AlertSettings.sectionToleranceRange, step: 5) {
                        LabeledValue("區間容許值（預設）", value: "+\(Int(model.settings.sectionToleranceKmh)) km/h")
                    }
                    NavigationLink {
                        SectionToleranceView()
                    } label: {
                        LabeledValue("個別區間設定",
                                     value: model.settings.sectionToleranceOverrides.isEmpty
                                         ? "未設定" : "\(model.settings.sectionToleranceOverrides.count) 段")
                    }
                    Stepper(value: $model.settings.sectionSafetyMargin, in: 0...0.10, step: 0.01) {
                        LabeledValue("安全餘裕", value: "\(Int((model.settings.sectionSafetyMargin * 100).rounded()))%")
                    }
                    Toggle("最後 30 秒、10 秒額外提醒", isOn: $model.settings.sectionFinalCountdown)
                } header: {
                    Text("區間測速")
                } footer: {
                    Text("倒數 = 區間長度 ÷（速限＋容許值）×（1＋安全餘裕）− 已經過秒數。容許值也套用在區間內與區間照相機前的超速嗶聲。預設 +10（例如北宜公路表定 40 → 以 50 計算），最多 +20；可在「個別區間設定」挑選特定區間另外設定。每分鐘語音提醒一次剩幾秒，歸零時提醒「可依速限行駛」。")
                }

                Section("聲音") {
                    Toggle("語音提醒", isOn: $model.settings.voiceEnabled)
                    Toggle("嗶聲", isOn: $model.settings.beepEnabled)
                    Button("試聽語音") { model.testVoice() }
                    Button("試聽嗶聲") { model.testBeep() }
                }

                // 舊系統沒有 Live Activity，不顯示這一段
                if LegacySupport.supportsLiveActivity {
                    Section {
                        Toggle("Live Activity（鎖定畫面／CarPlay）", isOn: $model.settings.liveActivityEnabled)
                        Toggle("重要時刻跳出提醒", isOn: $model.settings.liveActivityAlertsEnabled)
                            .disabled(!model.settings.liveActivityEnabled)
                    } header: {
                        Text("Live Activity")
                    } footer: {
                        Text("iOS 26 起，Live Activity 會出現在 CarPlay 儀表板（Dashboard）。CarPlay 上的位置和大小由系統決定；想看得更清楚，可以到 iPhone「設定 → 一般 → CarPlay → 選擇車輛 → 顯示」開啟 Smart Display Zoom。「重要時刻跳出提醒」會在接近照相點、超速、區間開始和歸零時提醒；不在 Dashboard 頁面時，CarPlay 會顯示成畫面底部的通知。提醒會有系統提示音，覺得和語音重疊可以關掉。")
                    }
                }

                Section {
                    LabeledValue("資料版本", value: model.database.version)
                    LabeledValue("照相點", value: "\(model.database.cameras.count) 處")
                    LabeledValue("區間測速", value: "\(model.database.sections.count) 段")
                    ForEach(model.database.sources, id: \.self) { source in
                        Text(source).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(RoadLineStore.attribution).font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("資料")
                } footer: {
                    Text("照相點資料僅供參考，請依現場標誌與速限行駛。")
                }

                Section {
                    Button("恢復預設值", role: .destructive) { model.resetSettings() }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: mapLanguage) { newValue in
                MapLanguage.select(newValue)
                showRestartNotice = languagePending
            }
            .alert("要現在重新開啟 App 嗎？", isPresented: $showRestartNotice) {
                Button("立即重新開啟") { restartForLanguage() }
                Button("稍後", role: .cancel) {}
            } message: {
                Text("App 會回到主畫面並關閉，再點一次「測速地圖」圖示，地名、搜尋和導航就會改用「\(mapLanguage.displayName)」。")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func restartForLanguage() {
        model.prepareForRelaunch()
        AppRelauncher.closeToHomeScreen()
    }

    private func distanceStepper(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range, step: 50) {
            LabeledValue(title, value: "\(Int(value.wrappedValue)) m")
        }
    }
}
