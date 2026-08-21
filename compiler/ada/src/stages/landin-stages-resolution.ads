--  The resolution stage.
--
--  It walks what the syntax stage built and says what every name means.
--  Two passes, because [1840] gives the kernel one unordered scope and two
--  ordered kinds: every module declaration of every file is collected
--  before any body is walked, so a name may be used above the line that
--  introduces it; and a local is declared when the walk reaches it, so a
--  binding's own value is read before its name exists [0110].
--
--  It is the walk and nothing else.  Landin.Resolution owns the table and
--  refuses to know a traversal order; Landin.Diagnostics.Resolution owns
--  the two codes; this owns the order in which the trees are read, which
--  is the order the sources were added and then the order the declarations
--  were written.  That is what makes the report source-stable, which is
--  the evidence R1.50 owes.
--
--  Why a walk at all, when Landin.Syntax promises that 1 .. Last_Node is a
--  post-order and a synthesising pass needs no recursion.  Resolution is
--  not synthesising: what a name means depends on where it is, so the
--  scope has to be carried down rather than read off a node.  R1.60's
--  types are the pass that gets to be a forward loop.

package Landin.Stages.Resolution is

   type Instance is limited new Landin.Stages.Stage with null record;

   overriding function Name (Item : Instance) return String;

   overriding procedure Run
     (Item    : Instance;
      Context : in out Compilation;
      Outcome : out Stage_Outcome);

end Landin.Stages.Resolution;
