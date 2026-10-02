--  The names a user selects a target description by, and the one a build
--  selects when it names none.
--
--  One mapping, so that `refine --target=` and the language server's
--  `target` initialization option cannot come to accept different names:
--  they did, when the server's copy never learned `synthetic-32`.  A name is
--  this repository's own spelling, never a triplet or a CPU name, and the
--  description it selects still comes from one of the named constructors.
--
--  A build that names no target is for the compiler's own host (D257), and
--  cross-compilation is always explicit.  The host is the triplet the
--  compiler itself was built for, which GNAT fixes when it compiles this
--  unit, so nothing asks the running machine anything: a compiler built for
--  x86-64 still defaults to x86-64 under an emulator on an arm64 machine.
--  The triplet is read here and nowhere else, and only as the compiler's
--  build; it never becomes a name a user writes.

package Landin.Targets.Selection is

   function Is_Described (Name : String) return Boolean;

   function Described (Name : String) return Target_Facts
     with Pre => Is_Described (Name);

   --  The description a compiler built for TRIPLET defaults to, if any:
   --  x86-64 Linux, arm64 Linux and arm64 Darwin each describe their own
   --  host, and any other build describes none, so a build there must name
   --  its target.  Parts of the triplet are matched rather than the whole,
   --  since a vendor field and a Darwin release number say nothing about
   --  which description applies.
   function Has_Host_Default (Triplet : String) return Boolean;

   function Host_Default (Triplet : String) return Target_Facts
     with Pre => Has_Host_Default (Triplet);

   --  The triplet this compiler was built for.
   function Build_Triplet return String;

end Landin.Targets.Selection;
