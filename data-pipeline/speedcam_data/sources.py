"""下載與解析原始資料（CSV / JSON）。只用 Python 標準函式庫。"""
from __future__ import annotations

import csv
import io
import json
import urllib.request
from typing import Any, Iterable, Optional

USER_AGENT = "taiwan-speedcam-data-pipeline/1.0 (+https://github.com)"

# 政府資料開放平臺「測速執法設置點」（內政部警政署）
NATIONAL_DATASET_ID = "7320"
DATASET_API = "https://data.gov.tw/api/v2/rest/dataset/{id}"
# 平臺 API 取不到下載連結時的備援（警政署開放資料 API）
FALLBACK_URLS = [
    "https://od.moi.gov.tw/api/v1/rest/datastore/A01010000C-000674-011",
]

ATTRIBUTION = [
    "內政部警政署「測速執法設置點」，政府資料開放授權條款－第1版（https://data.gov.tw/license）",
]


def http_get(url: str, timeout: float = 60) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310（只連政府網站）
        return resp.read()


def decode_text(raw: bytes) -> str:
    """政府資料常見 UTF-8（含 BOM）或 Big5（cp950）。"""
    for enc in ("utf-8-sig", "cp950", "big5"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def parse_csv(text: str) -> list[dict]:
    reader = csv.DictReader(io.StringIO(text))
    return [dict(r) for r in reader]


def _find_records(obj: Any) -> Optional[list[dict]]:
    """在 JSON 中找出「物件陣列」形式的資料列。"""
    if isinstance(obj, list) and obj and all(isinstance(x, dict) for x in obj):
        return obj
    if isinstance(obj, dict):
        for key in ("records", "data", "result", "Data", "Records", "items"):
            if key in obj:
                found = _find_records(obj[key])
                if found is not None:
                    return found
        for value in obj.values():
            found = _find_records(value)
            if found is not None:
                return found
    return None


def parse_json(text: str) -> list[dict]:
    records = _find_records(json.loads(text))
    if records is None:
        raise ValueError("JSON 裡找不到資料列")
    return records


def parse_payload(raw: bytes, hint: str = "") -> list[dict]:
    text = decode_text(raw).strip()
    if hint.lower().endswith("json") or text.startswith("{") or text.startswith("["):
        return parse_json(text)
    return parse_csv(text)


def _collect_urls(obj: Any, out: list[tuple[str, str]]) -> None:
    """從資料集 API 回應裡蒐集下載連結（欄位名稱可能變動，所以用遞迴搜尋）。"""
    if isinstance(obj, dict):
        fmt = str(obj.get("resourceFormat") or obj.get("format") or "")
        for key, value in obj.items():
            if isinstance(value, str) and value.startswith("http") and (
                "download" in key.lower() or "url" in key.lower()
            ):
                out.append((value, fmt))
            else:
                _collect_urls(value, out)
    elif isinstance(obj, list):
        for item in obj:
            _collect_urls(item, out)


def dataset_download_urls(dataset_id: str) -> list[tuple[str, str]]:
    meta = json.loads(decode_text(http_get(DATASET_API.format(id=dataset_id))))
    urls: list[tuple[str, str]] = []
    _collect_urls(meta.get("result", meta), urls)
    # CSV、JSON 優先；排除資料集頁面本身
    preferred = [u for u in urls if u[1].upper() in ("CSV", "JSON") or u[0].lower().endswith((".csv", ".json"))]
    others = [u for u in urls if u not in preferred and "data.gov.tw/dataset" not in u[0]]
    return preferred + others


def fetch_national_rows(log=print) -> list[dict]:
    """下載全國測速執法設置點資料。依序嘗試平臺 API 提供的連結與備援連結。"""
    candidates: list[tuple[str, str]] = []
    try:
        candidates += dataset_download_urls(NATIONAL_DATASET_ID)
    except Exception as exc:  # noqa: BLE001
        log(f"[警告] 無法讀取資料集 {NATIONAL_DATASET_ID} 的中繼資料：{exc}")
    candidates += [(u, "JSON") for u in FALLBACK_URLS]

    errors = []
    for url, fmt in candidates:
        try:
            log(f"下載 {url}")
            rows = parse_payload(http_get(url), fmt or url)
            if rows:
                log(f"  取得 {len(rows)} 筆，欄位：{list(rows[0].keys())}")
                return rows
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{url}: {exc}")
            log(f"  失敗：{exc}")
    raise RuntimeError("所有資料來源都下載失敗：\n" + "\n".join(errors))


def read_local_rows(paths: Iterable[str]) -> list[dict]:
    rows: list[dict] = []
    for p in paths:
        with open(p, "rb") as f:
            rows += parse_payload(f.read(), p)
    return rows
