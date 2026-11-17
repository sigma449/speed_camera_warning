import copy
import csv
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import urllib.error
from urllib.parse import parse_qs, urlsplit

import pytest
import yaml

from ci_contract_helpers import ROOT

sys.path.insert(0, str(ROOT / "data-pipeline"))
import watch_announcements as watcher

FIXTURES = Path(__file__).with_name("fixtures") / "announcements"
CONFIG = watcher.load_config(ROOT / "data-pipeline" / "announcement_sources.json")
SOURCES = {source["id"]: source for source in CONFIG["sources"]}


def fixture(name):
    return (FIXTURES / (name + ".html")).read_text(encoding="utf-8")


def configuration(*ids):
    config = copy.deepcopy(CONFIG)
    config["sources"] = [copy.deepcopy(SOURCES[name]) for name in ids]
    config["search_terms"] = ["科技執法"]
    return config


class FixtureClient:
    def __init__(self, source, options, evidence):
        self.source = source
        self.options = options
        self.requests = []

    def fetch(self, url, fields=None):
        self.requests.append({"url": url, "method": "POST" if fields else "GET"})
        if self.source["id"] == "highway":
            raise urllib.error.URLError("官方入口暫時失聯")
        if "/news/view?" in url:
            return fixture("npa-body"), url
        return fixture("npa-list"), url


def run_watch(tmp_path, config=None, seen=None, client=FixtureClient):
    return watcher.watch(config or configuration("npa"), seen or {}, [], "2025-11-16", "2026-11-16",
                         tmp_path, client_type=client)


@pytest.mark.parametrize("filename,source,count,first_date,title_part", [
    ("npa-list", "npa", 3, "2026-10-08", "公車站區"),
    ("ccms-list", "taipei-traffic", 2, "2026-11-06", "固定式科技執法"),
    ("ntpc-list", "ntpc-traffic", 1, "2024-11-07", "39處"),
    ("taichung-list", "taichung", 1, "2026-06-03", "誰騎得最慢"),
    ("tnpd-list", "tainan", 1, "2026-07-01", "新營"),
    ("keelung-list", "keelung", 1, "2022-03-13", "4/1起執法"),
    ("keelung-table", "keelung", 1, "2022-03-13", "4/1起執法"),
    ("changhua-list", "changhua", 1, "2026-09-04", "AI辨識"),
])
def test_recorded_official_list_formats(filename, source, count, first_date, title_part):
    root, rows = watcher.parse_listing(fixture(filename), SOURCES[source], SOURCES[source]["url"])
    assert len(rows) == count
    assert rows[0]["date"] == first_date
    assert title_part in rows[0]["title"]
    assert rows[0]["url"].startswith("https://")
    if source == "npa":
        assert rows[0]["agency"] == "臺北市政府警察局"
        assert rows[0]["date_kind"] == "更新日期"
    if source == "taipei-traffic":
        assert rows[0]["agency"] == "臺北市政府警察局中山分局"


@pytest.mark.parametrize("title,expected", [
    ("新增2處固定式測速照相", "新增"),
    ("新設區間測速10月啟用", "新增"),
    ("增設固定桿", "新增"),
    ("增加1處固定式測速照相桿", "新增"),
    ("固定式照相設備移設公告", "調整"),
    ("調整區間測速速限", "調整"),
    ("拆除測速設備", "移除"),
    ("停止執法：區間測速", "移除"),
    ("科技執法重新啟用", "調整"),
    ("科技執法測試期間寄發通知單", "調整"),
    ("彰化首處科技執法導入AI辨識剔除禮讓救護車違規9月1日啟用", "調整"),
    ("拆除舊測速桿並新增2處", "調整"),
    ("新增公車路線", None),
    ("測速照相機改當裁判！學生比拚誰騎得最慢", None),
    ("固定式科技執法設備設置地點一覽表", None),
    ("再次公布固定式測速照相位置", None),
])
def test_change_and_enforcement_keywords_are_both_required(title, expected):
    assert watcher.classify_title(title, CONFIG["keywords"]) == expected


def test_filter_keywords_are_configurable_without_changing_parser():
    keywords = copy.deepcopy(CONFIG["keywords"])
    keywords["changes"]["調整"].append("重啟")
    keywords["exclude"] = ["績效"]
    assert watcher.classify_title("北宜區間測速重啟", keywords) == "調整"
    assert watcher.classify_title("新增測速照相取締績效", keywords) is None


