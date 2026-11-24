import http.cookiejar
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import zipfile

from server import LibraryState, extract_canonical_id, make_handler
from http.server import ThreadingHTTPServer


def make_test_epub(path: Path) -> None:
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("mimetype", "application/epub+zip")
        zf.writestr(
            "META-INF/container.xml",
            '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        )
        zf.writestr(
            "OEBPS/content.opf",
            '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier>urn:gutenberg:84</dc:identifier><dc:title>Frankenstein</dc:title><dc:creator>Mary Shelley</dc:creator></metadata><manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>',
        )
        zf.writestr("OEBPS/ch1.xhtml", "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>Letter I</p></body></html>")


class BYOBackendTest(unittest.TestCase):
    def test_canonical_id_and_http_contract(self) -> None:
        self.assertEqual(extract_canonical_id("ISBN 978-0-7546-1590-3"), "isbn:9780754615903")
        self.assertIsNone(extract_canonical_id("ISBN 978-0-7546-1590-4"))
        self.assertEqual(extract_canonical_id("urn:gutenberg:84"), "gutenberg:84")

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            books_dir = root / "books" / "Science"
            books_dir.mkdir(parents=True)
            epub_path = books_dir / "frankenstein.epub"
            make_test_epub(epub_path)

            notes_dir = books_dir / "frankenstein.notes"
            notes_dir.mkdir()
            (notes_dir / "notes.json").write_text(
                json.dumps({"notes": [{"id": "n1", "spine": 0, "anchor": "Letter I", "kind": "note", "label": "Letter I", "note": "Opening letter.", "source": "Test"}]}),
                encoding="utf-8",
            )

            state = LibraryState(
                books_dir=root / "books",
                passphrase="test-pass-phrase",
                server_name="Test Shelf",
                manifold_url=None,
                state_path=root / "state.json",
            )
            state.scan()
            self.assertEqual(len(state.books), 1)
            rec = next(iter(state.books.values()))
            self.assertEqual(rec.canonical_id, "gutenberg:84")
            self.assertEqual(rec.title, "Frankenstein")

            srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(state))
            port = srv.server_address[1]
            th = threading.Thread(target=srv.serve_forever, daemon=True)
            th.start()
            try:
                base = f"http://127.0.0.1:{port}"
                # Unauthenticated rejected
                with self.assertRaises(urllib.error.HTTPError) as ctx:
                    urllib.request.urlopen(f"{base}/api/home")
                self.assertEqual(ctx.exception.code, 401)
                ctx.exception.close()

                jar = http.cookiejar.CookieJar()
                opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

                login_req = urllib.request.Request(
                    f"{base}/api/login",
                    data=json.dumps({"pass": "test-pass-phrase"}).encode(),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                login_res = json.loads(opener.open(login_req).read().decode())
                self.assertEqual(login_res["name"], "Test Shelf")

                home = json.loads(opener.open(f"{base}/api/home").read().decode())
                self.assertEqual(len(home["items"]), 1)
                bid = home["items"][0]["id"]

                search = json.loads(opener.open(f"{base}/api/search?q=Shelley").read().decode())
                self.assertEqual(len(search["items"]), 1)

                # HTTP 206 byte-range fetch
                full_bytes = epub_path.read_bytes()
                range_req = urllib.request.Request(f"{base}/api/book/{bid}", headers={"Range": "bytes=0-63"})
                with opener.open(range_req) as r:
                    self.assertEqual(r.status, 206)
                    part = r.read()
                    self.assertEqual(part, full_bytes[:64])

                notes = json.loads(opener.open(f"{base}/api/notes/{bid}").read().decode())
                self.assertEqual(len(notes["notes"]), 1)

                prog_req = urllib.request.Request(
                    f"{base}/api/progress",
                    data=json.dumps({"events": [{"bookId": bid, "spine": 0, "fraction": 0.42, "wordOffset": 120}]}).encode(),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                prog_res = json.loads(opener.open(prog_req).read().decode())
                self.assertEqual(prog_res["accepted"], 1)
                self.assertTrue((root / "state.json").is_file())
            finally:
                srv.shutdown()
                srv.server_close()


if __name__ == "__main__":
    unittest.main()
