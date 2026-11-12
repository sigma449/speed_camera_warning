import csv
import json
from pathlib import Path
import subprocess
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_route_hints


def test_committed_resource_is_exactly_generated_from_reviewable_csv():
    actual = json.loads(build_route_hints.DEFAULT_OUTPUT.read_text(encoding="utf-8"))
    assert actual == build_route_hints.build(build_route_hints.DEFAULT_INPUT)
    assert all("OSM" in hint["source"] and "使用者實測" in hint["source"] for hint in actual)


@pytest.mark.parametrize("field,value", [
    ("heading", "nan"), ("heading", "360"), ("radius_m", "80"),
    ("lat", "0"), ("short_text", ""), ("instruction", ""), ("source", ""), ("replace_text", "|左轉"),
])
def test_invalid_hint_cannot_silently_become_an_undirected_or_empty_hint(tmp_path, field, value):
    with build_route_hints.DEFAULT_INPUT.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        columns = reader.fieldnames
        row = next(reader)
    row[field] = value
    path = tmp_path / "hints.csv"
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        writer.writerow(row)
    with pytest.raises(ValueError, match="第2列"):
        build_route_hints.build(path)


def test_cli_reports_failure_and_does_not_replace_resource(tmp_path, capsys):
    target = tmp_path / "out.json"
    target.write_text("unchanged", encoding="utf-8")
    assert build_route_hints.main(["--input", str(tmp_path / "missing.csv"), "--output", str(target)]) == 1
    assert "建置失敗" in capsys.readouterr().err
    assert target.read_text(encoding="utf-8") == "unchanged"


def test_confirmation_point_must_independently_prove_the_branch(tmp_path):
    with build_route_hints.DEFAULT_INPUT.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        columns, row = reader.fieldnames, next(reader)
    row["confirmation_lat"] = str(float(row["lat"]) + 0.00001)
    row["confirmation_lon"] = row["lon"]
    path = tmp_path / "too-close.csv"
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        writer.writerow(row)
    with pytest.raises(ValueError, match="至少20m"):
        build_route_hints.build(path)


def test_cli_runs_in_isolated_mode_without_installing_local_modules(tmp_path):
    target = tmp_path / "out.json"
    result = subprocess.run([sys.executable, "-I", "-X", "utf8", str(Path(build_route_hints.__file__)),
                             "--output", str(target)], capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == 0, result.stderr
    assert json.loads(target.read_text(encoding="utf-8")) == build_route_hints.build(build_route_hints.DEFAULT_INPUT)