@pytest.mark.parametrize("date_text,expected", [("115-11-06", "2026-11-06"), ("2026/11/06", "2026-11-06"), ("115年11月6日", "2026-11-06")])
def test_title_dates_do_not_override_the_publication_cell(date_text, expected):
    text = fixture("ccms-list").replace("115-11-06", date_text).replace(
        "臺北市政府警察局固定式科技執法設備設置地點一覽表", "2027-01-01新增科技執法")
    _, rows = watcher.parse_listing(text, SOURCES["taipei-traffic"], SOURCES["taipei-traffic"]["url"])
    assert rows[0]["date"] == expected


def test_invalid_publication_date_is_not_treated_as_no_announcements():
    text = fixture("npa-list").replace("115-10-08", "115-02-31")
    with pytest.raises(ValueError):
        watcher.parse_listing(text, SOURCES["npa"], SOURCES["npa"]["url"])


def test_article_body_omits_contact_address_and_retains_actual_junction():
    body = watcher.extract_body(fixture("npa-body"), "npa")
    locations = watcher.extract_locations("", body)
    assert "和平西路與重慶南路口" in locations
    assert "測試路999號" not in body
    assert not any("用路人" in location for location in locations)
    body = watcher.extract_body(fixture("changhua-body"), "changhua")
    assert "埔心鄉中山路1段與柳橋東路口" in watcher.extract_locations("", body)


def test_bus_stop_locations_remain_text_not_invented_addresses():
    body = "地點為【忠義新城（往東）、社子市場（往北）、社正路（往東）、明湖國小（公共電視台）（往西）】。"
    locations = watcher.extract_locations("", body)
    assert "忠義新城" in locations
    assert "社子市場" in locations
    assert "明湖國小（公共電視台）" in locations
    assert not any("號" in location for location in locations)


@pytest.mark.parametrize("parser,text", [
    ("npa", "<div class='list_group'><div class='list'></div></div>"),
    ("ccms", "<main>查無資料</main>"),
    ("taichung", "<div>查無相關資料</div>"),
])
def test_explicit_empty_results_are_valid(parser, text):
    _, rows = watcher.parse_listing(text, {"parser": parser, "agency": "測試", "id": "test"}, "https://example.gov.tw/")
    assert rows == []


@pytest.mark.parametrize("text", [
    "<html><title>Access denied</title><p>Please verify you are human</p></html>",
    "<html><div class='list'></div><form>登入</form></html>",
    "<html><p>網站已改版</p><a href='/news/view?serno=bad'>無日期公告</a></html>",
])
def test_blocked_or_changed_page_is_not_success_shaped_empty_list(text):
    with pytest.raises(ValueError, match="找不到有日期"):
        watcher.parse_listing(text, SOURCES["npa"], SOURCES["npa"]["url"])


def camera(address="北宜路一段177號前", city="新北市", id="known"):
    return {"id": id, "address": address, "city": city}


def compare(locations, cameras, city="新北市", title="新增固定式測速照相", body=""):
    return watcher.compare_cameras(
        {"agency": city + "政府警察局" if city else "官方", "title": title, "locations": locations},
        {"city": city}, body, cameras)


@pytest.mark.parametrize("locations,cameras,city,expected,matched", [
    (["新店區北宜路1段177號"], [camera()], "新北市", "可能已收", ["known"]),
    (["新店區北宜路1段178號"], [camera()], "新北市", "可能未收", []),
    (["新店區北宜路1段177號"], [camera(city="臺北市")], "新北市", "可能未收", []),
    (["北宜路"], [camera()], "新北市", "無法判斷", []),
    (["北宜路1段177號"], [camera()], "", "無法判斷", []),
    (["北宜路1段177號"], [], "新北市", "無法判斷", []),
    (["北宜路1段177號", "北宜路1段178號"], [camera()], "新北市", "可能未收", ["known"]),
    (["中山路1段與柳橋東路口"], [camera("柳橋東路與中山路一段口", "彰化縣")], "彰化縣", "可能已收", ["known"]),
    (["台9線14.5K處"], [camera("新店區台9線14.5K處")], "新北市", "可能已收", ["known"]),
    (["北宜路1段177號"], [camera("北宜路1段1177號")], "新北市", "可能未收", []),
])
def test_collection_hints_require_complete_place_and_same_city(locations, cameras, city, expected, matched):
    status, ids, reason = compare(locations, cameras, city)
    assert status == expected
    assert ids == matched
    assert reason


def test_multi_city_notice_is_ambiguous_and_does_not_inherit_publishers_city():
    status, ids, reason = compare(["北宜路1段177號"], [camera()], title="新增測速照相：新北市及臺北市")
    assert status == "無法判斷" and not ids


