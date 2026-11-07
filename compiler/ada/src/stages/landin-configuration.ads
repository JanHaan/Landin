with Landin.Memory;
with Landin.Machine;
--  D139/D202 configuration metadata. Syntax remains complete; this table
--  retains request overrides and mode, and records option provenance,
--  inactive declarations and ordered library requests for one compilation.

private with Ada.Containers.Ordered_Sets;
private with Ada.Containers.Ordered_Maps;
private with Ada.Containers.Vectors;
private with Ada.Strings.Unbounded;

with Landin.Source;
with Landin.Source.Names;
with Landin.Provenance;
with Landin.Syntax;
with Landin.Targets.Firmware;
with Landin.Types;

package Landin.Configuration is

   function Compiler_Member
     (Names : Landin.Source.Names.Table; Of_Tree : Landin.Syntax.Tree;
      Node : Landin.Syntax.Node_Id) return String;
   function Assembly_Call
     (Names : Landin.Source.Names.Table; Of_Tree : Landin.Syntax.Tree;
      Node : Landin.Syntax.Node_Id) return Boolean;
   function Fixed_Text
     (Snapshot : Landin.Source.Snapshot; Of_Tree : Landin.Syntax.Tree;
      Node : Landin.Syntax.Node_Id) return String;

   function Placement_Of
     (Snapshot : Landin.Source.Snapshot; Of_Tree : Landin.Syntax.Tree;
      Node : Landin.Syntax.Node_Id; Names : in out Landin.Source.Names.Table)
      return Landin.Machine.Placement;

   function Memory_Call
     (Names : Landin.Source.Names.Table; Of_Tree : Landin.Syntax.Tree;
      Node : Landin.Syntax.Node_Id) return Landin.Memory.Operation;

   --  Whether NODE calls `compiler.unreachable`, [1560]'s explicit trap: a
   --  `() -> noreturn` builtin that raises `unreachable` at its own site.
   --  Its arguments, however written, are the checker's to refuse.
   function Unreachable_Call
     (Names : Landin.Source.Names.Table; Of_Tree : Landin.Syntax.Tree;
      Node : Landin.Syntax.Node_Id) return Boolean;

   type Table is private;

   type Build_Mode is (Debug, Release);
   procedure Set_Firmware_Layout
     (Into : in out Table; Layout : Landin.Targets.Firmware.Layout_Kind);
   function Firmware_Layout (In_Table : Table)
      return Landin.Targets.Firmware.Layout_Kind;

   procedure Set_Mode (Into : in out Table; Mode : Build_Mode);
   function Mode (In_Table : Table) return Build_Mode;

   --  Whether the request links the C runtime and library on a system
   --  that may go without them, Linux with --link=libc: the half of
   --  `compiler.c_runtime` that the target alone does not decide.
   procedure Set_C_Runtime (Into : in out Table; Linked : Boolean);
   function C_Runtime_Requested (In_Table : Table) return Boolean;

   --  The compiler's fixed facts, `compiler.NAME` in a fixed condition or
   --  a module value [1530]/D437: the one table of their names, which
   --  configuration and name resolution both read.  An atom fact is
   --  compared with a configuration atom; `word_size` is an integer and
   --  each C fact a bool.  `compiler.feature.NAME` is a feature's, which
   --  Landin.Targets.Levels names.
   type Fixed_Fact is
     (Arch_Fact, OS_Fact, Byte_Order_Fact, Build_Mode_Fact, Word_Size_Fact,
      C_SysV_LP64_Fact, C_Darwin_LP64_Fact, C_AAPCS64_LP64_Fact,
      C_RiscV_LP64D_Fact, C_AAPCS32_Fact, C_RiscV_ILP32_Fact,
      C_Xtensa_Windowed_ILP32_Fact, C_Runtime_Fact);
   subtype Atom_Fact is Fixed_Fact range Arch_Fact .. Build_Mode_Fact;
   subtype Valued_Fact is Fixed_Fact range Word_Size_Fact .. C_Runtime_Fact;
   subtype C_ABI_Fact is Fixed_Fact
     range C_SysV_LP64_Fact .. C_Xtensa_Windowed_ILP32_Fact;

   function Fact_Name (Fact : Fixed_Fact) return String
     is (case Fact is
           when Arch_Fact => "arch",
           when OS_Fact => "os",
           when Byte_Order_Fact => "byte_order",
           when Build_Mode_Fact => "build_mode",
           when Word_Size_Fact => "word_size",
           when C_SysV_LP64_Fact => "c_sysv_lp64",
           when C_Darwin_LP64_Fact => "c_darwin_lp64",
           when C_AAPCS64_LP64_Fact => "c_aapcs64_lp64",
           when C_RiscV_LP64D_Fact => "c_riscv_lp64d",
           when C_AAPCS32_Fact => "c_aapcs32",
           when C_RiscV_ILP32_Fact => "c_riscv_ilp32",
           when C_Xtensa_Windowed_ILP32_Fact => "c_xtensa_windowed_ilp32",
           when C_Runtime_Fact => "c_runtime");

   function Is_Fact_Name (Word : String) return Boolean
     is (for some Fact in Fixed_Fact => Fact_Name (Fact) = Word);

   function Fact_Named (Word : String) return Fixed_Fact
     with Pre => Is_Fact_Name (Word);

   function Is_Atom_Fact_Name (Word : String) return Boolean
     is (Is_Fact_Name (Word) and then Fact_Named (Word) in Atom_Fact);

   function Is_Valued_Fact_Name (Word : String) return Boolean
     is (Is_Fact_Name (Word) and then Fact_Named (Word) in Valued_Fact);

   --  The C ABI on which a C fact is true.
   function ABI_Of (Fact : C_ABI_Fact) return Landin.Targets.C_ABI_Kind
     is (case Fact is
           when C_SysV_LP64_Fact => Landin.Targets.SysV_AMD64_LP64,
           when C_Darwin_LP64_Fact => Landin.Targets.Darwin_AAPCS64_LP64,
           when C_AAPCS64_LP64_Fact => Landin.Targets.AAPCS64_LP64,
           when C_RiscV_LP64D_Fact => Landin.Targets.RiscV_LP64D,
           --  D920: one fact for both of AAPCS32's variants, since the
           --  description's float unit, not the C ABI, selects VFP.
           when C_AAPCS32_Fact => Landin.Targets.Arm_AAPCS32_Soft,
           when C_RiscV_ILP32_Fact => Landin.Targets.RiscV_ILP32,
           when C_Xtensa_Windowed_ILP32_Fact =>
              Landin.Targets.Xtensa_Windowed_ILP32);

   --  The configuration atoms that are not an architecture's: a system's,
   --  a byte order's and a build mode's.
   type Fixed_Atom is
     (Linux_Atom, Darwin_Atom, FreeBSD_Atom, Freestanding_Atom,
      Little_Atom, Big_Atom, Debug_Atom, Release_Atom);

   function Atom_Name (Atom : Fixed_Atom) return String
     is (case Atom is
           when Linux_Atom => "linux",
           when Darwin_Atom => "darwin",
           when FreeBSD_Atom => "freebsd",
           when Freestanding_Atom => "freestanding",
           when Little_Atom => "little",
           when Big_Atom => "big",
           when Debug_Atom => "debug",
           when Release_Atom => "release");

   --  Whether WORD is a configuration atom an atom fact is compared with:
   --  an architecture's, Landin.Targets.Atom's, or a Fixed_Atom's.
   function Is_Configuration_Atom (Word : String) return Boolean
     is (Landin.Targets.Is_Architecture_Atom (Word)
         or else (for some Atom in Fixed_Atom => Atom_Name (Atom) = Word));

   --  Every configuration atom, each in backticks, the last after `or`:
   --  what a refusal of one as an option's name lists (D855).
   function Configuration_Atom_List return String;

   --  D542: the members a device description is written in.
   function Is_Description_Member (Namespace, Member : String) return Boolean
     is ((Namespace = "compiler"
          and then Member in "device" | "core" | "vectors" | "interrupt"
            | "boot" | "float_unit" | "esp_image")
         or else (Namespace = "linker" and then Member in "region" | "place"));

   --  Shared explanation for a tool member outside its enabled context.
   function Tool_Advice (Namespace, Member : String) return String;

   function Is_Builtin_Import
     (Names : Landin.Source.Names.Table;
      Of_Tree : Landin.Syntax.Tree; Node : Landin.Syntax.Node_Id)
      return Boolean;

   procedure Record_Option
     (Into : in out Table; Name : Landin.Source.Names.Name_Id;
      Origin : Landin.Provenance.Origin);
   function Option_Origin
     (In_Table : Table; Name : Landin.Source.Names.Name_Id)
      return Landin.Provenance.Origin;

   --  Whether Name may be a fixed option's name in a request: lowercase
   --  letters, digits after the first, and underscores.
   function Is_Option_Name (Name : String) return Boolean
     is (Name'Length > 0
         and then (for all Index in Name'Range =>
                     Name (Index) in 'a' .. 'z' | '_'
                     or else (Index /= Name'First
                              and then Name (Index) in '0' .. '9')));

   --  Request inputs survive Prepare; outputs are rebuilt for each run.
   procedure Add_Override
     (Into : in out Table; Name : String; Value : String);
   function Override_Count (In_Table : Table) return Natural;
   function Override_Name
     (In_Table : Table; Index : Positive) return String;
   function Override_Value
     (In_Table : Table; Index : Positive) return String;

   --  D202/D523: each active `linker.library`, in source order with its
   --  repeats, and the directive that asked for it, which D525's refusal
   --  of a library the link cannot find names.
   procedure Add_Library
     (Into : in out Table; Name : String;
      Source : Landin.Source.Source_Id := Landin.Source.No_Source;
      Where : Landin.Source.Span := Landin.Source.Empty_Span);
   function Library_Count (In_Table : Table) return Natural;
   function Library_Name
     (In_Table : Table; Index : Positive) return String;
   function Library_Source
     (In_Table : Table; Index : Positive) return Landin.Source.Source_Id;
   function Library_Where
     (In_Table : Table; Index : Positive) return Landin.Source.Span;

   --  D524: each active `linker.directory`, in source order with its
   --  repeats, as written and with the directive's place.  The driver
   --  resolves a relative one against the declaring file's directory,
   --  because only the driver asks the host where that is.
   procedure Add_Directory
     (Into : in out Table; Written : String;
      Source : Landin.Source.Source_Id; Where : Landin.Source.Span);
   function Directory_Count (In_Table : Table) return Natural;
   function Directory_Written
     (In_Table : Table; Index : Positive) return String;
   function Directory_Source
     (In_Table : Table; Index : Positive) return Landin.Source.Source_Id;
   function Directory_Where
     (In_Table : Table; Index : Positive) return Landin.Source.Span;

   --  D412: an active `compiler.assert` that measures a declared type's
   --  layout waits for checking, which knows that layout; configuration
   --  records it here, and resolution, checking and the late fold read it.
   procedure Defer_Assertion
     (Into : in out Table;
      Source : Landin.Source.Source_Id;
      Node : Landin.Syntax.Node_Id);
   function Deferred_Count (In_Table : Table) return Natural;
   function Deferred_Source
     (In_Table : Table; Index : Positive) return Landin.Source.Source_Id;
   function Deferred_Node
     (In_Table : Table; Index : Positive) return Landin.Syntax.Node_Id;

   --  D437: a compiler fact read in a module value.  Configuration
   --  evaluates it once arms are selected and records the node it stands
   --  at: a bool or integer fact, or an atom fact compared with `==` or
   --  `<>`, which is then that comparison's bool.  Resolution does not
   --  look inside a recorded node, the checker types it as the bool or
   --  untyped integer it is, and the one folder reads its value, so it is
   --  image data exactly as the literal it stands for would be.  A fact
   --  configuration refused is recorded as Refused_Fact, so that no later
   --  stage reports it again.
   type Fact_Kind is (No_Fact, Bool_Fact, Integer_Fact, Refused_Fact);
   procedure Record_Fact
     (Into : in out Table;
      Source : Landin.Source.Source_Id;
      Node : Landin.Syntax.Node_Id;
      Kind : Fact_Kind;
      Value : Landin.Types.Folded);
   function Fact_At
     (In_Table : Table;
      Source : Landin.Source.Source_Id;
      Node : Landin.Syntax.Node_Id) return Fact_Kind;
   function Fact_Value
     (In_Table : Table;
      Source : Landin.Source.Source_Id;
      Node : Landin.Syntax.Node_Id) return Landin.Types.Folded;

   --  D543: the firmware profile the program's one description selects,
   --  the library's constrained reference when it reaches no other, or
   --  none (Present False) when it reaches neither.
   procedure Set_Profile
     (Into : in out Table; Selected : Landin.Targets.Firmware.Profile);
   function Profile
     (In_Table : Table) return Landin.Targets.Firmware.Profile;

   procedure Prepare (Into : in out Table);

   procedure Mark_Inactive
     (Into : in out Table;
      Source : Landin.Source.Source_Id;
      Node : Landin.Syntax.Node_Id);

   function Is_Active
     (In_Table : Table;
      Source : Landin.Source.Source_Id;
      Node : Landin.Syntax.Node_Id) return Boolean;

   --  D139 presents selected declarations as one module declaration run.
   --  Stages use this instead of walking fixed-conditionals themselves, so
   --  nesting and inactive arms have one interpretation throughout.
   generic
      with procedure Action
        (Of_Tree : Landin.Syntax.Tree; Node : Landin.Syntax.Node_Id);
   procedure For_Each_Active_Declaration
     (In_Table : Table; Of_Tree : Landin.Syntax.Tree);

