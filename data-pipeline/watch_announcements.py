#!/usr/bin/env python3
"""監看官方設備異動公告，只產生待人工核對的清單，絕不寫入相機資料。"""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
import hashlib
import html
from html.parser import HTMLParser
import csv
import json
from pathlib import Path
import re
import sys
import time
import urllib.error
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit
import urllib.request

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from speedcam_data.geocoding import normalize_address, parse_address, without_place
from speedcam_data.sources import ascii_url, decode_text, ssl_context

USER_AGENT = "announcement-watch/1.0"
VOID_TAGS = frozenset(("area", "base", "br", "col", "embed", "hr", "img", "input",
                       "link", "meta", "param", "source", "track", "wbr"))
BLOCK_TAGS = frozenset(("p", "div", "section", "article", "li", "tr", "td", "br", "h1", "h2", "h3"))
DATE_PATTERN = re.compile(r"(?<!\d)(\d{3,4})[-/.年](\d{1,2})[-/.月](\d{1,2})(?:日)?(?!\d)")
LINK_PATTERNS = {
    "npa": r"/news/view\?",
    "ccms": r"News_(?:Photo_)?Content\.aspx\?",
    "ntpc": r"(?:cp|fp)-\d+-\d+-\d+\.html",
    "taichung": r"[?&]mcustomize=news_view\.jsp&",
    "tnpd": r"/News/Details/",
    "keelung": r"[?&]article_id=\d+",
    "changhua": r"/Announcement/[^?]+\?.*\bID=",
}
DETAIL_SELECTORS = {
    "npa": [".ed_txt"],
    "ccms": [".user-edit", ".area-essay", ".essay"],
    "ntpc": [".cpArticle", ".cp", ".article"],
    "taichung": [".text", ".editor"],
    "tnpd": [".news_content", ".news-content", ".editor"],
    "keelung": [".editor", ".content_text"],
    "changhua": [".editor", ".main_body"],
}
NO_RESULTS = ("查無資料", "查無相關資料", "目前無資料", "目前沒有資料", "暫無資料", "無相關資料", "尚無資料")
CITIES = ("臺北市", "新北市", "桃園市", "臺中市", "臺南市", "高雄市", "基隆市", "宜蘭縣",
          "新竹市", "新竹縣", "苗栗縣", "彰化縣", "南投縣", "雲林縣", "嘉義市", "嘉義縣",
          "屏東縣", "花蓮縣", "臺東縣", "澎湖縣", "金門縣", "連江縣")


@dataclass
class Node:
    tag: str = ""
    attrs: dict = field(default_factory=dict)
    parent: Node | None = field(default=None, repr=False)
    children: list = field(default_factory=list)

    def nodes(self, tag=None):
        if tag is None or self.tag == tag:
            yield self
        for child in self.children:
            if isinstance(child, Node):
                yield from child.nodes(tag)

    def text(self):
        if self.tag in ("script", "style", "noscript"):
            return ""
        text = "".join(child.text() if isinstance(child, Node) else child for child in self.children)
        return "\n" + text + "\n" if self.tag in BLOCK_TAGS else text

    def matches(self, selector):
        if selector.startswith("."):
            return selector[1:] in self.attrs.get("class", "").split()
        if selector.startswith("#"):
            return self.attrs.get("id") == selector[1:]
        return self.tag == selector


