--  [1970]'s one hosted entry shape.
--
--  The first native slice accepts exactly `public main: () -> (code: i32)`,
--  and D12 records why that is a boundary of this slice rather than a rule
--  about every hosted executable: [1650]'s C `argc`/`argv` form stays part
--  of the language, and a freestanding program names its entry in the build
--  description instead.
--
--  The selected entry uses the native convention and the effective linker
--  name `main`.  C exports (including a callback with source name `main`)
--  never acquire argc/argv implicitly.  A renamed native `main` is legal
--  assembly input, but does not satisfy an executable request: there is no
--  implicit wrapper or second linker name.
--
--  The source shape is asked in full, including the return's name.  D12 lists
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
with Landin.Modules;
with Landin.Platform;
with Landin.Resolution;
with Landin.Source.Names;

package Landin.Backend.Entry_Point is

   --  The item a hosted program starts at, or `Landin.IR.No_Item` when the
   --  module declares nothing matching [1970].
   function Hosted_Main
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Modules  : Landin.Modules.Table;
      Names    : Landin.Source.Names.Table) return Landin.IR.Item_Id;

   --  The program's C-callable definition of `Landin.Hosted`'s argument
   --  initializer, which a hosted entry calls with C's argc and argv before
   --  its body, or `Landin.IR.No_Item` when no module defines one.  The
   --  library's `hosted/io` defines it, so a hosted program that never
   --  imports that module has no argument root and nothing to call.
   --  Checking has already held the definition to its exact signature.
   function Argument_Initializer
     (Of_Unit : Landin.IR.Unit;
      Names   : Landin.Source.Names.Table) return Landin.IR.Item_Id;

   --  The link names of the bodyless imports the program's code
   --  calls, takes the address of, or holds in data or evidence, that no
   --  routine or datum of the program defines.  A static Linux link has no
   --  C library to satisfy them.  Every routine the program holds counts,
   --  whether or not the entry reaches it, in item order, each name once.
   function Unsatisfied_Imports
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table) return Landin.Platform.Path_List;

   function Firmware_Start
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Modules  : Landin.Modules.Table;
      Names    : Landin.Source.Names.Table;
      Selected : String) return Landin.IR.Item_Id;

   --  What [1970] requires, spelled once so a diagnostic and this package
   --  cannot drift apart.
   function Required_Shape return String
     is ("public main: () -> (code: i32)");

end Landin.Backend.Entry_Point;
