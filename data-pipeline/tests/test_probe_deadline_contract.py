from ci_contract_helpers import ROOT


def test_vehicle_planning_and_search_use_cancellable_deadlines():
    source = (ROOT / "scripts" / "ci" / "route-probe.swift").read_text(encoding="utf-8")
    plans = source.split("try await RoutePlanner.plan(")
    assert len(plans) == 3, "plan 與 replay 的指定車種路徑都必須受保護"
    assert all("withRequestDeadline(" in prefix[-350:] for prefix in plans[:-1])
    assert "try await withRequestDeadline(" in source.split("let response = try await search.start()")[0][-800:] \
        or "return try await search.start()" in source and "search.cancel()" in source
    replay = source.split("func runReplay(", 1)[1]
    assert 'caseName: caseName, stage: "目的地搜尋"' in replay
    assert 'caseName: leg.name, stage: "指定車種規劃"' in replay
