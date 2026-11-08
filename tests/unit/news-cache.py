"""Exercise the production embedded Python with fully mocked HTTP and clock."""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/cb-news.sh"
CODE = SCRIPT.read_text().split("python3 - <<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
NOW = 1794139200
DATE = "Sun, 08 Nov 2026 11:00:00 GMT"
EPOCH = 1794135600
RSS = f"""<rss><channel><item><title>Market update</title><link>https://example.invalid/1</link>
<pubDate>{DATE}</pubDate></item><item><title>Undated report</title>
<link>https://example.invalid/2</link></item></channel></rss>""".encode()
ATOM = b"""<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Market update</title>
<link href="https://example.invalid/1"/><updated>2026-11-08T11:00:00Z</updated></entry>
<entry><title>Undated report</title><link href="https://example.invalid/2"/></entry></feed>"""


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cache = Path(self.tmp.name) / "news.json"

    def run_feed(self, response, conditional=False, undated=False):
        calls = []
        def urlopen(req, timeout):
            calls.append((req, timeout))
            if isinstance(response, Exception):
                raise response
            class Reply:
                headers = {"ETag": '"fixture"', "Last-Modified": DATE}
                def __enter__(self): return self
                def __exit__(self, *args): pass
                def read(self, limit): return response
            return Reply()
        env = dict(LIMIT="20", SINCE="48h", SRC="fed_monetary", TAG="",
                   AS_JSON="1", NO_CACHE="0", UNDATED=str(int(undated)),
                   CACHE=str(self.cache), FIXTURE="", CB_NEWS_P0_FILE="")
        output = io.StringIO()
        with patch.dict(os.environ, env), patch("urllib.request.urlopen", urlopen), \
                patch("time.time", return_value=NOW), contextlib.redirect_stdout(output):
            try:
                exec(compile(CODE, str(SCRIPT), "exec"), {})
            except SystemExit as e:
                status = e.code
            else:
                status = 0
        self.assertEqual(len(calls), 1)
        req, timeout = calls[0]
        self.assertEqual(bool(req.get_header("If-none-match")), conditional)
        self.assertEqual(bool(req.get_header("If-modified-since")), conditional)
        self.assertEqual(timeout, 15)
        return status, json.loads(output.getvalue())

    def cached_items(self):
        return json.loads(self.cache.read_text())["sources"]["fed_monetary"]["items"]

    def test_reuse_and_failures(self):
        for feed in (RSS, ATOM):
            with self.subTest(format=feed[:5]):
                self.cache.unlink(missing_ok=True)
                status, first = self.run_feed(feed)
                self.assertEqual(status, 0)
                original = self.cached_items()
                self.assertEqual([x["epoch"] for x in original], [EPOCH, 0])
                for response in (
                    urllib.error.HTTPError("https://example.invalid", 304, "unchanged", {}, None),
                    urllib.error.HTTPError("https://example.invalid", 503, "unavailable", {}, None),
                    urllib.error.URLError("offline fixture"),
                ):
                    status, reused = self.run_feed(response, conditional=True)
                    self.assertEqual(status, 0)
                    self.assertEqual(self.cached_items(), original)
                    self.assertEqual(reused["items"], first["items"])
                    self.assertEqual(reused["count"], 1)
                    self.assertEqual(reused["fetched"], 0)
                    self.assertEqual(reused["not_modified"], int(getattr(response, "code", None) == 304))
                _, all_items = self.run_feed(
                    urllib.error.HTTPError("https://example.invalid", 304, "", {}, None),
                    conditional=True, undated=True)
                self.assertEqual(len(all_items["items"]), 2)
                self.assertEqual(self.cached_items()[-1]["epoch"], 0)

    def test_legacy_cache_refetched_without_validators(self):
        self.run_feed(RSS)
        old = json.loads(self.cache.read_text())
        old["version"] = 2
        for item in old["sources"]["fed_monetary"]["items"]:
            item["epoch"] = 0
        self.cache.write_text(json.dumps(old))
        status, _ = self.run_feed(RSS, conditional=False)
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(self.cache.read_text())["version"], 3)
        self.assertEqual(self.cached_items()[0]["epoch"], EPOCH)

    def test_failed_legacy_refresh_does_not_invent_dates(self):
        self.cache.write_text(json.dumps({"version": 2, "sources": {
            "fed_monetary": {"etag": "old", "items": [{"epoch": 0}]}}}))
        status, result = self.run_feed(urllib.error.URLError("offline fixture"))
        self.assertEqual(status, 6)
        self.assertEqual(result["items"], [])
        self.assertEqual(self.cached_items(), [])

    def test_empty_cache_accepts_304(self):
        self.run_feed(b"<rss><channel/></rss>")
        status, result = self.run_feed(
            urllib.error.HTTPError("https://example.invalid", 304, "", {}, None), conditional=True)
        self.assertEqual(status, 0)
        self.assertEqual(result["items"], [])


if __name__ == "__main__":
    unittest.main()
