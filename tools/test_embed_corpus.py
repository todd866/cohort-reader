from array import array
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

from embed_corpus import (
    GEMMA_DIM,
    append_vectors,
    assert_payload_clean,
    build_gemini_batch_shards,
    build_multichunk_windows,
    check_budget_and_gate,
    export_manifold_bundle,
    pool_chunk_vectors,
    repair_tail,
    sign_envelope,
    strip_boilerplate,
)
from resolve_canonical_ids import extract_id_from_text, inspect_epub_canonical_id, valid_isbn13


class EmbedCorpusTest(unittest.TestCase):
    def test_isbn13_and_epub_canonical_resolution(self) -> None:
        self.assertEqual(valid_isbn13("978-0-7546-1590-3"), "9780754615903")
        self.assertIsNone(valid_isbn13("978-0-7546-1590-4"))
        self.assertEqual(extract_id_from_text("arXiv:1706.03762v5"), "arxiv:1706.03762v5")
        self.assertEqual(extract_id_from_text("https://www.gutenberg.org/ebooks/84"), "gutenberg:84")

        with tempfile.TemporaryDirectory() as td:
            ep = Path(td) / "book.epub"
            with zipfile.ZipFile(ep, "w") as zf:
                zf.writestr(
                    "META-INF/container.xml",
                    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
                )
                zf.writestr(
                    "content.opf",
                    '<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier>urn:isbn:9780691140520</dc:identifier></metadata></package>',
                )
            self.assertEqual(inspect_epub_canonical_id(ep), "isbn:9780691140520")

    def test_boilerplate_stripping_and_multichunk_pooling(self) -> None:
        raw = (
            "The Project Gutenberg header boilerplate\n"
            "*** START OF THIS PROJECT GUTENBERG EBOOK FRANKENSTEIN ***\n"
            + ("Real narrative prose about Geneva and natural philosophy. " * 120)
            + "\n*** END OF THIS PROJECT GUTENBERG EBOOK FRANKENSTEIN ***\nLicense footer"
        )
        cleaned = strip_boilerplate(raw)
        self.assertNotIn("header boilerplate", cleaned)
        self.assertNotIn("License footer", cleaned)

        wins = build_multichunk_windows(
            title="Frankenstein",
            authors="Mary Shelley",
            genre="Fiction",
            description="Gothic novel",
            body=raw,
            max_body_windows=4,
            window_chars=400,
        )
        self.assertEqual(len(wins), 5)
        self.assertEqual(wins[0][2], 2.0)

        vecs = [[float(i + 1)] * 8 for i in range(5)]
        pooled = pool_chunk_vectors(vecs, [w for _, _, w in wins])
        self.assertAlmostEqual(math.sqrt(sum(x * x for x in pooled)), 1.0, places=5)

    def test_repair_tail_and_fail_closed_export_manifold(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            vdir = root / "vectors-gemma"
            v = [1.0] + [0.0] * (GEMMA_DIM - 1)
            append_vectors(vdir, [{"slug": "s1"}], [v])
            # Simulate crash appending extra unindexed vector bytes
            extra = array("f", v)
            if sys.byteorder != "little":
                extra.byteswap()
            with (vdir / "docs.f32").open("ab") as fh:
                fh.write(extra.tobytes())
            rows = repair_tail(vdir, GEMMA_DIM)
            self.assertEqual(len(rows), 1)
            self.assertEqual((vdir / "docs.f32").stat().st_size, GEMMA_DIM * 4)

            space_path = root / "reader-space.json"
            sample_home = "/" + "Users" + "/alice"
            sample_vol = "/" + "Volumes" + "/Drive"
            space_path.write_text(
                json.dumps({
                    "items": [
                        {
                            "slug": "md5-1111",
                            "canonicalId": "isbn:9780754615903",
                            "title": "Managing Maintenance Error.pdf",
                            "creator": "James Reason",
                            "year": 2003,
                            "kind": "book",
                            "summary": f"From {sample_home}/PaperLibrary/books/reason.pdf",
                            "vec32": [1] * 32,
                            "neighbours": [
                                {"slug": "md5-private", "workId": "md5-private", "sim": 0.9},
                                {"slug": "doi-1", "workId": "doi:10.1038/nrn2787", "sim": 0.8},
                            ],
                        },
                        {
                            "slug": "md5-private",
                            "canonicalId": None,
                            "title": "Private.epub",
                            "summary": f"{sample_vol}/Secret/Private.epub",
                        },
                    ]
                }),
                encoding="utf-8",
            )

            out_path = root / "manifold-export.json"
            signed, skipped = export_manifold_bundle(
                space_path,
                out_path,
                identity_file=root / "contrib.json",
            )
            self.assertEqual(skipped, 1)
            self.assertEqual(len(signed["items"]), 1)
            raw_out = out_path.read_text(encoding="utf-8")
            self.assertNotIn("/" + "Users/", raw_out)
            self.assertNotIn(".pdf", raw_out)
            self.assertNotIn(".epub", raw_out)
            self.assertNotIn("md5-private", raw_out)
            assert_payload_clean(signed)

            with self.assertRaises(ValueError):
                assert_payload_clean({"bad": f"{sample_home}/test.epub"})

            # Regression test: leading '-' in base64url private seed must not be parsed as node flag
            signed_hyphen = sign_envelope({"issuer": "ed25519:test", "domain": "reader"}, "-" + "A" * 42)
            self.assertIn("signature", signed_hyphen)

    def test_budget_gate_fails_closed_without_key_or_state(self) -> None:
        ok, reason = check_budget_and_gate(
            1.0,
            cap_usd=5.0,
            budget_state=Path("/nonexistent/budget/dir"),
        )
        self.assertFalse(ok)
        self.assertTrue(len(reason) > 0)

    def test_gemini_sharded_camelcase_batch_build(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            state = Path(td)
            records = [
                {
                    "slug": f"book-{i}",
                    "canonicalId": f"doi:10.1000/{i}",
                    "title": f"Book {i}",
                    "authors": "Author",
                    "genre": "Nonfiction",
                    "subgenre": "History",
                    "description": "Concise test work.",
                    "topics": ["history"],
                    "body": "Test prose paragraph. " * 200,
                }
                for i in range(3)
            ]
            prep = build_gemini_batch_shards(records, state, shard_lines=3)
            self.assertEqual(prep["docs"], 3)
            self.assertGreaterEqual(len(prep["shards"]), 2)
            first_shard = Path(prep["shards"][0]["path"])
            first_obj = json.loads(first_shard.read_text(encoding="utf-8").splitlines()[0])
            self.assertEqual(first_obj["request"]["outputDimensionality"], 3072)
            self.assertNotIn("output_dimensionality", first_obj["request"])
            self.assertTrue((state / "gemini" / "prepared.json").is_file())


if __name__ == "__main__":
    unittest.main()
