import SpeedCamCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("車種") {
                    Picker("車種", selection: $model.settings.vehicleMode) {
                        ForEach(VehicleMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("重機模式規劃路線時會避開國道（高速公路）與收費道路。")
                        .font(.footnote).foregroundStyle(.secondary)
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
                        LabeledContent("超速容許值", value: "+\(Int(model.settings.overspeedToleranceKmh)) km/h")
                    }
                    Stepper(value: $model.settings.overspeedBeepInterval, in: 1...10, step: 1) {
                        LabeledContent("嗶聲間隔", value: "\(Int(model.settings.overspeedBeepInterval)) 秒")
                    }
                } header: {
                    Text("超速警示")
                } footer: {
                    Text("接近照相點時，車速超過「速限＋容許值」會每隔設定秒數嗶一聲，直到降速或通過照相點。")
                }

                Section {
                    Stepper(value: $model.settings.sectionSafetyMargin, in: 0...0.10, step: 0.01) {
                        LabeledContent("安全餘裕", value: "\(Int((model.settings.sectionSafetyMargin * 100).rounded()))%")
                    }
                    Toggle("最後 30 秒、10 秒額外提醒", isOn: $model.settings.sectionFinalCountdown)
                } header: {
                    Text("區間測速")
                } footer: {
                    Text("倒數 = 區間長度 ÷ 速限 ×（1＋安全餘裕）− 已經過秒數。每分鐘語音提醒一次剩幾秒，歸零時提醒「可依速限行駛」。")
                }

                Section("聲音") {
                    Toggle("語音提醒", isOn: $model.settings.voiceEnabled)
                    Toggle("嗶聲", isOn: $model.settings.beepEnabled)
                    Button("試聽語音") { model.testVoice() }
                    Button("試聽嗶聲") { model.testBeep() }
                }

                Section {
                    Toggle("Live Activity（鎖定畫面／CarPlay）", isOn: $model.settings.liveActivityEnabled)
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text("iOS 26 起，Live Activity 會出現在 CarPlay 儀表板（Dashboard）。CarPlay 上的大小由系統決定；想看得更清楚，可以到 iPhone「設定 → 一般 → CarPlay → 選擇車輛 → 顯示」開啟 Smart Display Zoom。")
                }

                Section {
                    LabeledContent("資料版本", value: model.database.version)
                    LabeledContent("照相點", value: "\(model.database.cameras.count) 處")
                    LabeledContent("區間測速", value: "\(model.database.sections.count) 段")
                    ForEach(model.database.sources, id: \.self) { source in
                        Text(source).font(.footnote).foregroundStyle(.secondary)
                    }
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func distanceStepper(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range, step: 50) {
            LabeledContent(title, value: "\(Int(value.wrappedValue)) m")
        }
    }
}