def test_year_window_seen_state_and_cross_search_duplicates(tmp_path):
    config = configuration("npa")
    config["search_terms"] = ["測速", "科技執法", "照相"]
    report, updates = run_watch(tmp_path, config)
    assert report["new_count"] == 2
    assert len(updates) == 2
    assert all(item["date"] >= "2025-11-16" for item in report["announcements"])
    repeated, repeated_updates = run_watch(tmp_path, config, updates)
    assert repeated["new_count"] == 0 and not repeated_updates
    assert repeated["sources"][0]["requests"] == 3, "已見公告不再請求內文"


def test_changed_title_at_same_url_is_reported_again(tmp_path):
    report, seen = run_watch(tmp_path)
    changed = report["announcements"][0].copy()
    changed["title"] += "（修正）"
    seen[watcher.canonical_url(changed["url"])] = watcher.fingerprint(changed)
    report, updates = run_watch(tmp_path, seen=seen)
    assert report["new_count"] == 1
    assert len(updates) == 1


def test_canonical_identity_removes_view_category_tracking_and_padding():
    assert watcher.canonical_url("https://td.police.gov.taipei/News_Content.aspx?n=a&s=abc&PageSize=20") == (
        watcher.canonical_url("https://police.gov.taipei/News_Content.aspx?n=b&s=abc&_Query=temporary"))
    assert watcher.canonical_url("https://www.chpb.gov.tw/Announcement/C002100?SearchKeyword=x&ID=abc&PageIndex=1") == (
        watcher.canonical_url("https://www.chpb.gov.tw/Announcement/C002100?ID=abc&PageType=1"))
    assert watcher.canonical_url("https://www.hpb.npa.gov.tw/ch/app/news/view?serno=A241352%20%20") == (
        watcher.canonical_url("https://www.hpb.npa.gov.tw/ch/app/news/view?serno=A241352"))


def test_one_failed_entrance_does_not_discard_other_announcements(tmp_path, capsys):
    report, updates = run_watch(tmp_path, configuration("highway", "npa"))
    assert [source["status"] for source in report["sources"]] == ["failed", "ok"]
    assert report["new_count"] == 2 and len(updates) == 2
    assert "官方入口暫時失聯" in capsys.readouterr().err


def test_one_failed_list_does_not_block_another_list_at_the_same_agency(tmp_path):
    class MultipleLists(FixtureClient):
        def fetch(self, url, fields=None):
            self.requests.append({"url": url})
            if "lp-909" in url:
                raise urllib.error.URLError("第一個列表失聯")
            return fixture("ntpc-list").replace("113-11-07", "115-11-07"), url
    report, _ = run_watch(tmp_path, configuration("ntpc-traffic"), client=MultipleLists)
    assert report["new_count"] == 1
    assert report["sources"][0]["status"] == "partial"
    assert report["sources"][0]["rows"] == 2


def test_body_failure_keeps_pending_title_but_does_not_acknowledge_it(tmp_path):
    class FailedBody(FixtureClient):
        def fetch(self, url, fields=None):
            if "/news/view?" in url:
                raise urllib.error.URLError("內文失聯")
            return super().fetch(url, fields)
    report, updates = run_watch(tmp_path, client=FailedBody)
    assert report["new_count"] == 2 and not updates
    assert report["sources"][0]["status"] == "partial"
    assert all("內文失聯" in " ".join(item["notes"]) for item in report["announcements"])


def test_detail_limit_is_visible_and_unread_details_are_retried(tmp_path):
    config = configuration("npa")
    config["requests"]["max_details"] = 1
    report, updates = run_watch(tmp_path, config)
    assert report["new_count"] == 2 and len(updates) == 1
    assert any("內文上限" in warning for warning in report["warnings"])
    retried, retried_updates = run_watch(tmp_path, config, updates)
    assert retried["new_count"] == 1 and len(retried_updates) == 1


def test_javascript_pager_is_followed_and_page_cap_is_explicit(tmp_path):
    class Paged(FixtureClient):
        def fetch(self, url, fields=None):
            text, actual = super().fetch(url, fields)
            if "/news/view?" not in url:
                text = text.replace('</select>', '<option value="1">2</option></select>')
            return text, actual
    config = configuration("npa")
    config["requests"]["max_pages"] = 1
    report, updates = run_watch(tmp_path, config, client=Paged)
    assert any("分頁上限" in warning for warning in report["warnings"])
    root = watcher.Document(fixture("npa-list").replace('</select>', '<option value="1">2</option></select>')).root
    url = watcher.next_page(root, "https://www.npa.gov.tw/list?keyword=測速&page=0", "npa")
    assert parse_qs(urlsplit(url).query)["page"] == ["1"]