class Document(HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.root = Node()
        self.stack = [self.root]
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        node = Node(tag, dict(attrs), self.stack[-1])
        self.stack[-1].children.append(node)
        if tag not in VOID_TAGS:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID_TAGS:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == tag:
                del self.stack[index:]
                break

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def compact(text):
    return re.sub(r"\s+", " ", text).strip()


def parse_date(text):
    match = DATE_PATTERN.search(text)
    if not match:
        return ""
    year, month, day = map(int, match.groups())
    return date(year + 1911 if year < 1911 else year, month, day).isoformat()


def classify_title(title, keywords):
    if not any(term in title for term in keywords["subjects"]):
        return None
    if any(term in title for term in keywords.get("exclude", [])):
        return None
    found = {kind for kind, terms in keywords["changes"].items() if any(term in title for term in terms)}
    if len(found) > 1:
        return "調整"
    return next(iter(found)) if found else None


def canonical_url(url):
    parts = urlsplit(url.strip())
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.username or parts.password:
        raise ValueError(f"非公開 HTTP(S) 連結：{url}")
    host = parts.hostname.lower()
    if host.endswith(".police.gov.taipei"):
        host = "police.gov.taipei"
    query = dict(parse_qsl(parts.query))
    for key in ("s", "serno", "dataserno", "article_id", "ID"):
        if key in query:
            return urlunsplit(("https", host, parts.path.lower(), urlencode({key: query[key].strip()}), ""))
    path = re.sub(r"/(?:cp|fp)-\d+-(\d+)-\d+\.html$", r"/article-\1", parts.path)
    return urlunsplit(("https", host, path, "", ""))


def fingerprint(item):
    return hashlib.sha256((compact(item["title"]) + "\0" + item["date"]).encode()).hexdigest()


def row_for(link, parser):
    node = link
    while node.parent:
        if parser == "keelung" and node.matches(".card"):
            return node
        if parser == "changhua" and node.tag == "div" and node.matches(".row"):
            return node
        if parser != "changhua" and node.tag in ("tr", "li"):
            return node
        node = node.parent
    return None


def parse_listing(text, source, url):
    parser = source["parser"]
    root = Document(text).root
    rows = []
    for link in root.nodes("a"):
        href = link.attrs.get("href", "").strip()
        if not re.search(LINK_PATTERNS[parser], href, re.I):
            continue
        row = row_for(link, parser)
        if row is None:
            continue
        row_text = compact(row.text())
        if not DATE_PATTERN.search(row_text) and not any(
                DATE_PATTERN.fullmatch(compact(node.text())) for node in row.nodes()):
            continue
        title = link.attrs.get("title", "") if parser != "ntpc" else ""
        if not title:
            heading = next((n for n in link.nodes() if n.tag in ("h2", "h3", "h4")), None)
            title = heading.text() if heading else link.text()
        title = compact(title)
        agency = source["agency"]
        if parser == "npa":
            category = re.search(r"分類[：:]\s*(.*?)\s*發布單位", row_text)
            if category:
                agency = category[1]
        if parser in ("ccms", "tnpd"):
            cells = [compact(n.text()) for n in row.children if isinstance(n, Node) and n.tag == "td"]
            published_by = next((c for c in cells if "警察" in c and c != title and len(c) < 70), "")
            if published_by:
                agency = published_by
        date_kind = "列表日期"
        dated_text = row_text
        for label in ("發布日期", "發佈日期", "上版日期", "更新日期"):
            match = re.search(label + r"[：:]?\s*(" + DATE_PATTERN.pattern + ")", row_text)
            if match:
                dated_text, date_kind = match[1], label
                break
        if date_kind == "列表日期":
            dates = [compact(node.text()) for node in row.nodes()
                     if node.tag in ("td", "span", "time", "div") and DATE_PATTERN.fullmatch(compact(node.text()))]
            if dates:
                dated_text = dates[0]
        item = {"source": source["id"], "agency": agency, "title": title,
                "date": parse_date(dated_text), "date_kind": date_kind, "url": urljoin(url, href)}
        canonical_url(item["url"])
        rows.append(item)
    empty_list = any(node.matches(".list") and node.parent and node.parent.matches(".list_group")
                     and not compact(node.text()) for node in root.nodes())
    if not rows and not any(word in compact(root.text()) for word in NO_RESULTS) and not (parser == "npa" and empty_list):
        # 空列表必須有原站的明確空結果標記，不能把改版／阻擋當成零則。
        raise ValueError("找不到有日期的公告列，且沒有明確的查無資料標記")
    return root, rows


def extract_body(text, parser):
    root = Document(text).root
    for selector in DETAIL_SELECTORS[parser]:
        nodes = [node for node in root.nodes() if node.matches(selector)]
        if nodes:
            body = "\n".join(node.text() for node in nodes)
            if compact(body):
                return body
    raise ValueError("找不到公告內文節點，僅保留列表資訊")


def extract_locations(title, body):
    locations = []
    # 只摘地點片段；不把機關頁尾的聯絡地址或附件檔名當設備位置。
    for stop in re.findall(r"([\u4e00-\u9fff]{2,15}(?:[（(][^）)]{1,15}[）)])?)[（(]往[東西南北]{1,2}[）)]", body):
        if stop not in locations:
            locations.append(stop)
    for part in re.split(r"[\n，,。；;：:（）()【】、]", title + "\n" + body):
        part = compact(part).lstrip("「」『』 ")
        if re.search(r"[\u4e00-\u9fff]{2,12}(?:路|街)(?:[一二三四五六七八九十\d]+段)?(?:[與及\d]|$)|[台臺國北宜]\d+線|\d+(?:\.\d+)?[Kk]", part):
            part = re.sub(r"^(?:地點|地址|設置地點|位於|設於|擇定|包括|分別為)[為於：:\s]*", "", part)
            if "的" in part:
                part = part.rsplit("的", 1)[1]
            if part.endswith("事故路口") or part in ("路口", "道路"):
                continue
            if 2 <= len(part) <= 160 and part not in locations:
                locations.append(part)
    return locations[:12]


def place_context(item, source, body):
    explicit = {city for city in CITIES if normalize_address(city) in normalize_address(item["title"] + body)}
    if len(explicit) == 1:
        return explicit.pop()
    if len(explicit) > 1:
        return ""
    agency_cities = [city for city in CITIES if city in item["agency"]]
    return agency_cities[0] if len(agency_cities) == 1 else source.get("city", "")


def location_key(city, location):
    normalized = normalize_address(location).strip("「」『』. ")
    district = re.match(r"(.{1,5}?[區鄉鎮市])", normalized.removeprefix(normalize_address(city)))
    district = district[1] if district else ""
    query = parse_address(city, district, normalized)
    if query:
        if query.kind == "intersection":
            return ("intersection", *sorted((query.road, query.other_road)))
        return query.kind, query.key
    normalized = without_place(city, district, normalized)
    milestone = re.fullmatch(r"(台\d+[甲乙丙丁]?線|國道\d+號?)(?:[南北東西]向)?(\d+(?:\.\d+)?)[Kk](?:\+(\d+))?(?:處|附近)?", normalized)
    if milestone:
        meters = round(float(milestone[2]) * 1000) + int(milestone[3] or 0)
        return "milestone", milestone[1], str(meters)
    return None


def compare_cameras(item, source, body, cameras):
    city = place_context(item, source, body)
    keys = {key for text in item["locations"] if (key := location_key(city, text))}
    if not cameras or not city or not keys:
        return "無法判斷", [], "缺完整可比對地點、唯一縣市，或相機資料為空；不是未收錄的證據"
    matches = set()
    missing = 0
    for key in keys:
        found = []
        for camera in cameras:
            if normalize_address(camera.get("city", "")) != normalize_address(city):
                continue
            if location_key(city, camera.get("address", "")) == key:
                found.append(camera["id"])
        matches.update(found)
        missing += not found
    if missing:
        return "可能未收", sorted(matches), f"{len(keys)} 個文字地點中有 {missing} 個未精確對上；地址寫法、附件與資料版本仍須人工核對"
    return "可能已收", sorted(matches), "同縣市的完整門牌／路口／里程文字相符；未核座標、方向、功能或啟用日"


def with_query(url, **values):
    parts = urlsplit(url)
    query = dict(parse_qsl(parts.query))
    query.update({key: str(value) for key, value in values.items()})
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), ""))


