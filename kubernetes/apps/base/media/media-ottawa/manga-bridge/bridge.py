#!/usr/bin/env python3
"""Manga request bridge: Omnibus PENDING_APPROVAL manga requests -> Suwayomi.

Polls Omnibus Postgres for manga requests (Series.isManga = true) sitting in
PENDING_APPROVAL, searches Suwayomi's English MangaDex source, and — ONLY on a
high-confidence (normalized-exact, unambiguous) title match — adds the series to
Suwayomi's library and enqueues the right downloads, then marks the Omnibus
request COMPLETED. Ambiguous / no-match requests are LEFT in the queue and a
Discord alert fires (approach B: safety over full automation).

Downstream is unchanged: Suwayomi writes CBZ -> komga-watcher sidecar scans Komga.

stdlib only, except pg8000 (pure-Python Postgres driver, pip-installed at start).
See /workspace/handoffs/manga-request-bridge.md for the full spec.
"""

import json
import os
import re
import sys
import time
import urllib.request

import pg8000.dbapi

SUWAYOMI_GRAPHQL = os.environ["SUWAYOMI_GRAPHQL"]
DISCORD_WEBHOOK = os.environ.get("DISCORD_WEBHOOK", "")
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "60"))

PG = dict(
    host=os.environ["OMNIBUS_PG_HOST"],
    port=int(os.environ.get("OMNIBUS_PG_PORT", "5432")),
    database=os.environ["OMNIBUS_PG_DB"],
    user=os.environ["OMNIBUS_PG_USER"],
    password=os.environ["OMNIBUS_PG_PASSWORD"],
)

# Same issue-number shape Omnibus uses; presence => single chapter, absence => whole series.
ISSUE_RE = re.compile(
    r"(?:#|issue\s*#?|vol(?:ume)?\s*\.?|v\s*\.?|ch(?:apter)?\s*\.?)\s*0*(\d+(?:\.\d+)?)",
    re.IGNORECASE,
)


def log(msg):
    print(f"[manga-bridge] {msg}", flush=True)


def normalize(title):
    """Lowercase, drop everything but alphanumerics — for exact-title comparison."""
    return re.sub(r"[^a-z0-9]", "", (title or "").lower())


