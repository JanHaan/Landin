--  The checking stage.
--
--  It walks what the resolver resolved and says what type everything has,
--  refusing what [1870]-[1940] refuse.  Three passes, and each is forced
--  by something the tour says rather than chosen.
--
--  Pass one settles every declaration whose type is written down, over
--  every tree, before any body is read.  [1840]'s module scope is a set and
--  crosses files, so a function may call one declared in another file and
--  below it; a walk that typed declarations as it met them could not.
--
--  Pass two infers the module bindings written with [1790]'s `:=`, whose
--  type is their value's and whose value may name another module binding
--  [1940].  On demand, in declaration order, with Underway marking what is
--  already being asked: a chain that comes back to where it began names
--  nothing, and without the mark that is a stack overflow rather than a
--  diagnostic.
--
--  Pass three reads the bodies, one tree at a time in source order, so the
--  report is read top to bottom of the file it is about.
--
--  Inside an expression the walk is two mutually recursive halves and not
--  one, and [1880] is why.  A literal has no type until a context gives it
--  one, so a node is either *asked* what type it has or *required* to have
--  one the position states -- and the second is the only way a literal ever
--  gets a type at all.  R1.50's entry guessed that R1.60 would be a single
--  forward loop over 1 .. Last_Node; that is true of a pass that only
--  synthesises, and typing is not one, because [0190] makes the
--  information flow from a parent into a subtree the loop has already
--  passed.  What the flat table still buys is the answer: one array indexed
--  by Node_Id, with no map anywhere.
--
--  One rule about not reporting twice, applied everywhere.  A position
--  whose requirement is not a type -- because the subtree under it holds a
--  syntax hole, or a name that resolved to nothing, or something this pass
--  already refused -- is checked and says nothing.  That is what keeps one
--  missing `then` from becoming a column of type errors, and it is the same
--  rule Landin.Syntax.Is_Sound and Landin.Resolution.Verdict were built to
--  support.

package Landin.Stages.Checking is

   type Instance is limited new Landin.Stages.Stage with null record;

   overriding function Name (Item : Instance) return String;

   overriding procedure Run
     (Item    : Instance;
      Context : in out Compilation;
      Outcome : out Stage_Outcome);

end Landin.Stages.Checking;