def test_disabled_next_page_anchor_is_not_fetched_again():
    root = watcher.Document(fixture("keelung-table")).root
    assert watcher.next_page(root, SOURCES["keelung"]["url"], "keelung") is None


def test_standard_form_submission_preserves_viewstate_and_query_field(tmp_path):
    class FormClient(FixtureClient):
        def fetch(self, url, fields=None):
            self.requests.append({"url": url, "fields": fields})
            return fixture("ccms-list"), url
    client = FormClient(SOURCES["taipei-traffic"], CONFIG["requests"], tmp_path)
    list(watcher.search_pages(client, SOURCES["taipei-traffic"], ["測速", "科技執法"]))
    assert client.requests[1]["fields"] == {
        "__VIEWSTATE": "fixture-state", "__EVENTVALIDATION": "fixture-validation",
        "jNewsModule_field_0": "測速", "jNewsModule_BtnSend": "送出查詢"}
    assert client.requests[2]["fields"]["jNewsModule_field_0"] == "科技執法"


def test_http_timeout_spacing_budget_and_evidence_are_bounded(tmp_path, monkeypatch):
    options = dict(CONFIG["requests"], max_requests=2, interval=1)
    client = watcher.HttpClient(SOURCES["npa"], options, tmp_path)
    calls = []

    class Opener:
        def open(self, request, timeout):
            calls.append((request, timeout))
            response = io.BytesIO(b"<html>fixture</html>")
            response.status, response.url = 200, request.full_url
            return response
    client.opener = Opener()
    monkeypatch.setattr(watcher.time, "monotonic", lambda: 10.0)
    waits = []
    monkeypatch.setattr(watcher.time, "sleep", waits.append)
    client.fetch(SOURCES["npa"]["url"])
    client.fetch(SOURCES["npa"]["url"])
    with pytest.raises(ValueError, match="請求上限"):
        client.fetch(SOURCES["npa"]["url"])
    assert len(calls) == 2 and calls[0][1] == 12
    assert calls[0][0].get_header("User-agent") == "announcement-watch/1.0"
    assert waits == [1]
    assert len(list(tmp_path.glob("*.html"))) == 2
    assert client.requests[0]["sha256"] == hashlib.sha256(b"<html>fixture</html>").hexdigest()


def install_main_fixture(tmp_path, monkeypatch, config=None):
    paths = {name: tmp_path / name for name in ("config.json", "seen.json", "cameras.json", "body.md")}
    paths["config.json"].write_text(json.dumps(config or configuration("npa"), ensure_ascii=False), encoding="utf-8")
    paths["seen.json"].write_text('{"schema_version":1,"seen":{}}\n', encoding="utf-8")
    paths["cameras.json"].write_text('{"cameras":[]}\n', encoding="utf-8")
    paths["body.md"].write_text("既有資料更新說明\n", encoding="utf-8")
    monkeypatch.setattr(watcher, "HttpClient", FixtureClient)
    args = ["--config", str(paths["config.json"]), "--seen", str(paths["seen.json"]),
            "--cameras", str(paths["cameras.json"]), "--output-dir", str(tmp_path / "output"),
            "--since", "2025-11-16", "--until", "2026-11-16", "--pr-body", str(paths["body.md"])]
    return paths, args


def test_cli_outputs_csv_markdown_but_seen_requires_explicit_flag(tmp_path, monkeypatch):
    paths, args = install_main_fixture(tmp_path, monkeypatch)
    before = {name: path.read_bytes() for name, path in paths.items()}
    assert watcher.main(args) == 0
    assert paths["seen.json"].read_bytes() == before["seen.json"]
    assert paths["cameras.json"].read_bytes() == before["cameras.json"]
    with (tmp_path / "output" / "pending.csv").open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
    assert len(rows) == 2 and rows[0]["change"] == "調整"
    assert "本週新公告" in paths["body.md"].read_text(encoding="utf-8")
    assert "非自動新增相機" in paths["body.md"].read_text(encoding="utf-8")
    assert watcher.main(args + ["--update-seen"]) == 0
    seen = paths["seen.json"].read_bytes()
    paths["body.md"].write_bytes(before["body.md"])
    assert watcher.main(args + ["--update-seen"]) == 0
    assert paths["seen.json"].read_bytes() == seen
    assert paths["body.md"].read_bytes() == before["body.md"], "無新公告不追加雜訊"
    assert paths["cameras.json"].read_bytes() == before["cameras.json"]


