"""benchmarks.py's tables, its pinned C sources and its report."""

import hashlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import benchmarks  # noqa: E402


class Tables(unittest.TestCase):
    def test_performance_programs_are_the_five_with_c(self):
        chosen = benchmarks.programs("performance", [])
        self.assertEqual([entry["name"] for entry in chosen],
                         ["fannkuch-redux", "mandelbrot", "fasta",
                          "reverse-complement", "binary-trees"])
        self.assertTrue(all("c" in entry for entry in chosen))
        for entry in chosen:
            self.assertTrue((benchmarks.FIXTURES / entry["fixture"]).is_dir(), entry)

    def test_timing_programs_follow_the_workloads(self):
        chosen = {entry["name"]: entry for entry in benchmarks.programs("timing", [])}
        self.assertIn("fibre", chosen)
        self.assertNotIn("c", chosen["fibre"])
        self.assertIn("c", chosen["fasta"])
        self.assertIn("stdin_repeat", chosen["reverse-complement"])

    def test_an_unknown_name_is_refused(self):
        with self.assertRaisesRegex(benchmarks.Failure, "no program named nbody"):
            benchmarks.programs("performance", ["nbody"])


class Sources(unittest.TestCase):
    def archive(self, where: Path, members: dict) -> Path:
        path = where / "sources.zip"
        with zipfile.ZipFile(path, "w") as bundle:
            for name, data in members.items():
                bundle.writestr(name, data)
        return path

    def test_a_member_is_taken_only_with_its_pinned_digest(self):
        data = b"int main(void) { return 0; }\n"
        entry = {"name": "fasta", "c": {"member": "fasta/fasta.gcc-2.gcc",
                                        "sha256": hashlib.sha256(data).hexdigest()}}
        with tempfile.TemporaryDirectory() as scratch, \
                mock.patch.dict("os.environ", {"LANDIN_INPUTS": scratch}):
            archive = self.archive(Path(scratch), {"fasta/fasta.gcc-2.gcc": data})
            found = benchmarks.c_sources([entry], archive)
            self.assertEqual(found["fasta"].read_bytes(), data)
            changed = dict(entry, c=dict(entry["c"], sha256="0" * 64))
            with self.assertRaisesRegex(benchmarks.Failure, "not the pinned"):
                benchmarks.c_sources([changed], archive)
            missing = dict(entry, c=dict(entry["c"], member="fasta/fasta.gcc-9.gcc"))
            with self.assertRaisesRegex(benchmarks.Failure, "changed its programs"):
                benchmarks.c_sources([missing], archive)


class Report(unittest.TestCase):
    def test_multiples_and_the_geometric_mean(self):
        results = {
            "size": "performance", "runs": 3, "core": 5,
            "host": {"cpu": "a processor", "system": "Linux"},
            "versions": {"new": "refine dev", "C": "gcc"},
            "implementations": ["new", "C"],
            "programs": [{"name": "a"}, {"name": "b"}],
            "load_before": [1.0, 1.0, 1.0], "load_after": [2.0, 2.0, 2.0],
            "time": {"new": {"a": 2.0, "b": 8.0}, "C": {"a": 1.0, "b": 2.0}},
            "max_rss_kb": {"new": {"a": 2048, "b": None}, "C": {"a": 1024, "b": 1024}},
            "allocated": {"new": {"a": 1000, "b": 2000}, "C": {"a": 10, "b": 20}},
            "text": {"new": {"a": 500, "b": 600}, "C": {"a": 5, "b": 6}},
            "compile": {"new": {"a": 0.3, "b": 0.4}, "C": {"a": 0.1, "b": 0.1}},
        }
        text = benchmarks.report(results)
        self.assertIn("| new | 2 (2.00) | 8 (4.00) | 2.83 |", text)
        self.assertIn("| new | 2.0 | — |", text)
        self.assertIn("| new | 1,000 | 2,000 |", text)


if __name__ == "__main__":
    unittest.main()