class HttpClient:
    def __init__(self, source, options, evidence):
        self.source = source
        self.options = options
        self.evidence = evidence
        self.requests = []
        self.last_request = 0.0
        self.opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl_context()))

    def fetch(self, url, fields=None):
        if len(self.requests) >= self.options["max_requests"]:
            raise ValueError(f"已達單入口 {self.options['max_requests']} 次請求上限，未抓完的部分未視為零則")
        wait = self.options["interval"] - (time.monotonic() - self.last_request)
        if wait > 0:
            time.sleep(wait)
        record = {"url": url, "method": "POST" if fields is not None else "GET"}
        self.requests.append(record)
        self.last_request = time.monotonic()
        data = urlencode(fields).encode() if fields is not None else None
        request = urllib.request.Request(ascii_url(url), data=data,
                                         headers={"User-Agent": USER_AGENT, "Accept": "text/html"})
        try:
            with self.opener.open(request, timeout=self.options["timeout"]) as response:
                raw = response.read(2_000_001)
                record.update(status=response.status, final_url=response.url, bytes=len(raw))
            if len(raw) > 2_000_000:
                raise ValueError("回應超過 2 MB 上限")
            if urlsplit(response.url).hostname != urlsplit(url).hostname:
                raise ValueError(f"重新導向其他主機，未繼續解析：{response.url}")
            record["sha256"] = hashlib.sha256(raw).hexdigest()
            self.evidence.mkdir(parents=True, exist_ok=True)
            filename = f"{self.source['id']}-{len(self.requests):03}.html"
            (self.evidence / filename).write_bytes(raw)
            record["file"] = filename
            return decode_text(raw), response.url
        except (urllib.error.URLError, OSError, ValueError) as exc:
            record["error"] = str(exc)
            raise


