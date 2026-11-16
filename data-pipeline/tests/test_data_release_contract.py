import contextlib
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import zipfile

import pytest

from ci_contract_helpers import ROOT

sys.path.insert(0, str(ROOT / "data-pipeline"))

import build_cameras
from speedcam_data import additional_sources, mileposts, sources
from test_additional_sources import douliu_milepost_index

INPUT = Path(__file__).with_name("fixtures") / "ci" / "release-input-v1.json"


def load_bundle():
    path = ROOT / "scripts" / "ci" / "data-bundle.py"
    assert path.exists(), "發布入口尚未驗證同份資料的來源／區間完整性"
    spec = importlib.util.spec_from_file_location("ci_data_bundle", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def production_input(monkeypatch, tmp_path, douliu_milepost_index):
    fixture = json.loads(INPUT.read_text(encoding="utf-8"))
    for path, digest in fixture["inputSHA256LF"].items():
        assert hashlib.sha256((ROOT / path).read_bytes().replace(b"\r\n", b"\n")).hexdigest() == digest, path
    national = list(fixture["national"])
    for index in range(fixture["capacity"]["cameras"]):
        national.append(dict(Address=f"契約合成照相點{index}", Latitude=str(22.5 + index // 50 * 0.1),
                             Longitude=str(120.1 + index % 50 * 0.01), direct="北往南", limit="50"))
    monkeypatch.setattr(sources, "fetch_national_rows", lambda: list(national))
    monkeypatch.setattr(sources, "fetch_official_rows", lambda dataset, *args, **kwargs: sources.read_local_rows([
        build_cameras.DEFAULT_FREEWAY_SNAPSHOT if dataset == "13940" else build_cameras.DEFAULT_NTPC_SNAPSHOT]))
    markers = fixture["tai64"]
    for a, b in zip(markers, markers[1:]):
        for offset in range(round((b[0] - a[0]) * 10) + 1):
            ratio = offset / ((b[0] - a[0]) * 10)
            douliu_milepost_index.add("台64", round(a[0] + offset / 10, 1),
                                      a[1] + (b[1] - a[1]) * ratio, a[2] + (b[2] - a[2]) * ratio)
    monkeypatch.setattr(mileposts, "fetch_index", lambda **kwargs: douliu_milepost_index)
    monkeypatch.setattr(additional_sources, "load_official", lambda *args, **kwargs: ([], []))
    monkeypatch.setattr(build_cameras.osm_cameras, "load_elements", lambda **kwargs: [])
    mobile = additional_sources.parse_douliu_mobile((additional_sources.SNAPSHOTS / "douliu-mobile.raw").read_bytes())

    def load_mobile(report, *, resolve, **kwargs):
        return additional_sources.adapt_mobile(mobile, "douliu-mobile", report, resolve=resolve), [
            "斗六分局公告（流程契約 fixture）"]

    monkeypatch.setattr(additional_sources, "load_mobile", load_mobile)
    text = Path(build_cameras.DEFAULT_SECTIONS).read_text(encoding="utf-8")
    rows = list(csv.DictReader(line for line in text.splitlines() if not line.startswith("#")))
    for index in range(fixture["capacity"]["sections"]):
        rows.append(dict(id=f"contract-{index}", name=f"合成容量區間{index}", start_lat="23.1", start_lon="120.5",
                         end_lat="23.11", end_lon="120.5", length_m="1112", speed_limit="50"))
    manual = tmp_path / "sections.csv"
    with manual.open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    supplemental = tmp_path / "sections-text.csv"
    supplemental.write_text("Address\n", encoding="utf-8")
    return ["--sections", str(manual), "--sections-text", str(supplemental)]


def real_build(directory, arguments):
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "data-build.log").open("w", encoding="utf-8") as log, contextlib.redirect_stdout(log):
        status = build_cameras.main(["--output", str(directory / "cameras.json"), "--min-count", "500", *arguments])
    assert status == 0
    return json.loads((directory / "cameras.json").read_text(encoding="utf-8"))


def test_real_builder_records_required_input_state(production_input, tmp_path):
    db = real_build(tmp_path / "bundle", production_input)
    assert db["buildStatus"]["mileposts"]["status"] == "available"
    assert db["buildStatus"]["mileposts"]["count"] > 0
    assert len(db["sections"]) >= 70 and len(db["cameras"]) >= 500
    assert not any("金門大橋" in s["name"] for s in db["sections"]), "單點公告不能變成虛構雙端"
    assert len([c for c in db["cameras"] if c.get("source") == "douliu-mobile"]) == 4
    counts = db["sourceReport"]["sources"]["douliu-mobile"]
    assert (counts["locationSuccess"], counts["added"], counts["merged"]) == (5, 4, 1)
    assert all(c.get("speedLimit") is None for c in db["cameras"] if c.get("source") == "douliu-mobile")
    assert next(c for c in db["cameras"] if "銀河" in c["address"])["speedLimit"] == 40
    by_id = {s["id"]: s for s in db["sections"]}
    assert by_id["beiyi-2-f"]["start"] == {"lat": 24.9504174, "lon": 121.6477995}
    assert by_id["beiyi-2-r"]["end"] == {"lat": 24.9503516, "lon": 121.6478697}


@pytest.mark.parametrize("offline", [False, True])
def test_same_bundle_from_real_builder_to_release_gate(production_input, monkeypatch, tmp_path, offline):
    if offline:
        def unavailable(**kwargs):
            return sources.parse_payload(b"<!DOCTYPE html><html>7040 unavailable</html>")
        monkeypatch.setattr(mileposts, "fetch_index", unavailable)
    bundle = load_bundle()
    directory = tmp_path / "bundle"
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()

    def run_builder(output):
        real_build(output, production_input)
        return 0

    monkeypatch.setattr(bundle, "run_builder", run_builder)
    assert bundle.main(["prepare", "--directory", str(directory), "--commit", commit]) == 0
    manifest_path = directory / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    installed = tmp_path / "installed.json"
    arguments = ["verify", "--directory", str(directory), "--commit", commit, "--manifest-sha", expected_hash,
                 "--install", str(installed)]
    assert bundle.main(arguments) == 0, "降級 smoke 仍須明示後可測"
    assert installed.read_bytes() == (directory / "cameras.json").read_bytes()
    assert manifest["releaseEligible"] is (not offline)
    assert manifest["completeness"] == ("degraded" if offline else "complete")
    assert bundle.main(arguments + ["--release"]) == (1 if offline else 0)
    if offline:
        assert any("7040" in reason for reason in manifest["releaseBlockers"])
        assert "7040" in (directory / "data-build.log").read_text(encoding="utf-8")
    else:
        fixture_path = ROOT / "Packages" / "SpeedCamCore" / "Tests" / "SpeedCamCoreTests" / "Fixtures" / "current_database_v1.json"
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        assert fixture["inputManifestSHA256LF"] == hashlib.sha256(INPUT.read_bytes().replace(b"\r\n", b"\n")).hexdigest()
        for key in ("cameras", "sections"):
            actual = {row["id"]: row for row in json.loads(installed.read_text(encoding="utf-8"))[key]}
            assert all(actual[row["id"]] == row for row in fixture[key]), "核心小型 fixture 必須來自同一真建置入口"


@pytest.mark.parametrize("fault", ["cameras", "sources", "log", "manifest", "commit", "sections",
                                  "missing-douliu", "hotspot-speed", "galaxy-limit"])
def test_bundle_rejects_tampering_wrong_revision_and_section_collapse(production_input, tmp_path, fault):
    bundle = load_bundle()
    directory = tmp_path / "bundle"
    db = real_build(directory, production_input)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if fault == "sections":
        db["sections"] = db["sections"][:19]
    if fault == "missing-douliu":
        db["cameras"] = [c for c in db["cameras"] if c.get("source") != "douliu-mobile"]
    if fault == "hotspot-speed":
        next(c for c in db["cameras"] if c.get("source") == "douliu-mobile")["speedLimit"] = 70
    if fault == "galaxy-limit":
        next(c for c in db["cameras"] if "銀河" in c["address"])["speedLimit"] = 50
    if fault in ("sections", "missing-douliu", "hotspot-speed", "galaxy-limit"):
        (directory / "cameras.json").write_text(json.dumps(db), encoding="utf-8")
    bundle.create_manifest(directory, commit)
    manifest_path = directory / "manifest.json"
    expected_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    if fault in ("cameras", "sources", "log", "manifest"):
        filename = {"cameras": "cameras.json", "sources": "sources.json", "log": "data-build.log",
                    "manifest": "manifest.json"}[fault]
        with (directory / filename).open("ab") as output:
            output.write(b"\nchanged")
    if fault == "commit":
        commit = "0" * 40
    assert bundle.main(["verify", "--directory", str(directory), "--commit", commit,
                        "--manifest-sha", expected_hash, "--release"]) == 1


def test_failed_preparation_cannot_reuse_old_successful_bundle(monkeypatch, tmp_path):
    bundle = load_bundle()
    directory = tmp_path / "bundle"
    directory.mkdir()
    for name in ("cameras.json", "manifest.json", "sources.json"):
        (directory / name).write_text('{"old": true}', encoding="utf-8")
    monkeypatch.setattr(bundle, "run_builder", lambda output: 1)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    assert bundle.main(["prepare", "--directory", str(directory), "--commit", commit]) == 1
    assert not (directory / "manifest.json").exists()
    assert not (directory / "cameras.json").exists()


@pytest.mark.parametrize("changed", ["none", "bytes", "degraded"])
def test_packaged_ipa_must_contain_the_exact_tested_data(production_input, tmp_path, changed):
    bundle = load_bundle()
    directory = tmp_path / "bundle"
    db = real_build(directory, production_input)
    if changed == "degraded":
        db["buildStatus"]["mileposts"] = {"status": "unavailable", "reason": "7040 offline"}
        (directory / "cameras.json").write_text(json.dumps(db), encoding="utf-8")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    bundle.create_manifest(directory, commit)
    data = (directory / "cameras.json").read_bytes()
    ipa = tmp_path / "SpeedCam.ipa"
    with zipfile.ZipFile(ipa, "w") as archive:
        archive.writestr("Payload/SpeedCam.app/cameras.json", data + (b" " if changed == "bytes" else b""))
    assert bundle.main(["verify", "--directory", str(directory), "--commit", commit,
                        "--manifest-sha", bundle.sha256(directory / "manifest.json"),
                        "--ipa", str(ipa)]) == (0 if changed == "none" else 1)
