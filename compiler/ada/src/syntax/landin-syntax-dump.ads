--  A canonical text for a tree.
--
--  One line per node, in post-order, with the kind, the extent, the anchor
--  and the spelling of any name.  Deterministic, so it can be a recorded
--  golden the way `compiler/tests/lexical.tokens` is, and honest about what
--  that golden proves: check.py independently derives positive sources and
--  checks negative sources according to their refusing stage.  This dump
--  records the parser's structure, not independent semantic correctness.
--
--  Not a stable interface, and not a serialisation.  `Landin.IR.Dump` says the
--  same of the IR dumps for the same reason: the moment a dump is an
--  interface, the representation stops being free to change, and the language
--  keeps changing it.

with Landin.Source.Names;

package Landin.Syntax.Dump is

   function Text
     (Of_Tree : Tree; Names : Landin.Source.Names.Table) return String;

end Landin.Syntax.Dump;
