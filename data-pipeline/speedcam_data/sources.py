"""下載與解析原始資料（CSV / JSON）。只用 Python 標準函式庫。"""
from __future__ import annotations

import csv
import io
import json
import ssl
import urllib.request
import zipfile
from typing import Any, Callable, Iterable, Optional

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
FREEWAY_ATTRIBUTION = "國道公路警察局「國道公路固定式測速照相地點」（13940），政府資料開放授權條款－第1版"
NTPC_ATTRIBUTION = "新北市政府警察局「區間平均速率執法設備設置地點」（126156），政府資料開放授權條款－第1版"
NTPC_SECTION_URL = "https://data.ntpc.gov.tw/api/datasets/27b97ad9-9dba-4ca9-b0ed-14b29000ffec/csv/file"


def ssl_context() -> ssl.SSLContext:
    """一般的憑證驗證（憑證鏈、主機名稱照常檢查），但關閉 Python 3.13 起預設的 X509 嚴格模式。

    政府網站（例如 opdadm.moi.gov.tw）的憑證缺少 Subject Key Identifier 欄位，
    在嚴格模式下會出現「CERTIFICATE_VERIFY_FAILED: Missing Subject Key Identifier」。
    """
    ctx = ssl.create_default_context()
    strict = getattr(ssl, "VERIFY_X509_STRICT", 0)
    if strict:
        ctx.verify_flags &= ~strict
    return ctx


def http_get(url: str, timeout: float = 60) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout, context=ssl_context()) as resp:  # noqa: S310（只連政府網站）
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
    if raw.startswith(b"PK\x03\x04"):
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            names = [n for n in archive.namelist()
                     if n.lower().endswith(".csv") and n.rsplit("/", 1)[-1].lower() != "manifest.csv"]
            if not names:
                raise ValueError("ZIP 裡沒有資料 CSV")
            return [row for name in names for row in parse_csv(decode_text(archive.read(name)))]
    text = decode_text(raw).strip()
    if text.lower().startswith(("<!doctype html", "<html")):
        raise ValueError("來源回傳 HTML，不是資料")
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


def fetch_official_rows(dataset_id: str, snapshot: str, validate: Callable[[list[dict]], None],
                        fallback_urls: tuple[str, ...] = (), log=print) -> list[dict]:
    """新增來源失聯或格式異常時使用已保存的官方快照，不讓單一來源拖垮整個建置。"""
    saved: list[dict] = []
    try:
        saved = read_local_rows([snapshot])
        validate(saved)
    except (OSError, ValueError) as exc:
        log(f"[警告] 官方快照 {snapshot} 無法使用：{exc}")
        saved = []

    candidates = [(u, "CSV") for u in fallback_urls]
    try:
        candidates += dataset_download_urls(dataset_id)
    except Exception as exc:  # noqa: BLE001（來源失聯，明確回退）
        log(f"[警告] 無法讀取資料集 {dataset_id} 的中繼資料：{exc}")
    for url, fmt in dict.fromkeys(candidates):
        try:
            log(f"下載官方資料 {dataset_id}：{url}")
            rows = parse_payload(http_get(url), fmt or url)
            validate(rows)
            if saved and len(rows) < len(saved):
                raise ValueError(f"只有 {len(rows)} 筆，少於已保存快照 {len(saved)} 筆，需人工確認是否撤點")
            log(f"官方資料 {dataset_id}：取得 {len(rows)} 筆")
            return rows
        except Exception as exc:  # noqa: BLE001（逐一嘗試並記錄失敗）
            log(f"[警告] 官方資料 {dataset_id} 下載或驗證失敗：{exc}")
    if saved:
        log(f"[警告] 官方資料 {dataset_id} 改用 repo 官方快照 {snapshot}（{len(saved)} 筆；非即時資料）")
        return saved
    log(f"[警告] 官方資料 {dataset_id} 與快照皆無法取得；保留原主來源／人工資料，未套用此來源，請人工確認")
    return []
