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
   procedure Set_Mode (Into : in out Table; Mode : Build_Mode);
   function Mode (In_Table : Table) return Build_Mode;

   --  Whether the request links the C runtime and library on a system
   --  that may go without them, Linux with --link=libc: the half of
   --  `compiler.c_runtime` that the target alone does not decide.
   procedure Set_C_Runtime (Into : in out Table; Linked : Boolean);
   function C_Runtime_Requested (In_Table : Table) return Boolean;

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
      C_Runtime_Linked : Boolean := False;
   end record;

end Landin.Configuration;