@pytest.mark.parametrize("fault", ["seen", "cameras", "config"])
def test_corrupt_inputs_fail_before_network_and_do_not_reset_state(tmp_path, monkeypatch, fault):
    paths, args = install_main_fixture(tmp_path, monkeypatch)
    paths[fault + ".json"].write_text("{}", encoding="utf-8")
    before = paths["seen.json"].read_bytes()
    def unexpected(*args):
        pytest.fail("無效輸入不得發送網路請求")
    monkeypatch.setattr(watcher, "HttpClient", unexpected)
    assert watcher.main(args + ["--update-seen"]) == 2
    assert paths["seen.json"].read_bytes() == before


def test_all_entrances_failed_returns_failure_with_report_not_false_zero_success(tmp_path, monkeypatch):
    paths, args = install_main_fixture(tmp_path, monkeypatch, configuration("highway"))
    assert watcher.main(args + ["--update-seen"]) == 1
    report = json.loads((tmp_path / "output" / "report.json").read_text(encoding="utf-8"))
    assert report["sources"][0]["status"] == "failed"
    assert report["warnings"]
    assert json.loads(paths["seen.json"].read_text(encoding="utf-8"))["seen"] == {}


def test_missing_existing_pr_body_fails_without_acknowledging_notices(tmp_path, monkeypatch):
    paths, args = install_main_fixture(tmp_path, monkeypatch)
    paths["body.md"].unlink()
    assert watcher.main(args + ["--update-seen"]) == 2
    assert json.loads(paths["seen.json"].read_text(encoding="utf-8"))["seen"] == {}
    assert not paths["body.md"].exists()


@pytest.mark.parametrize("camera", [{"id": 42, "address": "北宜路"}, {"id": "test", "address": None}])
def test_bad_camera_rows_do_not_produce_missing_collection_hints(tmp_path, monkeypatch, camera):
    paths, args = install_main_fixture(tmp_path, monkeypatch)
    paths["cameras.json"].write_text(json.dumps({"cameras": [camera]}), encoding="utf-8")
    assert watcher.main(args) == 2
    assert not (tmp_path / "output" / "report.json").exists()


def test_csv_and_markdown_escape_external_text(tmp_path):
    report, _ = run_watch(tmp_path)
    item = report["announcements"][0]
    item["title"] = "=1+2|[偽連結]<script>"
    path = tmp_path / "pending.csv"
    watcher.write_csv(path, [item])
    with path.open(encoding="utf-8-sig", newline="") as stream:
        assert next(csv.DictReader(stream))["title"].startswith("'=")
    text = watcher.render_markdown(report)
    assert "<script>" not in text and "&lt;script&gt;" in text
    assert "\\|" in text and "\\[偽連結\\]" in text


def test_cli_runs_in_isolated_python_without_installing_packages(tmp_path):
    result = subprocess.run([sys.executable, "-I", "-X", "utf8", str(ROOT / "data-pipeline" / "watch_announcements.py"), "--help"],
                            cwd=tmp_path, capture_output=True)
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    assert b"--cameras" in result.stdout


def test_weekly_workflow_parses_and_only_persists_seen_index_as_announcement_change():
    document = yaml.safe_load((ROOT / ".github" / "workflows" / "data.yml").read_text(encoding="utf-8"))
    steps = document["jobs"]["refresh"]["steps"]
    watch = next(step for step in steps if "watch_announcements.py" in step.get("run", ""))
    install = next(step for step in steps if "data-pr-body.py" in step.get("run", ""))
    pr = next(step for step in steps if step.get("uses", "").startswith("peter-evans/create-pull-request@"))
    assert steps.index(install) < steps.index(watch) < steps.index(pr)
    assert "--cameras build/ci-data/cameras.json" in watch["run"]
    assert "--update-seen" in watch["run"] and "--pr-body build/data-pr-body.md" in watch["run"]
    assert watch["continue-on-error"] is True
    assert pr["with"]["add-paths"].splitlines() == [
        "SpeedCam/Resources/cameras.json", "data-pipeline/announcements_seen.json"]
    assert not any("issues:" in key for key in document["permissions"])
    artifact = next(step for step in steps if step.get("uses", "").startswith("actions/upload-artifact@"))
    assert "always()" in artifact["if"] and "build/announcements/" in artifact["with"]["path"]
