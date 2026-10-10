"""The fuzz lane's mutants are the same on every host and every Python.

A seed names one mutant only while the generator and the seven mutations
stay what they are: the gate's run, a recorded hit and a reproduction a
person makes from its seed all depend on it.  So the generator is held to
splitmix64's published first outputs, each mutation kind to the bytes it
makes of a fixed text, and the seed list to the corpus it is read from.
"""
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "compiler/tests/fuzz"))

import fuzz  # noqa: E402


class Mutator(unittest.TestCase):
    def test_the_generator_is_splitmix64(self):
        generator = fuzz.Generator(0)
        self.assertEqual([generator.next() for _ in range(3)],
                         [0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4,
                          0x06C45D188009454F])

    def test_each_seed_names_one_mutant(self):
        text = "alpha beta\ngamma delta\n"
        self.assertEqual(
            [fuzz.mutate(seed, text) for seed in range(1, 8)],
            ["gamma delta\nalpha beta\ngamma delta\n",
             "alpha beta\ngamma delta{-\n",
             "alpha beta\nalpha beta\ngamma delta\n",
             "delta beta\ngamma alpha\n",
             "type beta\ngamma delta\n",
             "alpha when\ngamma delta\n",
             "alpha beta\nalpha beta\ngamma delta\n"])

    def test_every_kind_is_reached(self):
        kinds = {fuzz.Generator(seed).below(7) for seed in range(64)}
        self.assertEqual(kinds, set(range(7)))

    def test_an_empty_source_is_mutated_without_failing(self):
        for seed in range(64):
            self.assertIsInstance(fuzz.mutate(seed, ""), str)

    def test_the_seeds_are_the_corpus_and_the_reproducers(self):
        seeds = fuzz.seeds()
        labels = [label for label, _, _ in seeds]
        self.assertEqual(len(labels), len(set(labels)))
        fixtures = ROOT / "compiler/tests/fixtures"
        for kind in ("positive", "negative", "runtime", "abi"):
            expected = [kind + "/" + directory.name
                        for directory in sorted((fixtures / kind).iterdir())
                        if len(list(directory.glob("*.ldn"))) == 1]
            self.assertEqual([label for label in labels
                              if label.startswith(kind + "/")], expected)
        self.assertEqual(
            sum(label.startswith("reproducers/") for label in labels),
            len(list((ROOT / "compiler/tests/fuzz/reproducers")
                     .glob("*.ldn"))))
        self.assertGreater(len(seeds), 1000)
        for label, path, text in seeds:
            self.assertTrue(path.is_file(), label)
            self.assertTrue(path.is_relative_to(ROOT), label)
            text.encode("utf-8")

    def test_discovery_uses_one_direct_source_per_fixture(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixtures = root / "fixtures"
            for kind in ("positive", "negative", "runtime", "abi"):
                (fixtures / kind / "a").mkdir(parents=True)
                (fixtures / kind / "a" / "main.ldn").write_bytes(
                    kind.encode() + b"\xff")
            (fixtures / "runtime" / "b").mkdir()
            (fixtures / "runtime" / "b" / "main.ldn").write_text("one")
            (fixtures / "runtime" / "b" / "other.ldn").write_text("two")
            (fixtures / "abi" / "empty").mkdir()
            (fixtures / "abi" / "a" / "peer.c").write_text("C companion")
            (root / "reproducers").mkdir()
            (root / "reproducers" / "z_hit.ldn").write_text("last")
            (root / "reproducers" / "a_hit.ldn").write_text("first")
            with patch.object(fuzz, "FIXTURES", fixtures), \
                    patch.object(fuzz, "HERE", root):
                self.assertEqual([(label, text) for label, _, text in fuzz.seeds()], [
                    (kind + "/a", kind + "\ufffd")
                    for kind in ("positive", "negative", "runtime", "abi")
                ] + [("reproducers/a_hit.ldn", "first"),
                     ("reproducers/z_hit.ldn", "last")])
    def test_reduction_does_not_load_a_sibling_hit(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            (out / "hit-1.ldn").write_text("target")
            (out / "hit-2.ldn").write_text("broken sibling")
            server = Mock()
            server.stop.return_value = ""
            seen = []

            def inspect(_, seed, path, original, mutant):
                self.assertEqual(seed, 0)
                self.assertEqual(original, "trial")
                self.assertEqual(mutant, "trial")
                self.assertEqual(path.read_text(), "trial")
                self.assertEqual(list(path.parent.glob("*.ldn")), [path])
                self.assertNotEqual(path.parent, out)
                seen.append(path)

            with patch.object(fuzz, "Server", return_value=server), \
                    patch.object(fuzz, "serve_one", side_effect=inspect):
                self.assertEqual(
                    fuzz.reduce_one("refine", 0, 10, out, "trial"), "")
            self.assertEqual(len(seen), 1)
            self.assertFalse(seen[0].exists())
            server.stop.assert_called_once_with()

    def test_reduction_retains_shutdown_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            server = Mock()
            server.stop.return_value = "server exited after shutdown, status 70"
            with patch.object(fuzz, "Server", return_value=server), \
                    patch.object(fuzz, "serve_one"):
                self.assertIn("status 70", fuzz.reduce_one(
                    "refine", 0, 10, Path(directory), "trial"))
    def test_reproducers_have_separate_rooted_modules(self):
        corpus = fuzz.seeds()
        siblings = [path for label, path, _ in corpus
                    if label.startswith("reproducers/")]
        self.assertGreater(len(siblings), 1)
        self.assertEqual(len({path.parent for path in siblings}), 1)
        with tempfile.TemporaryDirectory() as directory:
            isolated = fuzz.isolate_reproducers(corpus, Path(directory))
            self.assertEqual(len(isolated), len(siblings))
            for label, original, text in corpus:
                if label in isolated:
                    entry = isolated[label]
                    self.assertNotEqual(entry.parent, original.parent)
                    self.assertEqual(list(entry.parent.glob("*.ldn")), [entry])
                    self.assertEqual(entry.read_text(), text)

    def test_import_preflight_requires_current_code_line_and_uri(self):
        uri = (fuzz.FIXTURES /
               "negative/core-fault-needs-mutable-inner/main.ldn").as_uri()
        for code, line, report_uri, accepted in (
                ("L0340", 9, uri, True), ("L0301", 9, uri, False),
                ("L0340", 8, uri, False), ("L0340", 9, uri + "other", False)):
            with self.subTest(code=code, line=line, uri=report_uri):
                server = Mock()
                server.diagnostics = []

                def publish(*_):
                    server.diagnostics.append({"uri": report_uri, "diagnostics": [
                        {"code": code, "range": {"start": {"line": line}}}]})

                server.request.side_effect = publish
                if accepted:
                    fuzz.check_imports(server)
                else:
                    with self.assertRaises(fuzz.Broken):
                        fuzz.check_imports(server)
                self.assertEqual(server.notify.call_args.args[0],
                                 "textDocument/didClose")

    def test_reproducer_preflight_requires_all_local_diagnostics(self):
        path = (fuzz.HERE / "reproducers/min-100299.ldn").resolve()
        for codes, local, accepted in ((["L0336", "L0339", "L0303"], True, True),
                                       (["L0336", "L0303"], True, False),
                                       (["L0339", "L0303"], True, False),
                                       (["L0336", "L0339"], True, False),
                                       (["L0301", "L0303"], True, False),
                                       (["L0336", "L0339", "L0303"], False, False)):
            with self.subTest(codes=codes, local=local):
                server = Mock()
                server.diagnostics = []

                def publish(*_):
                    server.diagnostics.append({
                        "uri": path.as_uri() if local else "file:///other.ldn",
                        "diagnostics": [{"code": code} for code in codes]})

                with patch.object(fuzz, "serve_one", side_effect=publish):
                    if accepted:
                        fuzz.check_reproducer(server, path, "trial")
                    else:
                        with self.assertRaises(fuzz.Broken):
                            fuzz.check_reproducer(server, path, "trial")


if __name__ == "__main__":
    unittest.main()