def search_pages(client, source, terms):
    parser = source["parser"]
    for base in source.get("urls", [source["url"]]):
        if parser == "ccms" and source.get("search_field"):
            text, actual = client.fetch(with_query(base, PageSize=200))
            root = Document(text).root
            form = next((node for node in root.nodes("form") if node.attrs.get("id") == "form1"), None)
            if form is None:
                raise ValueError("找不到原站搜尋表單 form1")
            hidden = {node.attrs["name"]: node.attrs.get("value", "") for node in form.nodes("input")
                      if node.attrs.get("name", "").startswith("__")}
            for term in terms:
                fields = dict(hidden)
                fields.update({source["search_field"]: term, "jNewsModule_BtnSend": "送出查詢"})
                yield client.fetch(urljoin(actual, form.attrs.get("action", "")), fields)
        elif parser in ("npa", "taichung", "keelung", "changhua"):
            field_name = "SearchKeyword" if parser == "changhua" else "keyword"
            for term in terms:
                query = {field_name: term}
                if parser == "npa":
                    query["pageSize"] = 100
                if parser == "taichung":
                    query["pagesize"] = 100
                yield client.fetch(with_query(base, **query))
        else:
            yield client.fetch(base)


def next_page(root, current, parser):
    if parser in ("npa", "taichung"):
        select = next((node for node in root.nodes("select") if node.attrs.get("name") == "page"), None)
        if select:
            options = list(select.nodes("option"))
            selected = next((index for index, option in enumerate(options) if "selected" in option.attrs), 0)
            if selected + 1 < len(options):
                return with_query(current, page=options[selected + 1].attrs["value"])
    for link in root.nodes("a"):
        label = compact(link.attrs.get("title", "") + " " + link.text())
        if label in ("下一頁", "下頁", "Next page", "Next page »") or label.startswith("下一頁 "):
            raw_href = link.attrs.get("href", "").strip()
            if not raw_href or raw_href.startswith("#"):
                continue
            href = urljoin(current, raw_href)
            parts = urlsplit(href)
            if href != current and parts.scheme in ("http", "https") and parts.hostname == urlsplit(current).hostname:
                return urlunsplit(("https", parts.netloc, parts.path, parts.query, ""))
    return None


