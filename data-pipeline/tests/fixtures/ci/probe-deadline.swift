import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@MainActor
final class FakeMapRequest {
    var cancelled = false

    func run() async throws -> Int {
        try await withTaskCancellationHandler(operation: {
            try await Task.sleep(nanoseconds: 500_000_000)
            return 7
        }, onCancel: {
            Task { @MainActor in self.cancelled = true }
        })
    }
}

@main
struct DeadlineContracts {
    struct Failure: Error {}

    @MainActor
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition {
            print(message)
            throw Failure()
        }
    }

    @MainActor
    static func main() async {
        do {
            let value = try await withRequestDeadline(caseName: "成功", stage: "搜尋", seconds: 1) { 7 }
            try check(value == 7, "正常結果遺失")

            let request = FakeMapRequest()
            let start = Date()
            do {
                _ = try await withRequestDeadline(caseName: "指定車種", stage: "規劃", seconds: 0.02) {
                    try await request.run()
                }
                throw Failure()
            } catch let error as ProbeRequestTimedOut {
                try check(error.description.contains("指定車種") && error.description.contains("規劃"), "逾時缺少案名／階段")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            try check(request.cancelled && Date().timeIntervalSince(start) < 0.3, "逾時沒有取消底層請求")

            let cancelled = FakeMapRequest()
            let task = Task { @MainActor in
                try await withRequestDeadline(caseName: "外層取消", stage: "搜尋", seconds: 1) {
                    try await cancelled.run()
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            task.cancel()
            do {
                _ = try await task.value
                throw Failure()
            } catch is CancellationError {}
            try await Task.sleep(nanoseconds: 10_000_000)
            try check(cancelled.cancelled, "外層取消沒有傳遞")

            do {
                let _: Int = try await withRequestDeadline(caseName: "錯誤", stage: "規劃", seconds: 1) {
                    throw NSError(domain: "fixture", code: 9)
                }
                throw Failure()
            } catch let error as NSError where error.domain == "fixture" && error.code == 9 {}

            do {
                _ = try await withRequestDeadline(caseName: "晚到", stage: "搜尋", seconds: 0.01) {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    return 8
                }
                throw Failure()
            } catch is ProbeRequestTimedOut {}
            try await Task.sleep(nanoseconds: 20_000_000)
            print("5 個 RouteProbe 期限契約通過")
        } catch {
            print("RouteProbe 期限契約失敗：\(error)")
            exit(1)
        }
    }
}
