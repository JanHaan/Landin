--  The names a user selects a target description by.
--
--  One mapping, so that `refine --target=` and the language server's
--  `target` initialization option cannot come to accept different names:
--  they did, when the server's copy never learned `synthetic-32`.  A name is
--  this repository's own spelling, never a triplet or a CPU name, and the
--  description it selects still comes from one of the named constructors.

package Landin.Targets.Selection is

   function Is_Described (Name : String) return Boolean;

   function Described (Name : String) return Target_Facts
     with Pre => Is_Described (Name);

end Landin.Targets.Selection;
