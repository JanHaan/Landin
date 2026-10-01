"""The fuzz lane's mutants are the same on every host and every Python.

A seed names one mutant only while the generator and the seven mutations
stay what they are: the gate's run, a recorded hit and a reproduction a
person makes from its seed all depend on it.  So the generator is held to
splitmix64's published first outputs, each mutation kind to the bytes it
makes of a fixed text, and the seed list to the corpus it is read from.
"""
from pathlib import Path
import sys
import unittest

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
        labels = [label for label, _ in seeds]
        self.assertEqual(len(labels), len(set(labels)))
        self.assertEqual(
            sum(label.startswith("reproducers/") for label in labels),
            len(list((ROOT / "compiler/tests/fuzz/reproducers")
                     .glob("*.ldn"))))
        self.assertGreater(len(seeds), 1000)
        for _, text in seeds:
            text.encode("utf-8")


if __name__ == "__main__":
    unittest.main()
