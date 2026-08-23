--  A canonical text for a Unit.
--
--  One line per item, slot, block and instruction, in the order the table
--  holds them, so a recorded copy changes only where the program did.  It
--  is `Landin.Syntax.Dump`'s sibling and it is honest about the same
--  thing: it proves the lowering has not changed its mind, and nothing
--  else.  What the instructions mean is `Landin.IR.Verifier`'s, and that
--  the corpus derives at all is check.py's.
--
--  There is no reader and there will be none.  `Landin.IR`'s header rules
--  one out -- "a reader would be both a second constructor of an IR and
--  the first half of the serialised stage protocol R0.60 refused to
--  freeze" -- so R1.70's "round-trip textual dumps" cannot mean parse
--  back.  It is read here as regenerate and compare: the recorded
--  artefact is a fixed point of this function over the corpus, and the
--  trip is closed by re-running the suite after recording rather than by
--  a parser.  Whether that is what the sentence meant is R1.90's to say.
--
--  Not a stable interface.  Every word below that the language does not
--  already spell -- item, slot, block, param, datum, callee, target,
--  alternative, negated, loose, and the arrow before an operand list --
--  is this function's and no paragraph's.  The words the language does
--  spell are taken from it: a type is `Landin.Types`' spelling of one of
--  [1790]'s eleven, and a `Truth` is [1870]'s `true` or `false` and never
--  a zero or a one.
--
--  No origin is printed, and that is a decision and not an omission.
--  Every instruction carries one, and a byte offset in a golden moves
--  when a comment above it is edited, so every documentation change would
--  rewrite the artefact and the diff would stop meaning anything.  What
--  R4.60 needs pinned is that an instruction is attributed to the right
--  token, and that is a case about one program rather than a column in
--  every line of a corpus-wide file.
--
--  Nothing here asks how wide anything is.  A type is printed by name, so
--  usize stays usize [1870]; a `Number` is [1770]'s magnitude and
--  [1880]'s sign in two fields, because forming a two's complement
--  pattern needs a width and a width needs a target.  No loop here walks
--  a hashed container -- `Landin.Resolution` holds one and this only ever
--  indexes it -- which with the above is what makes "the same bytes on
--  macOS arm64 and in the pinned linux/amd64 container" a property of the
--  text rather than a hope.
--
--  Blocks print in Block_Id order, which is the order they were created
--  and not the order they were filled: an `if`'s else-entry is created
--  before the then-arm's inner blocks, so the instruction numbers inside
--  them do not ascend down the file.  `Landin.IR`'s header asks that a
--  reader be told which order a dump prints, and this is the telling.

with Landin.Source.Names;

package Landin.IR.Dump is

   --  Meanings puts a name on an item and a slot and a sort on a block's
   --  scope: `Landin.IR` holds identities and refers to R1.50's table
   --  rather than copying it, so a dump that wants the names is handed
   --  the same two tables `Landin.Syntax.Dump` is.
   --
   --  Total on any Unit whose runs partition their vectors, which is what
   --  the verifier checks first and for this reason: this prints an
   --  identity a malformed unit got wrong rather than refusing, because a
   --  dump is what a reader looks at when the verifier has just said
   --  something is wrong.
   function Text
     (Of_Unit  : Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table) return String;

end Landin.IR.Dump;