def gql(query, variables=None):
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(
        SUWAYOMI_GRAPHQL, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        payload = json.loads(resp.read().decode())
    if payload.get("errors"):
        raise RuntimeError(f"GraphQL error: {payload['errors']}")
    return payload["data"]


def discord(msg):
    if not DISCORD_WEBHOOK:
        log(f"(no discord webhook) would alert: {msg}")
        return
    try:
        body = json.dumps({"content": msg}).encode()
        req = urllib.request.Request(
            DISCORD_WEBHOOK, data=body, headers={"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req, timeout=15).read()
    except Exception as e:  # noqa: BLE001 - alerting must never crash the loop
        log(f"discord alert failed: {e}")


def mangadex_en_source_id():
    """Resolve the English MangaDex source id at runtime (it changes on reinstall)."""
    data = gql("{ sources { nodes { id name lang } } }")
    for n in data["sources"]["nodes"]:
        if n["name"] == "MangaDex" and n["lang"] == "en":
            return n["id"]
    raise RuntimeError("MangaDex (en) source not installed in Suwayomi")


def fetch_pending_manga_requests(conn):
    """Manga requests in PENDING_APPROVAL, joined to Series for the title + isManga flag."""
    cur = conn.cursor()
    cur.execute(
        '''
        SELECT r.id, r."activeDownloadName", s.name, s.year
        FROM "Request" r
        JOIN "Series" s
          ON s."metadataId" = r."volumeId"
         AND s."metadataSource" = COALESCE(r."metadataSource", 'COMICVINE')
        WHERE r.status = 'PENDING_APPROVAL'
          AND s."isManga" = true
        '''
    )
    rows = cur.fetchall()
    cur.close()
    return rows  # (request_id, activeDownloadName, series_name, year)


def mark_completed(conn, request_id):
    cur = conn.cursor()
    cur.execute('UPDATE "Request" SET status = %s WHERE id = %s', ("COMPLETED", request_id))
    conn.commit()
    cur.close()


def search_manga(source_id, query):
    data = gql(
        """
        mutation($input: FetchSourceMangaInput!) {
          fetchSourceManga(input: $input) { mangas { id title inLibrary } }
        }
        """,
        {"input": {"source": source_id, "type": "SEARCH", "page": 1, "query": query}},
    )
    return data["fetchSourceManga"]["mangas"]


def confident_match(query_title, mangas):
    """Approach B: exactly one normalized-exact-title candidate, else None."""
    want = normalize(query_title)
    exact = [m for m in mangas if normalize(m["title"]) == want]
    return exact[0] if len(exact) == 1 else None


def add_to_library(manga_id):
    gql(
        """
        mutation($input: UpdateMangaInput!) {
          updateManga(input: $input) { manga { id inLibrary } }
        }
        """,
        {"input": {"id": manga_id, "patch": {"inLibrary": True}}},
    )


def fetch_chapters(manga_id):
    data = gql(
        """
        mutation($input: FetchChaptersInput!) {
          fetchChapters(input: $input) { chapters { id chapterNumber } }
        }
        """,
        {"input": {"mangaId": manga_id}},
    )
    return data["fetchChapters"]["chapters"]


def enqueue_downloads(chapter_ids):
    if not chapter_ids:
        return
    gql(
        """
        mutation($input: EnqueueChapterDownloadsInput!) {
          enqueueChapterDownloads(input: $input) { clientMutationId }
        }
        """,
        {"input": {"ids": chapter_ids}},
    )


def process_request(source_id, request_id, active_name, series_name, year):
    title = series_name or active_name or ""
    if not title:
        log(f"request {request_id}: no title, skipping")
        return False

    mangas = search_manga(source_id, title)
    match = confident_match(title, mangas)
    if match is None:
        n = len(mangas)
        log(f"request {request_id}: no confident match for '{title}' ({n} candidates) — leaving queued")
        discord(
            f"📚 Manga request needs manual review: **{title}**"
            + (f" ({year})" if year else "")
            + f" — {n} MangaDex candidate(s), no unambiguous exact match."
        )
        return False  # leave in PENDING_APPROVAL

    manga_id = match["id"]
    if not match.get("inLibrary"):
        add_to_library(manga_id)
        log(f"request {request_id}: added '{match['title']}' (id={manga_id}) to library")

    # Scope: single chapter if the request names an issue number, else whole series (auto-download).
    m = ISSUE_RE.search(active_name or "")
    if m:
        want_num = float(m.group(1))
        chapters = fetch_chapters(manga_id)
        picked = [c["id"] for c in chapters if _num_eq(c.get("chapterNumber"), want_num)]
        if picked:
            enqueue_downloads(picked)
            log(f"request {request_id}: enqueued chapter {want_num} ({len(picked)} id(s))")
        else:
            log(f"request {request_id}: chapter {want_num} not found on source; series in library, auto-dl will catch up")
    else:
        log(f"request {request_id}: whole series — relying on AUTO_DOWNLOAD_CHAPTERS")

    return True


def _num_eq(a, b):
    try:
        return abs(float(a) - float(b)) < 1e-6
    except (TypeError, ValueError):
        return False


def tick(source_id):
    conn = pg8000.dbapi.connect(**PG)
    try:
        rows = fetch_pending_manga_requests(conn)
        if rows:
            log(f"{len(rows)} pending manga request(s)")
        for request_id, active_name, series_name, year in rows:
            try:
                if process_request(source_id, request_id, active_name, series_name, year):
                    mark_completed(conn, request_id)
                    log(f"request {request_id}: marked COMPLETED")
            except Exception as e:  # noqa: BLE001 - one bad request must not stall the batch
                log(f"request {request_id}: error: {e}")
    finally:
        conn.close()


def main():
    log("starting; resolving MangaDex (en) source id …")
    source_id = None
    while True:
        try:
            if source_id is None:
                source_id = mangadex_en_source_id()
                log(f"MangaDex (en) source id = {source_id}")
            tick(source_id)
        except Exception as e:  # noqa: BLE001 - keep the loop alive across transient failures
            log(f"tick error: {e}")
            source_id = None  # re-resolve source next loop in case Suwayomi restarted
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