def watch(config, seen, cameras, since, until, output, client_type=None):
    client_type = client_type or HttpClient
    pending = {}
    seen_updates = {}
    statuses = []
    all_requests = []
    warnings = []
    for source in config["sources"]:
        options = dict(config["requests"], **source.get("requests", {}))
        client = client_type(source, options, output / "raw")
        status = {"id": source["id"], "agency": source["agency"], "url": source["url"], "rows": 0,
                  "matched": 0, "new": 0, "status": "ok", "warnings": [], "dates": []}
        candidates = {}
        for base in source.get("urls", [source["url"]]):
            try:
                entrance = dict(source, urls=[base])
                for text, actual in search_pages(client, entrance, config["search_terms"]):
                    page_url = actual
                    visited = {page_url}
                    for page in range(options["max_pages"]):
                        root, rows = parse_listing(text, source, page_url)
                        status["rows"] += len(rows)
                        status["dates"].extend(row["date"] for row in rows)
                        for item in rows:
                            if not since <= item["date"] <= until:
                                continue
                            change = classify_title(item["title"], config["keywords"])
                            if change:
                                item["change"] = change
                                candidates[canonical_url(item["url"])] = item
                        following = next_page(root, page_url, source["parser"])
                        if not following or all(row["date"] < since for row in rows):
                            break
                        if following in visited:
                            raise ValueError("下一頁回到已讀網址，停止重複請求；未確認完整涵蓋")
                        if page + 1 == options["max_pages"]:
                            status["warnings"].append("列表仍有下一頁，已達分頁上限；本輪不是完整年度搜尋")
                        else:
                            text, page_url = client.fetch(following)
                            visited.add(page_url)
            except (urllib.error.URLError, OSError, ValueError) as exc:
                status["warnings"].append(f"{base}：{exc}")
        status["matched"] = len(candidates)
        detail_count = 0
        for key, item in sorted(candidates.items(), key=lambda pair: pair[1]["date"], reverse=True):
            if seen.get(key) == fingerprint(item) or key in pending:
                continue
            notes = []
            body = ""
            complete = False
            if item["date_kind"] == "更新日期":
                notes.append("日期為原站更新日，不能當成首發或啟用日")
            try:
                if detail_count >= options["max_details"]:
                    raise ValueError("已達單入口內文上限，尚未讀內文；下輪仍會重試")
                if urlsplit(item["url"]).hostname != urlsplit(source["url"]).hostname:
                    raise ValueError("內文連結跨主機，未抓取")
                detail_count += 1
                text, _ = client.fetch(item["url"])
                body = extract_body(text, source["parser"])
                complete = True
            except (urllib.error.URLError, OSError, ValueError) as exc:
                notes.append(str(exc))
                status["warnings"].append(f"{item['title']}：{exc}")
            item["locations"] = extract_locations(item["title"], body)
            item["collection_status"], item["matched_ids"], item["match_reason"] = compare_cameras(item, source, body, cameras)
            item["notes"] = notes
            pending[key] = item
            status["new"] += 1
            if complete:
                seen_updates[key] = fingerprint(item)
        if status["warnings"]:
            status["status"] = "partial" if status["rows"] else "failed"
        if status["dates"]:
            status["oldest_date"], status["newest_date"] = min(status["dates"]), max(status["dates"])
        del status["dates"]
        status["requests"] = len(client.requests)
        statuses.append(status)
        all_requests.extend(dict(source=source["id"], **request) for request in client.requests)
        for warning in status["warnings"]:
            message = f"{source['agency']}：{warning}"
            warnings.append(message)
            print(f"警告：{message}", file=sys.stderr)
    items = sorted(pending.values(), key=lambda item: (item["date"], item["agency"], item["title"]), reverse=True)
    return {"since": since, "until": until, "new_count": len(items), "announcements": items,
            "by_agency": dict(sorted(Counter(item["agency"] for item in items).items())),
            "by_collection_status": dict(Counter(item["collection_status"] for item in items)),
            "sources": statuses, "warnings": warnings, "requests": all_requests}, seen_updates


def markdown_text(text):
    return html.escape(compact(text), quote=False).replace("\\", "\\\\").replace("|", "\\|").replace("[", "\\[").replace("]", "\\]")


