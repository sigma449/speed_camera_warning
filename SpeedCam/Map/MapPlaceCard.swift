import SpeedCamCore
import SwiftUI

struct MapPlaceCard: View {
    let place: MapPlaceSelection.Place
    let onStart: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(place.name)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(place.address ?? place.coordinateText)
                        .font(.subheadline)
                        .foregroundStyle(BannerStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("關閉選點卡")
            }
            if place.isResolvingAddress {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("查詢地址中，可先開始導航").font(.footnote)
                }
            } else if place.addressUnavailable {
                Text("無法取得地址，仍可使用所選座標導航")
                    .font(.footnote.weight(.semibold))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BannerStyle.caution, in: RoundedRectangle(cornerRadius: 10))
            }
            Button(action: onStart) {
                Text("開始導航")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(BannerStyle.good, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityHint("先預覽地點與路線，再開始導航")
        }
        .padding(16)
        .foregroundStyle(.white)
        .background(BannerStyle.dark, in: RoundedRectangle(cornerRadius: 20))
    }
}

@available(iOS 17, *)
struct MapPlaceGalleryView: View {
    private let point = GeoPoint(lat: 25.0478, lon: 121.5170)
    private let startAnchor: UnitPoint =
        ProcessInfo.processInfo.arguments.contains("-galleryBottom") ? .bottom : .top

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("選點卡版面示例：長名稱／地址").font(.headline)
                card(MapPlaceSelection.Place(point: point, name: "台北車站（地圖選點卡長名稱示例）",
                    address: "臺北市中正區北平西路3號", isResolvingAddress: false))
                Text("查詢中仍可使用座標").font(.headline)
                card(MapPlaceSelection.Place(point: point, name: "所選位置"))
                Text("反查地址失敗").font(.headline)
                card(MapPlaceSelection.Place(point: point, name: "所選位置",
                    isResolvingAddress: false, addressUnavailable: true))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(maxWidth: 375)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(startAnchor)
        .foregroundStyle(.white)
        .background(Color(white: 0.3))
    }

    private func card(_ place: MapPlaceSelection.Place) -> some View {
        MapPlaceCard(place: place, onStart: {}, onClose: {})
    }
}
