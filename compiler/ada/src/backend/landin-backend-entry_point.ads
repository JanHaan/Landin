--  [1970]'s one hosted entry shape.
--
--  The first native slice accepts exactly `public main: () -> (code: i32)`,
--  and D12 records why that is a boundary of this slice rather than a rule
--  about every hosted executable: [1650]'s C `argc`/`argv` form stays part
--  of the language, and a freestanding program names its entry in the build
--  description instead.
--
--  All five conditions are asked, including the return's name.  D12 lists
--  "treat the return's name as immaterial" among the alternatives it did
--  not take, so accepting `-> (status: i32)` here would quietly implement
--  the alternative rather than the decision.
--
--  This is asked of the IR and not of the tree, because by the time an
--  entry is wanted the frontend has finished and the Unit is what the
--  backend has.  It is also why nothing here is a `Compiler_Defect`: a
--  module with no `main` is an ordinary program that was accepted, and only
--  asking it for an executable makes the absence a fault.

with Landin.IR;
with Landin.Resolution;
with Landin.Source.Names;

package Landin.Backend.Entry_Point is

   --  The item a hosted program starts at, or `Landin.IR.No_Item` when the
   --  module declares nothing matching [1970].
   function Hosted_Main
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table) return Landin.IR.Item_Id;

   --  What [1970] requires, spelled once so a diagnostic and this package
   --  cannot drift apart.
   function Required_Shape return String
     is ("public main: () -> (code: i32)");

end Landin.Backend.Entry_Point;
