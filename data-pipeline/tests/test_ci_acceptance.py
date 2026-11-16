import json
from pathlib import Path

import pytest

from ci_contract_helpers import ROOT, bash, shell_workspace, tool
from test_replay_1108_checker import records, row


def run_probe(tmp_path, suite, text, *, producer_exit=0, data_log="固定資料建置報告\n"):
    tools, env = shell_workspace(tmp_path)
    source = tmp_path / "producer.log"
    source.write_text(text, encoding="utf-8")
    (tmp_path / "data-build.log").write_text(data_log, encoding="utf-8")
    producer = tmp_path / "producer.py"
    producer.write_text(
        "import os,pathlib,sys\n"
        "print(pathlib.Path(os.environ['FAKE_PROBE_LOG']).read_text(encoding='utf-8'))\n"
        "pathlib.Path(sys.argv[3]).write_text('{}\\n')\n"
        f"sys.exit({producer_exit})\n", encoding="utf-8")
    tool(tools, "swiftc", """
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then shift; target="$1"; fi
  shift
done
mkdir -p "$(dirname "$target")"
printf '#!/usr/bin/env bash\\nexec python3 "$FAKE_PROBE_PRODUCER" "$@"\\n' > "$target"
chmod +x "$target"
""")
    for name in ("codesign", "defaults", "killall"):
        tool(tools, name, "exit 0")
    env.update(FAKE_PROBE_LOG=str(source), FAKE_PROBE_PRODUCER=str(producer),
               DATA_BUILD_LOG="data-build.log")
    return bash("scripts/ci/route-probe.sh", "replay", f"scripts/ci/route-replay-{suite}.json",
                "route-probe-results.jsonl", cwd=tmp_path, env=env)


def log_text(records):
    return "\n".join("REPLAY1108 " + json.dumps(r, ensure_ascii=False) for r in records)


@pytest.mark.parametrize("fault", ["navigation", "entered", "abort", "gate", "truncated", "source-report"])
def test_1108_real_entry_propagates_checker_failure(tmp_path, records, fault):
    data_log = "固定資料建置報告\n"
    if fault == "navigation":
        records[-1].update(correctManeuvers=99, totalManeuvers=100)
    elif fault == "entered":
        records.remove(row(records, "補測06", "section_entered"))
    elif fault == "abort":
        row(records, "北宜1去程", "section_completed")["event"] = "section_aborted"
    elif fault == "gate":
        row(records, "北宜2回程", "section_completed")["gateLat"] = 0
    elif fault == "truncated":
        records.pop()
    else:
        data_log += "[熱點行向] 壞掉的來源報告\n"
    result = run_probe(tmp_path, "1108", log_text(records), data_log=data_log)
    assert result.returncode != 0, result.stdout


def test_1108_real_entry_accepts_valid_log_and_retains_evidence(tmp_path, records):
    result = run_probe(tmp_path, "1108", log_text(records))
    assert result.returncode == 0, result.stdout + result.stderr
    assert (tmp_path / "build" / "route-probe" / "replay.log").read_text(encoding="utf-8").count("REPLAY1108 ") == len(records)
    report = json.loads((tmp_path / "build" / "route-probe" / "checker-result.json").read_text(encoding="utf-8"))
    assert report["conclusion"] == "success"


def test_producer_failure_is_not_hidden_by_tee(tmp_path, records):
    result = run_probe(tmp_path, "1108", log_text(records), producer_exit=42)
    assert result.returncode != 0


def basic_records(suite):
    cases = json.loads((ROOT / "scripts" / "ci" / f"route-replay-{suite}.json").read_text(encoding="utf-8"))
    result = [dict(schema=1, case="", event="run_start", t=0)]
    sections = {3: "tai64-zhonghe-west", 6: "tai64-zhonghe-east", 7: "ziqiang-tunnel-r",
                8: "xinhai-tunnel-r", 9: "xinhai-tunnel-f"} if suite == "1107" else {
                    0: "xinhai-tunnel-r", 1: "xinhai-tunnel-r"}
    for index, case in enumerate(cases):
        begin = len(result)
        def add(event, t, **kwargs):
            result.append(dict(schema=1, case=case["name"], event=event, t=t, lat=25, lon=121) | kwargs)
        add("case_start", 0)
        add("route_geometry", 0, pointCount=2, chunkCount=1, appleSteps=[])
        add("route_geometry_part", 0, index=0, points=[[25, 121], [25.01, 121]])
        if index in sections:
            for event, t in (("section_approach", 1), ("section_entered", 2), ("section_completed", 20)):
                add(event, t, id=sections[index])
        if suite == "tunnels":
            for camera in range(8 if index >= 7 else 1):
                address = case["name"].split("（")[0] + "照相點"
                add("camera_pre", 3 + camera, id=f"camera-{camera}", address=address, estimated=True, speeches=["前方照相"])
                if index < 7:
                    add("camera_near", 15 + camera, id=f"camera-{camera}", address=address, estimated=True, speeches=["100公尺"])
        result[begin:] = sorted(result[begin:], key=lambda row: row["t"])
        add("case_end", 30, sectionStillActive=False)
    result.append(dict(schema=1, case="", event="run_end", t=0, failed=0, succeeded=len(cases),
                       correctManeuvers=2, totalManeuvers=2))
    return result


@pytest.mark.parametrize("suite", ["1107", "tunnels"])
@pytest.mark.parametrize("fault", ["missing-event", "navigation", "truncated", "abort", "valid"])
def test_other_suites_use_their_own_contracts(tmp_path, suite, fault):
    rows = basic_records(suite)
    if fault == "missing-event":
        rows.remove(next(r for r in rows if r["event"] == ("section_entered" if suite == "1107" else "camera_pre")))
    elif fault == "navigation":
        rows[-1]["correctManeuvers"] = 1
    elif fault == "truncated":
        rows.pop()
    elif fault == "abort":
        next(r for r in rows if r["event"] == "section_completed")["event"] = "section_aborted"
    result = run_probe(tmp_path, suite, log_text(rows))
    assert (result.returncode == 0) == (fault == "valid"), result.stdout + result.stderr