private

   type Inactive_Node is record
      Source : Landin.Source.Source_Id;
      Node   : Landin.Syntax.Node_Id;
   end record;

   function "<" (Left, Right : Inactive_Node) return Boolean;

   --  Every node of every inactive subtree is marked, and every stage asks
   --  about nodes and declarations one at a time, so a lookup must not cost
   --  a walk of the marks: a list made each question linear in the inactive
   --  code, which on platform/linux and its numbers module was most of the
   --  frontend's time.
   package Entries is new Ada.Containers.Ordered_Sets
     (Element_Type => Inactive_Node);

   type Override_Entry is record
      Name, Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   package Overrides is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Override_Entry);
   type Link_Request is record
      Text : Ada.Strings.Unbounded.Unbounded_String;
      Source : Landin.Source.Source_Id := Landin.Source.No_Source;
      Where : Landin.Source.Span := Landin.Source.Empty_Span;
   end record;
   package Libraries is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Link_Request);
   type Option_Site is record
      Name : Landin.Source.Names.Name_Id;
      Origin : Landin.Provenance.Origin;
   end record;
   package Option_Sites is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Option_Site);

   package Deferrals is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Inactive_Node);

   type Recorded_Fact is record
      Kind : Fact_Kind := No_Fact;
      Value : Landin.Types.Folded := 0;
   end record;
   package Fact_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type => Inactive_Node, Element_Type => Recorded_Fact);

   type Table is record
      Deferred : Deferrals.Vector;
      Facts : Fact_Maps.Map;
      Inactive : Entries.Set;
      Settings : Overrides.Vector;
      Linked   : Libraries.Vector;
      Searched : Libraries.Vector;
      Declared : Option_Sites.Vector;
      Selected_Mode : Build_Mode := Debug;
      Selected_Layout : Landin.Targets.Firmware.Layout_Kind :=
        Landin.Targets.Firmware.Boot_Layout;
      C_Runtime_Linked : Boolean := False;
      Selected_Profile : Landin.Targets.Firmware.Profile;
   end record;

end Landin.Configuration;
