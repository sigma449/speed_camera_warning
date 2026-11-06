import XCTest
@testable import SpeedCamCore

/// 測試資料大多取自開放資料裡真實的地址；測邊界情況的幾筆是自己造的。
final class CameraShortAddressTests: XCTestCase {
    private func short(_ address: String) -> String {
        Camera(id: "x", type: .fixed, lat: 25, lon: 121, address: address).shortAddress
    }

    func testAddressThatFitsIsKeptAsIs() {
        XCTAssertEqual(short("花壇鄉台1線198.4公里"), "花壇鄉台1線198.4公里")
        XCTAssertEqual(short("北寧路(海洋大學前)"), "北寧路(海洋大學前)")
        XCTAssertEqual(short("國軒路/鵬程東二路口"), "國軒路/鵬程東二路口")
    }

    func testLongAddressDropsParentheses() {
        XCTAssertEqual(short("線西鄉台61線170.11公里(快速道路)(20公噸以上大貨車速限80公里/小時)"), "線西鄉台61線170.11公里")
        XCTAssertEqual(short("樂群一路(基湖路口西往東天橋下(金泰公園))再往前一段路的路口"), "樂群一路再往前一段路的路口")
    }

    func testParenthesesInTheMiddleKeepTheRoadName() {
        XCTAssertEqual(short("員林市(埔心鄉)中山路1段與柳橋東路口"), "員林市中山路1段與柳橋東路口")
    }

    func testMismatchedHalfAndFullWidthParentheses() {
        XCTAssertEqual(short("高速公路接金福路之高架聯絡道南下（離金福路出口900公尺處)"), "高速公路接金福路之高架聯絡道南下")
    }

    func testMultipleSegmentsKeepOnlyTheFirst() {
        XCTAssertEqual(short("市道182線27.2248公里至28.358公里處(往高雄)；市道182線28.3378公里至27.1907公里處(往關廟)"),
                       "市道182線27.2248公里至28.358公里處")
        XCTAssertEqual(short("台61線快速道路157.8K至151.6K(南向北)/148.1K至156.4K(北向南)"), "台61線快速道路157.8K至151.6K")
    }

    func testSlashWithShortPrefixIsAnIntersectionNotASegment() {
        let address = "國軒路/鵬程東二路口與其他道路交叉口附近路段"
        XCTAssertEqual(short(address), address)
    }

    func testAddressThatIsAllParenthesesFallsBackToOriginal() {
        let address = "(這是一段超過十八個字而且全部都在括號裡面的說明文字)"
        XCTAssertEqual(short(address), address)
    }
}
