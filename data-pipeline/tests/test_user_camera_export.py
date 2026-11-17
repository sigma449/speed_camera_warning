from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from speedcam_data.normalize import normalize_rows  # noqa: E402
from speedcam_data.sources import read_local_rows  # noqa: E402


FIXTURE = (Path(__file__).resolve().parents[2] / "Packages" / "SpeedCamCore" / "Tests"
           / "SpeedCamCoreTests" / "Fixtures" / "user_cameras_export.csv")


def test_swift_user_camera_csv_is_readable_by_the_existing_manual_pipeline():
    rows = read_local_rows([str(FIXTURE)])
    assert list(rows[0]) == ["設置地點", "座標緯度", "座標經度", "拍攝方向", "速限",
                             "取締項目", "縣市", "行政區", "來源"]
    assert len(rows) == 8
    cameras = sorted(normalize_rows(rows), key=lambda camera: camera.lat)
    assert len(cameras) == 8
    expected = [
        ("fixed", 50, 240.6, None), ("fixed", 80, 0, None),
        ("redLight", None, None, 90), ("fixed", 30, None, 0),
        ("fixed", 50, None, None), ("redLight", None, None, None),
        ("fixed", 110, None, None), ("redLight", None, 315, None),
    ]
    for index, (camera, values) in enumerate(zip(cameras, expected)):
        assert (camera.type, camera.speedLimit, camera.heading, camera.axis) == values
        assert camera.lat == pytest.approx(25.03 + index * 0.001)
        assert camera.lon == 121.565
        assert (camera.city, camera.district) == ("臺北市", "信義區")
        assert rows[index]["來源"] == "使用者於 App 自行新增（2026-11-17）"
    assert cameras[0].address == '測試路口,東側"桿"'
    assert "軸向45°" in rows[4]["拍攝方向"]
    assert "軸向135°" in rows[5]["拍攝方向"]


@pytest.mark.parametrize("kind,expected", [("測速照相", "fixed"), ("闖紅燈照相", "redLight")])
@pytest.mark.parametrize("direction,heading", [("240.6°", 240.6), ("", None), ("南北雙向", None)])
def test_app_export_choices_override_misleading_poi_names_but_not_official_rows(kind, expected, direction, heading):
    row = {
        "設置地點": "旗津往前鎮（區間測速與闖紅燈照相附近）",
        "座標緯度": "22.6", "座標經度": "120.3", "拍攝方向": direction,
        "速限": "50" if expected == "fixed" else "", "取締項目": kind,
        "來源": "使用者於 App 自行新增（2026-11-17）",
    }
    camera = normalize_rows([row])[0]
    assert camera.type == expected
    assert camera.heading == heading
    assert camera.axis == (0 if direction == "南北雙向" else None)
    row["來源"] = "官方資料"
    official = normalize_rows([row])[0]
    assert official.type == "section"
    assert official.heading == 52