def render_markdown(report, limit=None):
    lines = ["# 官方設備公告待人工核對清單", "",
             f"搜尋範圍：{report['since']}～{report['until']}；本輪未見過的公告 **{report['new_count']} 則**。",
             "只按標題關鍵字篩選；一則可能有多處設備，也可能只是測試或功能調整。"
             "**不是設備新增清單，不自動寫入 cameras.json 或 cameras_extra.csv。**", "",
             "收錄提示只比對同縣市地點文字，不代表座標、方向、功能、啟用日已核實；「可能未收」不是確定漏點。",
             "已見只代表曾列入清單，不代表人工核准。日期種類見各列；未下載 PDF、圖片或附件。", ""]
    if report.get("cameras_sha256"):
        lines += [f"比對資料：{report['camera_count']} 點；SHA-256 `{report['cameras_sha256']}`。", ""]
    lines += ["## 統計", "", "| 機關 | 公告數 |", "|---|---:|"]
    lines += [f"| {markdown_text(agency)} | {count} |" for agency, count in report["by_agency"].items()]
    lines += ["", "；".join(f"{key} {report['by_collection_status'].get(key, 0)} 則" for key in ("可能已收", "可能未收", "無法判斷")), "",
              "## 待核公告", "", "| 日期／依據 | 機關 | 類型 | 標題／原站 | 地點文字（可能不完整） | 收錄提示 |",
              "|---|---|---|---|---|---|"]
    items = report["announcements"] if limit is None else report["announcements"][:limit]
    for item in items:
        url = item["url"].replace(" ", "%20").replace("(", "%28").replace(")", "%29")
        location = "；".join(item["locations"]) or "內文／標題未解析出地點，請開原文及附件"
        notes = "；".join(item["notes"])
        lines.append(f"| {item['date']}（{item['date_kind']}） | {markdown_text(item['agency'])} | {item['change']} | "
                     f"[{markdown_text(item['title'])}](<{url}>) | {markdown_text(location)} | "
                     f"{item['collection_status']}：{markdown_text(item['match_reason'] + ('；' + notes if notes else ''))} |")
    if limit is not None and len(report["announcements"]) > limit:
        lines += ["", f"僅列前 {limit} 則；完整 CSV／Markdown／請求證據見本輪 `ci-data` artifact 的 announcements 目錄。"]
    lines += ["", "## 入口執行狀態", "", "| 入口 | 狀態 | 讀取列數 | 命中 | 新公告 | 請求數 | 可及列表日期 |",
              "|---|---|---:|---:|---:|---:|---|"]
    for source in report["sources"]:
        lines.append(f"| [{markdown_text(source['agency'])}](<{source['url']}>) | {source['status']} | "
                     f"{source['rows']} | {source['matched']} | {source['new']} | {source['requests']} | "
                     f"{source.get('oldest_date', '—')}～{source.get('newest_date', '—')} |")
    lines += ["", "同一公告跨搜尋詞／臺北共用文章鏡像去重；其他機關轉載仍可能重複，公告數不等於設備數。"
              "有分頁／請求上限或失敗的入口不能宣稱完整涵蓋一年，更不能把零則解讀成當地沒有新增設備。"]
    if report["warnings"]:
        lines += ["", "## 警告／未完整涵蓋", ""]
        lines += ["- " + markdown_text(warning) for warning in report["warnings"]]
    return "\n".join(lines) + "\n"


def write_csv(path, items):
    fields = ("agency", "title", "date", "date_kind", "url", "change", "locations", "collection_status",
              "matched_ids", "match_reason", "notes")
    with path.open("w", encoding="utf-8-sig", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        for item in items:
            row = {key: "；".join(item[key]) if isinstance(item[key], list) else item[key] for key in fields}
            writer.writerow({key: "'" + value if value.lstrip().startswith(("=", "+", "-", "@")) else value
                             for key, value in row.items()})


def load_config(path):
    config = json.loads(path.read_text(encoding="utf-8"))
    assert_keys = ("search_terms", "requests", "keywords", "sources")
    if any(key not in config for key in assert_keys) or not config["sources"]:
        raise ValueError("公告設定缺少必要欄位或來源")
    ids = set()
    for source in config["sources"]:
        if source["id"] in ids or source["parser"] not in LINK_PATTERNS:
            raise ValueError("來源 ID 重複或解析器未知")
        ids.add(source["id"])
        for url in source.get("urls", [source["url"]]):
            canonical_url(url)
        options = dict(config["requests"], **source.get("requests", {}))
        for key in ("timeout", "interval", "max_requests", "max_pages", "max_details"):
            if not isinstance(options[key], (int, float)) or not 0 < options[key] <= 300:
                raise ValueError(f"{source['id']} 的 {key} 超出允許範圍")
            if key.startswith("max_") and not isinstance(options[key], int):
                raise ValueError(f"{key} 必須為整數")
    return config


def load_seen(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1 or not isinstance(data.get("seen"), dict):
        raise ValueError("已見清單格式不符，未覆寫")
    if not all(isinstance(key, str) and isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value)
               for key, value in data["seen"].items()):
        raise ValueError("已見清單含無效指紋，未覆寫")
    return data["seen"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=HERE / "announcement_sources.json")
    parser.add_argument("--seen", type=Path, default=HERE / "announcements_seen.json")
    parser.add_argument("--cameras", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=Path("build") / "announcements")
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--since", type=date.fromisoformat)
    parser.add_argument("--until", type=date.fromisoformat, default=datetime.now(timezone(timedelta(hours=8))).date())
    parser.add_argument("--update-seen", action="store_true")
    parser.add_argument("--pr-body", type=Path)
    parser.add_argument("--source", action="append", help="只執行指定來源 ID（可重複）")
    args = parser.parse_args(argv)
    try:
        since = args.since or args.until - timedelta(days=365)
        if since > args.until:
            raise ValueError("開始日期不能晚於結束日期")
        config = load_config(args.config)
        if args.source:
            known = {source["id"] for source in config["sources"]}
            if not set(args.source) <= known:
                raise ValueError("指定了未知來源 ID")
            config["sources"] = [source for source in config["sources"] if source["id"] in args.source]
        seen = load_seen(args.seen)
        camera_bytes = args.cameras.read_bytes()
        database = json.loads(camera_bytes)
        if not isinstance(database.get("cameras"), list) or not all(
                isinstance(camera, dict) and isinstance(camera.get("id"), str)
                and isinstance(camera.get("address"), str) and isinstance(camera.get("city", ""), str)
                for camera in database["cameras"]):
            raise ValueError("cameras.json 缺 cameras 陣列，或相機的 id／address／city 不是字串")
        if args.pr_body and not args.pr_body.is_file():
            raise ValueError("--pr-body 必須是既有的資料 PR 說明，不會靜默建立替代檔")
        args.output_dir.mkdir(parents=True, exist_ok=True)
        report, updates = watch(config, seen, database["cameras"], since.isoformat(), args.until.isoformat(), args.output_dir)
        report.update(cameras_sha256=hashlib.sha256(camera_bytes).hexdigest(), camera_count=len(database["cameras"]))
        markdown = args.markdown or args.output_dir / "pending.md"
        markdown.parent.mkdir(parents=True, exist_ok=True)
        markdown.write_text(render_markdown(report), encoding="utf-8")
        write_csv(args.output_dir / "pending.csv", report["announcements"])
        (args.output_dir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        if args.pr_body and report["new_count"]:
            with args.pr_body.open("a", encoding="utf-8") as output:
                output.write("\n\n## 本週新公告（待人工核對，非自動新增相機）\n\n")
                output.write(render_markdown(report, limit=20).replace("# 官方設備公告待人工核對清單\n", ""))
        if args.update_seen and updates:
            state = json.dumps({"schema_version": 1, "seen": dict(sorted((seen | updates).items()))}, ensure_ascii=False, indent=2) + "\n"
            temporary = args.seen.with_suffix(".tmp")
            temporary.write_text(state, encoding="utf-8")
            temporary.replace(args.seen)
        print(f"新公告 {report['new_count']} 則；可能未收 {report['by_collection_status'].get('可能未收', 0)} 則。")
        return 0 if any(source["status"] != "failed" for source in report["sources"]) else 1
    except (OSError, ValueError, KeyError) as exc:
        print(f"錯誤：{exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
