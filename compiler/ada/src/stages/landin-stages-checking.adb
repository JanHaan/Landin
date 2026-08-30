with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Checking;
with Landin.Diagnostics.Checking;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Source;
with Landin.Stages.Checking.Flow;
with Landin.Syntax.Forest;
with Landin.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Stages.Checking is

   package Bad renames Landin.Diagnostics.Checking;
   package Res renames Landin.Resolution;
   package Syn renames Landin.Syntax;
   package Ty renames Landin.Types;

   use type Landin.Provenance.Declaration_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Count;
   use type Landin.Types.Type_Kind;
   use type Landin.Types.Folded;
   use type Landin.Types.Magnitude;
   use type Landin.Checking.Progress;
   use type Landin.Checking.Actual_Kind;
   use type Landin.Checking.Array_Element_Form;
   use type Landin.Checking.Atom_Set_Id;
   use type Landin.Checking.Element_Count;
   use type Landin.Checking.Error_Set_Form;
   use type Landin.Checking.Field_Kind;
   use type Landin.Checking.Instance_State;
   use type Landin.Checking.Nominal_Type_Id;
   use type Landin.Checking.Routine_Instance_Id;
   use type Landin.Checking.Routine_Instance_State;
   use type Landin.Checking.Signature_Id;
   use type Res.Verdict;
   use type Res.Declaration_Sort;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Names.Name_Id;

   overriding function Name (Item : Instance) return String is
      pragma Unreferenced (Item);
   begin
      return "checking";
   end Name;

   overriding procedure Run
     (Item    : Instance;
      Context : in out Compilation;
      Outcome : out Stage_Outcome)
   is
      pragma Unreferenced (Item);

      Spellings : constant not null access Landin.Source.Names.Table :=
        Identities (Context);
      Trees     : constant not null access Syn.Forest.Table :=
        Landin.Stages.Trees (Context);
      Meanings  : constant not null access Res.Table :=
        Landin.Stages.Meanings (Context);
      Types     : constant not null access Landin.Checking.Table :=
        Landin.Stages.Types (Context);

      Facts : constant Landin.Targets.Target_Facts := Target (Context);
      Found : Landin.Diagnostics.Diagnostic_List;

      --  Generic declarations are templates, not runtime types.  This
      --  short-lived stack detects expansion cycles without recording an
      --  instantiation-specific answer against a template syntax node.
      Generic_Expansion : array
        (Positive range 1 .. Positive'Max
           (1, Res.Declaration_Count (Meanings.all))) of Boolean :=
             [others => False];
      Template_Checked : array
        (Positive range 1 .. Positive'Max
           (1, Res.Declaration_Count (Meanings.all))) of Boolean :=
             [others => False];
      Template_Invalid : array
        (Positive range 1 .. Positive'Max
           (1, Res.Declaration_Count (Meanings.all))) of Boolean :=
             [others => False];
      Struct_Layout_Depth : Natural := 0;
      Active_Struct_Body : Landin.Provenance.Origin :=
        Landin.Provenance.No_Origin;
      Active_Struct_Field : Landin.Provenance.Origin :=
        Landin.Provenance.No_Origin;

      --  D137 separates an identity mention from a by-value edge.  Function
      --  signatures and type-actual keys need only the former; a field,
      --  payload or array element needs the latter even at length zero.
      type Type_Requirement is (Identity_Only, Value_Layout);

      type Symbolic_Layout_Id is range 0 .. Integer'Last;
      No_Symbolic_Layout : constant Symbolic_Layout_Id := 0;

      type Type_Descriptor is record
         Kind    : Ty.Type_Kind := Ty.Ill_Typed;
         Length  : Landin.Checking.Element_Count := 0;
         Element : Ty.Scalar_Name := Ty.U8;
         Element_Nominal : Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.No_Nominal_Type;
         Nominal : Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.No_Nominal_Type;
         Atoms : Landin.Checking.Atom_Set_Id :=
           Landin.Checking.No_Atom_Set;
         Signature : Landin.Checking.Signature_Id :=
           Landin.Checking.No_Signature;
         --  A transient declaration-validation obligation.  It belongs to
         --  this Run invocation, never to syntax or the canonical key.
         Symbolic : Symbolic_Layout_Id := No_Symbolic_Layout;
      end record;

      type Formal_Actual is record
         Formal     : Res.Declaration_Id := Res.No_Declaration;
         Value      : Type_Descriptor;
         Fixed      : Ty.Magnitude := 0;
         Fixed_Known : Boolean := False;
      end record;

      type Formal_Actual_Array is array (Positive range <>) of Formal_Actual;

      package Formal_Actual_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Formal_Actual);

      type Symbolic_Layout_Kind is
        (Symbolic_Nominal_Layout, Symbolic_Array_Layout);

      type Symbolic_Layout is record
         Kind     : Symbolic_Layout_Kind := Symbolic_Nominal_Layout;
         Template : Res.Declaration_Id := Res.No_Declaration;
         First    : Natural := 0;
         Count    : Natural := 0;
         Element  : Type_Descriptor;
      end record;

      package Symbolic_Layout_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Symbolic_Layout);

      Symbolic_Actuals : Formal_Actual_Vectors.Vector;
      Symbolic_Layouts : Symbolic_Layout_Vectors.Vector;

      ------------------------------------------------------------

      function Tree_For (Id : Landin.Source.Source_Id)
        return not null access constant Syn.Tree
        is (Syn.Forest.Tree_Of (Trees.all, Id));

      function Template_Declaration
        (Nominal : Landin.Checking.Nominal_Type_Id)
         return Res.Declaration_Id
        is (Landin.Checking.Template_Of (Types.all, Nominal));

      function Spelled (Of_Name : Landin.Source.Names.Name_Id) return String
        is (Landin.Source.Names.Spelling (Spellings.all, Of_Name));

      --  Which declaration a declaring node is.  Resolution publishes the
      --  other direction, so the few stage-level callers scan the short,
      --  source-ordered declaration table.
      function Declaration_At
        (Src : Landin.Source.Source_Id; Node : Syn.Node_Id)
         return Res.Declaration_Id;

      function Declaration_At
        (Src : Landin.Source.Source_Id; Node : Syn.Node_Id)
         return Res.Declaration_Id
      is
      begin
         for Id in Res.Declaration_Id'(1)
                   .. Res.Declaration_Id
                        (Res.Declaration_Count (Meanings.all))
         loop
            if Res.Source_Of (Meanings.all, Id) = Src
              and then Res.Node_Of (Meanings.all, Id) = Node
            then
               return Id;
            end if;
         end loop;

         return Res.No_Declaration;
      end Declaration_At;

      function Generic_Routine_Owner
        (Id : Res.Declaration_Id) return Res.Declaration_Id;

      function Generic_Routine_Owner
        (Id : Res.Declaration_Id) return Res.Declaration_Id
      is
         Member_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Id));
         Member_Node : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Id);
      begin
         for Candidate in Res.Declaration_Id'(1)
           .. Res.Declaration_Id (Res.Declaration_Count (Meanings.all))
         loop
            if Res.Sort_Of (Meanings.all, Candidate) = Res.Module_Function
              and then Res.Source_Of (Meanings.all, Candidate)
                = Res.Source_Of (Meanings.all, Id)
            then
               declare
                  Function_Node : constant Syn.Node_Id :=
                    Res.Node_Of (Meanings.all, Candidate);
               begin
                  if Syn.Generic_Formal_Count
                       (Member_Tree.all, Function_Node) /= 0
                    and then Landin.Source.Contains
                      (Syn.Where (Member_Tree.all, Function_Node),
                       Syn.Where (Member_Tree.all, Member_Node))
                  then
                     return Candidate;
                  end if;
               end;
            end if;
         end loop;
         return Res.No_Declaration;
      end Generic_Routine_Owner;

      --  How a type is named in a sentence a user reads.  The five that are
      --  not one of [1790]'s eleven are described and not spelled, because
      --  no program can write one of them down.
      function Shown (Item : Ty.Type_Kind) return String
        is (case Item is
               when Ty.Scalar_Name     => "`" & Ty.Spelling (Item) & "`",
               when Ty.Untyped_Integer => "a number",
               when Ty.No_Value        => "nothing",
               when Ty.Atom_Value      => "an atom",
               when others             => "something unknown");

      --  A requirement that is not a real type is checked and says
      --  nothing.  One rule at every position: a hole, a name that
      --  resolved to nothing and a node already refused all arrive here,
      --  and none of them is a second mistake the program made.
      function Decidable (Item : Ty.Type_Kind) return Boolean
        is (Item in Ty.Settled);

      --  A count a sentence can hold.  Natural'Image pads and pluralises
      --  nothing, and a report is bytes a fixture pins.
      function Counted (Value : Natural; Thing : String) return String
        is (Ada.Strings.Fixed.Trim
              (Natural'Image (Value), Ada.Strings.Both)
            & " " & Thing & (if Value = 1 then "" else "s"));

      --  'Image pads a non-negative value with a blank, and a report is
      --  bytes a fixture pins.
      function Written (Value : Ty.Folded) return String
        is (Ada.Strings.Fixed.Trim
              (Ty.Folded'Image (Value), Ada.Strings.Both));

      ------------------------------------------------------------
      --  Forward declarations
      ------------------------------------------------------------

      function Settled_Type (Id : Res.Declaration_Id) return Ty.Type_Kind;
      function Declared_As (Id : Res.Declaration_Id) return Ty.Type_Kind;
      function Signature_At
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
         return Landin.Checking.Signature_Id;
      function Is_Local_Binding
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      function Construction_Body
        (Of_Tree : Syn.Tree; Literal : Syn.Node_Id)
         return Landin.Checking.Nominal_Type_Id;
      function Construction_Agrees
        (Of_Tree  : Syn.Tree;
         Literal  : Syn.Node_Id;
         Expected : Landin.Checking.Nominal_Type_Id;
         Related  : Landin.Provenance.Origin;
         Because  : String) return Boolean;
      function Declared_As_Node
        (Of_Tree         : Syn.Tree;
         Node            : Syn.Node_Id;
         For_Declaration : Res.Declaration_Id := Res.No_Declaration)
         return Ty.Type_Kind;
      procedure Check_Literal
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Ty.Scalar_Name;
         Negated : Boolean);
      procedure Commit_To
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Ty.Scalar_Name);
      function Synthesise
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind;
      function Selected_From
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind;
      function Admit_Array_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      --  D118/D119: whether a selection chain [0420] starts at a bound
      --  name.  The depth is the source's; nothing here fixes one.
      function Selects_From_A_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      function Chain_Root_Of
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id;
      --  The same chain, when what it started from is runtime storage: a
      --  module binding or a local.  This is what makes a contextual copy
      --  source a place rather than a value.
      function Chain_Names_Storage
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      --  A whole aggregate element is storage whether its index is known
      --  or computed; lowering retains a checked internal address for the
      --  latter without exposing a source pointer.
      function Chain_Names_Element_Storage
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      function Is_Aggregate_Alias_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      --  D126: whether a selection chain [0420] starts at a name that
      --  resolved.  Deliberately wider than Chain_Names_Storage: a named
      --  return, a parameter and D121's payload alias all hold a variant
      --  part, and none of them is a binding.
      function Chain_Starts_At_A_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      function Admit_Variant_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      function Synthesise_Binary
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind;
      function Signatures_Agree
        (Left, Right : Landin.Checking.Signature_Id) return Boolean;
      function Field_Has_Zero_Image
        (Wrote : Landin.Checking.Nominal_Type_Id;
         Field : Positive) return Boolean;
      function Has_Zero_Image
        (Wrote : Landin.Checking.Nominal_Type_Id) return Boolean;
      procedure Check_Aggregate_Zeroed
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wrote   : Landin.Checking.Nominal_Type_Id;
         Site    : Landin.Provenance.Origin;
         Because : String);
      procedure Check_Array_Zeroed
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Length  : Landin.Checking.Element_Count;
         Element : Ty.Scalar_Name;
         Element_Nominal : Landin.Checking.Nominal_Type_Id;
         Site    : Landin.Provenance.Origin;
         Because : String);

      --  D124: a control expression is checked against one complete result
      --  shape.  Scalar kind alone is enough for a scalar; arrays carry D17's
      --  structural identity, aggregates carry [0710]'s nominal body and
      --  D123's function values carry their recursive signature.  Keeping
      --  this target-neutral is what lets lowering choose storage without
      --  importing a backend layout into checking.
      type Value_Context is record
         Kind         : Ty.Type_Kind := Ty.Undecided;
         Nominal      : Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.No_Nominal_Type;
         Length       : Landin.Checking.Element_Count := 0;
         Element      : Ty.Scalar_Name := Ty.Bool;
         Element_Nominal : Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.No_Nominal_Type;
         Signature    : Landin.Checking.Signature_Id :=
           Landin.Checking.No_Signature;
         --  Nonzero only for [0990]'s anonymous structural aggregate: the
         --  source signature whose ordered named results form this value.
         Result_Shape : Landin.Checking.Signature_Id :=
           Landin.Checking.No_Signature;
         Atoms        : Landin.Checking.Atom_Set_Id :=
           Landin.Checking.No_Atom_Set;
      end record;

      No_Value_Context : constant Value_Context := (others => <>);

      procedure Check_Contextual_Value
        (Of_Tree      : Syn.Tree;
         Node         : Syn.Node_Id;
         Expected     : Value_Context;
         Site         : Landin.Provenance.Origin;
         Because      : String;
         Static_Image : Boolean := False);
      function Synthesise_Control
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind;

      function Check_Call
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Signature : Landin.Checking.Signature_Id) return Ty.Type_Kind;
      function Instantiate_Generic_Call
        (Caller_Tree : Syn.Tree;
         Call        : Syn.Node_Id;
         Template    : Res.Declaration_Id)
         return Landin.Checking.Signature_Id;
      procedure Require
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Ty.Type_Kind;
         Site    : Landin.Provenance.Origin;
         Because : String);
      procedure Require_Atom
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Landin.Checking.Atom_Set_Id;
         Site    : Landin.Provenance.Origin;
         Because : String);
      procedure Check_Place
        (Of_Tree        : Syn.Tree;
         Node           : Syn.Node_Id;
         Stepping       : Boolean;
         Variant_Context : Boolean := False);
      procedure Check_Array_Literal
        (Of_Tree      : Syn.Tree;
         Context      : Syn.Node_Id;
         Literal      : Syn.Node_Id;
         Expected     : Landin.Checking.Element_Count;
         Element      : Ty.Scalar_Name;
         Static_Image : Boolean;
         Context_Site : Landin.Provenance.Origin :=
           Landin.Provenance.No_Origin);
      procedure Check_Struct_Literal
        (Of_Tree      : Syn.Tree;
         Literal      : Syn.Node_Id;
         Wrote        : Landin.Checking.Nominal_Type_Id;
         Static_Image : Boolean);
      procedure Check_Variant_Value
        (Of_Tree : Syn.Tree;
         Site    : Syn.Node_Id;
         Value   : Syn.Node_Id;
         Wrote   : Landin.Checking.Nominal_Type_Id;
         Field   : Positive;
         Static_Image : Boolean := False);
      procedure Check_Match
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Returns : Ty.Type_Kind;
         Expected : Value_Context := No_Value_Context;
         Value_Site : Landin.Provenance.Origin :=
           Landin.Provenance.No_Origin;
         Value_Because : String := "");
      procedure Check_Mixed_Array_Repetition
        (Of_Tree      : Syn.Tree;
         Site_Node    : Syn.Node_Id;
         Repetition   : Syn.Node_Id;
         Expected     : Landin.Checking.Element_Count;
         Element      : Ty.Scalar_Name;
         Static_Image : Boolean;
         Context_Site : Landin.Provenance.Origin :=
           Landin.Provenance.No_Origin);
      procedure Check_Array_Repetition
        (Of_Tree      : Syn.Tree;
         Site_Node    : Syn.Node_Id;
         Repetition   : Syn.Node_Id;
         Expected     : Landin.Checking.Element_Count;
         Element      : Ty.Scalar_Name;
         Static_Image : Boolean;
         Context_Site : Landin.Provenance.Origin :=
           Landin.Provenance.No_Origin);
      procedure Check_Statement
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Returns : Ty.Type_Kind);
      procedure Check_Block
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Returns : Ty.Type_Kind;
         Expected : Value_Context := No_Value_Context;
         Value_Site : Landin.Provenance.Origin :=
           Landin.Provenance.No_Origin;
         Value_Because : String := "");
      procedure Check_Routine_Body
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);
      procedure Check_Operands
        (Of_Tree    : Syn.Tree;
         Node       : Syn.Node_Id;
         Whole_Fold : Boolean);
      procedure Infer (Id : Res.Declaration_Id);
      function Is_Known (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Boolean;
      procedure Check_Module_Value
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

      ------------------------------------------------------------
      --  What a declaration's type is
      ------------------------------------------------------------

      --  The type a declaration writes down, or Undecided when it writes
      --  none.  Every declaration the kernel has except a module `:=`
      --  binding writes one, which is why pass two is so small.
      --  The type a declaring node writes down: [0110]'s right of the
      --  colon, read as one of [1790]'s eleven.  Undecided when it writes
      --  none, which in the kernel is only [1790]'s `:=` form.
      --  What a type position names.  One of [1790]'s eleven, which the
      --  parser recognised; or [1795]'s declared name, which only
      --  resolution can answer for and which this follows to the type it
      --  was declared from.  D15 makes that an alias, so following it is
      --  the whole of what a type declaration means.
      function Type_At
        (Of_Tree         : Syn.Tree;
         Written         : Syn.Node_Id;
         For_Declaration : Res.Declaration_Id := Res.No_Declaration;
         Requirement     : Type_Requirement := Value_Layout)
         return Ty.Type_Kind;

      --  D135 substitutes only while expanding an application.  The result
      --  is a value local to this walk; in particular, an array node in a
      --  generic alias never receives the length of one instantiation.
      function Normalized_Type
        (Of_Tree    : Syn.Tree;
         Written    : Syn.Node_Id;
         Actuals    : Formal_Actual_Array;
         Application : Landin.Provenance.Origin :=
           Landin.Provenance.No_Origin;
         Requirement : Type_Requirement := Value_Layout)
         return Type_Descriptor;

      function Actual_For
        (Descriptor : Type_Descriptor) return Landin.Checking.Actual_Key;

      function Descriptor_For
        (Actual : Landin.Checking.Actual_Key) return Type_Descriptor;

      function Remember_Symbolic_Nominal
        (Template : Res.Declaration_Id;
         Actuals  : Formal_Actual_Array) return Symbolic_Layout_Id;

      function Remember_Symbolic_Array
        (Element : Type_Descriptor) return Symbolic_Layout_Id;

      function Require_Value_Layout
        (Descriptor  : Type_Descriptor;
         Of_Tree     : Syn.Tree;
         At_Node     : Syn.Node_Id;
         Application : Landin.Provenance.Origin) return Type_Descriptor;

      procedure Build_Struct_Instance
        (Of_Tree     : Syn.Tree;
         Struct_Node        : Syn.Node_Id;
         Instance    : Landin.Checking.Nominal_Type_Id;
         Actuals     : Formal_Actual_Array;
         Application : Landin.Provenance.Origin;
         Valid       : out Boolean);

      procedure Validate_Template (Id : Res.Declaration_Id);

      procedure Report_Application
        (Of_Tree : Syn.Tree; At_Node : Syn.Node_Id; Message : String);

      function Fixed_Argument
        (Of_Tree : Syn.Tree;
         Written : Syn.Node_Id;
         Actuals : Formal_Actual_Array;
         Valid   : out Boolean;
         Known   : out Boolean) return Ty.Magnitude;

      --  D136's one evaluator for direct and substituted array bounds.  It
      --  returns a local mathematical value and never annotates a template
      --  node with an instantiation-specific answer.
      function Fixed_Bound
        (Of_Tree    : Syn.Tree;
         Written    : Syn.Node_Id;
         Actuals    : Formal_Actual_Array;
         Application : Landin.Provenance.Origin;
         Valid      : out Boolean;
         Known      : out Boolean) return Ty.Folded;

      procedure Report_Fixed_Bound_Range
        (Of_Tree    : Syn.Tree;
         At_Node    : Syn.Node_Id;
         Application : Landin.Provenance.Origin;
         Message    : String;
         Note       : String);

      procedure Report_Fixed_Bound_Operand
        (Of_Tree    : Syn.Tree;
         At_Node    : Syn.Node_Id;
         Application : Landin.Provenance.Origin;
         Message    : String);

      procedure Report_Application
        (Of_Tree : Syn.Tree; At_Node : Syn.Node_Id; Message : String) is
      begin
         Bad.Report
           (Item    => Bad.Unsupported_Use,
            Source  => Syn.Source_Of (Of_Tree),
            Where   => Syn.Where (Of_Tree, At_Node),
            Message => Message,
            Refused => Bad.Parameterized_Type_Alias,
            Into    => Found);
      end Report_Application;

      function Fixed_Argument
        (Of_Tree : Syn.Tree;
         Written : Syn.Node_Id;
         Actuals : Formal_Actual_Array;
         Valid   : out Boolean;
         Known   : out Boolean) return Ty.Magnitude
      is
      begin
         Valid := False;
         Known := False;
         if Syn.Kind (Of_Tree, Written) = Syn.Integer_Literal then
            declare
               Snap : constant Landin.Source.Snapshot :=
                 Source (Context, Syn.Source_Of (Of_Tree));
               Text : constant String := Landin.Source.Slice
                 (Snap, Syn.Digit_Span (Of_Tree, Written));
               Value : Ty.Magnitude;
               Overflowed : Boolean;
            begin
               Ty.Evaluate (Text, Syn.Base (Of_Tree, Written), Value,
                            Overflowed);
               if Overflowed then
                  Bad.Report
                    (Item    => Bad.Literal_Out_Of_Range,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Written),
                     Message => "this fixed argument is too large",
                     Note    => "[1350]: a fixed argument is a compile-time"
                                & " integer",
                     Into    => Found);
                  return 0;
               end if;
               Valid := True;
               Known := True;
               return Value;
            end;
         end if;

         if Syn.Kind (Of_Tree, Written)
              in Syn.Name_Reference | Syn.Type_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Written) = Res.Bound
         then
            declare
               Formal : constant Res.Declaration_Id :=
                 Res.Bound_To (Meanings.all, Of_Tree, Written);
            begin
               if Res.Sort_Of (Meanings.all, Formal) = Res.Fixed_Parameter
               then
                  for Each of Actuals loop
                     if Each.Formal = Formal then
                        Valid := True;
                        Known := Each.Fixed_Known;
                        return Each.Fixed;
                     end if;
                  end loop;
               end if;
            end;
         end if;

         Report_Application
           (Of_Tree, Written,
            "this fixed argument is not an integer literal or fixed formal");
         return 0;
      end Fixed_Argument;

      procedure Report_Fixed_Bound_Range
        (Of_Tree    : Syn.Tree;
         At_Node    : Syn.Node_Id;
         Application : Landin.Provenance.Origin;
         Message    : String;
         Note       : String) is
      begin
         if Landin.Provenance.Is_Known (Application) then
            Bad.Report
              (Item    => Bad.Literal_Out_Of_Range,
               Source  => Application.Source,
               Where   => Application.Where,
               Message => Message,
               Note    => Note,
               Related => Syn.Origin (Of_Tree, At_Node),
               Because => "the template expression folded here",
               Into    => Found);
         else
            Bad.Report
              (Item    => Bad.Literal_Out_Of_Range,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Anchor (Of_Tree, At_Node),
               Message => Message,
               Note    => Note,
               Into    => Found);
         end if;
      end Report_Fixed_Bound_Range;

      procedure Report_Fixed_Bound_Operand
        (Of_Tree    : Syn.Tree;
         At_Node    : Syn.Node_Id;
         Application : Landin.Provenance.Origin;
         Message    : String) is
      begin
         if Landin.Provenance.Is_Known (Application) then
            Bad.Report
              (Item    => Bad.Impossible_Operand,
               Source  => Application.Source,
               Where   => Application.Where,
               Message => Message,
               Note    => "[1950]: an operand the operation cannot take is"
                          & " refused where the compiler knows it",
               Related => Syn.Origin (Of_Tree, At_Node),
               Because => "the impossible template operand",
               Into    => Found);
         else
            Bad.Report
              (Item    => Bad.Impossible_Operand,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, At_Node),
               Message => Message,
               Note    => "[1950]: an operand the operation cannot take is"
                          & " refused where the compiler knows it",
               Into    => Found);
         end if;
      end Report_Fixed_Bound_Operand;

      function Fixed_Bound
        (Of_Tree    : Syn.Tree;
         Written    : Syn.Node_Id;
         Actuals    : Formal_Actual_Array;
         Application : Landin.Provenance.Origin;
         Valid      : out Boolean;
         Known      : out Boolean) return Ty.Folded
      is
         procedure Report_Not_Fixed (At_Node : Syn.Node_Id; Message : String);
         procedure Report_Not_Integer
           (At_Node : Syn.Node_Id; Message : String);
         procedure Report_Overflow (At_Node : Syn.Node_Id);

         procedure Report_Not_Fixed
           (At_Node : Syn.Node_Id; Message : String) is
         begin
            Bad.Report
              (Item    => Bad.Not_Known_At_Compile_Time,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, At_Node),
               Message => Message,
               Note    => "D136: an array bound is folded from integer"
                          & " literals, fixed formals and target-independent"
                          & " integer arithmetic; no user routine runs",
               Into    => Found);
         end Report_Not_Fixed;

         procedure Report_Not_Integer
           (At_Node : Syn.Node_Id; Message : String) is
         begin
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, At_Node),
               Message => Message,
               Note    => "D136: a fixed-array bound must produce an"
                          & " integer element count",
               Related => Syn.Origin (Of_Tree, At_Node),
               Because => "the bound requiring an integer count",
               Into    => Found);
         end Report_Not_Integer;

         procedure Report_Overflow (At_Node : Syn.Node_Id) is
         begin
            Report_Fixed_Bound_Range
              (Of_Tree, At_Node, Application,
               "this fixed expression overflows the compiler's widest"
               & " enabled integer magnitude",
               "D136: every intermediate arithmetic answer must remain"
               & " representable");
         end Report_Overflow;

         Of_Kind : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Written);
      begin
         Valid := False;
         Known := False;

         if Of_Kind = Syn.Integer_Literal then
            declare
               Snap : constant Landin.Source.Snapshot :=
                 Source (Context, Syn.Source_Of (Of_Tree));
               Text : constant String := Landin.Source.Slice
                 (Snap, Syn.Digit_Span (Of_Tree, Written));
               Value : Ty.Magnitude;
               Overflowed : Boolean;
            begin
               Ty.Evaluate
                 (Text, Syn.Base (Of_Tree, Written), Value, Overflowed);
               if Overflowed then
                  Report_Overflow (Written);
                  return 0;
               end if;
               Valid := True;
               Known := True;
               return Ty.Folded (Value);
            end;
         end if;

         if Of_Kind = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Written) = Res.Bound
         then
            declare
               Formal : constant Res.Declaration_Id :=
                 Res.Bound_To (Meanings.all, Of_Tree, Written);
            begin
               if Res.Sort_Of (Meanings.all, Formal) = Res.Fixed_Parameter
               then
                  for Each of Actuals loop
                     if Each.Formal = Formal then
                        Valid := True;
                        Known := Each.Fixed_Known;
                        return Ty.Folded (Each.Fixed);
                     end if;
                  end loop;
               end if;
            end;
         end if;

         if Of_Kind = Syn.Negation then
            declare
               Under : Ty.Folded;
               Under_Valid, Under_Known : Boolean;
            begin
               Under := Fixed_Bound
                 (Of_Tree, Syn.Operand_Of (Of_Tree, Written), Actuals,
                  Application, Under_Valid, Under_Known);
               Valid := Under_Valid;
               Known := Under_Known;
               return (if Under_Known then -Under else 0);
            end;
         end if;

         if Of_Kind in Syn.Add | Syn.Subtract | Syn.Multiply
                       | Syn.Divide | Syn.Remainder
         then
            declare
               Left, Right : Ty.Folded;
               Left_Valid, Right_Valid : Boolean;
               Left_Known, Right_Known : Boolean;
               Fits : Boolean := True;
            begin
               Left := Fixed_Bound
                 (Of_Tree, Syn.Left_Of (Of_Tree, Written), Actuals,
                  Application, Left_Valid, Left_Known);
               Right := Fixed_Bound
                 (Of_Tree, Syn.Right_Of (Of_Tree, Written), Actuals,
                  Application, Right_Valid, Right_Known);
               Valid := Left_Valid and then Right_Valid;
               if not Valid then
                  return 0;
               end if;

               if Of_Kind in Syn.Divide | Syn.Remainder
                 and then Right_Known and then Right = 0
               then
                  Report_Fixed_Bound_Operand
                    (Of_Tree, Syn.Right_Of (Of_Tree, Written), Application,
                     "this fixed-expression divisor is zero");
                  Valid := False;
                  return 0;
               end if;

               if not Left_Known or else not Right_Known then
                  Known := False;
                  return 0;
               end if;

               case Of_Kind is
                  when Syn.Add =>
                     Fits := (if Right > 0
                              then Left <= Ty.Folded'Last - Right
                              else Left >= Ty.Folded'First - Right);
                  when Syn.Subtract =>
                     Fits := (if Right > 0
                              then Left >= Ty.Folded'First + Right
                              else Left <= Ty.Folded'Last + Right);
                  when Syn.Multiply =>
                     Fits := Left = 0
                       or else abs Right <= Ty.Folded'Last / abs Left;
                  when Syn.Divide | Syn.Remainder =>
                     null;
                  when others =>
                     raise Landin.Compiler_Defect with
                       "non-arithmetic fixed expression in arithmetic fold";
               end case;

               if not Fits then
                  Report_Overflow (Written);
                  Valid := False;
                  return 0;
               end if;

               Valid := True;
               Known := True;
               case Of_Kind is
                  when Syn.Add       => return Left + Right;
                  when Syn.Subtract  => return Left - Right;
                  when Syn.Multiply  => return Left * Right;
                  when Syn.Divide    => return Left / Right;
                  when Syn.Remainder => return Left rem Right;
                  when others =>
                     raise Landin.Compiler_Defect with
                       "non-arithmetic fixed expression after arithmetic fold";
               end case;
            end;
         end if;

         if Of_Kind in Syn.True_Literal | Syn.False_Literal
                       | Syn.Equal_To | Syn.Not_Equal_To | Syn.Less_Than
                       | Syn.Less_Or_Equal | Syn.Greater_Than
                       | Syn.Greater_Or_Equal | Syn.Logical_And
                       | Syn.Logical_Or | Syn.Logical_Not
         then
            Report_Not_Integer
              (Written, "this fixed-array bound produces a bool, not an"
                        & " integer element count");
            return 0;
         end if;

         if Of_Kind in Syn.Wrapping_Add | Syn.Wrapping_Subtract
                       | Syn.Wrapping_Multiply | Syn.Bitwise_And
                       | Syn.Bitwise_Xor | Syn.Bitwise_Or | Syn.Shift_Left
                       | Syn.Shift_Right | Syn.Complement
         then
            Report_Not_Fixed
              (Written, "this operator needs an operand width and is not"
                        & " available in a target-independent fixed"
                        & " expression");
            return 0;
         end if;

         if Of_Kind = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Written) = Res.Bound
         then
            declare
               Sort : constant Res.Declaration_Sort := Res.Sort_Of
                 (Meanings.all,
                  Res.Bound_To (Meanings.all, Of_Tree, Written));
            begin
               Report_Not_Fixed
                 (Written,
                  (case Sort is
                      when Res.Type_Parameter =>
                         "this name is a type formal, not a fixed value",
                      when Res.Module_Type | Res.Module_Function
                         | Res.Module_Atom | Res.Case_Name =>
                         "this name does not denote a fixed integer value",
                      when Res.Fixed_Parameter =>
                         "this fixed formal has no value in this fold",
                      when others =>
                         "this name is runtime storage, not a fixed formal"));
               return 0;
            end;
         end if;

         Report_Not_Fixed
           (Written,
            (if Of_Kind = Syn.Call
             then "a user call is not a fixed expression and its body is"
                  & " not executed"
             else "this is not one of the closed fixed-expression forms"));
         return 0;
      end Fixed_Bound;

      function Actual_For
        (Descriptor : Type_Descriptor) return Landin.Checking.Actual_Key is
      begin
         case Descriptor.Kind is
            when Ty.Scalar_Name =>
               return Landin.Checking.Scalar_Type_Actual
                 (Ty.Scalar_Name (Descriptor.Kind));
            when Ty.Atom_Value =>
               return Landin.Checking.Atom_Set_Type_Actual
                 (Types.all, Descriptor.Atoms);
            when Ty.Fixed_Array =>
               if Descriptor.Element_Nominal
                 = Landin.Checking.No_Nominal_Type
               then
                  return Landin.Checking.Fixed_Array_Type_Actual
                    (Descriptor.Length, Descriptor.Element);
               else
                  return Landin.Checking.Fixed_Array_Type_Actual
                    (Types.all, Descriptor.Length,
                     Descriptor.Element_Nominal);
               end if;
            when Ty.Aggregate =>
               return Landin.Checking.Nominal_Type_Actual
                 (Types.all, Descriptor.Nominal);
            when Ty.Function_Value =>
               return Landin.Checking.Function_Type_Actual
                 (Types.all, Descriptor.Signature);
            when others =>
               raise Landin.Compiler_Defect with
                 "a non-concrete type became a nominal actual";
         end case;
      end Actual_For;

      function Descriptor_For
        (Actual : Landin.Checking.Actual_Key) return Type_Descriptor is
      begin
         if Landin.Checking.Actual_Kind_Of (Actual)
              = Landin.Checking.Fixed_Actual_Kind
         then
            raise Landin.Compiler_Defect with
              "a fixed actual was requested as a type descriptor";
         end if;

         case Landin.Checking.Type_Form_Of (Actual) is
            when Landin.Checking.Scalar_Actual_Type =>
               return
                 (Kind => Landin.Checking.Scalar_Of (Types.all, Actual),
                  others => <>);
            when Landin.Checking.Atom_Set_Actual_Type =>
               return
                 (Kind  => Ty.Atom_Value,
                  Atoms => Landin.Checking.Atom_Set_Of (Types.all, Actual),
                  others => <>);
            when Landin.Checking.Fixed_Array_Actual_Type =>
               if Landin.Checking.Array_Element_Form_Of
                 (Types.all, Actual) = Landin.Checking.Scalar_Array_Element
               then
                  return
                    (Kind    => Ty.Fixed_Array,
                     Length  => Landin.Checking.Array_Length_Of
                       (Types.all, Actual),
                     Element => Landin.Checking.Array_Scalar_Element_Of
                       (Types.all, Actual),
                     others  => <>);
               end if;
               return
                 (Kind            => Ty.Fixed_Array,
                  Length          => Landin.Checking.Array_Length_Of
                    (Types.all, Actual),
                  Element         => Ty.U8,
                  Element_Nominal =>
                    Landin.Checking.Array_Nominal_Element_Of
                      (Types.all, Actual),
                  others          => <>);
            when Landin.Checking.Nominal_Actual_Type =>
               return
                 (Kind    => Ty.Aggregate,
                  Nominal => Landin.Checking.Nominal_Of (Types.all, Actual),
                  others  => <>);
            when Landin.Checking.Function_Actual_Type =>
               return
                 (Kind      => Ty.Function_Value,
                  Signature => Landin.Checking.Function_Signature_Of
                    (Types.all, Actual),
                  others    => <>);
         end case;
      end Descriptor_For;

      function Remember_Symbolic_Nominal
        (Template : Res.Declaration_Id;
         Actuals  : Formal_Actual_Array) return Symbolic_Layout_Id
      is
         First : constant Natural :=
           Natural (Symbolic_Actuals.Length) + 1;
      begin
         for Actual of Actuals loop
            Symbolic_Actuals.Append (Actual);
         end loop;
         Symbolic_Layouts.Append
           (Symbolic_Layout'(Kind     => Symbolic_Nominal_Layout,
             Template => Template,
             First    => First,
             Count    => Actuals'Length,
             Element  => (others => <>)));
         return Symbolic_Layout_Id (Symbolic_Layouts.Last_Index);
      end Remember_Symbolic_Nominal;

      function Remember_Symbolic_Array
        (Element : Type_Descriptor) return Symbolic_Layout_Id is
      begin
         Symbolic_Layouts.Append
           (Symbolic_Layout'(Kind     => Symbolic_Array_Layout,
             Template => Res.No_Declaration,
             First    => 0,
             Count    => 0,
             Element  => Element));
         return Symbolic_Layout_Id (Symbolic_Layouts.Last_Index);
      end Remember_Symbolic_Array;

      function Require_Value_Layout
        (Descriptor  : Type_Descriptor;
         Of_Tree     : Syn.Tree;
         At_Node     : Syn.Node_Id;
         Application : Landin.Provenance.Origin) return Type_Descriptor
      is
         function Invalid return Type_Descriptor
           is ((Kind => Ty.Ill_Typed, others => <>));

         procedure Ensure_Nominal
           (Instance : Landin.Checking.Nominal_Type_Id;
            Valid    : out Boolean);

         procedure Ensure_Symbolic
           (Id    : Symbolic_Layout_Id;
            Valid : out Boolean);

         procedure Report_Recursion
           (Template_Tree : Syn.Tree; Struct_Node : Syn.Node_Id);

         procedure Report_Recursion
           (Template_Tree : Syn.Tree; Struct_Node : Syn.Node_Id) is
         begin
            if Landin.Provenance.Is_Known (Application) then
               Bad.Report
                 (Item    => Bad.Recursive_Nominal_Value,
                  Source  => Application.Source,
                  Where   => Application.Where,
                  Message => "this nominal instance would contain itself"
                             & " by value",
                  Note    => "D137: identity-only mentions do not request"
                             & " layout, but this substituted value site does",
                  Related => Syn.Origin (Of_Tree, At_Node),
                  Because => "the substituted by-value use",
                  Into    => Found);
            else
               Bad.Report
                 (Item    => Bad.Recursive_Nominal_Value,
                  Source  => Syn.Source_Of (Template_Tree),
                  Where   => Syn.Where (Template_Tree, Struct_Node),
                  Message => "this nominal instance would contain itself"
                             & " by value",
                  Note    => "D137: a finite nominal value layout cannot"
                             & " include itself by value",
                  Into    => Found);
            end if;
         end Report_Recursion;

         procedure Ensure_Nominal
           (Instance : Landin.Checking.Nominal_Type_Id;
            Valid    : out Boolean)
         is
            Template_Id : constant Res.Declaration_Id :=
              Landin.Checking.Template_Of (Types.all, Instance);
            Template_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Template_Id));
            Declaration : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Template_Id);
            Struct_Node : constant Syn.Node_Id :=
              Syn.Declared_Type (Template_Tree.all, Declaration);
            Count : constant Natural :=
              Landin.Checking.Instance_Actual_Count (Types.all, Instance);
            Bound : Formal_Actual_Array (1 .. Count) :=
              [others => (others => <>)];
            Was_Expanding : constant Boolean :=
              Generic_Expansion (Positive (Template_Id));
         begin
            pragma Assert
              (Syn.Kind (Template_Tree.all, Struct_Node) = Syn.Struct_Body
               and then Syn.Type_Formal_Count
                 (Template_Tree.all, Declaration) = Count);

            if Landin.Checking.Instance_State_Of (Types.all, Instance)
                 = Landin.Checking.Instance_Ready
            then
               Valid := True;
               return;
            elsif Landin.Checking.Instance_State_Of (Types.all, Instance)
                 = Landin.Checking.Instance_Building
              or else Was_Expanding
            then
               Report_Recursion (Template_Tree.all, Struct_Node);
               Valid := False;
               return;
            end if;

            for Index in Bound'Range loop
               declare
                  Formal_Node : constant Syn.Node_Id :=
                    Syn.Nth_Type_Formal
                      (Template_Tree.all, Declaration, Index);
                  Actual : constant Landin.Checking.Actual_Key :=
                    Landin.Checking.Nth_Instance_Actual
                      (Types.all, Instance, Index);
               begin
                  Bound (Index).Formal := Declaration_At
                    (Syn.Source_Of (Template_Tree.all), Formal_Node);
                  if Landin.Checking.Actual_Kind_Of (Actual)
                       = Landin.Checking.Type_Actual_Kind
                  then
                     Bound (Index).Value := Descriptor_For (Actual);
                  else
                     Bound (Index).Fixed :=
                       Landin.Checking.Fixed_Magnitude_Of (Actual);
                     Bound (Index).Fixed_Known := True;
                  end if;
               end;
            end loop;

            if Landin.Checking.Instance_State_Of (Types.all, Instance)
                 = Landin.Checking.Instance_Unseen
            then
               Landin.Checking.Begin_Instance (Types.all, Instance);
            else
               Landin.Checking.Retry_Instance (Types.all, Instance);
            end if;

            Generic_Expansion (Positive (Template_Id)) := True;
            Build_Struct_Instance
              (Template_Tree.all, Struct_Node, Instance, Bound,
               Application, Valid);
            Generic_Expansion (Positive (Template_Id)) := Was_Expanding;

            if not Valid
              and then Landin.Checking.Instance_State_Of
                (Types.all, Instance) = Landin.Checking.Instance_Building
            then
               Landin.Checking.Invalidate_Instance (Types.all, Instance);
            end if;
         end Ensure_Nominal;

         procedure Ensure_Symbolic
           (Id    : Symbolic_Layout_Id;
            Valid : out Boolean)
         is
            Layout : constant Symbolic_Layout :=
              Symbolic_Layouts (Positive (Id));
         begin
            if Layout.Kind = Symbolic_Array_Layout then
               if Layout.Element.Symbolic /= No_Symbolic_Layout then
                  Ensure_Symbolic (Layout.Element.Symbolic, Valid);
               elsif Layout.Element.Kind = Ty.Aggregate then
                  Ensure_Nominal (Layout.Element.Nominal, Valid);
               else
                  Valid := True;
               end if;
               return;
            end if;

            declare
               Template_Tree : constant not null access constant Syn.Tree :=
                 Tree_For (Res.Source_Of (Meanings.all, Layout.Template));
               Declaration : constant Syn.Node_Id :=
                 Res.Node_Of (Meanings.all, Layout.Template);
               Struct_Node : constant Syn.Node_Id :=
                 Syn.Declared_Type (Template_Tree.all, Declaration);
               Bound : Formal_Actual_Array (1 .. Layout.Count) :=
                 [others => (others => <>)];
               Was_Expanding : constant Boolean :=
                 Generic_Expansion (Positive (Layout.Template));
            begin
               pragma Assert
                 (Syn.Kind (Template_Tree.all, Struct_Node) = Syn.Struct_Body);

               if Was_Expanding then
                  Report_Recursion (Template_Tree.all, Struct_Node);
                  Valid := False;
                  return;
               end if;

               for Index in Bound'Range loop
                  Bound (Index) := Symbolic_Actuals
                    (Positive (Layout.First + Index - 1));
               end loop;

               Generic_Expansion (Positive (Layout.Template)) := True;
               Build_Struct_Instance
                 (Template_Tree.all, Struct_Node,
                  Landin.Checking.No_Nominal_Type, Bound,
                  Landin.Provenance.No_Origin, Valid);
               Generic_Expansion (Positive (Layout.Template)) :=
                 Was_Expanding;
            end;
         end Ensure_Symbolic;

         Result : Type_Descriptor := Descriptor;
         Valid  : Boolean := True;
      begin
         if Descriptor.Symbolic /= No_Symbolic_Layout then
            Ensure_Symbolic (Descriptor.Symbolic, Valid);
         elsif Descriptor.Kind = Ty.Aggregate then
            Ensure_Nominal (Descriptor.Nominal, Valid);
         elsif Descriptor.Kind = Ty.Fixed_Array then
            if Descriptor.Element_Nominal
              /= Landin.Checking.No_Nominal_Type
            then
               Ensure_Nominal (Descriptor.Element_Nominal, Valid);
            end if;

            if Valid then
               declare
                  Element_Bytes : constant Ty.Magnitude :=
                    (if Descriptor.Element_Nominal
                           /= Landin.Checking.No_Nominal_Type
                     then Ty.Magnitude
                       (Landin.Checking.Layout_Size
                          (Types.all, Descriptor.Element_Nominal))
                     else Ty.Magnitude
                       (Landin.Targets.Bytes
                          (Ty.Storage_Size (Descriptor.Element, Facts))));
                  Maximum_Bytes : constant Ty.Magnitude := Ty.Magnitude
                    (Landin.Targets.Maximum_Object_Size (Facts));
                  Length : constant Ty.Magnitude :=
                    Ty.Magnitude (Descriptor.Length);
               begin
                  if Element_Bytes /= 0
                    and then Length > Maximum_Bytes / Element_Bytes
                  then
                     if Landin.Provenance.Is_Known (Application) then
                        Bad.Report
                          (Item    => Bad.Literal_Out_Of_Range,
                           Source  => Application.Source,
                           Where   => Application.Where,
                           Message => "this substituted array is larger than"
                                      & " the target can address",
                           Note    => "D18: an array's byte extent must fit"
                                      & " the target's usize",
                           Related => Syn.Origin (Of_Tree, At_Node),
                           Because => "the substituted by-value use",
                           Into    => Found);
                     else
                        Bad.Report
                          (Item    => Bad.Literal_Out_Of_Range,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, At_Node),
                           Message => "this array is larger than the target"
                                      & " can address",
                           Note    => "D18: an array's byte extent must fit"
                                      & " the target's usize",
                           Into    => Found);
                     end if;
                     Valid := False;
                  end if;
               end;
            end if;
         end if;

         if not Valid then
            Result := Invalid;
         end if;
         return Result;
      end Require_Value_Layout;

      function Normalized_Type
        (Of_Tree    : Syn.Tree;
         Written    : Syn.Node_Id;
         Actuals    : Formal_Actual_Array;
         Application : Landin.Provenance.Origin :=
           Landin.Provenance.No_Origin;
         Requirement : Type_Requirement := Value_Layout)
         return Type_Descriptor
      is
         function Invalid return Type_Descriptor
           is ((Kind => Ty.Ill_Typed, others => <>));

         procedure Require_Type_Actual
           (At_Node : Syn.Node_Id; Got : Type_Descriptor;
            Into : out Type_Descriptor);

         procedure Require_Type_Actual
           (At_Node : Syn.Node_Id; Got : Type_Descriptor;
            Into : out Type_Descriptor) is
         begin
            if Got.Kind = Ty.Ill_Typed then
               --  The nested normalization already diagnosed its reason.
               Into := Invalid;
            elsif Got.Kind
              in Ty.Undecided | Ty.Scalar_Name | Ty.Atom_Value
                 | Ty.Fixed_Array | Ty.Aggregate | Ty.Function_Value
            then
               --  Undecided is one symbolic type formal during declaration
               --  validation.  A concrete application never leaves it so.
               --  Every enabled concrete identity is a legal unconstrained
               --  type actual; the substituted field or payload position,
               --  not the binder, decides whether that identity is usable.
               Into := Got;
            else
               Report_Application
                 (Of_Tree, At_Node,
                  "this positional argument is not an enabled concrete"
                  & " type");
               Into := Invalid;
            end if;
         end Require_Type_Actual;
      begin
         if Syn.Kind (Of_Tree, Written) = Syn.Type_Name then
            return (Kind    => Landin.Checking.Named
                      (Types.all, Syn.Name (Of_Tree, Written)),
                    others => <>);
         end if;

         if Syn.Kind (Of_Tree, Written) = Syn.Array_Type then
            declare
               Element : constant Type_Descriptor := Normalized_Type
                 (Of_Tree, Syn.Element_Of (Of_Tree, Written), Actuals,
                  Application, Requirement);
               Folded_Value : Ty.Folded;
               Value : Ty.Magnitude := 0;
               Is_Fixed : Boolean;
               Is_Known : Boolean;
            begin
               Folded_Value := Fixed_Bound
                 (Of_Tree, Syn.Bound_Of (Of_Tree, Written), Actuals,
                  Application, Is_Fixed, Is_Known);
               if Element.Kind = Ty.Ill_Typed or else not Is_Fixed then
                  return Invalid;
               elsif Is_Known and then Folded_Value < 0 then
                  Report_Fixed_Bound_Range
                    (Of_Tree, Syn.Bound_Of (Of_Tree, Written), Application,
                     "this fixed-array bound is negative",
                     "D136 accepts zero as a fixed-array bound but refuses"
                     & " a negative answer");
                  return Invalid;
               elsif Element.Kind /= Ty.Undecided
                 and then Element.Kind not in Ty.Scalar_Name | Ty.Aggregate
               then
                  if Landin.Provenance.Is_Known (Application) then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Application.Source,
                        Where   => Application.Where,
                        Message => "this substituted array element is not"
                                   & " enabled",
                        Note    => "[0520]: an enabled fixed-array element"
                                   & " is scalar or nominal aggregate",
                        Related => Syn.Origin
                          (Of_Tree, Syn.Element_Of (Of_Tree, Written)),
                        Because => "the template element type",
                        Refused => Bad.Array_Element,
                        Into    => Found);
                  else
                     Report_Application
                       (Of_Tree, Syn.Element_Of (Of_Tree, Written),
                        "an array element must be a scalar or nominal"
                        & " aggregate type");
                  end if;
                  return Invalid;
               elsif Element.Kind = Ty.Undecided or else not Is_Known then
                  --  Retain a nominal element obligation across an
                  --  identity-only array actual.  A plain type formal still
                  --  remains wholly unknown and carries no guessed shape.
                  return
                    (Kind     => Ty.Undecided,
                     Symbolic =>
                       (if Element.Symbolic = No_Symbolic_Layout
                        then No_Symbolic_Layout
                        else Remember_Symbolic_Array (Element)),
                     others   => <>);
               end if;

               Value := Ty.Magnitude (Folded_Value);
               if Requirement = Value_Layout then
                  declare
                     Element_Bytes : constant Ty.Magnitude :=
                       (if Element.Kind = Ty.Aggregate
                        then Ty.Magnitude
                          (Landin.Checking.Layout_Size
                             (Types.all, Element.Nominal))
                        else Ty.Magnitude
                          (Landin.Targets.Bytes
                             (Ty.Storage_Size
                                (Ty.Scalar_Name (Element.Kind), Facts))));
                     Maximum_Bytes : constant Ty.Magnitude := Ty.Magnitude
                       (Landin.Targets.Maximum_Object_Size (Facts));
                  begin
                     if Element_Bytes /= 0
                       and then Value > Maximum_Bytes / Element_Bytes
                     then
                        Report_Fixed_Bound_Range
                          (Of_Tree, Syn.Bound_Of (Of_Tree, Written),
                           Application,
                           "this array is larger than the target can address",
                           "D18: an array's byte extent must fit the target's"
                           & " usize");
                        return Invalid;
                     end if;
                  end;
               end if;

               return (Kind    => Ty.Fixed_Array,
                       Length  => Landin.Checking.Element_Count (Value),
                       Element => (if Element.Kind = Ty.Aggregate
                                   then Ty.U8
                                   else Ty.Scalar_Name (Element.Kind)),
                       Element_Nominal =>
                         (if Element.Kind = Ty.Aggregate
                          then Element.Nominal
                          else Landin.Checking.No_Nominal_Type),
                       others => <>);
            end;
         end if;

         if Syn.Kind (Of_Tree, Written) = Syn.Atom_Union_Type then
            if Type_At (Of_Tree, Written) = Ty.Atom_Value then
               return
                 (Kind   => Ty.Atom_Value,
                  Atoms  => Landin.Checking.Atom_Set_Of
                    (Types.all, Of_Tree, Written),
                  others => <>);
            end if;
            return Invalid;
         end if;

         if Syn.Kind (Of_Tree, Written) = Syn.Function_Type then
            declare
               Parameters : Landin.Checking.Signature_Part_Array
                 (1 .. Syn.Parameter_Count (Of_Tree, Written)) :=
                   [others => (others => <>)];
               Results : Landin.Checking.Signature_Part_Array
                 (1 .. Syn.Return_Count (Of_Tree, Written)) :=
                   [others => (others => <>)];
               Errors : Landin.Checking.Atom_Set_Id :=
                 Landin.Checking.No_Atom_Set;
               Valid : Boolean := True;
               Concrete : Boolean := True;

               function Part_At
                 (Node : Syn.Node_Id) return Landin.Checking.Signature_Part;

               function Part_At
                 (Node : Syn.Node_Id) return Landin.Checking.Signature_Part
               is
                  Descriptor : constant Type_Descriptor := Normalized_Type
                    (Of_Tree, Syn.Declared_Type (Of_Tree, Node), Actuals,
                     Application, Identity_Only);
               begin
                  if Descriptor.Kind = Ty.Undecided then
                     Concrete := False;
                  elsif Descriptor.Kind
                    not in Ty.Scalar_Name | Ty.Atom_Value | Ty.Fixed_Array
                       | Ty.Aggregate | Ty.Function_Value
                  then
                     Valid := False;
                  end if;
                  return
                    (Kind      => Descriptor.Kind,
                     Nominal   =>
                       (if Descriptor.Kind = Ty.Fixed_Array
                        then Descriptor.Element_Nominal
                        else Descriptor.Nominal),
                     Length    => Descriptor.Length,
                     Element   => Descriptor.Element,
                     Signature => Descriptor.Signature,
                     Name      => Syn.Name (Of_Tree, Node),
                     Atoms     => Descriptor.Atoms,
                     Site      => Syn.Origin (Of_Tree, Node));
               end Part_At;
            begin
               for Index in Parameters'Range loop
                  Parameters (Index) := Part_At
                    (Syn.Nth_Parameter (Of_Tree, Written, Index));
               end loop;
               for Index in Results'Range loop
                  Results (Index) := Part_At
                    (Syn.Nth_Return (Of_Tree, Written, Index));
               end loop;

               if Syn.Error_Set_Of (Of_Tree, Written) /= Syn.No_Node then
                  declare
                     Error_Type : constant Type_Descriptor := Normalized_Type
                       (Of_Tree, Syn.Error_Set_Of (Of_Tree, Written), Actuals,
                        Application, Identity_Only);
                  begin
                     if Error_Type.Kind = Ty.Atom_Value then
                        Errors := Error_Type.Atoms;
                     else
                        Valid := False;
                     end if;
                  end;
               end if;

               if not Valid then
                  return Invalid;
               elsif not Concrete then
                  return (Kind => Ty.Undecided, others => <>);
               end if;

               return
                 (Kind      => Ty.Function_Value,
                  Signature => Landin.Checking.Add_Signature
                    (Types.all, Parameters, Results,
                     Syn.Origin (Of_Tree, Written), Errors,
                     (if Errors = Landin.Checking.No_Atom_Set
                      then Landin.Checking.Infallible
                      else Landin.Checking.Concrete)),
                  others    => <>);
            end;
         end if;

         if Syn.Kind (Of_Tree, Written) = Syn.Type_Reference then
            if Res.Verdict_Of (Meanings.all, Of_Tree, Written) /= Res.Bound
            then
               Report_Application
                 (Of_Tree, Written, "this type argument names no type");
               return Invalid;
            end if;

            declare
               Means : constant Res.Declaration_Id :=
                 Res.Bound_To (Meanings.all, Of_Tree, Written);
            begin
               if Res.Sort_Of (Meanings.all, Means)
                    = Res.Type_Parameter
               then
                  for Each of Actuals loop
                     if Each.Formal = Means then
                        if Requirement = Value_Layout then
                           return Require_Value_Layout
                             (Each.Value, Of_Tree, Written, Application);
                        end if;
                        return Each.Value;
                     end if;
                  end loop;
                  Report_Application
                    (Of_Tree, Written,
                     "this type formal has no argument in this application");
                  return Invalid;
               end if;

               if Res.Sort_Of (Meanings.all, Means) /= Res.Module_Type then
                  Report_Application
                    (Of_Tree, Written,
                     "this positional argument is not a type");
                  return Invalid;
               end if;

               declare
                  Template : constant not null access constant Syn.Tree :=
                    Tree_For (Res.Source_Of (Meanings.all, Means));
                  Declaration : constant Syn.Node_Id :=
                    Res.Node_Of (Meanings.all, Means);
               begin
                  if Syn.Type_Formal_Count
                       (Template.all, Declaration) /= 0
                  then
                     Report_Application
                       (Of_Tree, Written,
                        "this parameterized type alias requires arguments");
                     return Invalid;
                  end if;
               end;

               declare
                  Held : constant Ty.Type_Kind := Settled_Type (Means);
               begin
                  case Held is
                     when Ty.Fixed_Array =>
                        return
                          (Kind    => Held,
                           Length  => Landin.Checking.Array_Length
                             (Types.all, Means),
                           Element => Landin.Checking.Array_Element
                             (Types.all, Means),
                           Element_Nominal =>
                             Landin.Checking.Array_Element_Nominal
                               (Types.all, Means),
                           others => <>);
                     when Ty.Aggregate =>
                        return
                          (Kind    => Held,
                           Nominal => Landin.Checking.Nominal_Of
                             (Types.all, Means),
                           others  => <>);
                     when Ty.Atom_Value =>
                        return
                          (Kind   => Held,
                           Atoms  => Landin.Checking.Atom_Set_Of
                             (Types.all, Means),
                           others => <>);
                     when Ty.Function_Value =>
                        return
                          (Kind      => Held,
                           Signature => Landin.Checking.Signature_Of
                             (Types.all, Means),
                           others    => <>);
                     when others =>
                        return (Kind => Held, others => <>);
                  end case;
               end;
            end;
         end if;

         if Syn.Kind (Of_Tree, Written) /= Syn.Type_Application then
            Report_Application
              (Of_Tree, Written, "this positional argument must be a type");
            return Invalid;
         end if;

         declare
            Target : constant Syn.Node_Id :=
              Syn.Applied_Type (Of_Tree, Written);
            This_Application : constant Landin.Provenance.Origin :=
              (if Landin.Provenance.Is_Known (Application)
               then Application else Syn.Origin (Of_Tree, Written));
         begin
            if Syn.Kind (Of_Tree, Target) /= Syn.Type_Reference
              or else Res.Verdict_Of
                (Meanings.all, Of_Tree, Target) /= Res.Bound
            then
               Report_Application
                 (Of_Tree, Target,
                  "a parameterized type application targets a declared alias");
               return Invalid;
            end if;

            declare
               Means : constant Res.Declaration_Id :=
                 Res.Bound_To (Meanings.all, Of_Tree, Target);
            begin
               if Res.Sort_Of (Meanings.all, Means) /= Res.Module_Type then
                  Report_Application
                    (Of_Tree, Target,
                     "a parameterized type application targets a type alias");
                  return Invalid;
               end if;

               declare
                  Template : constant not null access constant Syn.Tree :=
                    Tree_For (Res.Source_Of (Meanings.all, Means));
                  Declaration : constant Syn.Node_Id :=
                    Res.Node_Of (Meanings.all, Means);
                  Formal_Count : constant Natural := Syn.Type_Formal_Count
                    (Template.all, Declaration);
               begin
                  if Formal_Count = 0 then
                     Report_Application
                       (Of_Tree, Target, "this type alias takes no arguments");
                     return Invalid;
                  end if;

                  --  Validate a nested declaration before this application
                  --  can inherit an origin. Unconditional defects belong to
                  --  that declaration regardless of declaration order;
                  --  symbolic failures remain open for substitution below.
                  Validate_Template (Means);
                  if Template_Invalid (Positive (Means)) then
                     --  Declaration validation already diagnosed the
                     --  template itself; a use is not a second source error.
                     return Invalid;
                  end if;

                  if Syn.Type_Argument_Count (Of_Tree, Written)
                       /= Formal_Count
                  then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Written),
                        Message => "this alias application has "
                                   & Counted
                                     (Syn.Type_Argument_Count
                                        (Of_Tree, Written),
                                      "argument") & ", but `"
                                   & Spelled
                                     (Syn.Name (Template.all, Declaration))
                                   & "` needs "
                                   & Counted (Formal_Count, "argument"),
                        Note    => "[1350]: type alias arguments are"
                                   & " positional",
                        Related => Syn.Origin (Template.all, Declaration),
                        Because => "the alias declares this positional run",
                        Into    => Found);
                     return Invalid;
                  end if;

                  if Generic_Expansion (Positive (Means))
                    and then
                      (Syn.Kind
                         (Template.all,
                          Syn.Declared_Type (Template.all, Declaration))
                           /= Syn.Struct_Body
                       or else Requirement = Value_Layout)
                  then
                     if Syn.Kind
                       (Template.all,
                        Syn.Declared_Type (Template.all, Declaration))
                          = Syn.Struct_Body
                     then
                        Bad.Report
                          (Item    => Bad.Recursive_Nominal_Value,
                           Source  => This_Application.Source,
                           Where   => This_Application.Where,
                           Message => "this nominal instance would contain"
                                      & " itself by value",
                           Note    => "D137: a finite nominal value layout"
                                      & " cannot include itself by value",
                           Related =>
                             (if Landin.Provenance.Is_Known (Application)
                              then Syn.Origin (Of_Tree, Written)
                              else Syn.Origin
                                (Template.all,
                                 Syn.Declared_Type
                                   (Template.all, Declaration))),
                           Because => "the recursive template field type",
                           Into    => Found);
                     else
                        --  Being reached while a struct layout is active does
                        --  not turn an alias expansion that reaches no type
                        --  into a nominal by-value edge.
                        Bad.Report
                          (Item    => Bad.Cyclic_Type_Alias,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Written),
                           Message => "this parameterized type alias"
                                      & " eventually applies itself",
                           Note    => "[1350]: a type alias expansion must"
                                      & " reach a concrete type",
                           Into    => Found);
                     end if;
                     for Id in Generic_Expansion'Range loop
                        if Generic_Expansion (Id) then
                           Template_Invalid (Id) := True;
                        end if;
                     end loop;
                     return Invalid;
                  end if;

                  declare
                     Bound : Formal_Actual_Array (1 .. Formal_Count) :=
                       [others => (others => <>)];
                     Good : Boolean := True;
                  begin
                     --  Give every binder its declaration identity first.
                     --  Type actuals are then substituted before fixed
                     --  actuals are checked, so `fixed n: t, t: type` has
                     --  the order-independent meaning D135 requires.
                     for Index in 1 .. Formal_Count loop
                        declare
                           Formal_Node : constant Syn.Node_Id :=
                             Syn.Nth_Type_Formal
                               (Template.all, Declaration, Index);
                        begin
                           Bound (Index).Formal := Declaration_At
                             (Syn.Source_Of (Template.all), Formal_Node);
                        end;
                     end loop;

                     for Index in 1 .. Formal_Count loop
                        declare
                           Formal_Node : constant Syn.Node_Id :=
                             Syn.Nth_Type_Formal
                               (Template.all, Declaration, Index);
                           Argument : constant Syn.Node_Id :=
                             Syn.Nth_Type_Argument (Of_Tree, Written, Index);
                        begin
                           if Syn.Kind (Template.all, Formal_Node)
                                = Syn.Type_Formal
                           then
                              Require_Type_Actual
                                (Argument,
                                 Normalized_Type
                                   (Of_Tree, Argument, Actuals,
                                    This_Application, Identity_Only),
                                 Bound (Index).Value);
                              Good := Good and then Bound (Index).Value.Kind
                                /= Ty.Ill_Typed;
                           end if;
                        end;
                     end loop;

                     if not Good then
                        return Invalid;
                     end if;

                     for Index in 1 .. Formal_Count loop
                        declare
                           Formal_Node : constant Syn.Node_Id :=
                             Syn.Nth_Type_Formal
                               (Template.all, Declaration, Index);
                           Argument : constant Syn.Node_Id :=
                             Syn.Nth_Type_Argument (Of_Tree, Written, Index);
                        begin
                           if Syn.Kind (Template.all, Formal_Node)
                                = Syn.Fixed_Formal
                           then
                              declare
                                 Is_Fixed : Boolean;
                                 Is_Known : Boolean;
                                 Value : constant Ty.Magnitude :=
                                   Fixed_Argument
                                     (Of_Tree, Argument, Actuals,
                                      Is_Fixed, Is_Known);
                                 Expected : constant Type_Descriptor :=
                                   Normalized_Type
                                     (Template.all,
                                      Syn.Declared_Type
                                        (Template.all, Formal_Node),
                                      Bound, This_Application,
                                      Identity_Only);
                              begin
                                 if not Is_Fixed
                                   or else Expected.Kind = Ty.Ill_Typed
                                 then
                                    Good := False;
                                 elsif Expected.Kind = Ty.Undecided then
                                    Bound (Index).Fixed := Value;
                                    Bound (Index).Fixed_Known := Is_Known;
                                 elsif Expected.Kind not in Ty.Integer_Name
                                 then
                                    Bad.Report
                                      (Item    => Bad.Unsupported_Use,
                                       Source  => This_Application.Source,
                                       Where   => This_Application.Where,
                                       Message => "this fixed formal does not"
                                          & " have an integer type",
                                       Related => Syn.Origin
                                         (Template.all,
                                          Syn.Declared_Type
                                            (Template.all, Formal_Node)),
                                       Because => "the fixed formal type",
                                       Refused =>
                                         Bad.Parameterized_Type_Alias,
                                       Into    => Found);
                                    Good := False;
                                 elsif Is_Known
                                   and then not Ty.Fits
                                     (Value, Ty.Scalar_Name (Expected.Kind),
                                      Facts, Negated => False)
                                 then
                                    Bad.Report
                                      (Item    => Bad.Unsupported_Use,
                                       Source  => This_Application.Source,
                                       Where   => This_Application.Where,
                                       Message => "this fixed argument does"
                                          & " not fit its declared integer"
                                          & " type",
                                       Related => Syn.Origin
                                         (Template.all,
                                          Syn.Declared_Type
                                            (Template.all, Formal_Node)),
                                       Because => "the fixed formal type",
                                       Refused =>
                                         Bad.Parameterized_Type_Alias,
                                       Into    => Found);
                                    Good := False;
                                 else
                                    Bound (Index).Fixed := Value;
                                    Bound (Index).Fixed_Known := Is_Known;
                                 end if;
                              end;
                           end if;
                        end;
                     end loop;

                     if not Good then
                        return Invalid;
                     end if;

                     declare
                        Struct_Node : constant Syn.Node_Id :=
                          Syn.Declared_Type (Template.all, Declaration);
                     begin
                        if Syn.Kind (Template.all, Struct_Node)
                          = Syn.Struct_Body
                        then
                           declare
                              Concrete : Boolean := True;
                              Valid : Boolean;
                              Was_Expanding : constant Boolean :=
                                Generic_Expansion (Positive (Means));
                           begin
                              for Each of Bound loop
                                 if Res.Sort_Of (Meanings.all, Each.Formal)
                                      = Res.Type_Parameter
                                 then
                                    Concrete := Concrete
                                      and then Each.Value.Kind /= Ty.Undecided;
                                 else
                                    Concrete := Concrete
                                      and then Each.Fixed_Known;
                                 end if;
                              end loop;

                              Generic_Expansion (Positive (Means)) := True;

                              if not Concrete then
                                 if Requirement = Identity_Only then
                                    Generic_Expansion (Positive (Means)) :=
                                      Was_Expanding;
                                    return
                                      (Kind     => Ty.Undecided,
                                       Symbolic => Remember_Symbolic_Nominal
                                         (Means, Bound),
                                       others   => <>);
                                 end if;

                                 Build_Struct_Instance
                                   (Template.all, Struct_Node,
                                    Landin.Checking.No_Nominal_Type, Bound,
                                    This_Application, Valid);
                                 Generic_Expansion (Positive (Means)) :=
                                   Was_Expanding;
                                 return
                                   (if Valid
                                    then (Kind => Ty.Undecided, others => <>)
                                    else Invalid);
                              end if;

                              declare
                                 Key : Landin.Checking.Actual_Tuple :=
                                   Landin.Checking.Empty_Actuals;
                              begin
                                 for Each of Bound loop
                                    if Res.Sort_Of
                                      (Meanings.all, Each.Formal)
                                        = Res.Type_Parameter
                                    then
                                       Landin.Checking.Append_Actual
                                         (Key, Actual_For (Each.Value));
                                    else
                                       Landin.Checking.Append_Actual
                                         (Key, Landin.Checking.Fixed_Actual
                                            (Each.Fixed));
                                    end if;
                                 end loop;

                                 declare
                                    Instance : constant
                                      Landin.Checking.Nominal_Type_Id :=
                                        Landin.Checking
                                          .Intern_Nominal_Instance
                                            (Types.all, Means, Key);
                                 begin
                                    if Requirement = Identity_Only then
                                       Valid := True;
                                    else
                                       case Landin.Checking.Instance_State_Of
                                         (Types.all, Instance)
                                       is
                                          when Landin.Checking.Instance_Unseen
                                          =>
                                             Landin.Checking.Begin_Instance
                                               (Types.all, Instance);
                                             Build_Struct_Instance
                                               (Template.all, Struct_Node,
                                                Instance, Bound,
                                                This_Application, Valid);
                                          when
                                            Landin.Checking.Instance_Building
                                          =>
                                             Bad.Report
                                               (Item    =>
                                                  Bad.Recursive_Nominal_Value,
                                                Source  =>
                                                  This_Application.Source,
                                                Where   =>
                                                  This_Application.Where,
                                                Message => "this nominal"
                                                   & " instance would contain"
                                                   & " itself by value",
                                                Note    => "D137: a finite"
                                                   & " nominal value layout"
                                                   & " cannot include itself"
                                                   & " by value",
                                                Related => Syn.Origin
                                                  (Template.all, Struct_Node),
                                                Because => "the recursive"
                                                   & " template body",
                                                Into    => Found);
                                             Valid := False;
                                          when Landin.Checking.Instance_Ready
                                          =>
                                             Valid := True;
                                          when
                                            Landin.Checking.Instance_Invalid
                                          =>
                                             Landin.Checking.Retry_Instance
                                               (Types.all, Instance);
                                             Build_Struct_Instance
                                               (Template.all, Struct_Node,
                                                Instance, Bound,
                                                This_Application, Valid);
                                       end case;
                                    end if;

                                    Generic_Expansion
                                      (Positive (Means)) := Was_Expanding;
                                    if not Valid then
                                       if Landin.Checking.Instance_State_Of
                                         (Types.all, Instance)
                                           = Landin.Checking.Instance_Building
                                       then
                                          Landin.Checking
                                            .Invalidate_Instance
                                              (Types.all, Instance);
                                       end if;
                                       return Invalid;
                                    end if;
                                    return
                                      (Kind    => Ty.Aggregate,
                                       Nominal => Instance,
                                       others  => <>);
                                 end;
                              end;
                           end;
                        else
                           Generic_Expansion (Positive (Means)) := True;
                           declare
                              Result : constant Type_Descriptor :=
                                Normalized_Type
                                  (Template.all, Struct_Node, Bound,
                                   This_Application, Requirement);
                           begin
                              Generic_Expansion (Positive (Means)) := False;
                              if Result.Kind = Ty.Ill_Typed then
                                 --  The nested expansion already diagnosed
                                 --  its failure; each application reports
                                 --  once.
                                 return Invalid;
                              elsif Result.Kind not in
                                Ty.Undecided | Ty.Scalar_Name | Ty.Fixed_Array
                              then
                                 Report_Application
                                   (Of_Tree, Written,
                                    "this parameterized alias does not"
                                    & " normalize to a scalar or fixed-array"
                                    & " type");
                                 return Invalid;
                              end if;
                              return Result;
                           end;
                        end if;
                     end;
                  end;
               end;
            end;
         end;
      end Normalized_Type;

      procedure Build_Struct_Instance
        (Of_Tree     : Syn.Tree;
         Struct_Node        : Syn.Node_Id;
         Instance    : Landin.Checking.Nominal_Type_Id;
         Actuals     : Formal_Actual_Array;
         Application : Landin.Provenance.Origin;
         Valid       : out Boolean)
      is
         function Total_Cases return Natural;
         function Total_Payload_Fields return Natural;

         function Total_Cases return Natural is
            Total : Natural := 0;
         begin
            for Index in 1 .. Syn.Field_Count (Of_Tree, Struct_Node) loop
               declare
                  Member : constant Syn.Node_Id :=
                    Syn.Nth_Field (Of_Tree, Struct_Node, Index);
               begin
                  if Syn.Kind (Of_Tree, Member) = Syn.Variant_Part then
                     Total := Total + Syn.Case_Count (Of_Tree, Member);
                  end if;
               end;
            end loop;
            return Total;
         end Total_Cases;

         function Total_Payload_Fields return Natural is
            Total : Natural := 0;
         begin
            for Index in 1 .. Syn.Field_Count (Of_Tree, Struct_Node) loop
               declare
                  Member : constant Syn.Node_Id :=
                    Syn.Nth_Field (Of_Tree, Struct_Node, Index);
               begin
                  if Syn.Kind (Of_Tree, Member) = Syn.Variant_Part then
                     for Which in 1 .. Syn.Case_Count
                       (Of_Tree, Member)
                     loop
                        Total := Total + Syn.Payload_Field_Count
                          (Of_Tree, Syn.Nth_Case
                             (Of_Tree, Member, Which));
                     end loop;
                  end if;
               end;
            end loop;
            return Total;
         end Total_Payload_Fields;

         Fields : Landin.Checking.Field_Shape_Array
           (1 .. Syn.Field_Count (Of_Tree, Struct_Node)) :=
             [others => (Kind    => Landin.Checking.Scalar_Field,
                         Element => Ty.U8,
                         Length  => 1,
                         others  => <>)];
         Cases : Landin.Checking.Case_Run_Array
           (1 .. Total_Cases) := [others => (others => 0)];
         Payloads : Landin.Checking.Field_Shape_Array
           (1 .. Total_Payload_Fields) :=
             [others => (Kind    => Landin.Checking.Scalar_Field,
                         Element => Ty.U8,
                         Length  => 1,
                         others  => <>)];
         Concrete : Boolean := True;
         Next_Case : Natural := 1;
         Next_Payload : Natural := 1;

         procedure Report_Field
           (Field : Syn.Node_Id; Message : String);

         procedure Report_Field
           (Field : Syn.Node_Id; Message : String) is
            Declared : constant Syn.Node_Id :=
              Syn.Declared_Type (Of_Tree, Field);
         begin
            if Landin.Provenance.Is_Known (Application) then
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Application.Source,
                  Where   => Application.Where,
                  Message => Message,
                  Related => Syn.Origin (Of_Tree, Declared),
                  Because => "the substituted template field type",
                  Refused => Bad.Struct_Value,
                  Into    => Found);
            else
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Declared),
                  Message => Message,
                  Refused => Bad.Struct_Value,
                  Into    => Found);
            end if;
         end Report_Field;

         procedure Check_Leaf
           (Field : Syn.Node_Id;
            Into  : out Landin.Checking.Field_Shape);

         procedure Check_Leaf
           (Field : Syn.Node_Id;
            Into  : out Landin.Checking.Field_Shape)
         is
            Descriptor : constant Type_Descriptor := Normalized_Type
              (Of_Tree, Syn.Declared_Type (Of_Tree, Field), Actuals,
               Application);
         begin
            Into := (Kind    => Landin.Checking.Scalar_Field,
                     Element => Ty.U8,
                     Length  => 1,
                     others  => <>);
            case Descriptor.Kind is
               when Ty.Scalar_Name =>
                  Into := (Kind    => Landin.Checking.Scalar_Field,
                           Element => Ty.Scalar_Name (Descriptor.Kind),
                           Length  => 1,
                           others  => <>);
               when Ty.Function_Value =>
                  if Descriptor.Signature = Landin.Checking.No_Signature then
                     Valid := False;
                  else
                     Into :=
                       (Kind      => Landin.Checking.Scalar_Field,
                        Element   => Ty.Usize,
                        Length    => 1,
                        Signature => Descriptor.Signature,
                        others    => <>);
                  end if;
               when Ty.Fixed_Array =>
                  Into :=
                    (Kind    => Landin.Checking.Fixed_Array_Field,
                     Element => Descriptor.Element,
                     Length  => Descriptor.Length,
                     Nominal => Descriptor.Element_Nominal,
                     others  => <>);
               when Ty.Aggregate =>
                  if Descriptor.Nominal
                       = Landin.Checking.No_Nominal_Type
                    or else not Landin.Checking.Has_Layout
                      (Types.all, Descriptor.Nominal)
                  then
                     Valid := False;
                  else
                     Into :=
                       (Kind    => Landin.Checking.Aggregate_Field,
                        Element => Ty.Bool,
                        Length  => 1,
                        Nominal => Descriptor.Nominal,
                        others  => <>);
                  end if;
               when Ty.Undecided =>
                  --  Symbolic validation cannot lay out a type formal, but
                  --  it can prove the rest of this body without guessing an
                  --  actual.  Concrete application revisits this field.
                  Concrete := False;
               when Ty.Ill_Typed =>
                  Valid := False;
               when others =>
                  Report_Field
                    (Field, "this substituted struct field shape is not"
                            & " enabled");
                  Valid := False;
            end case;
         end Check_Leaf;
      begin
         Valid := True;

         --  Field and variant-part labels are one structural namespace.
         --  They are not resolver declarations, so validate the template's
         --  own run even when no application reaches it.
         for Right in 2 .. Syn.Field_Count (Of_Tree, Struct_Node) loop
            for Left in 1 .. Right - 1 loop
               declare
                  Earlier : constant Syn.Node_Id :=
                    Syn.Nth_Field (Of_Tree, Struct_Node, Left);
                  Later : constant Syn.Node_Id :=
                    Syn.Nth_Field (Of_Tree, Struct_Node, Right);
               begin
                  if Syn.Name (Of_Tree, Earlier) = Syn.Name (Of_Tree, Later)
                  then
                     Bad.Report
                       (Item    => Bad.Field_Named_Twice,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Anchor (Of_Tree, Later),
                        Message => "this template declares the same struct"
                                   & " field twice",
                        Note    => "[0750]: one struct field name selects one"
                                   & " declared position",
                        Related => Syn.Origin (Of_Tree, Earlier),
                        Because => "the first field with that name",
                        Into    => Found);
                     Valid := False;
                  end if;
               end;
            end loop;
         end loop;

         for Index in 1 .. Syn.Field_Count (Of_Tree, Struct_Node) loop
            declare
               Member : constant Syn.Node_Id :=
                 Syn.Nth_Field (Of_Tree, Struct_Node, Index);
            begin
               if Syn.Kind (Of_Tree, Member) = Syn.Field then
                  Check_Leaf (Member, Fields (Index));
               else
                  declare
                     Count : constant Natural :=
                       Syn.Case_Count (Of_Tree, Member);
                     Tag : constant Ty.Scalar_Name :=
                       (if Count <= 2 ** 8 then Ty.U8
                        elsif Count <= 2 ** 16 then Ty.U16 else Ty.U32);
                  begin
                     Fields (Index) :=
                       (Kind           => Landin.Checking.Variant_Field,
                        Element        => Tag,
                        Length         => 1,
                        Cases          => Count,
                        Payloads_First => Next_Case,
                        others         => <>);

                     for Which in 1 .. Count loop
                        declare
                           Variant : constant Syn.Node_Id :=
                             Syn.Nth_Case (Of_Tree, Member, Which);
                           Payload_Count : constant Natural :=
                             Syn.Payload_Field_Count (Of_Tree, Variant);
                        begin
                           Cases (Next_Case) :=
                             (First => (if Payload_Count = 0
                                       then 0 else Next_Payload),
                              Count => Payload_Count);
                           Next_Case := Next_Case + 1;

                           for Right in 2 .. Payload_Count loop
                              for Left in 1 .. Right - 1 loop
                                 declare
                                    Earlier : constant Syn.Node_Id :=
                                      Syn.Nth_Payload_Field
                                        (Of_Tree, Variant, Left);
                                    Later : constant Syn.Node_Id :=
                                      Syn.Nth_Payload_Field
                                        (Of_Tree, Variant, Right);
                                 begin
                                    if Syn.Name (Of_Tree, Earlier)
                                      = Syn.Name (Of_Tree, Later)
                                    then
                                       Bad.Report
                                         (Item    => Bad.Field_Named_Twice,
                                          Source  =>
                                            Syn.Source_Of (Of_Tree),
                                          Where   =>
                                            Syn.Anchor (Of_Tree, Later),
                                          Message => "this template declares"
                                             & " the same payload field"
                                             & " twice",
                                          Note    => "[0750]: one payload"
                                             & " field name selects one"
                                             & " declared position",
                                          Related => Syn.Origin
                                            (Of_Tree, Earlier),
                                          Because => "the first payload"
                                             & " field with that name",
                                          Into    => Found);
                                       Valid := False;
                                    end if;
                                 end;
                              end loop;
                           end loop;

                           for Position in 1 .. Payload_Count loop
                              Check_Leaf
                                (Syn.Nth_Payload_Field
                                   (Of_Tree, Variant, Position),
                                 Payloads (Next_Payload));
                              Next_Payload := Next_Payload + 1;
                           end loop;
                        end;
                     end loop;
                  end;
               end if;
            end;
         end loop;

         if not Valid or else not Concrete
           or else Instance = Landin.Checking.No_Nominal_Type
         then
            return;
         end if;

         declare
            Fits : Boolean;
         begin
            Landin.Checking.Lay_Out
              (Types.all, Instance, Fields, Facts, Fits,
               Cases => Cases, Payloads => Payloads);
            Valid := Fits;
            if not Fits then
               if Landin.Provenance.Is_Known (Application) then
                  Bad.Report
                    (Item    => Bad.Literal_Out_Of_Range,
                     Source  => Application.Source,
                     Where   => Application.Where,
                     Message => "this nominal instance is too large for the"
                                & " target's usize",
                     Note    => "D137: each canonical instance has one"
                                & " target-specific padded layout",
                     Related => Syn.Origin (Of_Tree, Struct_Node),
                     Because => "the instantiated template body",
                     Into    => Found);
               else
                  Bad.Report
                    (Item    => Bad.Literal_Out_Of_Range,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Struct_Node),
                     Message => "this struct is too large for the target's"
                                & " usize",
                     Note    => "D45: every padded aggregate extent must fit"
                                & " the selected target",
                     Into    => Found);
               end if;
            end if;
         end;
      end Build_Struct_Instance;

      procedure Validate_Template (Id : Res.Declaration_Id) is
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Id));
         Declaration : constant Syn.Node_Id :=
           Res.Node_Of (Meanings.all, Id);
         Formal_Count : constant Natural :=
           Syn.Type_Formal_Count (Of_Tree.all, Declaration);
         Bound : Formal_Actual_Array (1 .. Formal_Count) :=
           [others => (others => <>)];
         Reports_Before : constant Natural :=
           Landin.Diagnostics.Count (Found);
      begin
         pragma Assert (Formal_Count > 0);
         if Template_Checked (Positive (Id)) then
            return;
         end if;
         Template_Checked (Positive (Id)) := True;

         for Index in Bound'Range loop
            declare
               Formal_Node : constant Syn.Node_Id :=
                 Syn.Nth_Type_Formal
                   (Of_Tree.all, Declaration, Index);
            begin
               Bound (Index).Formal := Declaration_At
                 (Syn.Source_Of (Of_Tree.all), Formal_Node);
               if Syn.Kind (Of_Tree.all, Formal_Node) = Syn.Type_Formal
               then
                  --  One symbolic type proves everything independent of its
                  --  eventual argument and deliberately records nothing in
                  --  Landin.Checking's node table.
                  Bound (Index).Value :=
                    (Kind => Ty.Undecided, others => <>);
               end if;
            end;
         end loop;

         --  A fixed formal's type is part of the declaration, not a fact
         --  supplied by an application.  Reject a decidable non-integer now;
         --  a type-formal-dependent answer remains symbolic until use.
         for Index in Bound'Range loop
            declare
               Formal_Node : constant Syn.Node_Id :=
                 Syn.Nth_Type_Formal
                   (Of_Tree.all, Declaration, Index);
            begin
               if Syn.Kind (Of_Tree.all, Formal_Node) = Syn.Fixed_Formal
               then
                  declare
                     Declared : constant Syn.Node_Id :=
                       Syn.Declared_Type (Of_Tree.all, Formal_Node);
                     Expected : constant Type_Descriptor := Normalized_Type
                       (Of_Tree.all, Declared, Bound);
                  begin
                     if Expected.Kind = Ty.Ill_Typed then
                        Template_Invalid (Positive (Id)) := True;
                     elsif Expected.Kind /= Ty.Undecided
                       and then Expected.Kind not in Ty.Integer_Name
                     then
                        Report_Application
                          (Of_Tree.all, Declared,
                           "this fixed formal's declared type is not an"
                           & " integer type");
                        Template_Invalid (Positive (Id)) := True;
                     end if;
                  end;
               end if;
            end;
         end loop;

         if not Template_Invalid (Positive (Id)) then
            declare
               Struct_Node : constant Syn.Node_Id :=
                 Syn.Declared_Type (Of_Tree.all, Declaration);
            begin
               Generic_Expansion (Positive (Id)) := True;
               if Syn.Kind (Of_Tree.all, Struct_Node) = Syn.Struct_Body then
                  declare
                     Valid : Boolean;
                  begin
                     Build_Struct_Instance
                       (Of_Tree.all, Struct_Node,
                        Landin.Checking.No_Nominal_Type, Bound,
                        Landin.Provenance.No_Origin, Valid);
                     Generic_Expansion (Positive (Id)) := False;
                     if not Valid then
                        Template_Invalid (Positive (Id)) := True;
                     end if;
                  end;
               else
                  declare
                     Result : constant Type_Descriptor := Normalized_Type
                       (Of_Tree.all, Struct_Node, Bound);
                  begin
                     Generic_Expansion (Positive (Id)) := False;
                     if Result.Kind = Ty.Ill_Typed then
                        Template_Invalid (Positive (Id)) := True;
                     elsif Result.Kind not in
                       Ty.Undecided | Ty.Scalar_Name | Ty.Fixed_Array
                     then
                        Report_Application
                          (Of_Tree.all, Struct_Node,
                           "this parameterized alias cannot produce a scalar"
                           & " or fixed-array type");
                        Template_Invalid (Positive (Id)) := True;
                     end if;
                  end;
               end if;
            end;
         end if;

         if Landin.Diagnostics.Count (Found) > Reports_Before then
            Template_Invalid (Positive (Id)) := True;
         end if;
      end Validate_Template;

      function Type_At
        (Of_Tree         : Syn.Tree;
         Written         : Syn.Node_Id;
         For_Declaration : Res.Declaration_Id := Res.No_Declaration;
         Requirement     : Type_Requirement := Value_Layout)
         return Ty.Type_Kind
      is
         Identity_Seen : array
           (Positive range 1 .. Positive'Max
              (1, Res.Declaration_Count (Meanings.all))) of Boolean :=
                [others => False];

         --  An ordinary struct's empty-actual identity is allocated before
         --  settlement.  Signature parts may follow only ordinary aliases to
         --  that identity without asking Settled_Type for a by-value layout.
         function Identity_Nominal
           (Id : Res.Declaration_Id)
            return Landin.Checking.Nominal_Type_Id;

         function Identity_Nominal
           (Id : Res.Declaration_Id)
            return Landin.Checking.Nominal_Type_Id
         is
            Target_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Id));
            Declaration : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Id);
            Declared : constant Syn.Node_Id :=
              Syn.Declared_Type (Target_Tree.all, Declaration);
         begin
            if Res.Sort_Of (Meanings.all, Id) /= Res.Module_Type
              or else Identity_Seen (Positive (Id))
              or else Syn.Type_Formal_Count
                (Target_Tree.all, Declaration) /= 0
            then
               return Landin.Checking.No_Nominal_Type;
            end if;
            Identity_Seen (Positive (Id)) := True;

            if Syn.Kind (Target_Tree.all, Declared) = Syn.Struct_Body then
               return Landin.Checking.Empty_Nominal_Instance (Types.all, Id);
            elsif Syn.Kind (Target_Tree.all, Declared) = Syn.Type_Reference
              and then Res.Verdict_Of
                (Meanings.all, Target_Tree.all, Declared) = Res.Bound
            then
               return Identity_Nominal
                 (Res.Bound_To (Meanings.all, Target_Tree.all, Declared));
            end if;
            return Landin.Checking.No_Nominal_Type;
         end Identity_Nominal;
      begin
         --  A routine instance publishes substituted type-position facts in
         --  its active overlay before checking the shared source body.  Read
         --  that concrete answer instead of following the template formal's
         --  global Not_Typed declaration.
         if Landin.Checking.Current_Routine_View (Types.all)
              /= Landin.Checking.No_Routine_Instance
           and then Syn.Kind (Of_Tree, Written) /= Syn.Type_Application
           and then Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
             /= Ty.Undecided
         then
            return Landin.Checking.Type_Of (Types.all, Of_Tree, Written);
         end if;

         if Syn.Kind (Of_Tree, Written) = Syn.Type_Application then
            if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                 /= Ty.Undecided
              and then
                (Requirement = Identity_Only
                 or else Landin.Checking.Type_Of
                   (Types.all, Of_Tree, Written) = Ty.Ill_Typed)
            then
               return Landin.Checking.Type_Of (Types.all, Of_Tree, Written);
            end if;

            --  An identity-only application may have already recorded its
            --  canonical nominal descriptor for a signature part.  A later
            --  ABI or other by-value use must replay normalization so it
            --  materializes that instance's layout; the node's cached kind
            --  alone cannot say that this requirement was met.

            declare
               Result : constant Type_Descriptor := Normalized_Type
                 (Of_Tree, Written,
                  Formal_Actual_Array'(1 .. 0 => (others => <>)),
                  Requirement => Requirement);
            begin
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                    /= Ty.Undecided
               then
                  --  Identity-only normalization already recorded this
                  --  source type.  The replay above exists solely to fulfill
                  --  the later layout requirement, so it must not overwrite
                  --  that immutable node answer or its descriptor.  A failed
                  --  replay belongs to this application node: retain that
                  --  outcome so a later ABI walk does not report it again.
                  if Result.Kind = Ty.Ill_Typed then
                     Landin.Checking.Refuse (Types.all, Of_Tree, Written);
                  end if;
                  return Result.Kind;
               end if;

               Landin.Checking.Note (Types.all, Of_Tree, Written, Result.Kind);
               case Result.Kind is
                  when Ty.Fixed_Array =>
                     Landin.Checking.Note_Array
                       (Types.all, Of_Tree, Written,
                        Result.Length, Result.Element);
                     if Result.Element_Nominal
                       /= Landin.Checking.No_Nominal_Type
                     then
                        Landin.Checking.Note_Array_Element_Nominal
                          (Types.all, Of_Tree, Written,
                           Result.Element_Nominal);
                     end if;
                  when Ty.Aggregate =>
                     Landin.Checking.Note_Nominal
                       (Types.all, Of_Tree, Written, Result.Nominal);
                  when Ty.Atom_Value =>
                     Landin.Checking.Note_Atom_Set
                       (Types.all, Of_Tree, Written, Result.Atoms);
                  when Ty.Function_Value =>
                     Landin.Checking.Note_Signature
                       (Types.all, Of_Tree, Written, Result.Signature);
                  when others =>
                     null;
               end case;
               return Result.Kind;
            end;
         end if;

         --  [0640]: source order describes a set, not an encoding.  Flatten
         --  aliases and repeated members into one structural identity while
         --  retaining declaration identities rather than inventing ordinals.
         if Syn.Kind (Of_Tree, Written) = Syn.Atom_Union_Type then
            declare
               Limit : constant Natural :=
                 Res.Declaration_Count (Meanings.all);
               Members : Landin.Checking.Atom_Array
                 (1 .. Positive'Max (1, Limit)) :=
                   [others => Res.No_Declaration];
               Count : Natural := 0;
               Valid : Boolean := True;
            begin
               for Index in 1 .. Syn.Atom_Member_Count
                 (Of_Tree, Written)
               loop
                  declare
                     Member : constant Syn.Node_Id :=
                       Syn.Nth_Atom_Member (Of_Tree, Written, Index);
                     Held : constant Ty.Type_Kind :=
                       Type_At (Of_Tree, Member);
                  begin
                     if Held = Ty.Atom_Value then
                        declare
                           Set_Id : constant Landin.Checking.Atom_Set_Id :=
                             Landin.Checking.Atom_Set_Of
                               (Types.all, Of_Tree, Member);
                        begin
                           for Position in 1 .. Landin.Checking.Atom_Count
                             (Types.all, Set_Id)
                           loop
                              declare
                                 Atom : constant Res.Declaration_Id :=
                                   Landin.Checking.Nth_Atom
                                     (Types.all, Set_Id, Position);
                                 Seen : Boolean := False;
                              begin
                                 for Prior in 1 .. Count loop
                                    Seen := Seen
                                      or else Members (Prior) = Atom;
                                 end loop;
                                 if not Seen then
                                    Count := Count + 1;
                                    Members (Count) := Atom;
                                 end if;
                              end;
                           end loop;
                        end;
                     elsif Held /= Ty.Ill_Typed then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Member),
                           Message => "this union member is not an atom"
                                      & " type",
                           Note    => "[0640]: an atom union contains only"
                                      & " atom identities",
                           Related => Syn.Origin (Of_Tree, Written),
                           Because => "the union declared here",
                           Into    => Found);
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Member);
                        Valid := False;
                     else
                        Valid := False;
                     end if;
                  end;
               end loop;

               if not Valid or else Count = 0 then
                  return Ty.Ill_Typed;
               end if;

               declare
                  Set_Id : constant Landin.Checking.Atom_Set_Id :=
                    Landin.Checking.Add_Atom_Set
                      (Types.all, Members (1 .. Count));
               begin
                  Landin.Checking.Note_Atom_Set
                    (Types.all, Of_Tree, Written, Set_Id);
                  return Ty.Atom_Value;
               end;
            end;
         end if;

         --  D117's written function type is the same target-neutral
         --  descriptor a declared function receives.  Build it once per
         --  syntax occurrence; aliases and values copy its identity below.
         if Syn.Kind (Of_Tree, Written) = Syn.Function_Type then
            if Landin.Checking.Signature_Of
                 (Types.all, Of_Tree, Written)
                 /= Landin.Checking.No_Signature
            then
               return Ty.Function_Value;
            end if;

            return
              (if Signature_At (Of_Tree, Written)
                    = Landin.Checking.No_Signature
               then Ty.Ill_Typed else Ty.Function_Value);
         end if;

         --  [0670]'s block form.  Every field's type is checked here,
         --  because this is the walk that reaches them: a field is a
         --  binding without a value and nothing else visits one.
         if Syn.Kind (Of_Tree, Written) = Syn.Struct_Body then
            declare
               function Total_Cases return Natural;
               function Total_Payload_Fields return Natural;

               function Total_Cases return Natural is
                  Total : Natural := 0;
               begin
                  for Index in 1 .. Syn.Field_Count (Of_Tree, Written) loop
                     declare
                        Member : constant Syn.Node_Id :=
                          Syn.Nth_Field (Of_Tree, Written, Index);
                     begin
                        if Syn.Kind (Of_Tree, Member) = Syn.Variant_Part then
                           Total := Total + Syn.Case_Count
                             (Of_Tree, Member);
                        end if;
                     end;
                  end loop;
                  return Total;
               end Total_Cases;

               function Total_Payload_Fields return Natural is
                  Total : Natural := 0;
               begin
                  for Index in 1 .. Syn.Field_Count (Of_Tree, Written) loop
                     declare
                        Member : constant Syn.Node_Id :=
                          Syn.Nth_Field (Of_Tree, Written, Index);
                     begin
                        if Syn.Kind (Of_Tree, Member) = Syn.Variant_Part then
                           for Which in 1 .. Syn.Case_Count
                             (Of_Tree, Member)
                           loop
                              Total := Total + Syn.Payload_Field_Count
                                (Of_Tree,
                                 Syn.Nth_Case (Of_Tree, Member, Which));
                           end loop;
                        end if;
                     end;
                  end loop;
                  return Total;
               end Total_Payload_Fields;

               Fields : Landin.Checking.Field_Shape_Array
                 (1 .. Syn.Field_Count (Of_Tree, Written)) :=
                   [others => (Kind    => Landin.Checking.Scalar_Field,
                               Element => Ty.U8,
                               Length  => 1,
                               others  => <>)];
               Cases : Landin.Checking.Case_Run_Array
                 (1 .. Total_Cases) := [others => (others => 0)];
               Payloads : Landin.Checking.Field_Shape_Array
                 (1 .. Total_Payload_Fields) :=
                   [others => (Kind    => Landin.Checking.Scalar_Field,
                               Element => Ty.U8,
                               Length  => 1,
                               others  => <>)];
               Can_Lay_Out : Boolean := True;
               Next_Case : Natural := 1;
               Next_Payload : Natural := 1;
               Prior_Body : constant Landin.Provenance.Origin :=
                 Active_Struct_Body;
               Prior_Field : constant Landin.Provenance.Origin :=
                 Active_Struct_Field;

               procedure Check_Leaf
                 (Each : Syn.Node_Id;
                  Into : out Landin.Checking.Field_Shape;
                  Aggregate_Allowed : Boolean);

               procedure Check_Leaf
                 (Each : Syn.Node_Id;
                  Into : out Landin.Checking.Field_Shape;
                  Aggregate_Allowed : Boolean)
               is
                  Held : Ty.Type_Kind;
                  Prior : constant Landin.Provenance.Origin :=
                    Active_Struct_Field;
                  Reports_Before : constant Natural :=
                    Landin.Diagnostics.Count (Found);
               begin
                  Active_Struct_Field := Syn.Origin
                    (Of_Tree, Syn.Declared_Type (Of_Tree, Each));
                  Held := Type_At
                    (Of_Tree, Syn.Declared_Type (Of_Tree, Each),
                     For_Declaration);
                  Active_Struct_Field := Prior;
                  Into := (Kind    => Landin.Checking.Scalar_Field,
                           Element => Ty.U8,
                           Length  => 1,
                           others  => <>);
                  if Held in Ty.Scalar_Name then
                     Into :=
                       (Kind    => Landin.Checking.Scalar_Field,
                        Element => Ty.Scalar_Name (Held),
                        Length  => 1,
                        others  => <>);
                  elsif Held = Ty.Function_Value then
                     declare
                        Signature : constant Landin.Checking.Signature_Id :=
                          Landin.Checking.Signature_Of
                            (Types.all, Of_Tree,
                             Syn.Declared_Type (Of_Tree, Each));
                     begin
                        if Signature = Landin.Checking.No_Signature then
                           Can_Lay_Out := False;
                        else
                           --  D131: a function field occupies the same one
                           --  `usize` carrier as every other function value;
                           --  the descriptor remains type evidence beside it.
                           Into :=
                             (Kind      => Landin.Checking.Scalar_Field,
                              Element   => Ty.Usize,
                              Length    => 1,
                              Signature => Signature,
                              others    => <>);
                        end if;
                     end;
                  elsif Held = Ty.Fixed_Array then
                     Into :=
                       (Kind    => Landin.Checking.Fixed_Array_Field,
                        Element => Landin.Checking.Array_Element
                                     (Types.all, Of_Tree,
                                      Syn.Declared_Type (Of_Tree, Each)),
                        Length  => Landin.Checking.Array_Length
                                     (Types.all, Of_Tree,
                                      Syn.Declared_Type (Of_Tree, Each)),
                        --  D121: an ordinary-struct element carries the
                        --  declaration that wrote it, as a child does.
                        Nominal =>
                          Landin.Checking.Array_Element_Nominal
                            (Types.all, Of_Tree,
                             Syn.Declared_Type (Of_Tree, Each)),
                        others  => <>);
                  elsif Held = Ty.Aggregate
                    and then Aggregate_Allowed
                  then
                     declare
                        Child_Body : constant
                          Landin.Checking.Nominal_Type_Id :=
                          Landin.Checking.Nominal_Of
                            (Types.all, Of_Tree,
                             Syn.Declared_Type (Of_Tree, Each));
                     begin
                        --  D119 drops D86's depth limit: a child holding
                        --  a child is laid out the same way, because the
                        --  extent of a field is the child's own layout and
                        --  the path that reaches through it is a run.
                        --  D126 drops the last one: a child holding a
                        --  variant part is reached by the same run, which
                        --  every variant operation now carries.
                        if Child_Body /= Landin.Checking.No_Nominal_Type
                          and then Landin.Checking.Has_Layout
                            (Types.all, Child_Body)
                        then
                           Into :=
                             (Kind    => Landin.Checking.Aggregate_Field,
                              Element => Ty.Bool,
                              Length  => 1,
                              Nominal => Child_Body,
                              others  => <>);
                        else
                           Can_Lay_Out := False;
                        end if;
                     end;
                  else
                     Can_Lay_Out := False;
                  end if;

                  if Held = Ty.Aggregate
                    and then Into.Kind /= Landin.Checking.Aggregate_Field
                    and then Landin.Diagnostics.Count (Found)
                               = Reports_Before
                  then
                     --  D119/D121/D126 admit an ordinary child and an
                     --  ordinary payload, variant part and all.  What is
                     --  left is a body the checker could not lay out,
                     --  which has already reported why.
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Each),
                        Message => "a field of a struct type is not"
                                   & " enabled yet",
                        Refused => Bad.Struct_Value,
                        Into    => Found);
                  end if;
               end Check_Leaf;
            begin
               Struct_Layout_Depth := Struct_Layout_Depth + 1;
               Active_Struct_Body := Syn.Origin (Of_Tree, Written);
               for Index in 1 .. Syn.Field_Count (Of_Tree, Written) loop
                  declare
                     Each : constant Syn.Node_Id :=
                       Syn.Nth_Field (Of_Tree, Written, Index);
                  begin
                     if Syn.Kind (Of_Tree, Each) = Syn.Field then
                        Check_Leaf (Each, Fields (Index), True);
                     else
                        declare
                           Count : constant Natural :=
                             Syn.Case_Count (Of_Tree, Each);
                           Tag : constant Ty.Scalar_Name :=
                             (if Count <= 2 ** 8 then Ty.U8
                              elsif Count <= 2 ** 16 then Ty.U16
                              else Ty.U32);
                        begin
                           Fields (Index) :=
                             (Kind           => Landin.Checking.Variant_Field,
                              Element        => Tag,
                              Length         => 1,
                              Cases          => Count,
                              Payloads_First => Next_Case,
                              others         => <>);

                           for Which in 1 .. Count loop
                              declare
                                 Variant : constant Syn.Node_Id :=
                                   Syn.Nth_Case
                                     (Of_Tree, Each, Which);
                                 Payload_Count : constant Natural :=
                                   Syn.Payload_Field_Count
                                     (Of_Tree, Variant);
                              begin
                                 Cases (Next_Case) :=
                                   (First =>
                                      (if Payload_Count = 0
                                       then 0 else Next_Payload),
                                    Count => Payload_Count);
                                 Next_Case := Next_Case + 1;

                                 for Position in 1 .. Payload_Count loop
                                    --  D120: a payload field may be an
                                    --  ordinary struct, for the reason an
                                    --  ordinary field may -- its extent is
                                    --  the child's own layout.  A variant
                                    --  part inside one is still refused,
                                    --  because Check_Leaf will not take a
                                    --  child that has one.
                                    Check_Leaf
                                      (Syn.Nth_Payload_Field
                                         (Of_Tree, Variant, Position),
                                       Payloads (Next_Payload), True);
                                    Next_Payload := Next_Payload + 1;
                                 end loop;
                              end;
                           end loop;
                        end;
                     end if;
                  end;
               end loop;

               if Can_Lay_Out then
                  if For_Declaration = Res.No_Declaration then
                     raise Landin.Compiler_Defect with
                       "a struct body has no declaration identity";
                  end if;

                  declare
                     Fits : Boolean;
                  begin
                     Landin.Checking.Lay_Out
                       (Types.all,
                        Landin.Checking.Empty_Nominal_Instance
                          (Types.all, For_Declaration),
                        Fields, Facts, Fits,
                        Cases => Cases, Payloads => Payloads);

                     if not Fits then
                        Bad.Report
                          (Item    => Bad.Literal_Out_Of_Range,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Written),
                           Message => "this struct is too large for the"
                                      & " target's usize",
                           Note    => "D45: every padded aggregate extent"
                                      & " must fit the selected target",
                           Into    => Found);
                     end if;
                  end;
               end if;
               Struct_Layout_Depth := Struct_Layout_Depth - 1;
               Active_Struct_Body := Prior_Body;
               Active_Struct_Field := Prior_Field;
            end;

            return Ty.Aggregate;
         end if;

         --  array_type ::= "[" expression "]" type           [1790]
         --
         --  D17 makes it structural, so what is recorded is the length and
         --  the element and never where it was written.  An element the
         --  kernel cannot lay out end to end is refused here rather than
         --  in the grammar, which derives `[2][3]u8` on purpose.
         if Syn.Kind (Of_Tree, Written) = Syn.Array_Type then
            declare
               Bound   : constant Syn.Node_Id :=
                 Syn.Bound_Of (Of_Tree, Written);
               Element : constant Syn.Node_Id :=
                 Syn.Element_Of (Of_Tree, Written);
               Held : constant Ty.Type_Kind := Type_At
                 (Of_Tree, Element, Requirement => Requirement);
               --  D121: [0520]'s element may be an ordinary struct.  Its
               --  extent is that struct's own already-computed layout, so
               --  the only thing an array adds is the repetition.  D127
               --  makes a known index one step of D118's run, which is
               --  how a variant part inside an element is reached.
               Element_Nominal : constant Landin.Checking.Nominal_Type_Id :=
                 (if Held = Ty.Aggregate
                  then Landin.Checking.Nominal_Of (Types.all, Of_Tree, Element)
                  else Landin.Checking.No_Nominal_Type);
               Aggregate_Element : constant Boolean :=
                 Element_Nominal /= Landin.Checking.No_Nominal_Type
                 and then
                   (Requirement = Identity_Only
                    or else Landin.Checking.Has_Layout
                      (Types.all, Element_Nominal));
               Length : Landin.Checking.Element_Count := 0;
            begin
               if Held not in Ty.Scalar_Name
                 and then not Aggregate_Element
               then
                  --  Three passes reach a written type; the first to
                  --  refuse it records that, so a reader sees one report.
                  if Held /= Ty.Ill_Typed
                    and then Landin.Checking.Type_Of
                      (Types.all, Of_Tree, Written) = Ty.Undecided
                  then
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Written, Ty.Ill_Typed);
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Element),
                        Message => "an array of this is not enabled yet",
                        Refused => Bad.Array_Element,
                        Into    => Found);
                  end if;

                  return Ty.Ill_Typed;
               end if;

               declare
                  Valid, Known : Boolean;
                  Folded_Value : constant Ty.Folded := Fixed_Bound
                    (Of_Tree, Bound,
                     Formal_Actual_Array'(1 .. 0 => (others => <>)),
                     Landin.Provenance.No_Origin, Valid, Known);
               begin
                  if not Valid or else not Known then
                     return Ty.Ill_Typed;
                  elsif Folded_Value < 0 then
                     Report_Fixed_Bound_Range
                       (Of_Tree, Bound, Landin.Provenance.No_Origin,
                        "this fixed-array bound is negative",
                        "D136 accepts zero as a fixed-array bound but refuses"
                        & " a negative answer");
                     return Ty.Ill_Typed;
                  end if;

                  declare
                     Value : constant Ty.Magnitude :=
                       Ty.Magnitude (Folded_Value);
                  begin
                     if Requirement = Value_Layout then
                        declare
                           Element_Bytes : constant Ty.Magnitude :=
                             (if Aggregate_Element
                              then Ty.Magnitude
                                (Landin.Checking.Layout_Size
                                   (Types.all, Element_Nominal))
                              else Ty.Magnitude
                                (Landin.Targets.Bytes
                                   (Ty.Storage_Size
                                      (Ty.Scalar_Name (Held), Facts))));
                           Maximum_Bytes : constant Ty.Magnitude :=
                             Ty.Magnitude
                               (Landin.Targets.Maximum_Object_Size (Facts));
                        begin
                           if Element_Bytes /= 0
                             and then Value > Maximum_Bytes / Element_Bytes
                           then
                              Bad.Report
                                (Item    => Bad.Literal_Out_Of_Range,
                                 Source  => Syn.Source_Of (Of_Tree),
                                 Where   => Syn.Where (Of_Tree, Bound),
                                 Message => "this array is larger than the"
                                            & " target can address",
                                 Note    => "D18: an array's byte extent must"
                                            & " fit the target's usize",
                                 Into    => Found);
                              return Ty.Ill_Typed;
                           end if;
                        end;
                     end if;

                     Length := Landin.Checking.Element_Count (Value);
                  end;
               end;

               Landin.Checking.Note_Array
                 (Types.all, Of_Tree, Written, Length,
                  (if Aggregate_Element then Ty.U8 else Ty.Scalar_Name
                     (Held)));
               if Aggregate_Element then
                  Landin.Checking.Note_Array_Element_Nominal
                    (Types.all, Of_Tree, Written, Element_Nominal);
               end if;
               return Ty.Fixed_Array;
            end;
         end if;

         if Syn.Kind (Of_Tree, Written) = Syn.Type_Name then
            return Landin.Checking.Named
              (Types.all, Syn.Name (Of_Tree, Written));
         end if;

         if Syn.Kind (Of_Tree, Written) /= Syn.Type_Reference then
            --  An Error_Type: the parser refused what stood there and said
            --  so, so this declines to answer.
            return Ty.Ill_Typed;
         end if;

         if Res.Verdict_Of (Meanings.all, Of_Tree, Written) /= Res.Bound
         then
            --  [1830]'s refusal from the checker's side.  A name that
            --  resolved to nothing may still be a type the tour writes
            --  and [1790] omits, and saying which it is costs one table:
            --  the difference between "not enabled yet" and "declared
            --  nowhere" is the whole of what a reader needs here.
            declare
               Spelled_Here : constant String :=
                 Spelled (Syn.Name (Of_Tree, Written));
            begin
               for Named in Bad.Refused_Type_Name loop
                  if Bad.Spelling (Named) = Spelled_Here then
                     if Landin.Checking.Type_Of
                          (Types.all, Of_Tree, Written) = Ty.Undecided
                     then
                        Landin.Checking.Note
                          (Types.all, Of_Tree, Written, Ty.Ill_Typed);
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Written),
                           Message => "`" & Spelled_Here
                                      & "` is not enabled yet",
                           Refused => Bad.Refusal (Named),
                           Into    => Found);
                     end if;

                     return Ty.Ill_Typed;
                  end if;
               end loop;
            end;

            --  [1860]: a name that names nothing, said here because
            --  resolution leaves a type name to this stage.
            if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
               = Ty.Undecided
            then
               Landin.Checking.Note
                 (Types.all, Of_Tree, Written, Ty.Ill_Typed);
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Written),
                  Message => "`" & Spelled (Syn.Name (Of_Tree, Written))
                             & "` is not declared in any scope this"
                             & " reaches",
                  Note    => "[1860]: a name that names nothing is"
                             & " refused",
                  Into    => Found);
            end if;

            return Ty.Ill_Typed;
         end if;

         declare
            Means : constant Res.Declaration_Id :=
              Res.Bound_To (Meanings.all, Of_Tree, Written);
         begin
            if Res.Sort_Of (Meanings.all, Means) = Res.Type_Parameter
              or else Res.Sort_Of (Meanings.all, Means) = Res.Fixed_Parameter
            then
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                    = Ty.Undecided
               then
                  Landin.Checking.Note (Types.all, Of_Tree, Written,
                                        Ty.Ill_Typed);
                  Report_Application
                    (Of_Tree, Written,
                     "a type formal is available only while an alias is"
                     & " being applied");
               end if;
               return Ty.Ill_Typed;
            end if;

            if Res.Sort_Of (Meanings.all, Means) = Res.Module_Type
              and then Syn.Type_Formal_Count
                (Tree_For (Res.Source_Of (Meanings.all, Means)).all,
                 Res.Node_Of (Meanings.all, Means)) /= 0
            then
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                    = Ty.Undecided
               then
                  Landin.Checking.Note (Types.all, Of_Tree, Written,
                                        Ty.Ill_Typed);
                  Report_Application
                    (Of_Tree, Written,
                     "this parameterized type alias requires arguments");
               end if;
               return Ty.Ill_Typed;
            end if;

            if Res.Sort_Of (Meanings.all, Means)
                 not in Res.Module_Type | Res.Module_Atom
            then
               --  Every place that needs this type asks again, so the
               --  node carries whether it has been answered for: without
               --  that a name used once is reported once per pass.
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                  /= Ty.Undecided
               then
                  return Ty.Ill_Typed;
               end if;

               Landin.Checking.Note (Types.all, Of_Tree, Written,
                                     Ty.Ill_Typed);
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Written),
                  Message => "`"
                             & Spelled (Syn.Name (Of_Tree, Written))
                             & "` names something that is not a type",
                  Note    => "[1795]: a type position names one of the"
                             & " scalar types or a `type` declaration",
                  Into    => Found);
               return Ty.Ill_Typed;
            end if;

            if Requirement = Identity_Only
              and then Res.Sort_Of (Meanings.all, Means) = Res.Module_Type
            then
               declare
                  Nominal : constant Landin.Checking.Nominal_Type_Id :=
                    Identity_Nominal (Means);
               begin
                  if Nominal /= Landin.Checking.No_Nominal_Type then
                     if Landin.Checking.Type_Of
                       (Types.all, Of_Tree, Written) = Ty.Undecided
                     then
                        Landin.Checking.Note
                          (Types.all, Of_Tree, Written, Ty.Aggregate);
                     end if;
                     Landin.Checking.Note_Nominal
                       (Types.all, Of_Tree, Written, Nominal);
                     return Ty.Aggregate;
                  end if;
               end;
            end if;

            declare
               Held : constant Ty.Type_Kind := Settled_Type (Means);
            begin
               --  [0710]: which aggregate this is, carried from the
               --  declaration that wrote it to every place that names it.
               if Held = Ty.Aggregate then
                  Landin.Checking.Note_Nominal
                    (Types.all, Of_Tree, Written,
                     Landin.Checking.Nominal_Of (Types.all, Means));
               end if;

               --  D17: and which array, which is its shape.
               if Held = Ty.Fixed_Array then
                  Landin.Checking.Note_Array
                    (Types.all, Of_Tree, Written,
                     Landin.Checking.Array_Length (Types.all, Means),
                     Landin.Checking.Array_Element (Types.all, Means));
               end if;

               if Held = Ty.Function_Value then
                  Landin.Checking.Note_Signature
                    (Types.all, Of_Tree, Written,
                     Landin.Checking.Signature_Of (Types.all, Means));
               elsif Held = Ty.Atom_Value then
                  Landin.Checking.Note_Atom_Set
                    (Types.all, Of_Tree, Written,
                     Landin.Checking.Atom_Set_Of (Types.all, Means));
               end if;

               return Held;
            end;
         end;
      end Type_At;

      function Signature_At
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
         return Landin.Checking.Signature_Id
      is
         Count : constant Natural := Syn.Parameter_Count (Of_Tree, Node);
         Parts : Landin.Checking.Signature_Part_Array (1 .. Count) :=
           [others => (others => <>)];
         Results : Landin.Checking.Signature_Part_Array
           (1 .. Syn.Return_Count (Of_Tree, Node)) :=
             [others => (others => <>)];
         Errors : Landin.Checking.Atom_Set_Id :=
           Landin.Checking.No_Atom_Set;
         Error_Form : Landin.Checking.Error_Set_Form :=
           Landin.Checking.Infallible;
         Valid : Boolean := True;

         function Part_At
           (Declared : Syn.Node_Id;
            Site     : Landin.Provenance.Origin)
            return Landin.Checking.Signature_Part;

         function Part_At
           (Declared : Syn.Node_Id;
            Site     : Landin.Provenance.Origin)
            return Landin.Checking.Signature_Part
         is
            Written : constant Syn.Node_Id :=
              Syn.Declared_Type (Of_Tree, Declared);
            Held : constant Ty.Type_Kind := Type_At
              (Of_Tree, Written, Requirement => Identity_Only);
            Part : Landin.Checking.Signature_Part :=
              (Kind => Held,
               Name => Syn.Name (Of_Tree, Declared),
               Site => Site,
               others => <>);
         begin
            case Held is
               when Ty.Scalar_Name =>
                  null;
               when Ty.Atom_Value =>
                  Part.Atoms := Landin.Checking.Atom_Set_Of
                    (Types.all, Of_Tree, Written);
                  Valid := Valid
                    and then Part.Atoms /= Landin.Checking.No_Atom_Set;
               when Ty.Aggregate =>
                  Part.Nominal :=
                    Landin.Checking.Nominal_Of (Types.all, Of_Tree, Written);
                  Valid := Valid
                    and then Part.Nominal /= Landin.Checking.No_Nominal_Type;
               when Ty.Fixed_Array =>
                  Part.Length :=
                    Landin.Checking.Array_Length
                      (Types.all, Of_Tree, Written);
                  Part.Element :=
                    Landin.Checking.Array_Element
                      (Types.all, Of_Tree, Written);
                  Part.Nominal :=
                    Landin.Checking.Array_Element_Nominal
                      (Types.all, Of_Tree, Written);
               when Ty.Function_Value =>
                  --  A function-valued position is one code-address carrier;
                  --  its own structural descriptor remains language type
                  --  evidence and contributes no extra ABI position.
                  Part.Signature :=
                    Landin.Checking.Signature_Of
                      (Types.all, Of_Tree, Written);
                  Valid := Valid
                    and then Part.Signature /= Landin.Checking.No_Signature;
               when others =>
                  Valid := False;
            end case;
            return Part;
         end Part_At;
      begin
         for Index in Parts'Range loop
            declare
               Parameter : constant Syn.Node_Id :=
                 Syn.Nth_Parameter (Of_Tree, Node, Index);
            begin
               Parts (Index) :=
                 Part_At (Parameter, Syn.Origin (Of_Tree, Parameter));
            end;
         end loop;

         for Index in Results'Range loop
            declare
               Returned : constant Syn.Node_Id :=
                 Syn.Nth_Return (Of_Tree, Node, Index);
            begin
               Results (Index) :=
                 Part_At (Returned, Syn.Origin (Of_Tree, Returned));
            end;
         end loop;

         --  D128's multiple named returns form one ABI aggregate, whose
         --  placement needs each value result's layout now.  A function type
         --  nested in a callback remains identity-only: it is one code
         --  carrier in its enclosing layout and has no routine ABI here.
         if Valid and then Results'Length > 1
           and then Syn.Kind (Of_Tree, Node)
             in Syn.Function_Declaration | Syn.Anonymous_Function
         then
            for Index in Results'Range loop
               declare
                  Returned : constant Syn.Node_Id :=
                    Syn.Nth_Return (Of_Tree, Node, Index);
                  Held : constant Ty.Type_Kind := Type_At
                    (Of_Tree, Syn.Declared_Type (Of_Tree, Returned),
                     Requirement => Value_Layout);
               begin
                  Valid := Valid and then Held /= Ty.Ill_Typed;
               end;
            end loop;
         end if;

         --  A written function type opens no scope, but two equal result
         --  labels would still make [0990]'s structural field lookup
         --  ambiguous.  Declared routines get the equivalent [1850]
         --  diagnosis from resolution before checking reaches them.
         if Syn.Kind (Of_Tree, Node) = Syn.Function_Type then
            for Right in 2 .. Syn.Return_Count (Of_Tree, Node) loop
               for Left in 1 .. Right - 1 loop
                  if Results (Left).Name = Results (Right).Name then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Anchor
                          (Of_Tree, Syn.Nth_Return (Of_Tree, Node, Right)),
                        Message => "this function type gives two results the"
                                   & " same field name",
                        Note    => "[0990]: a multiple result is selected by"
                                   & " its unique return names",
                        Related => Syn.Origin
                          (Of_Tree, Syn.Nth_Return (Of_Tree, Node, Left)),
                        Because => "the first result with that name",
                        Into    => Found);
                     Valid := False;
                  end if;
               end loop;
            end loop;
         end if;

         if Valid and then Results'Length > 1 then
            declare
               Placed : Landin.Targets.Placement :=
                 Landin.Targets.Empty_Placement;
               Ignored : Landin.Targets.Byte_Count;
            begin
               for Part of Results loop
                  declare
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                     Scalar : Landin.Targets.Scalar_Size;
                  begin
                     case Part.Kind is
                        when Ty.Scalar_Name | Ty.Function_Value
                           | Ty.Atom_Value =>
                           Scalar := Ty.Storage_Size
                             ((if Part.Kind = Ty.Function_Value
                               then Ty.Usize
                               elsif Part.Kind = Ty.Atom_Value
                               then Ty.U32 else Ty.Scalar_Name (Part.Kind)),
                              Facts);
                           Size := Landin.Targets.Byte_Count
                             (Landin.Targets.Bytes (Scalar));
                           Alignment := Landin.Targets.Alignment_Of
                             (Facts, Scalar);
                        when Ty.Aggregate =>
                           Size := Landin.Checking.Layout_Size
                             (Types.all, Part.Nominal);
                           Alignment := Landin.Checking.Layout_Alignment
                             (Types.all, Part.Nominal);
                        when Ty.Fixed_Array =>
                           if Part.Nominal
                             /= Landin.Checking.No_Nominal_Type
                           then
                              Size := Landin.Targets.Byte_Count (Part.Length)
                                * Landin.Checking.Layout_Size
                                    (Types.all, Part.Nominal);
                              Alignment := Landin.Checking.Layout_Alignment
                                (Types.all, Part.Nominal);
                           else
                              Scalar := Ty.Storage_Size (Part.Element, Facts);
                              Size := Landin.Targets.Byte_Count (Part.Length)
                                * Landin.Targets.Byte_Count
                                    (Landin.Targets.Bytes (Scalar));
                              Alignment := Landin.Targets.Alignment_Of
                                (Facts, Scalar);
                           end if;
                        when others =>
                           Size := 0;
                           Alignment := 1;
                     end case;

                     if not Landin.Targets.Can_Place
                       (Placed, Size, Alignment,
                        Landin.Targets.Maximum_Object_Size (Facts))
                     then
                        Bad.Report
                          (Item    => Bad.Literal_Out_Of_Range,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where
                             (Of_Tree, Syn.Returns_Of (Of_Tree, Node)),
                           Message => "these named returns are too large for"
                                      & " the target's usize",
                           Note    => "D128: the anonymous result aggregate"
                                      & " has one padded caller-owned image",
                           Into    => Found);
                        Valid := False;
                        exit;
                     end if;
                     Landin.Targets.Place
                       (Placed, Size, Alignment, Ignored);
                  end;
               end loop;
            end;
         end if;

         if Syn.Error_Set_Of (Of_Tree, Node) /= Syn.No_Node then
            declare
               Written : constant Syn.Node_Id :=
                 Syn.Error_Set_Of (Of_Tree, Node);
            begin
               if Syn.Kind (Of_Tree, Written) = Syn.Inferred_Error_Set then
                  if Syn.Kind (Of_Tree, Node) /= Syn.Function_Declaration
                    or else Syn.Is_Public (Of_Tree, Node)
                  then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Written),
                        Message => "`! ...` is private routine inference,"
                                   & " not a concrete function type",
                        Note    => "[0960]: public and first-class"
                                   & " signatures write a concrete set",
                        Related => Syn.Origin (Of_Tree, Node),
                        Because => "this signature needs a stable type",
                        Into    => Found);
                     Valid := False;
                  else
                     Error_Form := Landin.Checking.Inferred;
                  end if;
               elsif Type_At (Of_Tree, Written) = Ty.Atom_Value then
                  Errors := Landin.Checking.Atom_Set_Of
                    (Types.all, Of_Tree, Written);
                  Error_Form := Landin.Checking.Concrete;
                  Valid := Errors /= Landin.Checking.No_Atom_Set;
               else
                  Valid := False;
               end if;
            end;
         end if;

         if not Valid then
            return Landin.Checking.No_Signature;
         end if;

         declare
            Made : constant Landin.Checking.Signature_Id :=
              Landin.Checking.Add_Signature
                (Types.all, Parts, Results, Syn.Origin (Of_Tree, Node),
                 Errors, Error_Form);
         begin
            Landin.Checking.Note_Signature
              (Types.all, Of_Tree, Node, Made);
            return Made;
         end;
      end Signature_At;

      --  D72: construction is a Struct_Literal whose optional nominal slot
      --  is a type position.  It supplies [0710]'s body to an inferred
      --  binding and must agree with a typed binding or assignment place.
      --  The literal itself remembers a failed callee so later contextual
      --  passes decline to add a second report.
      function Construction_Body
        (Of_Tree : Syn.Tree; Literal : Syn.Node_Id)
         return Landin.Checking.Nominal_Type_Id
      is
         Nominal : constant Syn.Node_Id :=
           Syn.Constructed_Type (Of_Tree, Literal);
      begin
         if Nominal = Syn.No_Node
           or else Landin.Checking.Type_Of (Types.all, Of_Tree, Literal)
                     = Ty.Ill_Typed
         then
            return Landin.Checking.No_Nominal_Type;
         end if;

         --  A resolved binding or function in this position is a permanent
         --  construction error, not a deferred call-shaped value feature.
         if Syn.Kind (Of_Tree, Nominal) = Syn.Type_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Nominal)
                      = Res.Bound
           and then Res.Sort_Of
             (Meanings.all,
              Res.Bound_To (Meanings.all, Of_Tree, Nominal))
                = Res.Case_Name
         then
            Bad.Report
              (Item    => Bad.Unsupported_Use,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Nominal),
               Message => "a variant case cannot be constructed until"
                          & " variant values are enabled",
               Refused => Bad.Variant_Value,
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
            return Landin.Checking.No_Nominal_Type;
         end if;

         if Syn.Kind (Of_Tree, Nominal) = Syn.Type_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Nominal)
                      = Res.Bound
           and then Res.Sort_Of
             (Meanings.all,
              Res.Bound_To (Meanings.all, Of_Tree, Nominal))
                /= Res.Module_Type
         then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Nominal),
               Message => "this name is not a type, so it cannot construct"
                          & " a struct",
               Note    => "[0700]: construction applies a type to labelled"
                          & " field values",
               Related => Syn.Origin (Of_Tree, Literal),
               Because => "this construction",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
            return Landin.Checking.No_Nominal_Type;
         end if;

         declare
            Held : constant Ty.Type_Kind := Type_At (Of_Tree, Nominal);
         begin
            if Held = Ty.Aggregate then
               --  D119: a construction whose body has an ordinary child is
               --  admitted, because Check_Aggregate_Field already checks a
               --  labelled child value against that child's own body and
               --  the lowering fills it one place deeper.
               return Landin.Checking.Nominal_Of (Types.all, Of_Tree, Nominal);
            elsif Held = Ty.Ill_Typed then
               --  Type_At either reported the missing/refused type or
               --  inherited its earlier owner.  Mark the enclosing value so
               --  module recovery does not walk the failed type a second
               --  time.
               Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
            else
               Bad.Report
                 (Item    => Bad.Type_Mismatch,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Nominal),
                  Message => "this is not an ordinary struct type",
                  Note    => "[0700]: construction applies a struct type to"
                             & " labelled field values",
                  Related => Syn.Origin (Of_Tree, Literal),
                  Because => "this construction",
                  Into    => Found);
               Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
            end if;

            return Landin.Checking.No_Nominal_Type;
         end;
      end Construction_Body;

      function Construction_Agrees
        (Of_Tree  : Syn.Tree;
         Literal  : Syn.Node_Id;
         Expected : Landin.Checking.Nominal_Type_Id;
         Related  : Landin.Provenance.Origin;
         Because  : String) return Boolean
      is
         Nominal : constant Syn.Node_Id :=
           Syn.Constructed_Type (Of_Tree, Literal);
         Wrote : Landin.Checking.Nominal_Type_Id;
      begin
         if Nominal = Syn.No_Node then
            return True;
         end if;

         Wrote := Construction_Body (Of_Tree, Literal);
         if Wrote = Landin.Checking.No_Nominal_Type then
            return False;
         elsif Wrote /= Expected then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Nominal),
               Message => "this constructs a different struct type",
               Note    => "[0710]: two structs are one type when one"
                          & " declaration wrote both, and never otherwise",
               Related => Related,
               Because => Because,
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
            return False;
         end if;

         return True;
      end Construction_Agrees;

      function Is_Local_Binding
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean is
      begin
         for Id in Res.Declaration_Id'(1)
                   .. Res.Declaration_Id
                        (Res.Declaration_Count (Meanings.all))
         loop
            if Res.Source_Of (Meanings.all, Id) = Syn.Source_Of (Of_Tree)
              and then Res.Node_Of (Meanings.all, Id) = Node
            then
               return Res.Sort_Of (Meanings.all, Id) = Res.Local_Binding;
            end if;
         end loop;

         return False;
      end Is_Local_Binding;

      function Declared_As_Node
        (Of_Tree         : Syn.Tree;
         Node            : Syn.Node_Id;
         For_Declaration : Res.Declaration_Id := Res.No_Declaration)
         return Ty.Type_Kind
      is
         Written : constant Syn.Node_Id := Syn.Declared_Type (Of_Tree, Node);
      begin
         if Written = Syn.No_Node then
            return Ty.Undecided;
         end if;

         declare
            Held : constant Ty.Type_Kind :=
              Type_At (Of_Tree, Written, For_Declaration);
            Struct_Body_Id : constant Landin.Checking.Nominal_Type_Id :=
              (if Held = Ty.Aggregate
               then Landin.Checking.Nominal_Of
                 (Types.all, Of_Tree, Written)
               else Landin.Checking.No_Nominal_Type);
            Variant_Bearing : constant Boolean :=
              Struct_Body_Id /= Landin.Checking.No_Nominal_Type
              and then Landin.Checking.Has_Layout
                (Types.all, Struct_Body_Id)
              and then Landin.Checking.Has_Variant_Part
                (Types.all, Struct_Body_Id);
            Aggregate_Bearing : constant Boolean :=
              Struct_Body_Id /= Landin.Checking.No_Nominal_Type
              and then Landin.Checking.Has_Layout
                (Types.all, Struct_Body_Id)
              and then Landin.Checking.Has_Aggregate_Field
                (Types.all, Struct_Body_Id);
            --  D46 admits [1740]'s declaration-only module state once D45
            --  laid out all of its scalar and fixed-array fields: D10 makes
            --  the entire datum zero without forming an aggregate value.
            --  D47 admits the same declaration-only shape as one frame cell;
            --  D16 still tracks and requires its scalar fields independently.
            --  A parameter, return or written value still needs a whole-value
            --  rule this slice does not have.
            Is_Aggregate_Parameter : constant Boolean :=
              Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) = Syn.Parameter;
            Is_Aggregate_Return : constant Boolean :=
              Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) = Syn.Named_Return;
            Is_Array_Parameter : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Parameter;
            Is_Array_Return : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Named_Return;
            Is_Zeroed_State : constant Boolean :=
              Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Syn.Value_Of (Of_Tree, Node) = Syn.No_Node
              --  A name, or an array written where the type belongs.
              --  [0710]'s identity is a declaration, so an anonymous
              --  struct body declares none and cannot be state; D17
              --  makes an array's identity its shape, which `[3]usize`
              --  carries wherever it is written.
              and then Syn.Kind (Of_Tree, Written)
                       in Syn.Type_Reference | Syn.Array_Type
                          | Syn.Type_Application
              and then
                (Held /= Ty.Aggregate
                 or else
                   Landin.Checking.Nominal_Of
                     (Types.all, Of_Tree, Written)
                       /= Landin.Checking.No_Nominal_Type);
            --  D21: an array binding may be initialized directly from a
            --  whole-array storage name.  Resolution makes that module
            --  storage at module scope and an in-scope storage declaration
            --  inside a body.  D51 also admits a fixed-array field when the
            --  destination binding is local; D70 admits the same contextual
            --  source for a module binding's static image.  The field remains
            --  outside the general-value rules.  Every other
            --  value form (an array literal, a call, `zeroed`, or a slice) is
            --  deferred: none of them is a Name_Reference.  An inferred
            --  direct-name binding has no Written node and is admitted
            --  separately by Infer.
            --  D118: the source may sit under however many selections
            --  [0420] composed; a module image still takes only a direct
            --  name or one field of one, because D70 folds it rather than
            --  copying at run time.
            Is_Direct_Name_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Chain_Names_Storage
                (Of_Tree, Syn.Value_Of (Of_Tree, Node))
              and then
                (Is_Local_Binding (Of_Tree, Node)
                 or else Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                           /= Syn.Member_Selection
                 or else Syn.Kind
                   (Of_Tree,
                    Syn.Target_Of
                      (Of_Tree, Syn.Value_Of (Of_Tree, Node)))
                     = Syn.Name_Reference);
            --  D55/D60: a written local or module struct type supplies the
            --  nominal context for one initializer copied directly from
            --  storage.  The module form copies a static image rather than
            --  executing a runtime copy.
            --  Resolution has already stopped the pipeline for an unresolved
            --  name; a resolved type declaration is not runtime storage.
            Is_Direct_Struct_Init : constant Boolean :=
              Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Chain_Names_Element_Storage
                (Of_Tree, Syn.Value_Of (Of_Tree, Node))
              and then
                (Is_Local_Binding (Of_Tree, Node)
                 or else Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                           = Syn.Name_Reference)
              and then Landin.Checking.Nominal_Of
                (Types.all, Of_Tree, Written)
                  /= Landin.Checking.No_Nominal_Type;
            Is_Array_Call_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Is_Local_Binding (Of_Tree, Node)
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Call;
            Is_Struct_Call_Init : constant Boolean :=
              Held = Ty.Aggregate
              and then Is_Local_Binding (Of_Tree, Node)
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Call
              and then Landin.Checking.Nominal_Of
                (Types.all, Of_Tree, Written)
                  /= Landin.Checking.No_Nominal_Type;
            --  D57/D59: the written local or module struct supplies [0540]'s
            --  complete all-bits-zero image.  Inference and general values
            --  remain separate contextual positions.
            Is_Struct_Zeroed_Init : constant Boolean :=
              Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Zeroed_Literal
              and then Landin.Checking.Nominal_Of
                (Types.all, Of_Tree, Written)
                  /= Landin.Checking.No_Nominal_Type;
            --  D64/D66: a written local or module struct type supplies the
            --  body for one labelled literal.  The module form is a static
            --  image; an inferred literal still has no nominal identity.
            Is_Struct_Literal_Init : constant Boolean :=
              Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Struct_Literal
              and then Landin.Checking.Nominal_Of
                (Types.all, Of_Tree, Written)
                  /= Landin.Checking.No_Nominal_Type;
            --  D23 admits a literal only where its written local array type
            --  supplies both the element context and the exact length.
            Is_Local_Literal_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Is_Local_Binding (Of_Tree, Node)
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Array_Literal;
            --  D24 admits the same literal as a module binding's static
            --  image, on the same terms: the written type supplies the
            --  exact length and the scalar context.  Every element must
            --  also be [1940]'s "known", which Check_Module_Value asks
            --  once the checker settles the types.
            --  D34 admits full-array repetition where a written nonzero array
            --  type supplies its shape, for either module or local storage.
            --  D33/D35's inferred local and module forms are admitted by Infer
            --  before this written-declaration gate.
            Is_Typed_Repetition_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Written /= Syn.No_Node
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Array_Repetition;
            --  D36/D38 admit a mixed prefix for an explicitly typed local or
            --  module array; inferred and general-value forms remain refused.
            Is_Typed_Mixed_Repetition_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Written /= Syn.No_Node
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Mixed_Array_Repetition;
            Is_Module_Literal_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then not Is_Local_Binding (Of_Tree, Node)
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Array_Literal;
            --  D27: every scalar element this kernel admits has one all-zero
            --  image, so an explicitly typed module array can use [0540]
            --  without recording a per-position static image.
            Is_Module_Zeroed_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then not Is_Local_Binding (Of_Tree, Node)
              and then Written /= Syn.No_Node
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Zeroed_Literal;
            --  D28 uses the same contextual image for an explicitly typed
            --  local, whose complete compact frame slot lowering clears at
            --  runtime rather than enumerating D18's target-sized extent.
            Is_Local_Zeroed_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Is_Local_Binding (Of_Tree, Node)
              and then Written /= Syn.No_Node
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Zeroed_Literal;
         begin
            --  Infallible function values use one code-address carrier in
            --  local or module storage, parameters and named results.  Their
            --  structural descriptor was copied by Type_At above.  Unlike a
            --  scalar, a code address has no all-zero value, so module storage
            --  must name its static function image explicitly.
            if Held = Ty.Function_Value
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then not Is_Local_Binding (Of_Tree, Node)
              and then Syn.Value_Of (Of_Tree, Node) = Syn.No_Node
            then
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                    /= Ty.Ill_Typed
               then
                  Bad.Report
                    (Item    => Bad.Not_Known_At_Compile_Time,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Node),
                     Message => "a module function value needs an initial"
                                & " function address",
                     Note    => "[1940]: a function address has no implicit"
                                & " all-zero module image",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Written);
               end if;
               return Ty.Ill_Typed;
            end if;

            --  [1795] declares the type; most *values* of one wait for the
            --  rest of R2.20.  A declaration-only module array is zeroed by
            --  D10, a declaration-only local array is frame storage whose
            --  compiler-known elements D19 assigns independently, and D21
            --  admits the one initializer form that copies from a whole-array
            --  storage name.  Parameters, returns and every other written
            --  value each need a rule this slice does not have.
            if Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) /= Syn.Type_Declaration
              and then not Is_Zeroed_State
              and then not Is_Direct_Name_Init
              and then not Is_Local_Literal_Init
              and then not Is_Typed_Repetition_Init
              and then not Is_Typed_Mixed_Repetition_Init
              and then not Is_Module_Literal_Init
              and then not Is_Module_Zeroed_Init
              and then not Is_Local_Zeroed_Init
              and then not Is_Array_Call_Init
              and then not Is_Array_Parameter
              and then not Is_Array_Return
            then
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                  = Ty.Undecided
               then
                  Landin.Checking.Note
                    (Types.all, Of_Tree, Written, Ty.Ill_Typed);
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Node),
                     Message =>
                       (if Syn.Kind (Of_Tree, Node) = Syn.Binding
                           and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
                           and then Syn.Kind
                                      (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                                    = Syn.Zeroed_Literal
                        then "`zeroed` is not enabled for a local array"
                        else "a value of an array type is not enabled yet"),
                     Refused =>
                       (if Syn.Kind (Of_Tree, Node) = Syn.Binding
                           and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
                           and then Syn.Kind
                                      (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                                    = Syn.Zeroed_Literal
                        then Bad.Zeroed_Value
                        else Bad.Array_Value),
                     Into    => Found);
               end if;

               return Ty.Ill_Typed;
            end if;

            if Held = Ty.Aggregate
              and then Aggregate_Bearing
              and then Syn.Kind (Of_Tree, Node) /= Syn.Type_Declaration
              and then not Is_Zeroed_State
              and then not Is_Struct_Zeroed_Init
              and then not Is_Struct_Literal_Init
              and then not Is_Direct_Struct_Init
              and then not Is_Struct_Call_Init
              and then not Is_Aggregate_Parameter
              and then not Is_Aggregate_Return
            then
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                  = Ty.Undecided
               then
                  Landin.Checking.Note
                    (Types.all, Of_Tree, Written, Ty.Ill_Typed);
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Node),
                     Message => "a nonzero value of a nested-struct type is"
                                & " not enabled yet",
                     Refused => Bad.Struct_Value,
                     Into    => Found);
               end if;
               return Ty.Ill_Typed;
            end if;

            if Held = Ty.Aggregate
              and then Variant_Bearing
              and then Syn.Kind (Of_Tree, Node) /= Syn.Type_Declaration
              and then not Is_Zeroed_State
              and then not Is_Struct_Zeroed_Init
              and then not Is_Struct_Literal_Init
              and then not Is_Direct_Struct_Init
              and then not Is_Struct_Call_Init
              and then not Is_Aggregate_Parameter
              and then not Is_Aggregate_Return
            then
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                  = Ty.Undecided
               then
                  Landin.Checking.Note
                    (Types.all, Of_Tree, Written, Ty.Ill_Typed);
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Node),
                     Message => "this value of a variant-bearing struct is"
                                & " not enabled yet",
                     Refused => Bad.Variant_Value,
                     Into    => Found);
               end if;
               return Ty.Ill_Typed;
            end if;

            if Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) /= Syn.Type_Declaration
              and then not Is_Zeroed_State
              and then not Is_Direct_Struct_Init
              and then not Is_Struct_Call_Init
              and then not Is_Struct_Zeroed_Init
              and then not Is_Struct_Literal_Init
              and then not Is_Aggregate_Parameter
              and then not Is_Aggregate_Return
            then
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                  = Ty.Undecided
               then
                  Landin.Checking.Note
                    (Types.all, Of_Tree, Written, Ty.Ill_Typed);
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Node),
                     Message => "a value of a struct type is not enabled"
                                & " yet",
                     Refused => Bad.Struct_Value,
                     Into    => Found);
               end if;

               return Ty.Ill_Typed;
            end if;

            return Held;
         end;
      end Declared_As_Node;

      function Declared_As (Id : Res.Declaration_Id) return Ty.Type_Kind is
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Id));
         Node    : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Id);
      begin
         if Syn.Kind (Of_Tree.all, Node) = Syn.Atom_Declaration then
            declare
               Set_Id : constant Landin.Checking.Atom_Set_Id :=
                 Landin.Checking.Add_Atom_Set
                   (Types.all, [1 => Id]);
            begin
               Landin.Checking.Note_Atom_Set (Types.all, Id, Set_Id);
               return Ty.Atom_Value;
            end;
         end if;

         if Syn.Kind (Of_Tree.all, Node) = Syn.Function_Declaration then
            declare
               Signature : constant Landin.Checking.Signature_Id :=
                 Signature_At (Of_Tree.all, Node);
            begin
               if Signature = Landin.Checking.No_Signature then
                  return Ty.Ill_Typed;
               end if;
               Landin.Checking.Note_Signature
                 (Types.all, Id, Signature);
               return Ty.Function_Value;
            end;
         end if;

         declare
            Written : constant Syn.Node_Id :=
              Syn.Declared_Type (Of_Tree.all, Node);
            Is_Body : constant Boolean :=
              Written /= Syn.No_Node
              and then Syn.Kind (Of_Tree.all, Written) = Syn.Struct_Body;
         begin
            --  The identity exists before the body is checked because its
            --  layout is recorded against that identity during the walk.
            if Is_Body then
               declare
                  Nominal : constant Landin.Checking.Nominal_Type_Id :=
                    Landin.Checking.Empty_Nominal_Instance
                      (Types.all, Id);
               begin
                  Landin.Checking.Note_Nominal (Types.all, Id, Nominal);
                  Landin.Checking.Note_Nominal
                    (Types.all, Of_Tree.all, Written, Nominal);
               end;
            end if;

            declare
               --  A Parameter or a Named_Return keeps its former refusal
               --  path because it is not a Binding node.
               Held : constant Ty.Type_Kind :=
                 Declared_As_Node
                   (Of_Tree.all, Node,
                    (if Is_Body then Id else Res.No_Declaration));
            begin
               --  A declaration that names an existing aggregate is D15's
               --  alias and carries the identity the type position was given.
               if Held = Ty.Aggregate and then not Is_Body then
                  Landin.Checking.Note_Nominal
                    (Types.all, Id,
                     Landin.Checking.Nominal_Of
                       (Types.all, Of_Tree.all, Written));
               end if;

               --  D17: an array's identity is its shape, so the
               --  declaration carries the shape the type position was
               --  given -- and an alias of one carries the same shape,
               --  because that is all there is to carry.  A binding of
               --  one carries it for the same reason: what it holds is
               --  the shape and nothing else names it.
               if Held = Ty.Fixed_Array then
                  Landin.Checking.Note_Array
                    (Types.all, Id,
                     Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Written),
                     Landin.Checking.Array_Element
                       (Types.all, Of_Tree.all, Written));
                  --  D121's element body is part of that shape.
                  Landin.Checking.Note_Array_Element_Nominal
                    (Types.all, Id,
                     Landin.Checking.Array_Element_Nominal
                       (Types.all, Of_Tree.all, Written));
               end if;

               if Held = Ty.Atom_Value then
                  Landin.Checking.Note_Atom_Set
                    (Types.all, Id,
                     Landin.Checking.Atom_Set_Of
                       (Types.all, Of_Tree.all, Written));
               end if;

               --  D118: a type alias and explicitly typed local carry the
               --  descriptor written by their type position.  This is
               --  independent of whichever function value later fills it.
               if Held = Ty.Function_Value then
                  Landin.Checking.Note_Signature
                    (Types.all, Id,
                     Landin.Checking.Signature_Of
                       (Types.all, Of_Tree.all, Written));
               end if;

               return Held;
            end;
         end;
      end Declared_As;

      function Settled_Type (Id : Res.Declaration_Id) return Ty.Type_Kind is
      begin
         if Id = Res.No_Declaration then
            return Ty.Ill_Typed;
         end if;

         case Landin.Checking.State_Of (Types.all, Id) is
            when Landin.Checking.Settled =>
               return Landin.Checking.Type_Of (Types.all, Id);

            when Landin.Checking.Underway =>
               --  A chain came back to where it began.  [1940] says that
               --  for module values; [1795] says an alias has to reach a
               --  type rather than itself.
               declare
                  Of_Tree : constant not null access constant Syn.Tree :=
                    Tree_For (Res.Source_Of (Meanings.all, Id));
                  Node : constant Syn.Node_Id :=
                    Res.Node_Of (Meanings.all, Id);
               begin
                  if Res.Sort_Of (Meanings.all, Id) = Res.Module_Type
                    and then Struct_Layout_Depth > 0
                  then
                     Bad.Report
                       (Item    => Bad.Recursive_Nominal_Value,
                        Source  => Active_Struct_Field.Source,
                        Where   => Active_Struct_Field.Where,
                        Message => "this nominal value layout eventually"
                                   & " contains itself by value",
                        Note    => "D137: a finite nominal value layout"
                                   & " cannot include itself by value",
                        Related => Active_Struct_Body,
                        Because => "the nominal struct body being laid out",
                        Into    => Found);
                  elsif Res.Sort_Of (Meanings.all, Id)
                    = Res.Module_Type
                  then
                     Bad.Report
                       (Item    => Bad.Cyclic_Type_Alias,
                        Source  => Res.Source_Of (Meanings.all, Id),
                        Where   => Syn.Anchor (Of_Tree.all, Node),
                        Message => "the type alias `"
                                   & Spelled (Syn.Name (Of_Tree.all, Node))
                                   & "` eventually names itself",
                        Note    => "[1795]: an alias chain has to reach a"
                                   & " scalar or a struct body",
                        Into    => Found);
                  else
                     Bad.Report
                       (Item    => Bad.Not_Known_At_Compile_Time,
                        Source  => Res.Source_Of (Meanings.all, Id),
                        Where   => Syn.Anchor (Of_Tree.all, Node),
                        Message => "the value of `"
                                   & Spelled (Syn.Name (Of_Tree.all, Node))
                                   & "` is worked out from itself",
                        Note    => "[1940]: a chain that comes back to where"
                                   & " it began names nothing at all",
                        Into    => Found);
                  end if;
               end;

               return Ty.Ill_Typed;

            when Landin.Checking.Untouched =>
               if Res.Sort_Of (Meanings.all, Id)
                    in Res.Module_Type | Res.Module_Atom
               then
                  --  A forward type alias or atom reaches here before pass
                  --  one's outer walk reaches the declaration it names.
                  --  Settle that written type now; Infer is only [1790]'s `:=`
                  --  binding and would ask a type declaration for a value.
                  Landin.Checking.Begin_Inference (Types.all, Id);

                  declare
                     Held : constant Ty.Type_Kind := Declared_As (Id);
                  begin
                     Landin.Checking.Settle (Types.all, Id, Held);
                     return Held;
                  end;
               end if;

               Infer (Id);
               return (if Landin.Checking.State_Of (Types.all, Id)
                          = Landin.Checking.Settled
                       then Landin.Checking.Type_Of (Types.all, Id)
                       else Ty.Ill_Typed);
         end case;
      end Settled_Type;

      function Instantiate_Generic_Call
        (Caller_Tree : Syn.Tree;
         Call        : Syn.Node_Id;
         Template    : Res.Declaration_Id)
         return Landin.Checking.Signature_Id
      is
         Template_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Template));
         Function_Node : constant Syn.Node_Id :=
           Res.Node_Of (Meanings.all, Template);
         Formal_Count : constant Natural :=
           Syn.Generic_Formal_Count (Template_Tree.all, Function_Node);
         Bound : Formal_Actual_Array (1 .. Formal_Count) :=
           [others => (others => <>)];
         Good : Boolean := True;

         function Descriptor_At
           (Of_Tree : Syn.Tree;
            Node    : Syn.Node_Id;
            Kind    : Ty.Type_Kind) return Type_Descriptor;

         function Descriptors_Agree (Left, Right : Type_Descriptor)
           return Boolean;

         procedure Publish_Descriptor
           (Node       : Syn.Node_Id;
            Declaration : Res.Declaration_Id;
            Descriptor : Type_Descriptor);

         function Descriptor_At
           (Of_Tree : Syn.Tree;
            Node    : Syn.Node_Id;
            Kind    : Ty.Type_Kind) return Type_Descriptor
         is
         begin
            case Kind is
               when Ty.Scalar_Name =>
                  return (Kind => Kind, others => <>);
               when Ty.Atom_Value =>
                  return
                    (Kind => Kind,
                     Atoms => Landin.Checking.Atom_Set_Of
                       (Types.all, Of_Tree, Node),
                     others => <>);
               when Ty.Fixed_Array =>
                  return
                    (Kind => Kind,
                     Length => Landin.Checking.Array_Length
                       (Types.all, Of_Tree, Node),
                     Element => Landin.Checking.Array_Element
                       (Types.all, Of_Tree, Node),
                     Element_Nominal =>
                       Landin.Checking.Array_Element_Nominal
                         (Types.all, Of_Tree, Node),
                     others => <>);
               when Ty.Aggregate =>
                  return
                    (Kind => Kind,
                     Nominal => Landin.Checking.Nominal_Of
                       (Types.all, Of_Tree, Node),
                     others => <>);
               when Ty.Function_Value =>
                  return
                    (Kind => Kind,
                     Signature => Landin.Checking.Signature_Of
                       (Types.all, Of_Tree, Node),
                     others => <>);
               when others =>
                  return (Kind => Ty.Ill_Typed, others => <>);
            end case;
         end Descriptor_At;

         function Descriptors_Agree (Left, Right : Type_Descriptor)
           return Boolean
         is
         begin
            if Left.Kind /= Right.Kind then
               return False;
            end if;
            case Left.Kind is
               when Ty.Scalar_Name =>
                  return True;
               when Ty.Atom_Value =>
                  return Landin.Checking.Atom_Sets_Agree
                    (Types.all, Left.Atoms, Right.Atoms);
               when Ty.Fixed_Array =>
                  return Left.Length = Right.Length
                    and then Left.Element = Right.Element
                    and then Left.Element_Nominal = Right.Element_Nominal;
               when Ty.Aggregate =>
                  return Left.Nominal = Right.Nominal;
               when Ty.Function_Value =>
                  return Landin.Checking.Signatures_Agree
                    (Types.all, Left.Signature, Right.Signature);
               when others =>
                  return False;
            end case;
         end Descriptors_Agree;

         procedure Publish_Descriptor
           (Node        : Syn.Node_Id;
            Declaration : Res.Declaration_Id;
            Descriptor  : Type_Descriptor) is
         begin
            if Landin.Checking.Type_Of
                 (Types.all, Template_Tree.all, Node) = Ty.Undecided
            then
               Landin.Checking.Note
                 (Types.all, Template_Tree.all, Node, Descriptor.Kind);
            end if;
            case Descriptor.Kind is
               when Ty.Atom_Value =>
                  Landin.Checking.Note_Atom_Set
                    (Types.all, Template_Tree.all, Node, Descriptor.Atoms);
                  Landin.Checking.Note_Atom_Set
                    (Types.all, Declaration, Descriptor.Atoms);
               when Ty.Fixed_Array =>
                  Landin.Checking.Note_Array
                    (Types.all, Template_Tree.all, Node,
                     Descriptor.Length, Descriptor.Element);
                  Landin.Checking.Note_Array
                    (Types.all, Declaration,
                     Descriptor.Length, Descriptor.Element);
                  if Descriptor.Element_Nominal
                    /= Landin.Checking.No_Nominal_Type
                  then
                     Landin.Checking.Note_Array_Element_Nominal
                       (Types.all, Template_Tree.all, Node,
                        Descriptor.Element_Nominal);
                     Landin.Checking.Note_Array_Element_Nominal
                       (Types.all, Declaration, Descriptor.Element_Nominal);
                  end if;
               when Ty.Aggregate =>
                  Landin.Checking.Note_Nominal
                    (Types.all, Template_Tree.all, Node,
                     Descriptor.Nominal);
                  Landin.Checking.Note_Nominal
                    (Types.all, Declaration, Descriptor.Nominal);
               when Ty.Function_Value =>
                  Landin.Checking.Note_Signature
                    (Types.all, Template_Tree.all, Node,
                     Descriptor.Signature);
                  Landin.Checking.Note_Signature
                    (Types.all, Declaration, Descriptor.Signature);
               when others =>
                  null;
            end case;
            Landin.Checking.Settle
              (Types.all, Declaration, Descriptor.Kind);
         end Publish_Descriptor;
      begin
         if Syn.Argument_Count (Caller_Tree, Call)
              /= Syn.Parameter_Count (Template_Tree.all, Function_Node)
         then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Caller_Tree),
               Where   => Syn.Where (Caller_Tree, Call),
               Message => "this generic call gives "
                          & Counted
                            (Syn.Argument_Count (Caller_Tree, Call),
                             "argument") & " and the template takes "
                          & Counted
                            (Syn.Parameter_Count
                               (Template_Tree.all, Function_Node),
                             "argument"),
               Note    => "D138: deduction first matches every runtime"
                          & " argument position",
               Related => Syn.Origin (Template_Tree.all, Function_Node),
               Because => "the generic routine template",
               Into    => Found);
            return Landin.Checking.No_Signature;
         end if;

         for Index in Bound'Range loop
            Bound (Index).Formal := Declaration_At
              (Syn.Source_Of (Template_Tree.all),
               Syn.Nth_Generic_Formal
                 (Template_Tree.all, Function_Node, Index));
         end loop;

         --  Deduction is deliberately context-free.  A literal therefore
         --  takes [0200]'s i32 default before any concrete parameter context
         --  exists; only after the complete tuple is known does Check_Call
         --  apply ordinary literal context and argument agreement.
         for Index in 1 .. Syn.Parameter_Count
           (Template_Tree.all, Function_Node)
         loop
            declare
               Parameter : constant Syn.Node_Id := Syn.Nth_Parameter
                 (Template_Tree.all, Function_Node, Index);
               Written : constant Syn.Node_Id :=
                 Syn.Declared_Type (Template_Tree.all, Parameter);
               Argument : constant Syn.Node_Id :=
                 Syn.Nth_Argument (Caller_Tree, Call, Index);
               Formal : Res.Declaration_Id := Res.No_Declaration;
            begin
               if Syn.Kind (Template_Tree.all, Written) = Syn.Type_Reference
                 and then Res.Verdict_Of
                   (Meanings.all, Template_Tree.all, Written) = Res.Bound
                 and then Res.Sort_Of
                   (Meanings.all,
                    Res.Bound_To (Meanings.all, Template_Tree.all, Written))
                      = Res.Type_Parameter
               then
                  Formal := Res.Bound_To
                    (Meanings.all, Template_Tree.all, Written);
               end if;

               if Formal /= Res.No_Declaration then
                  declare
                     Got : Ty.Type_Kind :=
                       (if Syn.Kind (Caller_Tree, Argument)
                            in Syn.Name_Reference | Syn.Member_Selection
                               | Syn.Element_Index
                        then Selected_From (Caller_Tree, Argument)
                        else Synthesise (Caller_Tree, Argument));
                     Actual : Type_Descriptor;
                     Position : Natural := 0;
                  begin
                     if Got = Ty.Untyped_Integer then
                        Commit_To (Caller_Tree, Argument, Ty.Default_Integer);
                        Got := Ty.Default_Integer;
                     end if;
                     Actual := Descriptor_At (Caller_Tree, Argument, Got);
                     for Which in Bound'Range loop
                        if Bound (Which).Formal = Formal then
                           Position := Which;
                           exit;
                        end if;
                     end loop;
                     if Position = 0 or else Actual.Kind = Ty.Ill_Typed then
                        Good := False;
                     elsif Bound (Position).Value.Kind = Ty.Ill_Typed then
                        Bound (Position).Value := Actual;
                     elsif not Descriptors_Agree
                       (Bound (Position).Value, Actual)
                     then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Caller_Tree),
                           Where   => Syn.Where (Caller_Tree, Argument),
                           Message => "this argument deduces a different"
                                      & " type for the repeated formal",
                           Note    => "D138: every direct occurrence of one"
                                      & " type formal must agree exactly",
                           Related => Syn.Origin
                             (Template_Tree.all, Written),
                           Because => "the repeated direct type formal",
                           Into    => Found);
                        Good := False;
                     end if;
                  end;
               elsif Syn.Kind (Template_Tree.all, Written) = Syn.Array_Type
               then
                  declare
                     Bound_Node : constant Syn.Node_Id :=
                       Syn.Bound_Of (Template_Tree.all, Written);
                     Element_Node : constant Syn.Node_Id :=
                       Syn.Element_Of (Template_Tree.all, Written);
                     Fixed_Formal : Res.Declaration_Id := Res.No_Declaration;
                     Type_Formal : Res.Declaration_Id := Res.No_Declaration;
                     Got : constant Ty.Type_Kind :=
                       (if Syn.Kind (Caller_Tree, Argument)
                            in Syn.Name_Reference | Syn.Member_Selection
                               | Syn.Element_Index
                        then Selected_From (Caller_Tree, Argument)
                        else Synthesise (Caller_Tree, Argument));
                  begin
                     if Syn.Kind (Template_Tree.all, Bound_Node)
                          = Syn.Name_Reference
                       and then Res.Verdict_Of
                         (Meanings.all, Template_Tree.all, Bound_Node)
                           = Res.Bound
                       and then Res.Sort_Of
                         (Meanings.all,
                          Res.Bound_To
                            (Meanings.all, Template_Tree.all, Bound_Node))
                           = Res.Fixed_Parameter
                     then
                        Fixed_Formal := Res.Bound_To
                          (Meanings.all, Template_Tree.all, Bound_Node);
                     end if;
                     if Syn.Kind (Template_Tree.all, Element_Node)
                          = Syn.Type_Reference
                       and then Res.Verdict_Of
                         (Meanings.all, Template_Tree.all, Element_Node)
                           = Res.Bound
                       and then Res.Sort_Of
                         (Meanings.all,
                          Res.Bound_To
                            (Meanings.all, Template_Tree.all, Element_Node))
                           = Res.Type_Parameter
                     then
                        Type_Formal := Res.Bound_To
                          (Meanings.all, Template_Tree.all, Element_Node);
                     end if;

                     if Fixed_Formal /= Res.No_Declaration
                       and then Type_Formal /= Res.No_Declaration
                     then
                        if Got /= Ty.Fixed_Array then
                           Good := False;
                        else
                           declare
                              Actual : constant Type_Descriptor :=
                                Descriptor_At (Caller_Tree, Argument, Got);
                              Element : constant Type_Descriptor :=
                                (if Actual.Element_Nominal
                                      /= Landin.Checking.No_Nominal_Type
                                 then (Kind => Ty.Aggregate,
                                       Nominal => Actual.Element_Nominal,
                                       others => <>)
                                 else (Kind => Actual.Element, others => <>));
                              Fixed_Position, Type_Position : Natural := 0;
                           begin
                              for Which in Bound'Range loop
                                 if Bound (Which).Formal = Fixed_Formal then
                                    Fixed_Position := Which;
                                 elsif Bound (Which).Formal = Type_Formal then
                                    Type_Position := Which;
                                 end if;
                              end loop;
                              if Fixed_Position = 0 or else Type_Position = 0
                              then
                                 Good := False;
                              else
                                 if Bound (Fixed_Position).Fixed_Known
                                   and then Bound (Fixed_Position).Fixed
                                     /= Ty.Magnitude (Actual.Length)
                                 then
                                    Good := False;
                                 else
                                    Bound (Fixed_Position).Fixed :=
                                      Ty.Magnitude (Actual.Length);
                                    Bound (Fixed_Position).Fixed_Known := True;
                                 end if;
                                 if Bound (Type_Position).Value.Kind
                                      = Ty.Ill_Typed
                                 then
                                    Bound (Type_Position).Value := Element;
                                 elsif not Descriptors_Agree
                                   (Bound (Type_Position).Value, Element)
                                 then
                                    Good := False;
                                 end if;
                              end if;
                           end;
                        end if;
                     end if;
                  end;
               end if;
            end;
         end loop;

         for Index in Bound'Range loop
            declare
               Formal_Node : constant Syn.Node_Id := Syn.Nth_Generic_Formal
                 (Template_Tree.all, Function_Node, Index);
            begin
               if Syn.Kind (Template_Tree.all, Formal_Node) = Syn.Type_Formal
                 and then Bound (Index).Value.Kind = Ty.Ill_Typed
               then
                  Bad.Report
                    (Item    => Bad.Type_Mismatch,
                     Source  => Syn.Source_Of (Caller_Tree),
                     Where   => Syn.Where (Caller_Tree, Call),
                     Message => "this call cannot deduce every type formal",
                     Note    => "D138: deduction uses direct runtime"
                                & " parameter occurrences only, never a"
                                & " return context",
                     Related => Syn.Origin
                       (Template_Tree.all, Formal_Node),
                     Because => "the undeduced type formal",
                     Into    => Found);
                  Good := False;
               elsif Syn.Kind (Template_Tree.all, Formal_Node)
                 = Syn.Fixed_Formal
                 and then not Bound (Index).Fixed_Known
               then
                  Bad.Report
                    (Item    => Bad.Type_Mismatch,
                     Source  => Syn.Source_Of (Caller_Tree),
                     Where   => Syn.Where (Caller_Tree, Call),
                     Message => "this call cannot deduce a fixed formal",
                     Note    => "D138: only an exact `[n]t` runtime shape"
                                & " binds a fixed formal; deduction performs"
                                & " no arithmetic inversion",
                     Related => Syn.Origin
                       (Template_Tree.all, Formal_Node),
                     Because => "the undeduced fixed formal",
                     Into    => Found);
                  Good := False;
               end if;
            end;
         end loop;

         if Good then
            for Index in Bound'Range loop
               declare
                  Formal_Node : constant Syn.Node_Id :=
                    Syn.Nth_Generic_Formal
                      (Template_Tree.all, Function_Node, Index);
               begin
                  if Syn.Kind (Template_Tree.all, Formal_Node)
                       = Syn.Fixed_Formal
                  then
                     declare
                        Expected : constant Type_Descriptor := Normalized_Type
                          (Template_Tree.all,
                           Syn.Declared_Type
                             (Template_Tree.all, Formal_Node),
                           Bound, Syn.Origin (Caller_Tree, Call),
                           Identity_Only);
                     begin
                        if Expected.Kind not in Ty.Integer_Name
                          or else not Ty.Fits
                            (Bound (Index).Fixed,
                             Ty.Scalar_Name (Expected.Kind), Facts,
                             Negated => False)
                        then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Caller_Tree),
                              Where   => Syn.Where (Caller_Tree, Call),
                              Message => "the deduced fixed value does not"
                                         & " fit its formal type",
                              Note    => "D138 reuses the normalized fixed"
                                         & " descriptor and its declared"
                                         & " integer range",
                              Related => Syn.Origin
                                (Template_Tree.all, Formal_Node),
                              Because => "the fixed formal",
                              Into    => Found);
                           Good := False;
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end if;

         if not Good then
            return Landin.Checking.No_Signature;
         end if;

         declare
            Key : Landin.Checking.Actual_Tuple :=
              Landin.Checking.Empty_Actuals;
         begin
            for Each of Bound loop
               if Res.Sort_Of (Meanings.all, Each.Formal)
                    = Res.Type_Parameter
               then
                  Landin.Checking.Append_Actual
                    (Key, Actual_For (Each.Value));
               else
                  Landin.Checking.Append_Actual
                    (Key, Landin.Checking.Fixed_Actual (Each.Fixed));
               end if;
            end loop;
            declare
               Instance : constant Landin.Checking.Routine_Instance_Id :=
                 Landin.Checking.Intern_Routine_Instance
                   (Types.all, Template, Key);
            begin
               Landin.Checking.Note_Routine_Target
                 (Types.all, Caller_Tree, Call, Instance);

               if Landin.Checking.Routine_State_Of (Types.all, Instance)
                    in Landin.Checking.Routine_Building
                       | Landin.Checking.Routine_Ready
               then
                  return Landin.Checking.Routine_Signature_Of
                    (Types.all, Instance);
               elsif Landin.Checking.Routine_State_Of (Types.all, Instance)
                 = Landin.Checking.Routine_Invalid
               then
                  return Landin.Checking.No_Signature;
               end if;

               for Position in 1 .. Landin.Checking.Routine_Instance_Count
                 (Types.all)
               loop
                  declare
                     Other : constant Landin.Checking.Routine_Instance_Id :=
                       Landin.Checking.Routine_Identities.Nth
                         (Types.all, Position);
                  begin
                     if Other /= Instance
                       and then Landin.Checking.Routine_Template_Of
                         (Types.all, Other) = Template
                       and then Landin.Checking.Routine_State_Of
                         (Types.all, Other) = Landin.Checking.Routine_Building
                     then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Caller_Tree),
                           Where   => Syn.Where (Caller_Tree, Call),
                           Message => "this recursive generic call expands"
                                      & " the same template at a different"
                                      & " actual tuple",
                           Note    => "D138: recursive same-key calls are"
                                      & " finite; a different active tuple"
                                      & " is not",
                           Related => Syn.Origin
                             (Template_Tree.all, Function_Node),
                           Because => "the active generic template",
                           Into    => Found);
                        return Landin.Checking.No_Signature;
                     end if;
                  end;
               end loop;

               Landin.Checking.Begin_Routine_Instance
                 (Types.all, Instance);
               declare
                  Previous : Landin.Checking.Routine_Instance_Id;
                  Parameters : Landin.Checking.Signature_Part_Array
                    (1 .. Syn.Parameter_Count
                      (Template_Tree.all, Function_Node)) :=
                        [others => (others => <>)];
                  Results : Landin.Checking.Signature_Part_Array
                    (1 .. Syn.Return_Count
                      (Template_Tree.all, Function_Node)) :=
                        [others => (others => <>)];
                  Valid : Boolean := True;
                  Signature : Landin.Checking.Signature_Id :=
                    Landin.Checking.No_Signature;
                  Reports_Before : constant Natural :=
                    Landin.Diagnostics.Count (Found);

                  function Part_For
                    (Node : Syn.Node_Id) return Landin.Checking.Signature_Part;

                  function Part_For
                    (Node : Syn.Node_Id)
                     return Landin.Checking.Signature_Part
                  is
                     Descriptor : constant Type_Descriptor := Normalized_Type
                       (Template_Tree.all,
                        Syn.Declared_Type (Template_Tree.all, Node), Bound,
                        Syn.Origin (Caller_Tree, Call), Identity_Only);
                  begin
                     if Descriptor.Kind not in
                       Ty.Scalar_Name | Ty.Atom_Value | Ty.Fixed_Array
                          | Ty.Aggregate | Ty.Function_Value
                     then
                        Valid := False;
                     end if;
                     return
                       (Kind      => Descriptor.Kind,
                        Nominal   => Descriptor.Nominal,
                        Length    => Descriptor.Length,
                        Element   => Descriptor.Element,
                        Signature => Descriptor.Signature,
                        Name      => Syn.Name (Template_Tree.all, Node),
                        Atoms     => Descriptor.Atoms,
                        Site      => Syn.Origin (Template_Tree.all, Node));
                  end Part_For;
               begin
                  Landin.Checking.Activate_Routine_View
                    (Types.all, Instance, Previous);
                  for Index in Parameters'Range loop
                     Parameters (Index) := Part_For
                       (Syn.Nth_Parameter
                         (Template_Tree.all, Function_Node, Index));
                  end loop;
                  for Index in Results'Range loop
                     Results (Index) := Part_For
                       (Syn.Nth_Return
                         (Template_Tree.all, Function_Node, Index));
                  end loop;

                  if Valid
                    and then Syn.Error_Set_Of
                      (Template_Tree.all, Function_Node) = Syn.No_Node
                  then
                     Signature := Landin.Checking.Add_Signature
                       (Types.all, Parameters, Results,
                        Syn.Origin (Template_Tree.all, Function_Node));
                  else
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Template_Tree.all),
                        Where   => Syn.Where
                          (Template_Tree.all, Function_Node),
                        Message => "this generic routine signature is not"
                                   & " concrete after deduction",
                        Note    => "D138: every runtime signature part must"
                                   & " substitute to an enabled type",
                        Into    => Found);
                  end if;

                  if Signature /= Landin.Checking.No_Signature then
                     Landin.Checking.Publish_Routine_Signature
                       (Types.all, Instance, Signature);
                     Landin.Checking.Note_Signature
                       (Types.all, Template_Tree.all, Function_Node,
                        Signature);
                     if Landin.Checking.Type_Of
                       (Types.all, Template_Tree.all, Function_Node)
                         = Ty.Undecided
                     then
                        Landin.Checking.Note
                          (Types.all, Template_Tree.all, Function_Node,
                           Ty.Function_Value);
                     end if;

                     for Id in Res.Declaration_Id'(1)
                       .. Res.Declaration_Id
                         (Res.Declaration_Count (Meanings.all))
                     loop
                        if Id /= Template
                          and then Generic_Routine_Owner (Id) = Template
                          and then Res.Sort_Of (Meanings.all, Id)
                            in Res.Parameter | Res.Named_Return
                               | Res.Local_Binding
                        then
                           declare
                              Declaring : constant Syn.Node_Id :=
                                Res.Node_Of (Meanings.all, Id);
                              Written : constant Syn.Node_Id :=
                                Syn.Declared_Type
                                  (Template_Tree.all, Declaring);
                           begin
                              if Written /= Syn.No_Node then
                                 declare
                                    Descriptor : constant Type_Descriptor :=
                                      Normalized_Type
                                        (Template_Tree.all, Written, Bound,
                                         Syn.Origin (Caller_Tree, Call));
                                 begin
                                    if Descriptor.Kind = Ty.Ill_Typed then
                                       Valid := False;
                                    else
                                       Publish_Descriptor
                                         (Written, Id, Descriptor);
                                    end if;
                                 end;
                              end if;
                           end;
                        end if;
                     end loop;
                  end if;

                  if Valid
                    and then Signature /= Landin.Checking.No_Signature
                  then
                     Check_Routine_Body
                       (Template_Tree.all, Function_Node);
                  end if;
                  Landin.Checking.Restore_Routine_View
                    (Types.all, Previous);

                  if not Valid
                    or else Signature = Landin.Checking.No_Signature
                    or else Landin.Diagnostics.Count (Found) > Reports_Before
                  then
                     Landin.Checking.Invalidate_Routine_Instance
                       (Types.all, Instance);
                  else
                     Landin.Checking.Finish_Routine_Instance
                       (Types.all, Instance);
                  end if;
                  return Signature;
               exception
                  when others =>
                     Landin.Checking.Restore_Routine_View
                       (Types.all, Previous);
                     if Landin.Checking.Routine_State_Of
                       (Types.all, Instance) = Landin.Checking.Routine_Building
                     then
                        Landin.Checking.Invalidate_Routine_Instance
                          (Types.all, Instance);
                     end if;
                     raise;
               end;
            end;
         end;
      end Instantiate_Generic_Call;

      ------------------------------------------------------------
      --  A literal's value, and whether the type holds it
      ------------------------------------------------------------

      procedure Check_Literal
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Ty.Scalar_Name;
         Negated : Boolean)
      is
         Snap  : constant Landin.Source.Snapshot :=
           Source (Context, Syn.Source_Of (Of_Tree));
         Text  : constant String :=
           Landin.Source.Slice (Snap, Syn.Digit_Span (Of_Tree, Node));
         Value      : Ty.Magnitude;
         Overflowed : Boolean;
      begin
         --  [1890]: a bool has no arithmetic, so a number is never one.
         if Wanted not in Ty.Integer_Name then
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "this is a number, and " & Shown (Wanted)
                          & " holds no number",
               Note    => "[1890]: a bool has no arithmetic and no"
                          & " bitwise set",
               Related => Syn.Origin (Of_Tree, Node),
               Because => "written here",
               Into    => Found);
            return;
         end if;

         Ty.Evaluate (Text, Syn.Base (Of_Tree, Node), Value, Overflowed);

         if Overflowed
           or else not Ty.Fits (Value, Wanted, Facts, Negated)
         then
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
            Bad.Report
              (Item    => Bad.Literal_Out_Of_Range,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "no " & Shown (Wanted) & " holds this value",
               Note    => "[1880]: a literal takes the type of its context"
                          & " and is checked there",
               Into    => Found);
         end if;
      end Check_Literal;

      --  [1880]: a context reaches inward through the arithmetic, bitwise,
      --  shift and unary levels.  The walk prunes at the first node that
      --  already has a type of its own, so a mixed expression stops at
      --  once.
      procedure Commit_To
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Ty.Scalar_Name) is
      begin
         if Node = Syn.No_Node
           or else Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                   /= Ty.Untyped_Integer
         then
            return;
         end if;

         Landin.Checking.Commit (Types.all, Of_Tree, Node, Wanted);

         if Syn.Kind (Of_Tree, Node) = Syn.Integer_Literal then
            Check_Literal (Of_Tree, Node, Wanted, Negated => False);
            return;
         end if;

         --  [1880]: a unary minus is part of the value the range check
         --  reads, which is what makes -128 the smallest i8.
         if Syn.Kind (Of_Tree, Node) = Syn.Negation
           and then Syn.Kind (Of_Tree, Syn.Operand_Of (Of_Tree, Node))
                    = Syn.Integer_Literal
         then
            declare
               Under : constant Syn.Node_Id :=
                 Syn.Operand_Of (Of_Tree, Node);
            begin
               Landin.Checking.Commit (Types.all, Of_Tree, Under, Wanted);
               Check_Literal (Of_Tree, Under, Wanted, Negated => True);
            end;
            return;
         end if;

         for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            Commit_To (Of_Tree, Syn.Slot (Of_Tree, Node, Position), Wanted);
         end loop;
      end Commit_To;

      ------------------------------------------------------------
      --  Requiring a type of a position
      ------------------------------------------------------------

      procedure Require
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Ty.Type_Kind;
         Site    : Landin.Provenance.Origin;
         Because : String)
      is
         Got : Ty.Type_Kind;
      begin
         if Node = Syn.No_Node then
            return;
         end if;

         if Syn.Kind (Of_Tree, Node)
              in Syn.If_Statement | Syn.Match_Statement | Syn.Bare_Block
           and then Wanted in Ty.Scalar_Name
         then
            Check_Contextual_Value
              (Of_Tree, Node, (Kind => Wanted, others => <>),
               Site, Because);
            return;
         end if;

         Got := Synthesise (Of_Tree, Node);

         if not Decidable (Wanted) or else not Decidable (Got) then
            return;
         end if;

         --  [1880]: this is the only way a literal ever gets a type.
         if Got = Ty.Untyped_Integer then
            if Wanted in Ty.Integer_Name then
               Commit_To (Of_Tree, Node, Wanted);
            else
               Commit_To (Of_Tree, Node, Ty.Bool);
            end if;

            return;
         end if;

         if Wanted = Ty.Untyped_Integer then
            return;
         end if;

         if Got /= Wanted then
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "this is " & Shown (Got) & " and "
                          & Shown (Wanted) & " belongs here",
               Note    => "[1890]: two types that must agree, and [0310]"
                          & " converts nothing between them",
               Related => Site,
               Because => Because,
               Into    => Found);
         end if;
      end Require;

      procedure Require_Atom
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Landin.Checking.Atom_Set_Id;
         Site    : Landin.Provenance.Origin;
         Because : String)
      is
         Got : Ty.Type_Kind;
      begin
         if Node = Syn.No_Node then
            return;
         end if;

         if Syn.Kind (Of_Tree, Node)
              in Syn.If_Statement | Syn.Match_Statement | Syn.Bare_Block
         then
            Check_Contextual_Value
              (Of_Tree, Node,
               (Kind => Ty.Atom_Value, Atoms => Wanted, others => <>),
               Site, Because);
            return;
         end if;

         Got := Synthesise (Of_Tree, Node);
         if Got = Ty.Ill_Typed then
            return;
         end if;

         if Got /= Ty.Atom_Value
           or else not Landin.Checking.Is_Subset
             (Types.all,
              Landin.Checking.Atom_Set_Of (Types.all, Of_Tree, Node),
              Wanted)
         then
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "this is not an atom admitted by the set"
                          & " required here",
               Note    => "[0640]: an atom value may widen only into a"
                          & " union that contains its identity",
               Related => Site,
               Because => Because,
               Into    => Found);
         end if;
      end Require_Atom;

      ------------------------------------------------------------
      --  Asking a node what type it has
      ------------------------------------------------------------

      --  [1890]: every binary operator takes two operands of one type.
      --  Which one is decided by whichever side already has a type; when
      --  neither does, the whole node is untyped and its context settles
      --  it, which is what makes `1 + 2` an i32 in a discard [0200] and a
      --  u8 in a u8 binding.
      function Synthesise_Binary
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind
      is
         Of_Kind    : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
         Comparing  : constant Boolean :=
           Of_Kind in Syn.Equal_To .. Syn.Greater_Or_Equal;
         Left       : constant Syn.Node_Id := Syn.Left_Of (Of_Tree, Node);
         Right      : constant Syn.Node_Id := Syn.Right_Of (Of_Tree, Node);
         Left_Type  : constant Ty.Type_Kind := Synthesise (Of_Tree, Left);
         Right_Type : constant Ty.Type_Kind := Synthesise (Of_Tree, Right);
         Decided    : Ty.Type_Kind;
      begin
         if not Decidable (Left_Type) or else not Decidable (Right_Type)
         then
            return Ty.Ill_Typed;
         end if;

         if Comparing
           and then Left_Type = Ty.Function_Value
           and then Right_Type = Ty.Function_Value
           and then not Signatures_Agree
             (Landin.Checking.Signature_Of (Types.all, Of_Tree, Left),
              Landin.Checking.Signature_Of (Types.all, Of_Tree, Right))
         then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Right),
               Message => "these function values have different signatures",
               Note    => "[1000]: a function value's complete signature"
                          & " is its type",
               Related => Syn.Origin (Of_Tree, Left),
               Because => "the function compared here",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Right);
            return Ty.Ill_Typed;
         end if;

         if Left_Type = Ty.Atom_Value or else Right_Type = Ty.Atom_Value then
            if Left_Type = Ty.Atom_Value
              and then Right_Type = Ty.Atom_Value
              and then Of_Kind in Syn.Equal_To | Syn.Not_Equal_To
            then
               return Ty.Bool;
            end if;

            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Anchor (Of_Tree, Node),
               Message => "atoms support identity comparison with `==` or"
                          & " `<>` only",
               Note    => "[0630]: an atom has identity without payload",
               Related => Syn.Origin (Of_Tree, Left),
               Because => "the atom used here",
               Into    => Found);
            return Ty.Ill_Typed;
         end if;

         if Left_Type = Ty.Untyped_Integer
           and then Right_Type = Ty.Untyped_Integer
         then
            --  Nothing here has a type yet.  A comparison has one anyway,
            --  because [1890] says it gives a bool back, so its operands
            --  take [0200]'s default and the node is a bool.
            if not Comparing then
               return Ty.Untyped_Integer;
            end if;

            Commit_To (Of_Tree, Left, Ty.Default_Integer);
            Commit_To (Of_Tree, Right, Ty.Default_Integer);
            return Ty.Bool;
         end if;

         Decided :=
           (if Left_Type = Ty.Untyped_Integer then Right_Type
            else Left_Type);

         --  [1890]: only a comparison takes a bool, and it takes two.
         if not Comparing and then Decided not in Ty.Integer_Name then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Anchor (Of_Tree, Node),
               Message => "this operator wants numbers and was given "
                          & Shown (Decided),
               Note    => "[1890]: an integer has no logical words and a"
                          & " bool has no arithmetic",
               Related => Syn.Origin (Of_Tree, Node),
               Because => "here",
               Into    => Found);
            return Ty.Ill_Typed;
         end if;

         Require
           (Of_Tree, Left, Decided, Syn.Origin (Of_Tree, Node),
            "required by this operator");
         Require
           (Of_Tree, Right, Decided, Syn.Origin (Of_Tree, Node),
            "required by this operator");

         return (if Comparing then Ty.Bool else Decided);
      end Synthesise_Binary;

      function Signatures_Agree
        (Left, Right : Landin.Checking.Signature_Id) return Boolean
        is (Landin.Checking.Signatures_Agree (Types.all, Left, Right));

      --  [1920]: a call names every parameter exactly once and in order,
      --  each argument has its parameter's type, and the call has the type
      --  of the named return.
      function Check_Call
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Signature : Landin.Checking.Signature_Id) return Ty.Type_Kind
      is
         Wanted : constant Natural :=
           Landin.Checking.Signature_Parameter_Count
             (Types.all, Signature);
         Given  : constant Natural := Syn.Argument_Count (Of_Tree, Node);
         Result_Count : constant Natural :=
           Landin.Checking.Signature_Result_Count (Types.all, Signature);
         Result : constant Landin.Checking.Signature_Part :=
           (if Result_Count = 1
            then Landin.Checking.Nth_Signature_Result
              (Types.all, Signature, 1)
            else (Kind => Ty.No_Value, others => <>));
      begin
         if Given /= Wanted then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "this call gives " & Counted (Given, "argument")
                          & " and the function takes "
                          & Counted (Wanted, "argument"),
               Note    => "[1920]: a call names every parameter exactly"
                          & " once and in order",
               Related => Landin.Checking.Signature_Origin
                            (Types.all, Signature),
               Because => "the signature written here",
               Into    => Found);
            return Ty.Ill_Typed;
         end if;

         for Which in 1 .. Wanted loop
            declare
               Parameter : constant Landin.Checking.Signature_Part :=
                 Landin.Checking.Nth_Signature_Parameter
                   (Types.all, Signature, Which);
               Wants : constant Ty.Type_Kind :=
                 Parameter.Kind;
               Argument : constant Syn.Node_Id :=
                 Syn.Nth_Argument (Of_Tree, Node, Which);
            begin
               if Wants in Ty.Aggregate | Ty.Fixed_Array | Ty.Function_Value
                              | Ty.Atom_Value
                 and then Syn.Kind (Of_Tree, Argument)
                            in Syn.If_Statement | Syn.Match_Statement
                               | Syn.Bare_Block
               then
                  declare
                     Expected : Value_Context := (Kind => Wants, others => <>);
                  begin
                     case Wants is
                        when Ty.Aggregate =>
                           Expected.Nominal := Parameter.Nominal;
                        when Ty.Fixed_Array =>
                           Expected.Length := Parameter.Length;
                           Expected.Element := Parameter.Element;
                           Expected.Element_Nominal := Parameter.Nominal;
                        when Ty.Function_Value =>
                           Expected.Signature := Parameter.Signature;
                        when Ty.Atom_Value =>
                           Expected.Atoms := Parameter.Atoms;
                        when others =>
                           raise Landin.Compiler_Defect;
                     end case;
                     Check_Contextual_Value
                       (Of_Tree, Argument, Expected, Parameter.Site,
                        "this parameter");
                  end;
               elsif Wants = Ty.Atom_Value then
                  Require_Atom
                    (Of_Tree, Argument, Parameter.Atoms, Parameter.Site,
                     "this atom-valued parameter");
               elsif Wants = Ty.Function_Value then
                  declare
                     Got : constant Ty.Type_Kind :=
                       Synthesise (Of_Tree, Argument);
                  begin
                     if Got = Ty.Function_Value
                       and then not Signatures_Agree
                         (Parameter.Signature,
                          Landin.Checking.Signature_Of
                            (Types.all, Of_Tree, Argument))
                     then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Argument),
                           Message => "this function argument has a"
                                      & " different signature",
                           Note    => "[1000]: a function value's complete"
                                      & " signature is its type",
                           Related => Parameter.Site,
                           Because => "this function-valued parameter",
                           Into    => Found);
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Argument);
                     elsif Got /= Ty.Function_Value then
                        Require
                          (Of_Tree, Argument, Wants, Parameter.Site,
                           "this function-valued parameter");
                     end if;
                  end;
               elsif Wants = Ty.Aggregate
                 and then Syn.Kind (Of_Tree, Argument) = Syn.Struct_Literal
               then
                  declare
                     Expected : constant Landin.Checking.Nominal_Type_Id :=
                       Parameter.Nominal;
                     Leaf_Only : Boolean := True;
                  begin
                     for Field in
                       1 .. Landin.Checking.Layout_Field_Count
                              (Types.all, Expected)
                     loop
                        Leaf_Only := Leaf_Only
                          and then Landin.Checking.Field_Kind_Of
                            (Types.all, Expected, Field)
                              in Landin.Checking.Scalar_Field
                                 | Landin.Checking.Fixed_Array_Field
                                 | Landin.Checking.Aggregate_Field
                                 | Landin.Checking.Variant_Field;
                     end loop;

                     if Leaf_Only
                       and then Construction_Agrees
                         (Of_Tree, Argument, Expected,
                          Parameter.Site,
                          "this parameter")
                     then
                        Check_Struct_Literal
                          (Of_Tree, Argument, Expected,
                           Static_Image => False);
                     else
                        Require
                          (Of_Tree, Argument, Wants,
                           Parameter.Site,
                           "this parameter");
                     end if;
                  end;
               elsif Wants = Ty.Fixed_Array
                 and then Syn.Kind (Of_Tree, Argument)
                            in Syn.Array_Literal | Syn.Array_Repetition
                               | Syn.Mixed_Array_Repetition
               then
                  declare
                     Expected : constant Landin.Checking.Element_Count :=
                       Parameter.Length;
                     Element : constant Ty.Scalar_Name := Parameter.Element;
                  begin
                     case Syn.Kind (Of_Tree, Argument) is
                        when Syn.Array_Literal =>
                           Check_Array_Literal
                             (Of_Tree, Node, Argument,
                              Expected, Element, Static_Image => False,
                              Context_Site => Parameter.Site);
                        when Syn.Array_Repetition =>
                           Check_Array_Repetition
                             (Of_Tree, Node, Argument,
                              Expected, Element, Static_Image => False,
                              Context_Site => Parameter.Site);
                        when Syn.Mixed_Array_Repetition =>
                           Check_Mixed_Array_Repetition
                             (Of_Tree, Node, Argument,
                              Expected, Element, Static_Image => False,
                              Context_Site => Parameter.Site);
                        when others =>
                           raise Landin.Compiler_Defect;
                     end case;
                  end;
               elsif Wants in Ty.Aggregate | Ty.Fixed_Array
                 and then Syn.Kind (Of_Tree, Argument) = Syn.Zeroed_Literal
               then
                  Landin.Checking.Note
                    (Types.all, Of_Tree, Argument, Wants);
                  if Wants = Ty.Aggregate then
                        Landin.Checking.Note_Nominal
                          (Types.all, Of_Tree, Argument,
                           Parameter.Nominal);
                  else
                        Landin.Checking.Note_Array
                          (Types.all, Of_Tree, Argument,
                           Parameter.Length, Parameter.Element);
                  end if;
               elsif Wants in Ty.Aggregate | Ty.Fixed_Array
                 and then Syn.Kind (Of_Tree, Argument)
                            in Syn.Name_Reference | Syn.Member_Selection
                               | Syn.Element_Index | Syn.Call
               then
                  declare
                     Got : constant Ty.Type_Kind :=
                       (if Syn.Kind (Of_Tree, Argument) = Syn.Call
                        then Synthesise (Of_Tree, Argument)
                        elsif Wants = Ty.Fixed_Array
                          and then Syn.Kind (Of_Tree, Argument)
                                     = Syn.Member_Selection
                        then (if Admit_Array_Field (Of_Tree, Argument)
                              then Ty.Fixed_Array else Ty.Ill_Typed)
                        else Selected_From (Of_Tree, Argument));
                     Expected : constant Landin.Checking.Nominal_Type_Id :=
                       Parameter.Nominal;
                     Actual : constant Landin.Checking.Nominal_Type_Id :=
                       Landin.Checking.Nominal_Of
                         (Types.all, Of_Tree, Argument);
                  begin
                     if Got = Ty.Aggregate and then Actual /= Expected then
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Argument);
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Argument),
                           Message => "this argument has a different struct"
                                      & " type",
                           Note    => "[0710]: ordinary structs are nominal",
                           Related => Parameter.Site,
                           Because => "this parameter",
                           Into    => Found);
                     elsif Got = Ty.Fixed_Array
                       and then
                         (Landin.Checking.Array_Length
                            (Types.all, Of_Tree, Argument)
                            /= Parameter.Length
                          or else Landin.Checking.Array_Element
                            (Types.all, Of_Tree, Argument)
                            /= Parameter.Element)
                     then
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Argument);
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Argument),
                           Message => "this argument has a different array"
                                      & " shape",
                           Note    => "D17: a fixed array is its length and"
                                      & " scalar element type",
                           Related => Parameter.Site,
                           Because => "this parameter",
                           Into    => Found);
                     elsif Got /= Wants then
                        Require
                          (Of_Tree, Argument, Wants,
                           Parameter.Site,
                           "this parameter");
                     end if;
                  end;
               else
                  Require
                    (Of_Tree, Argument, Wants,
                     Parameter.Site,
                     "this parameter");
               end if;
            end;
         end loop;

         if Syn.Recovery_Of (Of_Tree, Node) /= Syn.No_Node
           and then Landin.Checking.Signature_Error_Form
             (Types.all, Signature) /= Landin.Checking.Inferred
           and then
             (Syn.Name
                (Of_Tree, Syn.Recovery_Of (Of_Tree, Node))
                = Landin.Source.Names.No_Name
              or else Landin.Checking.State_Of
                (Types.all,
                 Declaration_At
                   (Syn.Source_Of (Of_Tree),
                    Syn.Recovery_Of (Of_Tree, Node)))
                  /= Landin.Checking.Untouched)
         then
            declare
               Recovery : constant Syn.Node_Id :=
                 Syn.Recovery_Of (Of_Tree, Node);
               Recovery_Body : constant Syn.Node_Id :=
                 Syn.Else_Body (Of_Tree, Recovery);
               Errors : constant Landin.Checking.Atom_Set_Id :=
                 Landin.Checking.Signature_Errors (Types.all, Signature);
               Expected : Value_Context :=
                 (Kind => (if Result_Count > 1 then Ty.Aggregate
                           else Result.Kind),
                  Result_Shape =>
                    (if Result_Count > 1 then Signature
                     else Landin.Checking.No_Signature),
                  others => <>);
               Result_Site : constant Landin.Provenance.Origin :=
                 (if Result_Count = 1 then Result.Site
                  else Landin.Checking.Signature_Origin
                    (Types.all, Signature));
            begin
               if Errors = Landin.Checking.No_Atom_Set then
                  Bad.Report
                    (Item    => Bad.Type_Mismatch,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Recovery),
                     Message => "this call cannot fail, so it has no error"
                                & " for `else` to handle",
                     Note    => "[1030]: call-site `else` handles only the"
                                & " declared error channel",
                     Related => Landin.Checking.Signature_Origin
                       (Types.all, Signature),
                     Because => "this infallible signature",
                     Into    => Found);
               end if;

               if Result_Count = 1 then
                  case Result.Kind is
                     when Ty.Atom_Value =>
                        Expected.Atoms := Result.Atoms;
                     when Ty.Aggregate =>
                        Expected.Nominal := Result.Nominal;
                     when Ty.Fixed_Array =>
                        Expected.Length := Result.Length;
                        Expected.Element := Result.Element;
                        Expected.Element_Nominal := Result.Nominal;
                     when Ty.Function_Value =>
                        Expected.Signature := Result.Signature;
                     when others =>
                        null;
                  end case;
               end if;

               if Syn.Kind (Of_Tree, Recovery_Body) = Syn.Block then
                  if Result_Count = 0 then
                     Check_Block (Of_Tree, Recovery_Body, Ty.No_Value);
                  else
                     Check_Block
                       (Of_Tree, Recovery_Body, Expected.Kind, Expected,
                        Result_Site, "the successful call result");
                  end if;
               else
                  Check_Contextual_Value
                    (Of_Tree, Recovery_Body, Expected, Result_Site,
                     "the successful call result");
               end if;
            end;
         end if;

         if Result_Count = 0 then
            return Ty.No_Value;
         elsif Result_Count > 1 then
            Landin.Checking.Note_Result_Shape
              (Types.all, Of_Tree, Node, Signature);
            return Ty.Aggregate;
         end if;

         if Result.Kind = Ty.Atom_Value then
            Landin.Checking.Note_Atom_Set
              (Types.all, Of_Tree, Node, Result.Atoms);
         elsif Result.Kind = Ty.Aggregate then
            Landin.Checking.Note_Nominal
              (Types.all, Of_Tree, Node, Result.Nominal);
         elsif Result.Kind = Ty.Fixed_Array then
            Landin.Checking.Note_Array
              (Types.all, Of_Tree, Node, Result.Length, Result.Element);
         elsif Result.Kind = Ty.Function_Value then
            Landin.Checking.Note_Signature
              (Types.all, Of_Tree, Node, Result.Signature);
         end if;
         return Result.Kind;
      end Check_Call;

      --  [1950]'s third row.  An index the compiler knows is refused when
      --  it is outside the length, and one it does not know is left to the
      --  trap the backend emits -- which is what the divisor and the shift
      --  amount already do, in the same paragraph and for the same reason.
      --  Known is [1880]'s: a literal, or a unary minus over one.
      procedure Check_Index_Bound
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         From    : Syn.Node_Id;
         Where   : Syn.Node_Id);

      --  Which field of an aggregate a name selects, by [0750]'s order,
      --  or zero when the aggregate has no field of that name.  The names
      --  are read from the struct body the identity names rather than
      --  kept beside the layout: a field's name is a fact about the
      --  source and Landin.Checking holds what a thing's type is.
      function Field_At
        (Wrote : Landin.Checking.Nominal_Type_Id;
         Named : Landin.Source.Names.Name_Id) return Natural;

      --  How a field of that struct is spelt, by [0750]'s order.  The
      --  other direction of Field_At, and read from the same body.
      function Field_Named
        (Wrote : Landin.Checking.Nominal_Type_Id;
         Index : Positive) return String;

      function Result_Field_At
        (Shape : Landin.Checking.Signature_Id;
         Named : Landin.Source.Names.Name_Id) return Natural;

      function Note_Result_Field
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Shape   : Landin.Checking.Signature_Id;
         Which   : Positive) return Ty.Type_Kind;

      function Note_Struct_Field
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wrote   : Landin.Checking.Nominal_Type_Id;
         Which   : Positive) return Ty.Type_Kind;

      function Field_At
        (Wrote : Landin.Checking.Nominal_Type_Id;
         Named : Landin.Source.Names.Name_Id) return Natural
      is
         Template : constant Res.Declaration_Id :=
           Landin.Checking.Template_Of (Types.all, Wrote);
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Template));
         Node : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Template);
         Written : constant Syn.Node_Id :=
           Syn.Declared_Type (Of_Tree.all, Node);
      begin
         if Written = Syn.No_Node
           or else Syn.Kind (Of_Tree.all, Written) /= Syn.Struct_Body
         then
            return 0;
         end if;

         for Index in 1 .. Syn.Field_Count (Of_Tree.all, Written) loop
            if Syn.Name
                 (Of_Tree.all,
                  Syn.Nth_Field (Of_Tree.all, Written, Index)) = Named
            then
               return Index;
            end if;
         end loop;

         return 0;
      end Field_At;

      function Field_Named
        (Wrote : Landin.Checking.Nominal_Type_Id;
         Index : Positive) return String
      is
         Template : constant Res.Declaration_Id :=
           Landin.Checking.Template_Of (Types.all, Wrote);
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Template));
         Node : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Template);
         Written : constant Syn.Node_Id :=
           Syn.Declared_Type (Of_Tree.all, Node);
      begin
         if Written = Syn.No_Node
           or else Syn.Kind (Of_Tree.all, Written) /= Syn.Struct_Body
           or else Index > Syn.Field_Count (Of_Tree.all, Written)
         then
            return "";
         end if;

         return Spelled
                  (Syn.Name
                     (Of_Tree.all,
                      Syn.Nth_Field (Of_Tree.all, Written, Index)));
      end Field_Named;

      function Result_Field_At
        (Shape : Landin.Checking.Signature_Id;
         Named : Landin.Source.Names.Name_Id) return Natural
      is
      begin
         for Index in
           1 .. Landin.Checking.Signature_Result_Count (Types.all, Shape)
         loop
            if Landin.Checking.Nth_Signature_Result
                 (Types.all, Shape, Index).Name = Named
            then
               return Index;
            end if;
         end loop;
         return 0;
      end Result_Field_At;

      function Note_Result_Field
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Shape   : Landin.Checking.Signature_Id;
         Which   : Positive) return Ty.Type_Kind
      is
         Part : constant Landin.Checking.Signature_Part :=
           Landin.Checking.Nth_Signature_Result
             (Types.all, Shape, Which);
      begin
         if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
              = Ty.Undecided
         then
            Landin.Checking.Note (Types.all, Of_Tree, Node, Part.Kind);
         end if;
         Landin.Checking.Note_Field (Types.all, Of_Tree, Node, Which);
         case Part.Kind is
            when Ty.Aggregate =>
               Landin.Checking.Note_Nominal
                 (Types.all, Of_Tree, Node, Part.Nominal);
            when Ty.Fixed_Array =>
               Landin.Checking.Note_Array
                 (Types.all, Of_Tree, Node, Part.Length, Part.Element);
               Landin.Checking.Note_Array_Element_Nominal
                 (Types.all, Of_Tree, Node, Part.Nominal);
            when Ty.Function_Value =>
               Landin.Checking.Note_Signature
                 (Types.all, Of_Tree, Node, Part.Signature);
            when Ty.Atom_Value =>
               Landin.Checking.Note_Atom_Set
                 (Types.all, Of_Tree, Node, Part.Atoms);
            when others =>
               null;
         end case;
         return Part.Kind;
      end Note_Result_Field;

      function Note_Struct_Field
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wrote   : Landin.Checking.Nominal_Type_Id;
         Which   : Positive) return Ty.Type_Kind
      is
         Shape : constant Landin.Checking.Field_Shape :=
           Landin.Checking.Field_Shape_Of
             (Types.all, Wrote, Which);
      begin
         Landin.Checking.Note_Field (Types.all, Of_Tree, Node, Which);
         if Shape.Kind = Landin.Checking.Scalar_Field
           and then Shape.Signature /= Landin.Checking.No_Signature
         then
            if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                 = Ty.Undecided
            then
               Landin.Checking.Note
                 (Types.all, Of_Tree, Node, Ty.Function_Value);
               Landin.Checking.Note_Signature
                 (Types.all, Of_Tree, Node, Shape.Signature);
            end if;
            return Ty.Function_Value;
         end if;

         pragma Assert (Shape.Kind = Landin.Checking.Scalar_Field);
         if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
              = Ty.Undecided
         then
            Landin.Checking.Note
              (Types.all, Of_Tree, Node, Shape.Element);
         end if;
         return Shape.Element;
      end Note_Struct_Field;

      function Field_Has_Zero_Image
        (Wrote : Landin.Checking.Nominal_Type_Id;
         Field : Positive) return Boolean
      is
         Shape : constant Landin.Checking.Field_Shape :=
           Landin.Checking.Field_Shape_Of
             (Types.all, Wrote, Field);

         function Shape_Has_Zero
           (Part : Landin.Checking.Field_Shape) return Boolean
         is (case Part.Kind is
                when Landin.Checking.Scalar_Field =>
                  Part.Signature = Landin.Checking.No_Signature,
                when Landin.Checking.Fixed_Array_Field =>
                  Part.Length = 0
                  or else Part.Nominal = Landin.Checking.No_Nominal_Type
                  or else Has_Zero_Image (Part.Nominal),
                when Landin.Checking.Aggregate_Field =>
                  Has_Zero_Image (Part.Nominal),
                when Landin.Checking.Variant_Field => False);
      begin
         if Shape.Kind /= Landin.Checking.Variant_Field then
            return Shape_Has_Zero (Shape);
         end if;

         --  All-zero selects source-order case one.  Inactive union bytes
         --  need not denote values of any other case.
         for Payload in 1 .. Landin.Checking.Variant_Case_Field_Count
           (Types.all, Wrote, Field, 1)
         loop
            if not Shape_Has_Zero
              (Landin.Checking.Nth_Variant_Case_Field
                 (Types.all, Wrote, Field, 1, Payload))
            then
               return False;
            end if;
         end loop;
         return True;
      end Field_Has_Zero_Image;

      function Has_Zero_Image
        (Wrote : Landin.Checking.Nominal_Type_Id) return Boolean
      is
      begin
         if Wrote = Landin.Checking.No_Nominal_Type
           or else not Landin.Checking.Has_Layout (Types.all, Wrote)
         then
            return False;
         end if;
         for Field in 1 .. Landin.Checking.Layout_Field_Count
           (Types.all, Wrote)
         loop
            if not Field_Has_Zero_Image (Wrote, Field) then
               return False;
            end if;
         end loop;
         return True;
      end Has_Zero_Image;

      procedure Check_Aggregate_Zeroed
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wrote   : Landin.Checking.Nominal_Type_Id;
         Site    : Landin.Provenance.Origin;
         Because : String) is
      begin
         if not Has_Zero_Image (Wrote) then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "this struct has no all-bits-zero value",
               Note    => "[0540]: a function address has no zero image,"
                          & " so neither does a value that contains one",
               Related => Site,
               Because => Because,
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
            return;
         end if;
         Landin.Checking.Note
           (Types.all, Of_Tree, Node, Ty.Aggregate);
         Landin.Checking.Note_Nominal
           (Types.all, Of_Tree, Node, Wrote);
      end Check_Aggregate_Zeroed;

      procedure Check_Array_Zeroed
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Length  : Landin.Checking.Element_Count;
         Element : Ty.Scalar_Name;
         Element_Nominal : Landin.Checking.Nominal_Type_Id;
         Site    : Landin.Provenance.Origin;
         Because : String) is
      begin
         if Length > 0
           and then Element_Nominal /= Landin.Checking.No_Nominal_Type
           and then not Has_Zero_Image (Element_Nominal)
         then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "this array has no all-bits-zero value",
               Note    => "[0540]: its struct element contains a function"
                          & " address, which has no zero image",
               Related => Site,
               Because => Because,
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
            return;
         end if;
         Landin.Checking.Note
           (Types.all, Of_Tree, Node, Ty.Fixed_Array);
         Landin.Checking.Note_Array
           (Types.all, Of_Tree, Node, Length, Element);
         if Element_Nominal /= Landin.Checking.No_Nominal_Type then
            Landin.Checking.Note_Array_Element_Nominal
              (Types.all, Of_Tree, Node, Element_Nominal);
         end if;
      end Check_Array_Zeroed;

      procedure Check_Index_Bound
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         From    : Syn.Node_Id;
         Where   : Syn.Node_Id)
      is
         Length : constant Landin.Checking.Element_Count :=
           Landin.Checking.Array_Length (Types.all, Of_Tree, From);
         Negated : constant Boolean :=
           Syn.Kind (Of_Tree, Where) = Syn.Negation;
         Literal : constant Syn.Node_Id :=
           (if Negated then Syn.Operand_Of (Of_Tree, Where) else Where);
      begin
         if Syn.Kind (Of_Tree, Literal) /= Syn.Integer_Literal then
            --  [1950] leaves this one to the runtime bounds check.  It is
            --  not folded here: [1880]'s known line stays a literal or a
            --  unary minus over one, independent of compiler cleverness.
            return;
         end if;

         declare
            Snap : constant Landin.Source.Snapshot :=
              Source (Context, Syn.Source_Of (Of_Tree));
            Text : constant String :=
              Landin.Source.Slice (Snap, Syn.Digit_Span (Of_Tree, Literal));
            Value      : Ty.Magnitude;
            Overflowed : Boolean;
         begin
            Ty.Evaluate
              (Text, Syn.Base (Of_Tree, Literal), Value, Overflowed);

            --  D18's `usize` context has already refused every negative
            --  value.  `-0` survives because its value is zero, which an
            --  array with any element at all has.
            if not Overflowed
              and then (not Negated or else Value = 0)
              and then Value < Ty.Magnitude (Length)
            then
               return;
            end if;

            Bad.Report
              (Item    => Bad.Impossible_Operand,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Where),
               Message => "this index is outside the "
                          & Written (Ty.Folded (Length))
                          & " this array has",
               Note    => "[1950]: an index the compiler knows is refused"
                          & " where it cannot be taken, and one it does"
                          & " not know traps",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
         end;
      end Check_Index_Bound;

      --  The type of a place, and of what a selection selects from.
      --  Separate from Synthesise because a bare aggregate name is a
      --  value this kernel refuses in an expression, while the same name
      --  is how a field is reached and how a whole struct is copied.
      --  D48 first admits a fixed-array field in the one context that names
      --  one of its elements.  Keeping this separate from Selected_From
      --  leaves the field itself refused as a general value or place while
      --  D49/D50 add two assignment contexts explicitly.
      function Indexed_From
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind;

      function Is_Direct_Module_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Is_Module_Array_Field
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Length  : Landin.Checking.Element_Count;
         Element : Ty.Scalar_Name) return Boolean;

      --  D49/D50 admit that same fixed-array field as a whole place only
      --  when assignment supplies `zeroed` or another fixed-array storage
      --  endpoint as its complete contextual value.  D51 reuses the note for
      --  a local initializer source; the local/module gates remain at those
      --  contextual callers.
      --  This predicate notes the field shape when that exact place exists;
      --  it reports nothing and leaves every other selection for the
      --  ordinary place checker, so root mutability and field diagnostics
      --  keep their existing ownership.
      function Is_Direct_Array_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Selected_From
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind is
      begin
         --  D88 admits a depth-one ordinary child only as the base of a
         --  further field selection.  Synthesise still refuses the child as
         --  a general aggregate value; this path-bearing question records
         --  both declaration-order identities and the child's nominal body.
         if Syn.Kind (Of_Tree, Node) = Syn.Member_Selection then
            declare
               From : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
               Held : constant Ty.Type_Kind := Selected_From (Of_Tree, From);
            begin
               if Held = Ty.Aggregate then
                  declare
                     Shape : constant Landin.Checking.Signature_Id :=
                       Landin.Checking.Result_Shape_Of
                         (Types.all, Of_Tree, From);
                     Which : constant Natural :=
                       (if Shape = Landin.Checking.No_Signature then 0
                        else Result_Field_At
                          (Shape, Syn.Name (Of_Tree, Node)));
                  begin
                     if Which > 0 then
                        return Note_Result_Field
                          (Of_Tree, Node, Shape, Positive (Which));
                     end if;
                  end;

                  declare
                     Wrote : constant Landin.Checking.Nominal_Type_Id :=
                       Landin.Checking.Nominal_Of (Types.all, Of_Tree, From);
                     Which : constant Natural :=
                       (if Wrote = Landin.Checking.No_Nominal_Type then 0
                        else Field_At (Wrote, Syn.Name (Of_Tree, Node)));
                  begin
                     if Which > 0
                       and then Landin.Checking.Has_Layout (Types.all, Wrote)
                       and then Landin.Checking.Field_Kind_Of
                                  (Types.all, Wrote, Which)
                                = Landin.Checking.Aggregate_Field
                     then
                        declare
                           Child : constant Landin.Checking.Nominal_Type_Id :=
                             Landin.Checking.Field_Shape_Of
                               (Types.all, Wrote, Which).Nominal;
                        begin
                           if Landin.Checking.Type_Of
                                (Types.all, Of_Tree, Node) = Ty.Undecided
                           then
                              Landin.Checking.Note
                                (Types.all, Of_Tree, Node, Ty.Aggregate);
                              Landin.Checking.Note_Field
                                (Types.all, Of_Tree, Node, Which);
                              Landin.Checking.Note_Nominal
                                (Types.all, Of_Tree, Node, Child);
                           end if;
                           return Ty.Aggregate;
                        end;
                     end if;
                  end;
               end if;
            end;
         end if;

         --  D121: an element of an array of ordinary structs is a struct,
         --  so a selection may start from one.  Synthesise settles its
         --  index and its [0710] identity; this only carries the answer.
         if Syn.Kind (Of_Tree, Node) = Syn.Element_Index then
            declare
               Held : constant Ty.Type_Kind := Synthesise (Of_Tree, Node);
            begin
               return Held;
            end;
         end if;

         if Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
         then
            declare
               Means : constant Res.Declaration_Id :=
                 Res.Bound_To (Meanings.all, Of_Tree, Node);
               Held  : constant Ty.Type_Kind := Settled_Type (Means);
            begin
               if Held = Ty.Aggregate then
                  if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                     = Ty.Undecided
                  then
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Node, Held);
                     if Landin.Checking.Result_Shape_Of
                          (Types.all, Means) /= Landin.Checking.No_Signature
                     then
                        Landin.Checking.Note_Result_Shape
                          (Types.all, Of_Tree, Node,
                           Landin.Checking.Result_Shape_Of
                             (Types.all, Means));
                     else
                        Landin.Checking.Note_Nominal
                          (Types.all, Of_Tree, Node,
                           Landin.Checking.Nominal_Of (Types.all, Means));
                     end if;
                  end if;

                  return Held;
               end if;

               --  D17: an array's identity is its shape, so a name that
               --  holds one carries the shape to wherever it is indexed.
               if Held = Ty.Ill_Typed then
                  return Held;
               end if;

               if Held = Ty.Fixed_Array then
                  if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                     = Ty.Undecided
                  then
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Node, Held);
                     Landin.Checking.Note_Array
                       (Types.all, Of_Tree, Node,
                        Landin.Checking.Array_Length (Types.all, Means),
                        Landin.Checking.Array_Element (Types.all, Means));
                     --  D121: which struct the elements are is part of
                     --  that shape.
                     Landin.Checking.Note_Array_Element_Nominal
                       (Types.all, Of_Tree, Node,
                        Landin.Checking.Array_Element_Nominal
                          (Types.all, Means));
                  end if;

                  return Held;
               end if;
            end;
         end if;

         return Synthesise (Of_Tree, Node);
      end Selected_From;

      --  An index is part of a storage chain whether it is known or computed.
      --  The checker retains its value semantics separately; this walk only
      --  finds the binding whose mutability and storage the chain uses.
      function Chain_Root_Of
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id
      is
         Where : Syn.Node_Id := Node;
      begin
         loop
            if Syn.Kind (Of_Tree, Where)
                 in Syn.Member_Selection | Syn.Element_Index
            then
               Where := Syn.Target_Of (Of_Tree, Where);
            else
               return Where;
            end if;
         end loop;
      end Chain_Root_Of;

      function Selects_From_A_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
        is (Syn.Kind (Of_Tree, Chain_Root_Of (Of_Tree, Node))
              = Syn.Name_Reference);

      function Chain_Starts_At_A_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
         Where : constant Syn.Node_Id := Chain_Root_Of (Of_Tree, Node);
      begin
         return Syn.Kind (Of_Tree, Where) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Where) = Res.Bound;
      end Chain_Starts_At_A_Name;

      --  D121's alias for an ordinary-struct payload names storage the
      --  same way a binding does, so a chain may start at one.
      function Root_Names_Storage
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
        is (Is_Aggregate_Alias_Name (Of_Tree, Node)
            or else (Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
                     and then Res.Verdict_Of
                       (Meanings.all, Of_Tree, Node) = Res.Bound
                     and then Res.Sort_Of
                       (Meanings.all,
                        Res.Bound_To (Meanings.all, Of_Tree, Node))
                         in Res.Module_Binding | Res.Local_Binding
                            | Res.Parameter | Res.Named_Return));

      function Chain_Names_Storage
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
         Where : Syn.Node_Id := Node;
      begin
         while Syn.Kind (Of_Tree, Where) = Syn.Member_Selection loop
            Where := Syn.Target_Of (Of_Tree, Where);
         end loop;
         return Root_Names_Storage (Of_Tree, Where);
      end Chain_Names_Storage;

      function Chain_Names_Element_Storage
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
         Where : Syn.Node_Id := Node;
      begin
         --  Both known and computed indexes remain inside the storage chain;
         --  only lowering decides whether a step is an identity or a checked
         --  runtime address.
         while Syn.Kind (Of_Tree, Where)
           in Syn.Member_Selection | Syn.Element_Index
         loop
            Where := Syn.Target_Of (Of_Tree, Where);
         end loop;
         return Root_Names_Storage (Of_Tree, Where);
      end Chain_Names_Element_Storage;

      function Admit_Array_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
      begin
         if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
              = Ty.Fixed_Array
         then
            return True;
         end if;

         if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
              /= Ty.Undecided
         then
            return False;
         end if;

         if Syn.Kind (Of_Tree, Node) = Syn.Member_Selection then
            declare
               From : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
            begin
               --  D118: the array field may sit under however many
               --  selections [0420] composed, so the question is whether
               --  the chain starts at a name and not how long it is.
               if Selects_From_A_Name (Of_Tree, From) then
                  declare
                     Held : constant Ty.Type_Kind :=
                       Selected_From (Of_Tree, From);
                  begin
                     if Held = Ty.Ill_Typed then
                        return False;
                     end if;

                     if Held = Ty.Aggregate then
                        declare
                           Wrote : constant Landin.Checking.Nominal_Type_Id :=
                             Landin.Checking.Nominal_Of
                               (Types.all, Of_Tree, From);
                           Which : constant Natural :=
                             (if Wrote = Landin.Checking.No_Nominal_Type then 0
                              else Field_At
                                     (Wrote, Syn.Name (Of_Tree, Node)));
                        begin
                           if Which /= 0
                             and then Landin.Checking.Has_Layout
                                        (Types.all, Wrote)
                             and then Landin.Checking.Field_Kind_Of
                                        (Types.all, Wrote, Which)
                                      = Landin.Checking.Fixed_Array_Field
                           then
                              Landin.Checking.Note
                                (Types.all, Of_Tree, Node, Ty.Fixed_Array);
                              Landin.Checking.Note_Field
                                (Types.all, Of_Tree, Node, Which);
                              Landin.Checking.Note_Array
                                (Types.all, Of_Tree, Node,
                                 Landin.Checking.Field_Array_Length
                                   (Types.all, Wrote, Which),
                                 Landin.Checking.Field_Array_Element
                                   (Types.all, Wrote, Which));
                              --  D121: an ordinary-struct element is part
                              --  of that field's shape.
                              Landin.Checking.Note_Array_Element_Nominal
                                (Types.all, Of_Tree, Node,
                                 Landin.Checking.Field_Shape_Of
                                   (Types.all, Wrote, Which)
                                     .Nominal);
                              return True;
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end;
         end if;

         return False;
      end Admit_Array_Field;

      function Admit_Variant_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
      begin
         if Syn.Kind (Of_Tree, Node) /= Syn.Member_Selection then
            return False;
         end if;

         declare
            From : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
         begin
            --  D126: the variant part may sit below however many
            --  selections [0420] composed, so what this asks is whether
            --  the chain starts at a bound name and not how long it is.
            if not Chain_Starts_At_A_Name (Of_Tree, From) then
               return False;
            end if;

            declare
               Held : constant Ty.Type_Kind := Selected_From (Of_Tree, From);
            begin
               if Held /= Ty.Aggregate then
                  return False;
               end if;

               declare
                  Wrote : constant Landin.Checking.Nominal_Type_Id :=
                    Landin.Checking.Nominal_Of (Types.all, Of_Tree, From);
                  Which : constant Natural :=
                    (if Wrote = Landin.Checking.No_Nominal_Type then 0
                     else Field_At (Wrote, Syn.Name (Of_Tree, Node)));
               begin
                  if Which = 0
                    or else not Landin.Checking.Has_Layout (Types.all, Wrote)
                    or else Landin.Checking.Field_Kind_Of
                      (Types.all, Wrote, Which)
                        /= Landin.Checking.Variant_Field
                  then
                     return False;
                  end if;

                  if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                       = Ty.Undecided
                  then
                     --  A variant part is a contextual destination, not a
                     --  general aggregate value.  Not_Typed records that
                     --  distinction while allowing Check_Place and lowering
                     --  to share the resolved field identity.
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Node, Ty.Not_Typed);
                     Landin.Checking.Note_Field
                       (Types.all, Of_Tree, Node, Which);
                  end if;
                  return True;
               end;
            end;
         end;
      end Admit_Variant_Field;

      function Is_Direct_Module_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
      begin
         return Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
           and then Syn.Kind
             (Of_Tree, Syn.Target_Of (Of_Tree, Node)) = Syn.Name_Reference
           and then Res.Verdict_Of
             (Meanings.all, Of_Tree, Syn.Target_Of (Of_Tree, Node))
               = Res.Bound
           and then Res.Sort_Of
             (Meanings.all,
              Res.Bound_To
                (Meanings.all, Of_Tree, Syn.Target_Of (Of_Tree, Node)))
               = Res.Module_Binding;
      end Is_Direct_Module_Field;

      function Is_Module_Array_Field
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Length  : Landin.Checking.Element_Count;
         Element : Ty.Scalar_Name) return Boolean
      is
      begin
         return Is_Direct_Module_Field (Of_Tree, Node)
           and then Admit_Array_Field (Of_Tree, Node)
           and then Landin.Checking.Array_Length
             (Types.all, Of_Tree, Node) = Length
           and then Landin.Checking.Array_Element
             (Types.all, Of_Tree, Node) = Element;
      end Is_Module_Array_Field;

      function Indexed_From
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind
      is
      begin
         if Admit_Array_Field (Of_Tree, Node) then
            return Ty.Fixed_Array;
         end if;

         return Selected_From (Of_Tree, Node);
      end Indexed_From;

      --  D21's inferred array initializer is deliberately narrower than an
      --  inferred value: it recognizes only a resolved direct storage name.
      --  Keeping that question here prevents Selected_From from admitting a
      --  struct name, or any expression that merely produces an array.
      function Is_Direct_Array_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
      begin
         return Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
           and then Res.Sort_Of
                      (Meanings.all,
                       Res.Bound_To (Meanings.all, Of_Tree, Node))
                    in Res.Module_Binding | Res.Local_Binding
           and then Settled_Type
                      (Res.Bound_To (Meanings.all, Of_Tree, Node))
                    = Ty.Fixed_Array;
      end Is_Direct_Array_Name;

      --  Whether this node directly names a binding that owns runtime storage.
      function Is_Direct_Binding_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Is_Direct_Binding_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
      begin
         return Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
           and then Res.Sort_Of
                      (Meanings.all,
                       Res.Bound_To (Meanings.all, Of_Tree, Node))
                    in Res.Module_Binding | Res.Local_Binding
                       | Res.Parameter | Res.Named_Return;
      end Is_Direct_Binding_Name;

      --  D120: a match alias for an ordinary-struct payload names storage
      --  the same way a binding does, so it is a copy source in every
      --  context that takes one.  It is deliberately a second question
      --  rather than a wider Is_Direct_Binding_Name: an alias is not a
      --  binding anywhere else in this checker.
      function Is_Aggregate_Alias_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
      begin
         if Syn.Kind (Of_Tree, Node) /= Syn.Name_Reference
           or else Res.Verdict_Of (Meanings.all, Of_Tree, Node) /= Res.Bound
         then
            return False;
         end if;

         declare
            Means : constant Res.Declaration_Id :=
              Res.Bound_To (Meanings.all, Of_Tree, Node);
         begin
            return Res.Sort_Of (Meanings.all, Means) = Res.Pattern_Binding
              and then Landin.Checking.Type_Of (Types.all, Means)
                         = Ty.Aggregate;
         end;
      end Is_Aggregate_Alias_Name;

      --  D41 is a direct-binding slice; D42 adds one ordinary scalar field or
      --  fixed-array element selected immediately from that storage.  D62
      --  adds the scalar element of a D48 fixed-array field.  D43 adds a
      --  direct named return, but not one of its subobjects.  D85 lets an
      --  indexed fixed-array match alias supply the same scalar context.
      --  Every other nested subobject remains a separate contextual position.
      function Is_Zeroed_Scalar_Place
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Is_Zeroed_Scalar_Place
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
         Is_Direct_Named_Return : constant Boolean :=
           Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
           and then Res.Sort_Of
                      (Meanings.all,
                       Res.Bound_To (Meanings.all, Of_Tree, Node))
                    = Res.Named_Return;
      begin
         return Is_Direct_Binding_Name (Of_Tree, Node)
           or else Is_Direct_Named_Return
           or else
             (Syn.Kind (Of_Tree, Node)
                in Syn.Member_Selection | Syn.Element_Index
              and then Is_Direct_Binding_Name
                         (Of_Tree, Syn.Target_Of (Of_Tree, Node)))
           or else
             (Syn.Kind (Of_Tree, Node) = Syn.Element_Index
              and then Syn.Kind
                (Of_Tree, Syn.Target_Of (Of_Tree, Node))
                  = Syn.Member_Selection
              and then Is_Direct_Binding_Name
                (Of_Tree,
                 Syn.Target_Of
                   (Of_Tree, Syn.Target_Of (Of_Tree, Node))))
           or else
             (Syn.Kind (Of_Tree, Node) = Syn.Element_Index
              and then Syn.Kind
                (Of_Tree, Syn.Target_Of (Of_Tree, Node))
                  = Syn.Name_Reference
              and then Res.Verdict_Of
                (Meanings.all, Of_Tree, Syn.Target_Of (Of_Tree, Node))
                  = Res.Bound
              and then Res.Sort_Of
                (Meanings.all,
                 Res.Bound_To
                   (Meanings.all, Of_Tree,
                    Syn.Target_Of (Of_Tree, Node)))
                  = Res.Pattern_Binding);
      end Is_Zeroed_Scalar_Place;

      function Synthesise
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind
      is
         Already : constant Ty.Type_Kind :=
           Landin.Checking.Type_Of (Types.all, Of_Tree, Node);

         function Kept (Item : Ty.Type_Kind) return Ty.Type_Kind;

         function Kept (Item : Ty.Type_Kind) return Ty.Type_Kind is
         begin
            if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
               = Ty.Undecided
            then
               Landin.Checking.Note (Types.all, Of_Tree, Node, Item);
            end if;

            return Landin.Checking.Type_Of (Types.all, Of_Tree, Node);
         end Kept;
      begin
         if Already /= Ty.Undecided then
            return Already;
         end if;

         --  A subtree with a hole in it is not checked: R1.40 already said
         --  what is wrong with it.
         if not Syn.Is_Sound (Of_Tree, Node) then
            return Kept (Ty.Ill_Typed);
         end if;

         case Syn.Kind (Of_Tree, Node) is
            when Syn.If_Statement | Syn.Match_Statement | Syn.Bare_Block =>
               return Kept (Synthesise_Control (Of_Tree, Node));

            when Syn.Integer_Literal =>
               return Kept (Ty.Untyped_Integer);

            when Syn.True_Literal | Syn.False_Literal =>
               return Kept (Ty.Bool);

            when Syn.Zeroed_Literal =>
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message => "`zeroed` needs a directly supplied initializer"
                             & " or assignment type",
                  Refused => Bad.Zeroed_Value,
                  Into    => Found);
               return Kept (Ty.Ill_Typed);

            --  D14: a measurement is a `usize`.  The type it asks about
            --  is recorded on its own node, because the lowering reads it
            --  from there and a type name is not an expression that would
            --  otherwise be walked.
            when Syn.Size_Of | Syn.Align_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Measured_Type (Of_Tree, Node);
               begin
                  --  D14, D17 and D44: legality follows the resolved checked
                  --  type, not the syntax that happened to spell it.  Type_At
                  --  also carries an array's structural shape or a struct's
                  --  nominal body onto this node, including through aliases.
                  declare
                     Held : constant Ty.Type_Kind := Type_At (Of_Tree, Asked);
                  begin
                     if Landin.Checking.Type_Of
                          (Types.all, Of_Tree, Asked) = Ty.Undecided
                     then
                        Landin.Checking.Note
                          (Types.all, Of_Tree, Asked, Held);
                     end if;

                     if Held in Ty.Scalar_Name | Ty.Fixed_Array
                       or else
                         (Held = Ty.Aggregate
                          and then Landin.Checking.Nominal_Of
                            (Types.all, Of_Tree, Asked)
                              /= Landin.Checking.No_Nominal_Type
                          and then Landin.Checking.Has_Layout
                            (Types.all,
                             Landin.Checking.Nominal_Of
                               (Types.all, Of_Tree, Asked)))
                     then
                        return Kept (Ty.Usize);
                     end if;

                     --  Type_At already reported the field that prevented a
                     --  complete layout, including D45's padded-size limit.
                     --  The measurement adds no second diagnosis.
                     if Held = Ty.Aggregate then
                        return Kept (Ty.Ill_Typed);
                     end if;

                     --  An unresolved or malformed type was already named by
                     --  its owning stage.  In particular, do not add a second
                     --  measurement report for it.
                     if Held = Ty.Ill_Typed then
                        return Kept (Ty.Ill_Typed);
                     end if;

                     --  Type_At answers one of the admitted shapes above or
                     --  Ill_Typed after its owning diagnostic.  Anything
                     --  else is compiler state, not a source refusal.
                     raise Landin.Compiler_Defect with
                       "a measured type has no settled checked shape";
                  end;
               end;

            --  [0370]: the length belongs to a named fixed-array type or to
            --  the source shape of D31's nonempty literal.  Neither form reads
            --  storage or evaluates a literal element.
            when Syn.Len_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Operand_Of (Of_Tree, Node);
               begin
                  if Syn.Kind (Of_Tree, Asked) = Syn.Array_Literal then
                     declare
                        Count : constant Landin.Checking.Element_Count :=
                          Landin.Checking.Element_Count
                            (Syn.Element_Count (Of_Tree, Asked));
                        First : constant Syn.Node_Id :=
                          Syn.Nth_Element (Of_Tree, Asked, 1);
                        Got : constant Ty.Type_Kind :=
                          Synthesise (Of_Tree, First);
                        Element : Ty.Scalar_Name;
                     begin
                        if Got = Ty.Untyped_Integer then
                           Element := Ty.Default_Integer;
                           Commit_To (Of_Tree, First, Element);
                        elsif Got in Ty.Scalar_Name then
                           Element := Ty.Scalar_Name (Got);
                        else
                           if Got = Ty.No_Value then
                              Bad.Report
                                (Item    => Bad.Type_Mismatch,
                                 Source  => Syn.Source_Of (Of_Tree),
                                 Where   => Syn.Where (Of_Tree, First),
                                 Message => "this hands back nothing, so it"
                                            & " cannot supply an array"
                                            & " element type",
                                 Note    => "D31: `lenof` checks one scalar"
                                            & " element type without"
                                            & " evaluating the elements",
                                 Related => Syn.Origin (Of_Tree, Asked),
                                 Because => "this measured literal",
                                 Into    => Found);
                           elsif Got /= Ty.Ill_Typed then
                              Bad.Report
                                (Item    => Bad.Type_Mismatch,
                                 Source  => Syn.Source_Of (Of_Tree),
                                 Where   => Syn.Where (Of_Tree, First),
                                 Message => "this is " & Shown (Got)
                                            & ", and an array literal needs"
                                            & " a scalar element type",
                                 Note    => "D31: `lenof` checks the literal's"
                                            & " D25 scalar shape",
                                 Related => Syn.Origin (Of_Tree, Asked),
                                 Because => "this measured literal",
                                 Into    => Found);
                           end if;

                           Landin.Checking.Refuse
                             (Types.all, Of_Tree, Asked);
                           return Kept (Ty.Ill_Typed);
                        end if;

                        Landin.Checking.Note
                          (Types.all, Of_Tree, Asked, Ty.Fixed_Array);
                        Landin.Checking.Note_Array
                          (Types.all, Of_Tree, Asked, Count, Element);

                        for Position in
                          2 .. Syn.Element_Count (Of_Tree, Asked)
                        loop
                           Require
                             (Of_Tree,
                              Syn.Nth_Element
                                (Of_Tree, Asked, Position),
                              Element, Syn.Origin (Of_Tree, Asked),
                              "the first literal element measured by `lenof`");
                        end loop;

                        return Kept (Ty.Usize);
                     end;
                  end if;

                  declare
                     Held : constant Ty.Type_Kind :=
                       Selected_From (Of_Tree, Asked);
                  begin
                     if Held = Ty.Ill_Typed then
                        --  In particular, an unresolved name was already
                        --  reported and remains resolution-owned.
                        return Kept (Ty.Ill_Typed);
                     end if;

                     if Held /= Ty.Fixed_Array then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Asked),
                           Message => "this is not a fixed array, so it has no"
                                      & " array length",
                           Note    => "[0370]: this kernel's `lenof` measures"
                                      & " a named array or array literal",
                           Related => Syn.Origin (Of_Tree, Asked),
                           Because => "what it names",
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;
                  end;

                  return Kept (Ty.Usize);
               end;

            when Syn.Array_Literal =>
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message => "an array literal needs a fixed-array binding"
                             & " or assignment context",
                  Refused => Bad.Array_Value,
                  Into    => Found);
               return Kept (Ty.Ill_Typed);

            when Syn.Struct_Literal =>
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message => "a struct literal needs an explicitly typed"
                             & " initializer or whole assignment",
                  Refused => Bad.Struct_Value,
                  Into    => Found);
               return Kept (Ty.Ill_Typed);

            when Syn.Array_Repetition =>
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message => "array repetition needs a typed binding, a"
                             & " counted inferred binding, or assignment",
                  Refused => Bad.Array_Value,
                  Into    => Found);
               return Kept (Ty.Ill_Typed);

            when Syn.Mixed_Array_Repetition =>
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message => "mixed-prefix array repetition needs an"
                             & " explicitly typed local initializer",
                  Refused => Bad.Array_Value,
                  Into    => Found);
               return Kept (Ty.Ill_Typed);

            when Syn.Anonymous_Function =>
               declare
                  Signature : constant Landin.Checking.Signature_Id :=
                    Signature_At (Of_Tree, Node);
               begin
                  if Signature = Landin.Checking.No_Signature then
                     return Kept (Ty.Ill_Typed);
                  end if;
                  return Kept (Ty.Function_Value);
               end;

            when Syn.Name_Reference =>
               if Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                  /= Res.Bound
               then
                  return Kept (Ty.Ill_Typed);
               end if;

               declare
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
               begin
                  if Res.Sort_Of (Meanings.all, Means) = Res.Case_Name then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Node),
                        Message => "a variant case used as a value is not"
                                   & " enabled yet",
                        Refused => Bad.Variant_Value,
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end if;

                  declare
                     Held : constant Ty.Type_Kind := Settled_Type (Means);
                  begin
                     if Held = Ty.Function_Value then
                        Landin.Checking.Note_Signature
                          (Types.all, Of_Tree, Node,
                           Landin.Checking.Signature_Of (Types.all, Means));
                        return Kept (Ty.Function_Value);
                     elsif Held = Ty.Atom_Value then
                        Landin.Checking.Note_Atom_Set
                          (Types.all, Of_Tree, Node,
                           Landin.Checking.Atom_Set_Of (Types.all, Means));
                        return Kept (Ty.Atom_Value);
                     end if;

                     --  [1740]'s state of [0670]'s type is storage a program
                     --  may declare and not yet reach: reading the whole of
                     --  one is a value, and carrying one waits for the rest
                     --  of R2.20 exactly as a binding of one does.
                     if Held = Ty.Aggregate
                       and then Landin.Checking.Result_Shape_Of
                         (Types.all, Means) /= Landin.Checking.No_Signature
                     then
                        Landin.Checking.Note_Result_Shape
                          (Types.all, Of_Tree, Node,
                           Landin.Checking.Result_Shape_Of
                             (Types.all, Means));
                        return Kept (Ty.Aggregate);
                     end if;

                     if Held = Ty.Aggregate then
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Node),
                           Message => "`"
                                      & Spelled (Syn.Name (Of_Tree, Node))
                                      & "` names a struct, and a value of one"
                                      & " is not enabled yet",
                           Refused => Bad.Struct_Value,
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;

                     if Held = Ty.Fixed_Array then
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Node),
                           Message => "`"
                                      & Spelled (Syn.Name (Of_Tree, Node))
                                      & "` names an array, and a value of one"
                                      & " is not enabled yet",
                           Refused => Bad.Array_Value,
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;

                     return Kept (Held);
                  end;
               end;

            when Syn.Element_Index =>
               declare
                  From : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Where : constant Syn.Node_Id := Syn.Index_Of (Of_Tree, Node);
                  Held : constant Ty.Type_Kind :=
                    Indexed_From (Of_Tree, From);
               begin
                  if Held = Ty.Ill_Typed then
                     return Kept (Ty.Ill_Typed);
                  end if;

                  --  [1820] indexes an array, and the kernel has one kind
                  --  of indexable thing: [0570]'s slice is not enabled and
                  --  [0610]'s text is not either.
                  if Held /= Ty.Fixed_Array then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, From),
                        Message => "this is not an array, so it has no"
                                   & " element to index",
                        Note    => "[1820]: the kernel indexes an array"
                                   & " [0520] and nothing else",
                        Related => Syn.Origin (Of_Tree, From),
                        Because => "what it names",
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end if;

                  --  D18: the index is exactly `usize`; accepting every
                  --  integer here would be an implicit conversion.  An
                  --  untyped literal receives that context rather than
                  --  [0200]'s context-free default.
                  declare
                     Got : Ty.Type_Kind;
                  begin
                     if Syn.Kind (Of_Tree, Where)
                          in Syn.If_Statement | Syn.Match_Statement
                             | Syn.Bare_Block
                     then
                        Check_Contextual_Value
                          (Of_Tree, Where,
                           (Kind => Ty.Usize, others => <>),
                           Syn.Origin (Of_Tree, From),
                           "the array indexed here");
                        Got := Landin.Checking.Type_Of
                          (Types.all, Of_Tree, Where);
                     else
                        Got := Synthesise (Of_Tree, Where);
                     end if;

                     if Got = Ty.Untyped_Integer then
                        Commit_To (Of_Tree, Where, Ty.Usize);
                     elsif Decidable (Got) and then Got /= Ty.Usize then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Where),
                           Message => "this indexes with " & Shown (Got)
                                      & ", and an index is a usize",
                           Note    => "D18: indexing accepts exactly usize"
                                      & " and performs no implicit conversion",
                           Related => Syn.Origin (Of_Tree, From),
                           Because => "the array indexed here",
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;
                  end;

                  if Landin.Checking.Type_Of (Types.all, Of_Tree, Where)
                       = Ty.Ill_Typed
                    or else
                      (Syn.Kind (Of_Tree, Where) = Syn.Negation
                       and then Landin.Checking.Type_Of
                                  (Types.all, Of_Tree,
                                   Syn.Operand_Of (Of_Tree, Where))
                                  = Ty.Ill_Typed)
                  then
                     return Kept (Ty.Ill_Typed);
                  end if;

                  Check_Index_Bound (Of_Tree, Node, From, Where);
                  if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                       = Ty.Ill_Typed
                  then
                     return Kept (Ty.Ill_Typed);
                  end if;

                  --  D19 gives a local array one definite-assignment fact per
                  --  compiler-known element.  D22 leaves the read of a
                  --  computed local element to the flow walk below, which
                  --  requires the whole-array fact D20 records; a computed
                  --  write is a place operation and establishes no element
                  --  fact of its own.  Module arrays keep D10's complete
                  --  state and their runtime-index path is unchanged.
                  --  D121: [0520]'s element may be an ordinary struct,
                  --  and then indexing hands back that struct with its
                  --  own [0710] identity rather than a scalar.
                  declare
                     Body_Of_Element : constant
                       Landin.Checking.Nominal_Type_Id :=
                       Landin.Checking.Array_Element_Nominal
                         (Types.all, Of_Tree, From);
                  begin
                     if Body_Of_Element /= Landin.Checking.No_Nominal_Type then
                        if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                             = Ty.Undecided
                        then
                           Landin.Checking.Note_Nominal
                             (Types.all, Of_Tree, Node, Body_Of_Element);
                        end if;
                        return Kept (Ty.Aggregate);
                     end if;
                  end;

                  return Kept
                    (Landin.Checking.Array_Element
                       (Types.all, Of_Tree, From));
               end;

            when Syn.Member_Selection =>
               declare
                  From : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Held : constant Ty.Type_Kind :=
                    Selected_From (Of_Tree, From);
               begin
                  if Held = Ty.Ill_Typed then
                     return Kept (Ty.Ill_Typed);
                  end if;

                  --  [0420] names four kinds of member and [1820] enables
                  --  one, so anything but a struct to the left of the dot
                  --  is a selection this kernel cannot make.
                  if Held /= Ty.Aggregate then
                     declare
                        Means : constant Res.Declaration_Id :=
                          (if Syn.Kind (Of_Tree, From) = Syn.Name_Reference
                             and then Res.Verdict_Of
                                        (Meanings.all, Of_Tree, From)
                                      = Res.Bound
                           then Res.Bound_To (Meanings.all, Of_Tree, From)
                           else Res.No_Declaration);
                     begin
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, From),
                           Message => "this is not a struct, so it has no"
                                      & " field to select",
                           Note    => "[1820]: the kernel selects a field"
                                      & " of a struct [0670] and nothing"
                                      & " else",
                           Related =>
                             (if Means = Res.No_Declaration
                              then Syn.Origin (Of_Tree, From)
                              else Syn.Origin
                                     (Tree_For
                                        (Res.Source_Of
                                           (Meanings.all, Means)).all,
                                      Res.Node_Of (Meanings.all, Means))),
                           Because => "what it names",
                           Into    => Found);
                     end;

                     return Kept (Ty.Ill_Typed);
                  end if;

                  declare
                     Shape : constant Landin.Checking.Signature_Id :=
                       Landin.Checking.Result_Shape_Of
                         (Types.all, Of_Tree, From);
                     Result_Field : constant Natural :=
                       (if Shape = Landin.Checking.No_Signature then 0
                        else Result_Field_At
                          (Shape, Syn.Name (Of_Tree, Node)));
                     Wrote : constant Landin.Checking.Nominal_Type_Id :=
                       Landin.Checking.Nominal_Of (Types.all, Of_Tree, From);
                     Which : constant Natural :=
                       (if Shape /= Landin.Checking.No_Signature
                        then Result_Field
                        elsif Wrote = Landin.Checking.No_Nominal_Type then 0
                        else Field_At (Wrote, Syn.Name (Of_Tree, Node)));
                  begin
                     if Shape /= Landin.Checking.No_Signature
                       and then Which > 0
                     then
                        return Kept
                          (Note_Result_Field
                             (Of_Tree, Node, Shape, Positive (Which)));
                     end if;

                     if Which = 0 then
                        Bad.Report
                          (Item    => Bad.Unresolved_Field,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Anchor (Of_Tree, Node),
                           Message => "this struct has no field called `"
                                      & Spelled (Syn.Name (Of_Tree, Node))
                                      & "`",
                           Note    => "[0750]: a struct has the fields it"
                                      & " was declared with, and no others",
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;

                     --  A struct one of whose fields was refused has no
                     --  layout, so it has no field types either.  The
                     --  refusal already named the field that stopped it,
                     --  and a second report about a field that is fine
                     --  would send a reader to the wrong line.
                     if not Landin.Checking.Has_Layout (Types.all, Wrote)
                     then
                        return Kept (Ty.Ill_Typed);
                     end if;

                     --  D46/D47 admit direct containing storage, D48 admits
                     --  its element through Indexed_From, and D89 does the
                     --  same through one ordinary child. The field by itself
                     --  is still not a value or whole place. Refuse it before
                     --  Field_Type's scalar precondition.
                     if Landin.Checking.Field_Kind_Of
                          (Types.all, Wrote, Which)
                          = Landin.Checking.Fixed_Array_Field
                     then
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Node),
                           Message => "a fixed-array field is not an enabled"
                                      & " value or nested place yet",
                           Refused => Bad.Array_Value,
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;

                     --  D75 carries the complete variant part in storage and
                     --  clears it as one zero image.  Its tag and payload are
                     --  not scalar fields: D76/D77 own construction and
                     --  matching, so a direct selection remains one refused
                     --  value/place instead of reaching Field_Type's scalar
                     --  precondition.
                     if Landin.Checking.Field_Kind_Of
                          (Types.all, Wrote, Which)
                          = Landin.Checking.Variant_Field
                     then
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Node),
                           Message => "a variant part cannot be selected as"
                                      & " a value or place yet",
                           Refused => Bad.Variant_Value,
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;

                     --  D88 admits scalar leaves only through a further
                     --  selection.  The intermediate ordinary child remains
                     --  no general value or whole place, so keep this direct
                     --  occurrence away from the scalar accessor.
                     if Landin.Checking.Field_Kind_Of
                          (Types.all, Wrote, Which)
                          = Landin.Checking.Aggregate_Field
                     then
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Node),
                           Message => "a nested struct field is not an"
                                      & " enabled value or place yet",
                           Refused => Bad.Struct_Value,
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;

                     return Kept
                       (Note_Struct_Field
                          (Of_Tree, Node, Wrote, Positive (Which)));
                  end;
               end;

            when Syn.Try_Expression =>
               declare
                  Operand : constant Syn.Node_Id :=
                    Syn.Operand_Of (Of_Tree, Node);
                  Held : Ty.Type_Kind;
               begin
                  if Syn.Kind (Of_Tree, Operand) /= Syn.Call
                    or else
                      (Syn.Kind (Of_Tree, Operand) = Syn.Call
                       and then Syn.Recovery_Of (Of_Tree, Operand)
                                  /= Syn.No_Node)
                  then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Node),
                        Message => "`try` propagates one unrecovered call",
                        Note    => "[0960]: `try` is visible at the call site",
                        Related => Syn.Origin (Of_Tree, Operand),
                        Because => "this operand",
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end if;

                  Held := Synthesise (Of_Tree, Operand);
                  declare
                     Callee : constant Syn.Node_Id :=
                       Syn.Callee_Of (Of_Tree, Operand);
                     Means : constant Res.Declaration_Id :=
                       (if Res.Verdict_Of (Meanings.all, Of_Tree, Callee)
                              = Res.Bound
                        then Res.Bound_To (Meanings.all, Of_Tree, Callee)
                        else Res.No_Declaration);
                     Signature : constant Landin.Checking.Signature_Id :=
                       (if Means /= Res.No_Declaration
                        then Landin.Checking.Signature_Of (Types.all, Means)
                        else Landin.Checking.Signature_Of
                          (Types.all, Of_Tree, Callee));
                  begin
                     if Signature /= Landin.Checking.No_Signature
                       and then Landin.Checking.Signature_Errors
                         (Types.all, Signature)
                           = Landin.Checking.No_Atom_Set
                     then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Node),
                           Message => "this call cannot fail, so `try` has"
                                      & " no error to propagate",
                           Note    => "[0960]: `try` is for the declared"
                                      & " error outcome of a call",
                           Related => Landin.Checking.Signature_Origin
                             (Types.all, Signature),
                           Because => "this infallible signature",
                           Into    => Found);
                     end if;
                  end;

                  if Held = Ty.Atom_Value then
                     Landin.Checking.Note_Atom_Set
                       (Types.all, Of_Tree, Node,
                        Landin.Checking.Atom_Set_Of
                          (Types.all, Of_Tree, Operand));
                  elsif Held = Ty.Aggregate
                    and then Landin.Checking.Result_Shape_Of
                      (Types.all, Of_Tree, Operand)
                        /= Landin.Checking.No_Signature
                  then
                     Landin.Checking.Note_Result_Shape
                       (Types.all, Of_Tree, Node,
                        Landin.Checking.Result_Shape_Of
                          (Types.all, Of_Tree, Operand));
                  elsif Held = Ty.Aggregate then
                     Landin.Checking.Note_Nominal
                       (Types.all, Of_Tree, Node,
                        Landin.Checking.Nominal_Of
                          (Types.all, Of_Tree, Operand));
                  elsif Held = Ty.Fixed_Array then
                     Landin.Checking.Note_Array
                       (Types.all, Of_Tree, Node,
                        Landin.Checking.Array_Length
                          (Types.all, Of_Tree, Operand),
                        Landin.Checking.Array_Element
                          (Types.all, Of_Tree, Operand));
                  elsif Held = Ty.Function_Value then
                     Landin.Checking.Note_Signature
                       (Types.all, Of_Tree, Node,
                        Landin.Checking.Signature_Of
                          (Types.all, Of_Tree, Operand));
                  end if;
                  return Kept (Held);
               end;

            when Syn.Call =>
               declare
                  Callee : constant Syn.Node_Id :=
                    Syn.Callee_Of (Of_Tree, Node);
                  Named : constant Boolean :=
                    Syn.Kind (Of_Tree, Callee) = Syn.Name_Reference
                    and then Res.Verdict_Of
                      (Meanings.all, Of_Tree, Callee) = Res.Bound;
                  Means : constant Res.Declaration_Id :=
                    (if Named
                     then Res.Bound_To (Meanings.all, Of_Tree, Callee)
                     else Res.No_Declaration);
                  Is_Generic : constant Boolean :=
                    Named
                    and then Res.Sort_Of (Meanings.all, Means)
                      = Res.Module_Function
                    and then Syn.Generic_Formal_Count
                      (Tree_For (Res.Source_Of (Meanings.all, Means)).all,
                       Res.Node_Of (Meanings.all, Means)) /= 0;
                  Held : constant Ty.Type_Kind :=
                    (if Is_Generic then Ty.Function_Value
                     elsif Named then Settled_Type (Means)
                     else Synthesise (Of_Tree, Callee));
                  Signature : constant Landin.Checking.Signature_Id :=
                    (if Is_Generic
                     then Instantiate_Generic_Call (Of_Tree, Node, Means)
                     elsif Named
                     then Landin.Checking.Signature_Of (Types.all, Means)
                     else Landin.Checking.Signature_Of
                       (Types.all, Of_Tree, Callee));
               begin
                  if Is_Generic
                    and then Signature = Landin.Checking.No_Signature
                  then
                     return Kept (Ty.Ill_Typed);
                  elsif Held = Ty.Ill_Typed then
                     return Kept (Ty.Ill_Typed);
                  end if;

                  if Held /= Ty.Function_Value
                    or else Signature = Landin.Checking.No_Signature
                  then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Callee),
                        Message => "this value is not a function, so this"
                                   & " is not a call",
                        Note    => "[1920]: a callee has a function type",
                        Related => Syn.Origin (Of_Tree, Node),
                        Because => "this call",
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end if;

                  return Kept (Check_Call (Of_Tree, Node, Signature));
               end;

            when Syn.Negation | Syn.Complement =>
               declare
                  Under : constant Ty.Type_Kind :=
                    Synthesise (Of_Tree, Syn.Operand_Of (Of_Tree, Node));
               begin
                  if Under = Ty.Untyped_Integer then
                     return Kept (Ty.Untyped_Integer);
                  end if;

                  if not Decidable (Under) then
                     return Kept (Ty.Ill_Typed);
                  end if;

                  if Under not in Ty.Integer_Name then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Anchor (Of_Tree, Node),
                        Message => "this operator wants a number and was"
                                   & " given " & Shown (Under),
                        Note    => "[1890]: a bool has no arithmetic and"
                                   & " no bitwise set",
                        Related => Syn.Origin (Of_Tree, Node),
                        Because => "here",
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end if;

                  return Kept (Under);
               end;

            when Syn.Logical_Not =>
               Require
                 (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Ty.Bool,
                  Syn.Origin (Of_Tree, Node), "required by `not`");
               return Kept (Ty.Bool);

            when Syn.Logical_And | Syn.Logical_Or =>
               Require
                 (Of_Tree, Syn.Left_Of (Of_Tree, Node), Ty.Bool,
                  Syn.Origin (Of_Tree, Node), "required by this operator");
               Require
                 (Of_Tree, Syn.Right_Of (Of_Tree, Node), Ty.Bool,
                  Syn.Origin (Of_Tree, Node), "required by this operator");
               return Kept (Ty.Bool);

            --  The binary band minus the logical words, which the arm
            --  above already answered: [1890] gives those a bool on both
            --  sides and everything here one integer type.
            when Syn.Multiply .. Syn.Greater_Or_Equal =>
               return Kept (Synthesise_Binary (Of_Tree, Node));

            when others =>
               return Kept (Ty.Not_Typed);
         end case;
      end Synthesise;

      ------------------------------------------------------------
      --  Statements
      ------------------------------------------------------------

      --  [1900]: of the four kinds of name the kernel has, two may be
      --  written and two may not.  Stepping says the place is an `inc` or a
      --  `dec`, which [0400] makes an addition and so wants a number too.
      procedure Check_Place
        (Of_Tree        : Syn.Tree;
         Node           : Syn.Node_Id;
         Stepping       : Boolean;
         Variant_Context : Boolean := False)
      is
         Held : Ty.Type_Kind;

         --  What a place is a place *in*.  A field and an element are
         --  written exactly as the binding holding them is [1810], so
         --  which binding that is is the question [1900] answers about,
         --  and it is the name at the left of however many dots and
         --  brackets were written.
         Base : Syn.Node_Id := Node;
      begin
         while Syn.Kind (Of_Tree, Base)
               in Syn.Member_Selection | Syn.Element_Index
         loop
            Base := Syn.Target_Of (Of_Tree, Base);
         end loop;

         if Res.Verdict_Of (Meanings.all, Of_Tree, Base) /= Res.Bound then
            return;
         end if;

         declare
            Means : constant Res.Declaration_Id :=
              Res.Bound_To (Meanings.all, Of_Tree, Base);
            Sort  : constant Res.Declaration_Sort :=
              Res.Sort_Of (Meanings.all, Means);
            Their_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Means));
            Their_Node : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Means);
            Writable : Boolean;
         begin
            Writable :=
              (case Sort is
                  when Res.Named_Return    => True,
                  when Res.Parameter       => False,
                  when Res.Module_Function => False,
                  --  An atom declaration is a value and a type, but it is
                  --  identity rather than storage and cannot be written.
                  when Res.Module_Atom => False,
                  --  [1795] names a type, and a type is not a place.  D135
                  --  formals are compile-time binders, never storage.
                  when Res.Module_Type | Res.Case_Name
                     | Res.Type_Parameter | Res.Fixed_Parameter => False,
                  when Res.Error_Binding => False,
                  when Res.Pattern_Binding =>
                     Syn.Is_Mutable (Their_Tree.all, Their_Node),
                  when Res.Result_Binding => False,
                  when Res.Module_Binding | Res.Local_Binding =>
                     Syn.Is_Mutable (Their_Tree.all, Their_Node));

            if not Writable then
               Bad.Report
                 (Item    => Bad.Immutable_Target,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message =>
                    "`" & Spelled (Syn.Name (Of_Tree, Base)) & "` "
                    & (case Sort is
                          when Res.Parameter =>
                             "is a parameter, and a parameter is taken in",
                          when Res.Module_Function =>
                             "names a function, which is not a place",
                          when Res.Module_Atom =>
                             "names an atom identity, which is not a place",
                          when others =>
                             "is not mutable, so it may not be written"),
                  Note    => "[1900]: a mutable binding and a named return"
                             & " may be written, and nothing else may",
                  Related => Landin.Provenance.Origin'
                               (Source => Res.Source_Of
                                            (Meanings.all, Means),
                                Where  => Syn.Anchor
                                            (Their_Tree.all, Their_Node)),
                  Because => "declared here",
                  Into    => Found);
               Landin.Checking.Refuse (Types.all, Of_Tree, Base);

               if Base /= Node then
                  Landin.Checking.Refuse (Types.all, Of_Tree, Node);
               end if;

               return;
            end if;

            if Variant_Context then
               return;
            end if;

            Held := Selected_From (Of_Tree, Node);

            --  [0400]: `inc` says what `x += 1` says, so it wants a number.
            if Stepping and then Decidable (Held)
              and then Held not in Ty.Integer_Name
            then
               Bad.Report
                 (Item    => Bad.Type_Mismatch,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message => "this steps " & Shown (Held)
                             & ", and only a number can be stepped",
                  Note    => "[1900]: `inc` and `dec` say what `x += 1`"
                             & " says [0400]",
                  Related => Syn.Origin (Of_Tree, Node),
                  Because => "here",
                  Into    => Found);
            end if;
         end;
      end Check_Place;

      --  D24/D66: a static image may fold scalar syntax but may not read a
      --  selected runtime place or carry a nested array value.  Keep this
      --  recursive refusal shared by array and struct image contexts so a
      --  construct hidden under an operator has one owner and one report.
      procedure Refuse_Static_Image_Subtree
        (Of_Tree : Syn.Tree; Where : Syn.Node_Id; Context : String);

      procedure Refuse_Static_Image_Subtree
        (Of_Tree : Syn.Tree; Where : Syn.Node_Id; Context : String)
      is
         What : constant String :=
           (if Where = Syn.No_Node then ""
            else
              (case Syn.Kind (Of_Tree, Where) is
                  when Syn.Member_Selection => "a field selection",
                  when Syn.Element_Index    => "an array index",
                  when Syn.Array_Literal    => "a nested array literal",
                  when others               => ""));
      begin
         if Where = Syn.No_Node then
            return;
         end if;

         if What /= "" then
            Bad.Report
              (Item    => Bad.Unsupported_Use,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Where),
               Message => What & " is not enabled as " & Context,
               Refused => Bad.Array_Value,
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Where);
            --  Stop walking a refused subtree so an operator above it does
            --  not multiply the same report.
            return;
         end if;

         for Slot in 1 .. Syn.Slot_Count (Of_Tree, Where) loop
            Refuse_Static_Image_Subtree
              (Of_Tree, Syn.Slot (Of_Tree, Where, Slot), Context);
         end loop;
      end Refuse_Static_Image_Subtree;

      procedure Check_Array_Literal
        (Of_Tree      : Syn.Tree;
         Context      : Syn.Node_Id;
         Literal      : Syn.Node_Id;
         Expected     : Landin.Checking.Element_Count;
         Element      : Ty.Scalar_Name;
         Static_Image : Boolean;
         Context_Site : Landin.Provenance.Origin :=
           Landin.Provenance.No_Origin)
      is
         Related : constant Landin.Provenance.Origin :=
           (if Landin.Provenance.Is_Known (Context_Site)
            then Context_Site else Syn.Origin (Of_Tree, Context));
      begin
         --  Check_Module_Value refuses a call element by [1940] and marks
         --  the whole literal Ill_Typed on the way out; walking each
         --  element still catches the shape and the scalar context, but
         --  the second Note on the literal itself would repeat what the
         --  first report already said.
         if Landin.Checking.Type_Of (Types.all, Of_Tree, Literal)
              = Ty.Undecided
         then
            Landin.Checking.Note
              (Types.all, Of_Tree, Literal, Ty.Fixed_Array);
            Landin.Checking.Note_Array
              (Types.all, Of_Tree, Literal, Expected, Element);
         end if;

         if Landin.Checking.Element_Count
              (Syn.Element_Count (Of_Tree, Literal)) /= Expected
         then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Literal),
               Message => "this literal has "
                          & Counted
                              (Syn.Element_Count (Of_Tree, Literal), "element")
                          & ", and its array context has a different length",
               Note    => "D23/D24/D26/D29: an array literal supplies exactly"
                          & " the number of elements its context names",
               Related => Related,
               Because => "the array context here",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
         end if;

         for Position in 1 .. Syn.Element_Count (Of_Tree, Literal) loop
            Require
              (Of_Tree, Syn.Nth_Element (Of_Tree, Literal, Position), Element,
               Related, "the array element type");
         end loop;

         --  D24: an element must be a compile-time known scalar the
         --  target-aware fold can compute; that admits every [1820]
         --  operator applied to literals and to another module scalar
         --  binding, and it excludes a member selection, an array
         --  element index and a nested array literal.  A call has been
         --  refused above by [1940] and reports L0305; these three are
         --  refused here so the reader sees a boundary rather than a
         --  compiler defect during image resolution.  The walk is
         --  recursive because a subtree hides the same construct: `p.x
         --  + 1` and `source[0] & 0xFF` reach the fold as an Add and a
         --  Bitwise_And whose top-level kind is admitted, and only the
         --  subtree carries the refusal.  A runtime literal (D23/D29)
         --  accepts every well-typed expression and does not run this walk.
         if Static_Image then
            for Position in 1 .. Syn.Element_Count (Of_Tree, Literal) loop
               Refuse_Static_Image_Subtree
                 (Of_Tree,
                  Syn.Nth_Element (Of_Tree, Literal, Position),
                  "a module array literal element");
            end loop;
         end if;
      end Check_Array_Literal;

      --  D76: a case value is contextual to one variant part.  A bare case
      --  selects an empty payload; a case construction labels each scalar
      --  payload leaf, while a fixed-array leaf may take only its zero image
      --  in this first executable slice.  The value and its labels retain
      --  source-order identities for lowering without becoming general
      --  aggregate values.
      procedure Check_Variant_Value
        (Of_Tree : Syn.Tree;
         Site    : Syn.Node_Id;
         Value   : Syn.Node_Id;
         Wrote   : Landin.Checking.Nominal_Type_Id;
         Field   : Positive;
         Static_Image : Boolean := False)
      is
         Body_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of
             (Meanings.all, Template_Declaration (Wrote)));
         Body_Node : constant Syn.Node_Id :=
           Syn.Declared_Type
             (Body_Tree.all, Res.Node_Of
               (Meanings.all, Template_Declaration (Wrote)));
         Part : constant Syn.Node_Id :=
           Syn.Nth_Field (Body_Tree.all, Body_Node, Field);
         Nominal : Syn.Node_Id := Syn.No_Node;
         Means : Res.Declaration_Id := Res.No_Declaration;
         Which : Natural := 0;
         Failed : Boolean := False;

         function Subtree_Was_Refused
           (Node : Syn.Node_Id) return Boolean;

         procedure Check_Fixed_Array_Payload
           (Label : Syn.Node_Id;
            Given : Syn.Node_Id;
            Shape : Landin.Checking.Field_Shape);

         --  D120: a payload field of ordinary struct type takes the same
         --  contextual values a labelled ordinary child does -- `zeroed`,
         --  a matching literal or nominal construction, and a copy from
         --  storage of the same nominal type.  D132 recursively folds those
         --  same forms when the destination is a module image.
         procedure Check_Aggregate_Payload
           (Label : Syn.Node_Id;
            Given : Syn.Node_Id;
            Shape : Landin.Checking.Field_Shape);

         function Subtree_Was_Refused
           (Node : Syn.Node_Id) return Boolean
         is
         begin
            if Node = Syn.No_Node then
               return False;
            elsif Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                    = Ty.Ill_Typed
            then
               return True;
            end if;

            for Slot in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
               if Subtree_Was_Refused
                    (Syn.Slot (Of_Tree, Node, Slot))
               then
                  return True;
               end if;
            end loop;
            return False;
         end Subtree_Was_Refused;

         procedure Check_Aggregate_Payload
           (Label : Syn.Node_Id;
            Given : Syn.Node_Id;
            Shape : Landin.Checking.Field_Shape)
         is
            Expected : constant
              Landin.Checking.Nominal_Type_Id := Shape.Nominal;
            Got : Ty.Type_Kind;
         begin
            if Syn.Kind (Of_Tree, Given) = Syn.Zeroed_Literal then
               Check_Aggregate_Zeroed
                 (Of_Tree, Given, Expected,
                  Syn.Origin (Of_Tree, Label),
                  "the ordinary-struct payload field");
               return;
            elsif Syn.Kind (Of_Tree, Given) = Syn.Struct_Literal then
               if Construction_Agrees
                    (Of_Tree, Given, Expected,
                     Syn.Origin (Of_Tree, Label),
                     "this ordinary-struct payload field")
               then
                  Check_Struct_Literal
                    (Of_Tree, Given, Expected,
                     Static_Image => Static_Image);
               end if;
               return;
            elsif Static_Image
              and then
                ((Syn.Kind (Of_Tree, Given) = Syn.Name_Reference
                  and then Res.Verdict_Of
                    (Meanings.all, Of_Tree, Given) = Res.Bound
                  and then Res.Sort_Of
                    (Meanings.all,
                     Res.Bound_To (Meanings.all, Of_Tree, Given))
                      = Res.Module_Binding)
                 or else Is_Direct_Module_Field (Of_Tree, Given))
            then
               Got := Selected_From (Of_Tree, Given);
            elsif not Static_Image
              and then
                (Is_Direct_Binding_Name (Of_Tree, Given)
                 or else Is_Aggregate_Alias_Name (Of_Tree, Given)
                 or else Syn.Kind (Of_Tree, Given) = Syn.Member_Selection)
            then
               Got := Selected_From (Of_Tree, Given);
            else
               Got := Synthesise (Of_Tree, Given);
               if Static_Image and then Got /= Ty.Ill_Typed then
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Given),
                     Message => "a module ordinary-struct payload takes"
                                & " `zeroed`, a static construction, or a"
                                & " module struct or direct child image",
                     Refused => Bad.Struct_Value,
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Given);
                  return;
               end if;
            end if;

            if Got = Ty.Aggregate
              and then Landin.Checking.Nominal_Of
                (Types.all, Of_Tree, Given) = Expected
            then
               null;
            elsif Got /= Ty.Ill_Typed then
               Bad.Report
                 (Item    => Bad.Type_Mismatch,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Given),
                  Message => "this is not the nominal struct type named by"
                             & " the payload field",
                  Note    => "[0710]: ordinary struct identity is nominal",
                  Related => Syn.Origin (Of_Tree, Label),
                  Because => "the payload field named here",
                  Into    => Found);
               Landin.Checking.Refuse (Types.all, Of_Tree, Given);
            end if;
         end Check_Aggregate_Payload;

         procedure Check_Fixed_Array_Payload
           (Label : Syn.Node_Id;
            Given : Syn.Node_Id;
            Shape : Landin.Checking.Field_Shape)
         is
            procedure Require_Known (Each : Syn.Node_Id);

            procedure Require_Known (Each : Syn.Node_Id) is
            begin
               if not Subtree_Was_Refused (Each)
                 and then not Is_Known (Of_Tree, Each)
               then
                  Bad.Report
                    (Item    => Bad.Not_Known_At_Compile_Time,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Each),
                     Message => "this variant payload image value has to be"
                                & " known when the module image is formed",
                     Note    => "[1940]: nothing runs before the entry"
                                & " point [1460]",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Each);
               end if;
            end Require_Known;
         begin
            pragma Assert (Shape.Kind = Landin.Checking.Fixed_Array_Field);

            --  D82/D83 reuse D67--D71's static image forms inside D81's
            --  selected payload descriptor run.  D84 gives runtime case
            --  construction D65's same contextual array-destination forms.
            --  Only the static branch asks [1940] to fold its expressions.
            case Syn.Kind (Of_Tree, Given) is
               when Syn.Array_Literal =>
                  Check_Array_Literal
                    (Of_Tree, Label, Given, Shape.Length, Shape.Element,
                     Static_Image => Static_Image);
                  if Static_Image then
                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Given)
                     loop
                        Require_Known
                          (Syn.Nth_Element (Of_Tree, Given, Position));
                     end loop;
                  end if;

               when Syn.Array_Repetition =>
                  Check_Array_Repetition
                    (Of_Tree, Label, Given, Shape.Length, Shape.Element,
                     Static_Image => Static_Image);
                  if Static_Image then
                     Require_Known (Syn.Repeated_Element (Of_Tree, Given));
                  end if;

               when Syn.Mixed_Array_Repetition =>
                  Check_Mixed_Array_Repetition
                    (Of_Tree, Label, Given, Shape.Length, Shape.Element,
                     Static_Image => Static_Image);
                  if Static_Image then
                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Given)
                     loop
                        Require_Known
                          (Syn.Nth_Element (Of_Tree, Given, Position));
                     end loop;
                     Require_Known (Syn.Repeated_Element (Of_Tree, Given));
                  end if;

               when Syn.Zeroed_Literal =>
                  Check_Array_Zeroed
                    (Of_Tree, Given, Shape.Length, Shape.Element,
                     Shape.Nominal, Syn.Origin (Of_Tree, Label),
                     "the fixed-array payload field");

               when Syn.Name_Reference =>
                  declare
                     Is_Storage : constant Boolean :=
                       (if Static_Image
                        then Res.Verdict_Of
                               (Meanings.all, Of_Tree, Given) = Res.Bound
                          and then Res.Sort_Of
                            (Meanings.all,
                             Res.Bound_To
                               (Meanings.all, Of_Tree, Given))
                              = Res.Module_Binding
                        else Is_Direct_Binding_Name (Of_Tree, Given));
                     Got : constant Ty.Type_Kind :=
                       (if Is_Storage
                        then Selected_From (Of_Tree, Given)
                        else Synthesise (Of_Tree, Given));
                  begin
                     if Got = Ty.Ill_Typed then
                        null;
                     elsif Is_Storage
                       and then
                         (Got /= Ty.Fixed_Array
                          or else Landin.Checking.Array_Length
                            (Types.all, Of_Tree, Given) /= Shape.Length
                          or else Landin.Checking.Array_Element
                            (Types.all, Of_Tree, Given) /= Shape.Element)
                     then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Given),
                           Message => "this is not an array of the"
                                      & " variant payload's type",
                           Note    => "D17: an array's length and element"
                                      & " type are its identity",
                           Related => Syn.Origin (Of_Tree, Label),
                           Because => "the payload field named here",
                           Into    => Found);
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Given);
                     end if;
                  end;

               when Syn.Member_Selection =>
                  declare
                     Is_Storage : constant Boolean :=
                       (if Static_Image
                        then Is_Direct_Module_Field (Of_Tree, Given)
                        else Syn.Kind
                          (Of_Tree, Syn.Target_Of (Of_Tree, Given))
                            = Syn.Name_Reference);
                     Admitted : constant Boolean :=
                       Is_Storage
                       and then Admit_Array_Field (Of_Tree, Given);
                     Got : constant Ty.Type_Kind :=
                       (if Admitted
                        then Selected_From (Of_Tree, Given)
                        else Synthesise (Of_Tree, Given));
                  begin
                     if Got = Ty.Ill_Typed then
                        null;
                     elsif Is_Storage
                       and then
                         (not Admitted
                          or else Landin.Checking.Array_Length
                            (Types.all, Of_Tree, Given) /= Shape.Length
                          or else Landin.Checking.Array_Element
                            (Types.all, Of_Tree, Given) /= Shape.Element)
                     then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Given),
                           Message => "this is not an array field of the"
                                      & " variant payload's type",
                           Note    => "D17: an array's length and element"
                                      & " type are its identity",
                           Related => Syn.Origin (Of_Tree, Label),
                           Because => "the payload field named here",
                           Into    => Found);
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Given);
                     end if;
                  end;

               when others =>
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Given),
                     Message =>
                       (if Static_Image
                        then "a module fixed-array case payload takes a"
                          & " literal, repetition, `zeroed` or a module"
                          & " array or array-field name"
                        else "a fixed-array case payload takes a literal,"
                          & " repetition, `zeroed` or an array or"
                          & " array-field name"),
                     Refused => Bad.Array_Value,
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Given);
            end case;

            if Subtree_Was_Refused (Given) then
               Landin.Checking.Refuse (Types.all, Of_Tree, Given);
            end if;
         end Check_Fixed_Array_Payload;
      begin
         pragma Assert (Syn.Kind (Body_Tree.all, Part) = Syn.Variant_Part);

         if Syn.Kind (Of_Tree, Value) = Syn.Name_Reference then
            Nominal := Value;
         elsif Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal
           and then Syn.Constructed_Type (Of_Tree, Value) /= Syn.No_Node
         then
            Nominal := Syn.Constructed_Type (Of_Tree, Value);
         else
            Bad.Report
              (Item    => Bad.Unsupported_Use,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Value),
               Message => "a variant part takes a bare case name or a"
                          & " labelled case construction",
               Refused => Bad.Variant_Value,
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Value);
            return;
         end if;

         if Res.Verdict_Of (Meanings.all, Of_Tree, Nominal) = Res.Bound then
            Means := Res.Bound_To (Meanings.all, Of_Tree, Nominal);
         end if;

         if Means /= Res.No_Declaration
           and then Res.Sort_Of (Meanings.all, Means) = Res.Case_Name
         then
            for Candidate in 1 .. Syn.Case_Count (Body_Tree.all, Part) loop
               if Res.Source_Of (Meanings.all, Means)
                    = Syn.Source_Of (Body_Tree.all)
                 and then Res.Node_Of (Meanings.all, Means)
                    = Syn.Nth_Case (Body_Tree.all, Part, Candidate)
               then
                  Which := Candidate;
                  exit;
               end if;
            end loop;
         end if;

         if Which = 0 then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Nominal),
               Message => "this case does not belong to the variant part"
                          & " selected here",
               Note    => "D76: a case is identified by the variant part"
                          & " that declared it",
               Related => Syn.Origin (Of_Tree, Site),
               Because => "the variant part selected here",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Value);
            return;
         end if;

         if Landin.Checking.Type_Of (Types.all, Of_Tree, Value)
              = Ty.Undecided
         then
            Landin.Checking.Note
              (Types.all, Of_Tree, Value, Ty.Not_Typed);
            Landin.Checking.Note_Field
              (Types.all, Of_Tree, Value, Which);
         end if;

         declare
            Case_Node : constant Syn.Node_Id :=
              Syn.Nth_Case (Body_Tree.all, Part, Which);
            Count : constant Natural :=
              Syn.Payload_Field_Count (Body_Tree.all, Case_Node);
         begin
            if Syn.Kind (Of_Tree, Value) = Syn.Name_Reference then
               if Count > 0 then
                  Bad.Report
                    (Item    => Bad.Type_Mismatch,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Value),
                     Message => "this case has a payload, so its fields"
                                & " must be constructed",
                     Note    => "D76: only a payload-free case is a bare"
                                & " case value",
                     Related => Syn.Origin (Body_Tree.all, Case_Node),
                     Because => "declared with a payload here",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Value);
               end if;
               return;
            end if;

            declare
               type Node_List is array (Natural range <>) of Syn.Node_Id;
               First : Node_List (1 .. Count) := [others => Syn.No_Node];
            begin
               for Position in
                 1 .. Syn.Field_Value_Count (Of_Tree, Value)
               loop
                  declare
                     Label : constant Syn.Node_Id :=
                       Syn.Nth_Field_Value (Of_Tree, Value, Position);
                     Given : constant Syn.Node_Id :=
                       Syn.Value_Of (Of_Tree, Label);
                     Payload_Field : Natural := 0;
                  begin
                     for Candidate in 1 .. Count loop
                        if Syn.Name (Of_Tree, Label)
                          = Syn.Name
                              (Body_Tree.all,
                               Syn.Nth_Payload_Field
                                 (Body_Tree.all, Case_Node, Candidate))
                        then
                           Payload_Field := Candidate;
                           exit;
                        end if;
                     end loop;

                     if Payload_Field = 0 then
                        Bad.Report
                          (Item    => Bad.Unresolved_Field,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Anchor (Of_Tree, Label),
                           Message => "this variant case has no payload"
                                      & " field called `"
                                      & Spelled (Syn.Name (Of_Tree, Label))
                                      & "`",
                           Note    => "D76: a case construction has exactly"
                                      & " its declared payload fields",
                           Into    => Found);
                        Failed := True;
                     elsif First (Payload_Field) /= Syn.No_Node then
                        Bad.Report
                          (Item    => Bad.Field_Named_Twice,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Anchor (Of_Tree, Label),
                           Message => "this payload field is named twice",
                           Note    => "D76: each case payload field is"
                                      & " written once",
                           Related => Syn.Origin
                             (Of_Tree, First (Payload_Field)),
                           Because => "first named here",
                           Into    => Found);
                        Failed := True;
                     else
                        First (Payload_Field) := Label;
                        Landin.Checking.Note_Field
                          (Types.all, Of_Tree, Label, Payload_Field);

                        declare
                           Shape : constant Landin.Checking.Field_Shape :=
                             Landin.Checking.Nth_Variant_Case_Field
                               (Types.all, Wrote, Field, Which,
                                Payload_Field);
                        begin
                           case Shape.Kind is
                              when Landin.Checking.Scalar_Field =>
                                 if Shape.Signature /=
                                      Landin.Checking.No_Signature
                                   and then Syn.Kind (Of_Tree, Given)
                                     = Syn.Zeroed_Literal
                                 then
                                    Bad.Report
                                      (Item    => Bad.Type_Mismatch,
                                       Source  => Syn.Source_Of (Of_Tree),
                                       Where   => Syn.Where (Of_Tree, Given),
                                       Message => "a function-valued"
                                                  & " payload has no zero"
                                                  & " image",
                                       Note    => "[0540]: a function"
                                                  & " address is never the"
                                                  & " null address",
                                       Related => Syn.Origin
                                         (Of_Tree, Label),
                                       Because => "the variant payload field"
                                                  & " named here",
                                       Into    => Found);
                                    Landin.Checking.Refuse
                                      (Types.all, Of_Tree, Given);
                                 elsif Shape.Signature /=
                                      Landin.Checking.No_Signature
                                 then
                                    declare
                                       Got : constant Ty.Type_Kind :=
                                         Synthesise (Of_Tree, Given);
                                    begin
                                       if Got = Ty.Function_Value
                                         and then not Signatures_Agree
                                           (Shape.Signature,
                                            Landin.Checking.Signature_Of
                                              (Types.all, Of_Tree, Given))
                                       then
                                          Bad.Report
                                            (Item    => Bad.Type_Mismatch,
                                             Source  => Syn.Source_Of
                                               (Of_Tree),
                                             Where   => Syn.Where
                                               (Of_Tree, Given),
                                             Message => "this function has"
                                               & " a different signature",
                                             Note    => "[1000]: a function"
                                               & " payload keeps its complete"
                                               & " structural signature",
                                             Related => Syn.Origin
                                               (Of_Tree, Label),
                                             Because => "the variant payload"
                                               & " field named here",
                                             Into    => Found);
                                          Landin.Checking.Refuse
                                            (Types.all, Of_Tree, Given);
                                       elsif Got /= Ty.Function_Value
                                         and then Got /= Ty.Ill_Typed
                                       then
                                          Require
                                            (Of_Tree, Given,
                                             Ty.Function_Value,
                                             Syn.Origin (Of_Tree, Label),
                                             "the function-valued variant"
                                             & " payload field named here");
                                       end if;
                                    end;
                                 elsif Syn.Kind (Of_Tree, Given)
                                         = Syn.Zeroed_Literal
                                 then
                                    Landin.Checking.Note
                                      (Types.all, Of_Tree, Given,
                                       Shape.Element);
                                 else
                                    Require
                                      (Of_Tree, Given, Shape.Element,
                                       Syn.Origin (Of_Tree, Label),
                                       "the variant payload field named"
                                       & " here");
                                 end if;

                                 if Static_Image
                                   and then Landin.Checking.Type_Of
                                     (Types.all, Of_Tree, Given)
                                       /= Ty.Ill_Typed
                                 then
                                    if Shape.Signature =
                                         Landin.Checking.No_Signature
                                    then
                                       Refuse_Static_Image_Subtree
                                         (Of_Tree, Given,
                                          "a module variant payload field");
                                    end if;

                                    if Subtree_Was_Refused (Given) then
                                       Landin.Checking.Refuse
                                         (Types.all, Of_Tree, Given);
                                    elsif not Is_Known (Of_Tree, Given) then
                                       Bad.Report
                                         (Item    =>
                                            Bad.Not_Known_At_Compile_Time,
                                          Source  => Syn.Source_Of (Of_Tree),
                                          Where   => Syn.Where
                                            (Of_Tree, Given),
                                          Message => "this variant payload"
                                            & " value has to be known when"
                                            & " the module image is formed",
                                          Note    => "[1940]: nothing runs"
                                            & " before the entry point"
                                            & " [1460]",
                                          Into    => Found);
                                       Landin.Checking.Refuse
                                         (Types.all, Of_Tree, Given);
                                    end if;
                                 end if;

                              when Landin.Checking.Fixed_Array_Field =>
                                 Check_Fixed_Array_Payload
                                   (Label, Given, Shape);

                              when Landin.Checking.Aggregate_Field =>
                                 Check_Aggregate_Payload
                                   (Label, Given, Shape);

                              when Landin.Checking.Variant_Field =>
                                 raise Landin.Compiler_Defect with
                                   "a nested variant payload reached D76";
                           end case;
                        end;

                        Failed := Failed
                          or else Landin.Checking.Type_Of
                            (Types.all, Of_Tree, Given) = Ty.Ill_Typed;
                     end if;
                  end;
               end loop;

               declare
                  Fill : constant Syn.Node_Id :=
                    Syn.Struct_Fill (Of_Tree, Value);
                  Missing : Ada.Strings.Unbounded.Unbounded_String;
                  Missing_Count : Natural := 0;
               begin
                  if Fill /= Syn.No_Node
                    and then Syn.Kind (Of_Tree, Fill)
                               /= Syn.Zeroed_Literal
                  then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Fill),
                        Message => "a case construction's trailing `of`"
                                   & " accepts only `zeroed`",
                        Refused => Bad.Variant_Value,
                        Into    => Found);
                     Landin.Checking.Refuse (Types.all, Of_Tree, Fill);
                     Failed := True;
                  end if;

                  if Fill /= Syn.No_Node
                    and then Syn.Kind (Of_Tree, Fill) = Syn.Zeroed_Literal
                  then
                     for Candidate in First'Range loop
                        if First (Candidate) = Syn.No_Node then
                           declare
                              Shape : constant Landin.Checking.Field_Shape :=
                                Landin.Checking.Nth_Variant_Case_Field
                                  (Types.all, Wrote, Field, Which,
                                   Candidate);
                              Zeroable : constant Boolean :=
                                (case Shape.Kind is
                                    when Landin.Checking.Scalar_Field =>
                                      Shape.Signature =
                                        Landin.Checking.No_Signature,
                                    when Landin.Checking.Fixed_Array_Field =>
                                      Shape.Length = 0
                                      or else Shape.Nominal =
                                        Landin.Checking.No_Nominal_Type
                                      or else Has_Zero_Image
                                        (Shape.Nominal),
                                    when Landin.Checking.Aggregate_Field =>
                                      Has_Zero_Image (Shape.Nominal),
                                    when Landin.Checking.Variant_Field =>
                                      False);
                           begin
                              if not Zeroable then
                                 Bad.Report
                                   (Item    => Bad.Type_Mismatch,
                                    Source  => Syn.Source_Of (Of_Tree),
                                    Where   => Syn.Where (Of_Tree, Fill),
                                    Message => "`of zeroed` cannot fill a"
                                               & " payload field with no"
                                               & " zero image",
                                    Note    => "[0540]: a function address"
                                               & " has no all-bits-zero"
                                               & " value",
                                    Related => Syn.Origin (Of_Tree, Value),
                                    Because => "the case construction",
                                    Into    => Found);
                                 Landin.Checking.Refuse
                                   (Types.all, Of_Tree, Fill);
                                 Failed := True;
                                 exit;
                              end if;
                           end;
                        end if;
                     end loop;
                  end if;

                  if Fill = Syn.No_Node then
                     for Candidate in First'Range loop
                        if First (Candidate) = Syn.No_Node then
                           Missing_Count := Missing_Count + 1;
                           if Missing_Count > 1 then
                              Ada.Strings.Unbounded.Append (Missing, ", ");
                           end if;
                           Ada.Strings.Unbounded.Append
                             (Missing, "`"
                              & Spelled
                                  (Syn.Name
                                     (Body_Tree.all,
                                      Syn.Nth_Payload_Field
                                        (Body_Tree.all, Case_Node,
                                         Candidate)))
                              & "`");
                        end if;
                     end loop;

                     if Missing_Count > 0 then
                        Bad.Report
                          (Item    => Bad.Field_Not_Given,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Value),
                           Message => "this case construction gives no"
                                      & " value for "
                                      & Ada.Strings.Unbounded.To_String
                                          (Missing),
                           Note    => "D76: every payload field is labelled"
                                      & " or covered by trailing `of"
                                      & " zeroed`",
                           Into    => Found);
                        Failed := True;
                     end if;
                  end if;
               end;
            end;
         end;

         if Failed then
            Landin.Checking.Refuse (Types.all, Of_Tree, Value);
         end if;
      end Check_Variant_Value;

      --  D64: a labelled struct literal is contextual.  The destination
      --  supplies [0710]'s nominal body; labels may be written in any order,
      --  but each names one scalar field at most once.  A trailing
      --  `of zeroed` covers every field not named explicitly, including an
      --  array field through D49's whole-field zero image.
      procedure Check_Struct_Literal
        (Of_Tree      : Syn.Tree;
         Literal      : Syn.Node_Id;
         Wrote        : Landin.Checking.Nominal_Type_Id;
         Static_Image : Boolean)
      is
         Count : constant Natural :=
           (if Landin.Checking.Has_Layout (Types.all, Wrote)
            then Landin.Checking.Layout_Field_Count (Types.all, Wrote)
            else 0);
         type Node_List is array (Natural range <>) of Syn.Node_Id;
         First : Node_List (1 .. Count) := [others => Syn.No_Node];
         Failed : Boolean := False;

         function Subtree_Was_Refused (Node : Syn.Node_Id) return Boolean;

         function Subtree_Was_Refused (Node : Syn.Node_Id) return Boolean is
         begin
            if Node = Syn.No_Node then
               return False;
            end if;

            if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                 = Ty.Ill_Typed
            then
               return True;
            end if;

            for Slot in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
               if Subtree_Was_Refused (Syn.Slot (Of_Tree, Node, Slot)) then
                  return True;
               end if;
            end loop;
            return False;
         end Subtree_Was_Refused;

         procedure Check_Aggregate_Field
           (Field : Syn.Node_Id; Value : Syn.Node_Id; Which : Positive);

         procedure Check_Aggregate_Field
           (Field : Syn.Node_Id; Value : Syn.Node_Id; Which : Positive)
         is
            Expected : constant Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.Field_Shape_Of
                (Types.all, Wrote, Which).Nominal;
            Got : Ty.Type_Kind;
         begin
            if Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal then
               Check_Aggregate_Zeroed
                 (Of_Tree, Value, Expected,
                  Syn.Origin (Of_Tree, Field),
                  "the ordinary-child field");
               return;
            elsif Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal then
               if Construction_Agrees
                    (Of_Tree, Value, Expected,
                     Syn.Origin (Of_Tree, Field),
                     "this ordinary-child field")
               then
                  Check_Struct_Literal
                    (Of_Tree, Value, Expected,
                     Static_Image => Static_Image);
               end if;
               return;
            elsif Static_Image
              and then
                ((Syn.Kind (Of_Tree, Value) = Syn.Name_Reference
                  and then Res.Verdict_Of
                    (Meanings.all, Of_Tree, Value) = Res.Bound
                  and then Res.Sort_Of
                    (Meanings.all,
                     Res.Bound_To (Meanings.all, Of_Tree, Value))
                      = Res.Module_Binding)
                 or else Is_Direct_Module_Field (Of_Tree, Value))
            then
               Got := Selected_From (Of_Tree, Value);
            elsif not Static_Image
              and then
                (Is_Direct_Binding_Name (Of_Tree, Value)
                 or else Is_Aggregate_Alias_Name (Of_Tree, Value)
                 or else Syn.Kind (Of_Tree, Value) = Syn.Member_Selection)
            then
               Got := Selected_From (Of_Tree, Value);
            else
               Got := Synthesise (Of_Tree, Value);
               if Static_Image and then Got /= Ty.Ill_Typed then
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Value),
                     Message => "a module ordinary-child field takes"
                                & " `zeroed`, a static construction, or a"
                                & " module struct or direct child image",
                     Refused => Bad.Struct_Value,
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Value);
                  return;
               end if;
            end if;

            if Got = Ty.Aggregate
              and then Landin.Checking.Nominal_Of
                (Types.all, Of_Tree, Value) = Expected
            then
               if Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal then
                  Check_Struct_Literal
                    (Of_Tree, Value, Expected, Static_Image => False);
               end if;
            elsif Got /= Ty.Ill_Typed then
               Bad.Report
                 (Item    => Bad.Type_Mismatch,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Value),
                  Message => "this is not the nominal struct type named by"
                             & " the ordinary-child field",
                  Note    => "[0710]: ordinary struct identity is nominal",
                  Related => Syn.Origin (Of_Tree, Field),
                  Because => "the child field named here",
                  Into    => Found);
               Landin.Checking.Refuse (Types.all, Of_Tree, Value);
            end if;
         end Check_Aggregate_Field;

         procedure Check_Array_Field
           (Field : Syn.Node_Id; Value : Syn.Node_Id; Which : Positive);

         procedure Check_Array_Field
           (Field : Syn.Node_Id; Value : Syn.Node_Id; Which : Positive)
         is
            Expected : constant Landin.Checking.Element_Count :=
              Landin.Checking.Field_Array_Length
                (Types.all, Wrote, Which);
            Element : constant Ty.Scalar_Name :=
              Landin.Checking.Field_Array_Element
                (Types.all, Wrote, Which);
            Element_Nominal : constant Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.Field_Shape_Of
                (Types.all, Wrote, Which).Nominal;

            procedure Require_Known (Each : Syn.Node_Id);

            procedure Require_Known (Each : Syn.Node_Id) is
            begin
               if not Subtree_Was_Refused (Each)
                 and then not Is_Known (Of_Tree, Each)
               then
                  Bad.Report
                    (Item    => Bad.Not_Known_At_Compile_Time,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Each),
                     Message => "this array-field image value has to be"
                                & " known when the module image is formed",
                     Note    => "[1940]: nothing runs before the entry"
                                & " point [1460]",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Each);
               end if;
            end Require_Known;
         begin
            --  D65 makes the label the same contextual destination as the
            --  selected field in D49--D53.  Each established array spelling
            --  keeps its own shape check and diagnostic owner.  D67 admits
            --  the finite and zero static forms; D68 adds D34/D38's compact
            --  repetitions, D69 follows one direct module-array image name,
            --  and D71 follows one directly selected module struct field
            --  without making either source a general value.
            if Static_Image then
               case Syn.Kind (Of_Tree, Value) is
                  when Syn.Array_Literal =>
                     Check_Array_Literal
                       (Of_Tree, Field, Value, Expected, Element,
                        Static_Image => True);

                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Value)
                     loop
                        Require_Known
                          (Syn.Nth_Element (Of_Tree, Value, Position));
                     end loop;

                     if Subtree_Was_Refused (Value) then
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Value);
                     end if;

                  when Syn.Array_Repetition =>
                     Check_Array_Repetition
                       (Of_Tree, Field, Value, Expected, Element,
                        Static_Image => True);
                     Require_Known
                       (Syn.Repeated_Element (Of_Tree, Value));

                     if Subtree_Was_Refused (Value) then
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Value);
                     end if;

                  when Syn.Mixed_Array_Repetition =>
                     Check_Mixed_Array_Repetition
                       (Of_Tree, Field, Value, Expected, Element,
                        Static_Image => True);
                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Value)
                     loop
                        Require_Known
                          (Syn.Nth_Element (Of_Tree, Value, Position));
                     end loop;
                     Require_Known
                       (Syn.Repeated_Element (Of_Tree, Value));

                     if Subtree_Was_Refused (Value) then
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Value);
                     end if;

                  when Syn.Zeroed_Literal =>
                     Check_Array_Zeroed
                       (Of_Tree, Value, Expected, Element, Element_Nominal,
                        Syn.Origin (Of_Tree, Field),
                        "the array field named here");

                  when Syn.Name_Reference =>
                     declare
                        Is_Module_Storage : constant Boolean :=
                          Res.Verdict_Of (Meanings.all, Of_Tree, Value)
                            = Res.Bound
                          and then Res.Sort_Of
                            (Meanings.all,
                             Res.Bound_To
                               (Meanings.all, Of_Tree, Value))
                              = Res.Module_Binding;
                        Got : constant Ty.Type_Kind :=
                          (if Is_Module_Storage
                           then Selected_From (Of_Tree, Value)
                           else Synthesise (Of_Tree, Value));
                     begin
                        if Got = Ty.Ill_Typed then
                           --  Resolution or the source declaration already
                           --  owns the report.  The contextual label adds no
                           --  second refusal.
                           null;
                        elsif Is_Module_Storage
                          and then
                            (Got /= Ty.Fixed_Array
                             or else Landin.Checking.Array_Length
                               (Types.all, Of_Tree, Value) /= Expected
                             or else Landin.Checking.Array_Element
                               (Types.all, Of_Tree, Value) /= Element)
                        then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Value),
                              Message => "this is not a module array of the"
                                         & " type named by the struct field",
                              Note    => "D17: an array's length and element"
                                         & " type are its identity",
                              Related => Syn.Origin (Of_Tree, Field),
                              Because => "the field named here",
                              Into    => Found);
                           Landin.Checking.Refuse
                             (Types.all, Of_Tree, Value);
                        end if;
                     end;

                  when Syn.Member_Selection =>
                     declare
                        Is_Module_Storage : constant Boolean :=
                          Is_Direct_Module_Field (Of_Tree, Value);
                        Admitted : constant Boolean :=
                          Is_Module_Storage
                          and then Admit_Array_Field (Of_Tree, Value);
                        Got : constant Ty.Type_Kind :=
                          (if Admitted
                           then Selected_From (Of_Tree, Value)
                           else Synthesise (Of_Tree, Value));
                     begin
                        if Got = Ty.Ill_Typed then
                           --  The root declaration, its layout or the field
                           --  lookup already owns the report.
                           null;
                        elsif Is_Module_Storage
                          and then not Is_Module_Array_Field
                            (Of_Tree, Value, Expected, Element)
                        then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Value),
                              Message => "this is not an array field of the"
                                         & " type named by this label",
                              Note    => "D17: an array's length and element"
                                         & " type are its identity",
                              Related => Syn.Origin (Of_Tree, Field),
                              Because => "the field named here",
                              Into    => Found);
                           Landin.Checking.Refuse
                             (Types.all, Of_Tree, Value);
                        end if;
                     end;

                  when others =>
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Value),
                        Message => "a module struct array field takes a"
                                   & " finite literal, repetition, `zeroed`"
                                   & " or a module array or array-field name"
                                   & " in this slice",
                        Refused => Bad.Array_Value,
                        Into    => Found);
                     Landin.Checking.Refuse
                       (Types.all, Of_Tree, Value);
               end case;
               return;
            end if;

            case Syn.Kind (Of_Tree, Value) is
               when Syn.Array_Literal =>
                  Check_Array_Literal
                    (Of_Tree, Field, Value, Expected, Element,
                     Static_Image => False);

               when Syn.Array_Repetition =>
                  Check_Array_Repetition
                    (Of_Tree, Field, Value, Expected, Element,
                     Static_Image => False);

               when Syn.Mixed_Array_Repetition =>
                  Check_Mixed_Array_Repetition
                    (Of_Tree, Field, Value, Expected, Element,
                     Static_Image => False);

               when Syn.Zeroed_Literal =>
                  Check_Array_Zeroed
                    (Of_Tree, Value, Expected, Element, Element_Nominal,
                     Syn.Origin (Of_Tree, Field),
                     "the array field named here");

               when others =>
                  declare
                     Admitted : constant Boolean :=
                       Syn.Kind (Of_Tree, Value) = Syn.Member_Selection
                       and then Admit_Array_Field (Of_Tree, Value);
                     Got : constant Ty.Type_Kind :=
                       (if Admitted
                            or else Is_Direct_Binding_Name (Of_Tree, Value)
                        then Selected_From (Of_Tree, Value)
                        else Synthesise (Of_Tree, Value));
                  begin
                     if Got = Ty.Ill_Typed then
                        null;
                     elsif Got /= Ty.Fixed_Array
                       or else Landin.Checking.Array_Length
                         (Types.all, Of_Tree, Value) /= Expected
                       or else Landin.Checking.Array_Element
                         (Types.all, Of_Tree, Value) /= Element
                     then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Value),
                           Message => "this is not an array of the type"
                                      & " named by the struct field",
                           Note    => "D17: an array's length and element"
                                      & " type are its identity",
                           Related => Syn.Origin (Of_Tree, Field),
                           Because => "the field named here",
                           Into    => Found);
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Value);
                     end if;
                  end;
            end case;
         end Check_Array_Field;
      begin
         --  A refused field or a target extent overflow leaves the body
         --  identified but deliberately without a layout.  That refusal
         --  owns the diagnostic; the contextual literal must neither ask
         --  the absent layout for field shapes nor add a cascade.
         if not Landin.Checking.Has_Layout (Types.all, Wrote) then
            Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
            return;
         end if;

         if Landin.Checking.Type_Of (Types.all, Of_Tree, Literal)
              = Ty.Ill_Typed
         then
            return;
         elsif Landin.Checking.Type_Of (Types.all, Of_Tree, Literal)
                 = Ty.Undecided
         then
            Landin.Checking.Note
              (Types.all, Of_Tree, Literal, Ty.Aggregate);
            Landin.Checking.Note_Nominal (Types.all, Of_Tree, Literal, Wrote);
         end if;

         for Position in 1 .. Syn.Field_Value_Count (Of_Tree, Literal) loop
            declare
               Field : constant Syn.Node_Id :=
                 Syn.Nth_Field_Value (Of_Tree, Literal, Position);
               Value : constant Syn.Node_Id := Syn.Value_Of (Of_Tree, Field);
               Which : constant Natural :=
                 Field_At (Wrote, Syn.Name (Of_Tree, Field));
            begin
               if Which = 0 then
                  Bad.Report
                    (Item    => Bad.Unresolved_Field,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Anchor (Of_Tree, Field),
                     Message => "this struct has no field called `"
                                & Spelled (Syn.Name (Of_Tree, Field)) & "`",
                     Note    => "[0750]: a struct has the fields it was"
                                & " declared with, and no others",
                     Into    => Found);
                  Failed := True;
               elsif First (Which) /= Syn.No_Node then
                  Bad.Report
                    (Item    => Bad.Field_Named_Twice,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Anchor (Of_Tree, Field),
                     Message => "the field `" & Field_Named (Wrote, Which)
                                & "` is named twice in this struct literal",
                     Note    => "D64: each labelled field is written once",
                     Related => Syn.Origin (Of_Tree, First (Which)),
                     Because => "first named here",
                     Into    => Found);
                  Failed := True;
               else
                  First (Which) := Field;
                  Landin.Checking.Note_Field
                    (Types.all, Of_Tree, Field, Which);

                  case Landin.Checking.Field_Kind_Of
                    (Types.all, Wrote, Which)
                  is
                     when Landin.Checking.Scalar_Field =>
                        declare
                           Shape : constant Landin.Checking.Field_Shape :=
                             Landin.Checking.Field_Shape_Of
                               (Types.all, Wrote, Which);
                           Held : constant Ty.Scalar_Name := Shape.Element;
                        begin
                           if Shape.Signature /= Landin.Checking.No_Signature
                             and then Syn.Kind (Of_Tree, Value)
                               = Syn.Zeroed_Literal
                           then
                              Bad.Report
                                (Item    => Bad.Type_Mismatch,
                                 Source  => Syn.Source_Of (Of_Tree),
                                 Where   => Syn.Where (Of_Tree, Value),
                                 Message => "a function-valued field has no"
                                            & " zero image",
                                 Note    => "[0540]: a function address is"
                                            & " never the null address",
                                 Related => Syn.Origin (Of_Tree, Field),
                                 Because => "the struct field named here",
                                 Into    => Found);
                              Landin.Checking.Refuse
                                (Types.all, Of_Tree, Value);
                           elsif Shape.Signature /=
                               Landin.Checking.No_Signature
                           then
                              declare
                                 Got : constant Ty.Type_Kind :=
                                   Synthesise (Of_Tree, Value);
                              begin
                                 if Got = Ty.Function_Value
                                   and then not Signatures_Agree
                                     (Shape.Signature,
                                      Landin.Checking.Signature_Of
                                        (Types.all, Of_Tree, Value))
                                 then
                                    Bad.Report
                                      (Item    => Bad.Type_Mismatch,
                                       Source  => Syn.Source_Of (Of_Tree),
                                       Where   => Syn.Where (Of_Tree, Value),
                                       Message => "this function has a"
                                                  & " different signature",
                                       Note    => "[1000]: a function-valued"
                                                  & " field keeps its complete"
                                                  & " structural signature",
                                       Related => Syn.Origin
                                         (Of_Tree, Field),
                                       Because => "the struct field named"
                                                  & " here",
                                       Into    => Found);
                                    Landin.Checking.Refuse
                                      (Types.all, Of_Tree, Value);
                                 elsif Got /= Ty.Function_Value
                                   and then Got /= Ty.Ill_Typed
                                 then
                                    Require
                                      (Of_Tree, Value, Ty.Function_Value,
                                       Syn.Origin (Of_Tree, Field),
                                       "the function-valued struct field"
                                       & " named here");
                                 end if;
                              end;
                           elsif Syn.Kind (Of_Tree, Value)
                                   = Syn.Zeroed_Literal
                           then
                              --  D65 extends D42's contextual zero image to
                              --  the ordinary scalar field this label names.
                              Landin.Checking.Note
                                (Types.all, Of_Tree, Value, Held);
                           else
                              Require
                                (Of_Tree, Value, Held,
                                 Syn.Origin (Of_Tree, Field),
                                 "the struct field named here");
                           end if;

                           if Static_Image
                             and then Landin.Checking.Type_Of
                               (Types.all, Of_Tree, Value) /= Ty.Ill_Typed
                           then
                              if Shape.Signature =
                                   Landin.Checking.No_Signature
                              then
                                 Refuse_Static_Image_Subtree
                                   (Of_Tree, Value,
                                    "a module struct literal field");
                              end if;

                              if Subtree_Was_Refused (Value) then
                                 Landin.Checking.Refuse
                                   (Types.all, Of_Tree, Value);
                              elsif not Is_Known (Of_Tree, Value) then
                                 Bad.Report
                                   (Item    =>
                                      Bad.Not_Known_At_Compile_Time,
                                    Source  => Syn.Source_Of (Of_Tree),
                                    Where   => Syn.Where (Of_Tree, Value),
                                    Message => "this struct field value has"
                                               & " to be known when the"
                                               & " module image is formed",
                                    Note    => "[1940]: nothing runs before"
                                               & " the entry point [1460]",
                                    Into    => Found);
                                 Landin.Checking.Refuse
                                   (Types.all, Of_Tree, Value);
                              end if;
                           end if;
                        end;

                     when Landin.Checking.Fixed_Array_Field =>
                        Check_Array_Field (Field, Value, Which);

                     when Landin.Checking.Aggregate_Field =>
                        Check_Aggregate_Field (Field, Value, Which);

                     when Landin.Checking.Variant_Field =>
                        Check_Variant_Value
                          (Of_Tree, Field, Value, Wrote, Which,
                           Static_Image);
                  end case;

                  Failed := Failed
                    or else Landin.Checking.Type_Of
                      (Types.all, Of_Tree, Value) = Ty.Ill_Typed;
               end if;
            end;
         end loop;

         declare
            Fill : constant Syn.Node_Id :=
              Syn.Struct_Fill (Of_Tree, Literal);
            Missing : Ada.Strings.Unbounded.Unbounded_String;
            Missing_Count : Natural := 0;
         begin
            if Fill /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Fill) /= Syn.Zeroed_Literal
            then
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Fill),
                  Message => "a struct literal's trailing `of` accepts only"
                             & " `zeroed` in this slice",
                  Refused => Bad.Struct_Value,
                  Into    => Found);
               Landin.Checking.Refuse (Types.all, Of_Tree, Fill);
               Failed := True;
            end if;

            if Fill /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Fill) = Syn.Zeroed_Literal
            then
               for Which in First'Range loop
                  if First (Which) = Syn.No_Node
                    and then not Field_Has_Zero_Image (Wrote, Which)
                  then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Fill),
                        Message => "`of zeroed` cannot fill field `"
                                   & Field_Named (Wrote, Which)
                                   & "`, which has no zero image",
                        Note    => "[0540]: a function address has no"
                                   & " all-bits-zero value",
                        Related => Syn.Origin (Of_Tree, Literal),
                        Because => "the struct literal",
                        Into    => Found);
                     Landin.Checking.Refuse
                       (Types.all, Of_Tree, Fill);
                     Failed := True;
                     exit;
                  end if;
               end loop;
            end if;

            if Fill = Syn.No_Node then
               for Which in First'Range loop
                  if First (Which) = Syn.No_Node then
                     Missing_Count := Missing_Count + 1;
                     if Missing_Count > 1 then
                        Ada.Strings.Unbounded.Append (Missing, ", ");
                     end if;
                     Ada.Strings.Unbounded.Append
                       (Missing, "`" & Field_Named (Wrote, Which) & "`");
                  end if;
               end loop;

               if Missing_Count > 0 then
                  Bad.Report
                    (Item    => Bad.Field_Not_Given,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Literal),
                     Message => "this struct literal gives no value for "
                                & Ada.Strings.Unbounded.To_String (Missing),
                     Note    => "D64: every field is labelled or covered by"
                                & " a trailing `of zeroed`",
                     Into    => Found);
                  Failed := True;
               end if;
            end if;
         end;

         if Failed then
            Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
         end if;
      end Check_Struct_Literal;

      procedure Check_Mixed_Array_Repetition
        (Of_Tree      : Syn.Tree;
         Site_Node    : Syn.Node_Id;
         Repetition   : Syn.Node_Id;
         Expected     : Landin.Checking.Element_Count;
         Element      : Ty.Scalar_Name;
         Static_Image : Boolean;
         Context_Site : Landin.Provenance.Origin :=
           Landin.Provenance.No_Origin)
      is
         Prefix : constant Natural := Syn.Element_Count (Of_Tree, Repetition);
         Related : constant Landin.Provenance.Origin :=
           (if Landin.Provenance.Is_Known (Context_Site)
            then Context_Site else Syn.Origin (Of_Tree, Site_Node));
      begin
         --  Check_Module_Value may already have refused a non-static subtree
         --  and marked the complete hybrid ill typed before this contextual
         --  shape walk.  Do not note the same node a second time.
         if Landin.Checking.Type_Of (Types.all, Of_Tree, Repetition)
              = Ty.Undecided
         then
            Landin.Checking.Note
              (Types.all, Of_Tree, Repetition, Ty.Fixed_Array);
            Landin.Checking.Note_Array
              (Types.all, Of_Tree, Repetition, Expected, Element);
         end if;

         --  The parser makes the prefix nonempty.  D36/D37 also require at
         --  least one destination position to remain for the repeated suffix.
         if Landin.Checking.Element_Count (Prefix) >= Expected then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Repetition),
               Message => "this mixed repetition leaves no array suffix to"
                          & " fill",
               Note    => "D36/D37: a prefix requires 1 <= k < N",
               Related => Related,
               Because => "the array context here",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Repetition);
         end if;

         for Position in 1 .. Prefix loop
            Require
              (Of_Tree, Syn.Nth_Element (Of_Tree, Repetition, Position),
               Element, Related,
               "the array element type");
         end loop;

         Require
           (Of_Tree, Syn.Repeated_Element (Of_Tree, Repetition), Element,
            Related, "the array element type");

         if Static_Image then
            declare
               procedure Refuse_Excluded_Subtree (Where : Syn.Node_Id);

               procedure Refuse_Excluded_Subtree (Where : Syn.Node_Id) is
                  What : constant String :=
                    (case Syn.Kind (Of_Tree, Where) is
                        when Syn.Member_Selection => "a field selection",
                        when Syn.Element_Index    => "an array index",
                        when Syn.Array_Literal    => "a nested array literal",
                        when others               => "");
               begin
                  if What /= "" then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Where),
                        Message => What & " is not enabled as a module"
                                   & " mixed array repetition element",
                        Refused => Bad.Array_Value,
                        Into    => Found);
                     Landin.Checking.Refuse (Types.all, Of_Tree, Where);
                     return;
                  end if;

                  for Slot in 1 .. Syn.Slot_Count (Of_Tree, Where) loop
                     Refuse_Excluded_Subtree
                       (Syn.Slot (Of_Tree, Where, Slot));
                  end loop;
               end Refuse_Excluded_Subtree;
            begin
               for Position in 1 .. Prefix loop
                  Refuse_Excluded_Subtree
                    (Syn.Nth_Element (Of_Tree, Repetition, Position));
               end loop;
               Refuse_Excluded_Subtree
                 (Syn.Repeated_Element (Of_Tree, Repetition));
            end;
         end if;
      end Check_Mixed_Array_Repetition;

      procedure Check_Array_Repetition
        (Of_Tree      : Syn.Tree;
         Site_Node    : Syn.Node_Id;
         Repetition   : Syn.Node_Id;
         Expected     : Landin.Checking.Element_Count;
         Element      : Ty.Scalar_Name;
         Static_Image : Boolean;
         Context_Site : Landin.Provenance.Origin :=
           Landin.Provenance.No_Origin)
      is
         Count : constant Syn.Node_Id :=
           Syn.Repetition_Count (Of_Tree, Repetition);
         Related : constant Landin.Provenance.Origin :=
           (if Landin.Provenance.Is_Known (Context_Site)
            then Context_Site else Syn.Origin (Of_Tree, Site_Node));
      begin
         --  D32's repetition is contextual like `zeroed`: the destination
         --  supplies the complete array shape, while one scalar expression
         --  supplies the value stored into every element.
         if Landin.Checking.Type_Of (Types.all, Of_Tree, Repetition)
              = Ty.Undecided
         then
            Landin.Checking.Note
              (Types.all, Of_Tree, Repetition, Ty.Fixed_Array);
            Landin.Checking.Note_Array
              (Types.all, Of_Tree, Repetition, Expected, Element);
         end if;

         --  D136 admits [0520]'s zero-length fixed-array type. Repetition
         --  still needs at least one destination position, so a zero
         --  contextual extent is refused by this construct-specific rule.
         if Expected = 0 then
            Bad.Report
              (Item    => Bad.Unsupported_Use,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Repetition),
               Message => "array repetition needs a nonzero contextual length",
               Refused => Bad.Array_Value,
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Repetition);
         end if;

         if Count /= Syn.No_Node then
            declare
               Snap : constant Landin.Source.Snapshot :=
                 Source (Context, Syn.Source_Of (Of_Tree));
               Text : constant String :=
                 Landin.Source.Slice
                   (Snap, Syn.Digit_Span (Of_Tree, Count));
               Value      : Ty.Magnitude;
               Overflowed : Boolean;
            begin
               Ty.Evaluate
                 (Text, Syn.Base (Of_Tree, Count), Value, Overflowed);

               if Overflowed
                 or else Value /= Ty.Magnitude (Expected)
               then
                  Bad.Report
                    (Item    => Bad.Type_Mismatch,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Count),
                     Message => "this repetition count does not match the"
                                & " array context",
                     Note    => "D32: a written repetition count is exactly"
                                & " the destination array's length",
                     Related => Related,
                     Because => "the array context here",
                     Into    => Found);
                  Landin.Checking.Refuse
                    (Types.all, Of_Tree, Repetition);
               end if;
            end;
         end if;

         Require
           (Of_Tree, Syn.Repeated_Element (Of_Tree, Repetition), Element,
            Related, "the array element type");

         if Static_Image then
            declare
               procedure Refuse_Excluded_Subtree (Where : Syn.Node_Id);

               procedure Refuse_Excluded_Subtree (Where : Syn.Node_Id) is
                  What : constant String :=
                    (case Syn.Kind (Of_Tree, Where) is
                        when Syn.Member_Selection => "a field selection",
                        when Syn.Element_Index    => "an array index",
                        when Syn.Array_Literal    => "a nested array literal",
                        when others               => "");
               begin
                  if What /= "" then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Where),
                        Message => What & " is not enabled as a module"
                                   & " array repetition element",
                        Refused => Bad.Array_Value,
                        Into    => Found);
                     Landin.Checking.Refuse (Types.all, Of_Tree, Where);
                     return;
                  end if;

                  for Slot in 1 .. Syn.Slot_Count (Of_Tree, Where) loop
                     Refuse_Excluded_Subtree
                       (Syn.Slot (Of_Tree, Where, Slot));
                  end loop;
               end Refuse_Excluded_Subtree;
            begin
               Refuse_Excluded_Subtree
                 (Syn.Repeated_Element (Of_Tree, Repetition));
            end;
         end if;
      end Check_Array_Repetition;

      --  D77: matching is contextual to one directly selected variant
      --  part.  Case identity comes from resolution, while declaration
      --  order supplies the tag number shared with D76 and lowering.
      procedure Check_Match
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Returns : Ty.Type_Kind;
         Expected : Value_Context := No_Value_Context;
         Value_Site : Landin.Provenance.Origin :=
           Landin.Provenance.No_Origin;
         Value_Because : String := "")
      is
         Subject : constant Syn.Node_Id := Syn.Match_Subject (Of_Tree, Node);

         function Binding_Id (Binding : Syn.Node_Id)
           return Res.Declaration_Id;

         procedure Refuse_Bindings (Arm : Syn.Node_Id);

         function Binding_Id (Binding : Syn.Node_Id)
           return Res.Declaration_Id
         is
         begin
            for Id in Res.Declaration_Id'(1)
                      .. Res.Declaration_Id
                           (Res.Declaration_Count (Meanings.all))
            loop
               if Res.Source_Of (Meanings.all, Id) = Syn.Source_Of (Of_Tree)
                 and then Res.Node_Of (Meanings.all, Id) = Binding
               then
                  return Id;
               end if;
            end loop;
            raise Landin.Compiler_Defect with
              "a match binding the resolver never recorded";
         end Binding_Id;

         procedure Refuse_Bindings (Arm : Syn.Node_Id) is
         begin
            for Position in 1 .. Syn.Match_Binding_Count (Of_Tree, Arm)
            loop
               declare
                  Binding : constant Syn.Node_Id :=
                    Syn.Nth_Match_Binding (Of_Tree, Arm, Position);
                  Id : constant Res.Declaration_Id := Binding_Id (Binding);
               begin
                  Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Binding);
               end;
            end loop;
         end Refuse_Bindings;
      begin
         --  [0640]/[1030]: an atom union is already a closed value set, so
         --  the same exhaustive control form matches it directly.  Unlike a
         --  variant case it has no payload aliases to establish.
         if not Admit_Variant_Field (Of_Tree, Subject)
           and then Synthesise (Of_Tree, Subject) = Ty.Atom_Value
         then
            declare
               Set_Id : constant Landin.Checking.Atom_Set_Id :=
                 Landin.Checking.Atom_Set_Of
                   (Types.all, Of_Tree, Subject);
               Seen : array
                 (1 .. Res.Declaration_Count (Meanings.all)) of Boolean :=
                   [others => False];
               Wildcard : Syn.Node_Id := Syn.No_Node;
            begin
               for Position in 1 .. Syn.Match_Arm_Count (Of_Tree, Node) loop
                  declare
                     Arm : constant Syn.Node_Id :=
                       Syn.Nth_Match_Arm (Of_Tree, Node, Position);
                     Pattern : constant Syn.Node_Id :=
                       Syn.Match_Pattern (Of_Tree, Arm);
                     Means : Res.Declaration_Id := Res.No_Declaration;
                  begin
                     if Syn.Match_Binding_Count (Of_Tree, Arm) /= 0 then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Pattern),
                           Message => "an atom arm has no payload to bind",
                           Note    => "[0630]: an atom is identity without"
                                      & " payload",
                           Related => Syn.Origin (Of_Tree, Subject),
                           Because => "this atom subject",
                           Into    => Found);
                        Refuse_Bindings (Arm);
                     end if;

                     if Syn.Name (Of_Tree, Pattern)
                          = Landin.Source.Names.No_Name
                     then
                        if Wildcard /= Syn.No_Node then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Pattern),
                              Message => "this match has two wildcard arms",
                              Note    => "[0640]: one exhaustive arm can"
                                         & " cover the atoms left over",
                              Related => Syn.Origin (Of_Tree, Wildcard),
                              Because => "the first wildcard",
                              Into    => Found);
                        else
                           Wildcard := Pattern;
                           Landin.Checking.Note
                             (Types.all, Of_Tree, Pattern, Ty.Not_Typed);
                           if Position /= Syn.Match_Arm_Count
                             (Of_Tree, Node)
                           then
                              Bad.Report
                                (Item    => Bad.Type_Mismatch,
                                 Source  => Syn.Source_Of (Of_Tree),
                                 Where   => Syn.Where (Of_Tree, Pattern),
                                 Message => "the wildcard atom arm is last",
                                 Note    => "[0640]: `_` covers every atom"
                                            & " not named by another arm",
                                 Related => Syn.Origin (Of_Tree, Subject),
                                 Because => "this matched atom set",
                                 Into    => Found);
                           end if;
                        end if;
                     elsif Res.Verdict_Of
                       (Meanings.all, Of_Tree, Pattern) = Res.Bound
                     then
                        Means := Res.Bound_To
                          (Meanings.all, Of_Tree, Pattern);
                        if Res.Sort_Of (Meanings.all, Means)
                             /= Res.Module_Atom
                          or else not Landin.Checking.Contains_Atom
                            (Types.all, Set_Id, Means)
                        then
                           Means := Res.No_Declaration;
                        end if;
                     end if;

                     if Syn.Name (Of_Tree, Pattern)
                          /= Landin.Source.Names.No_Name
                     then
                        if Means = Res.No_Declaration then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Pattern),
                              Message => "this atom is not a member of the"
                                         & " matched set",
                              Note    => "[0640]: every named arm belongs to"
                                         & " the subject's atom union",
                              Related => Syn.Origin (Of_Tree, Subject),
                              Because => "this matched atom set",
                              Into    => Found);
                           Landin.Checking.Refuse
                             (Types.all, Of_Tree, Pattern);
                        elsif Seen (Positive (Means)) then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Pattern),
                              Message => "this atom is matched twice",
                              Note    => "[0640]: an exhaustive match names"
                                         & " each atom at most once",
                              Related => Syn.Origin (Of_Tree, Subject),
                              Because => "this matched atom set",
                              Into    => Found);
                        else
                           Seen (Positive (Means)) := True;
                           Landin.Checking.Note
                             (Types.all, Of_Tree, Pattern, Ty.Atom_Value);
                           Landin.Checking.Note_Atom_Set
                             (Types.all, Of_Tree, Pattern,
                              Landin.Checking.Atom_Set_Of
                                (Types.all, Means));
                        end if;
                     end if;

                     Check_Block
                       (Of_Tree, Syn.Body_Of (Of_Tree, Arm), Returns,
                        Expected, Value_Site, Value_Because);
                  end;
               end loop;

               if Wildcard = Syn.No_Node then
                  for Index in 1 .. Landin.Checking.Atom_Count
                    (Types.all, Set_Id)
                  loop
                     declare
                        Missing : constant Res.Declaration_Id :=
                          Landin.Checking.Nth_Atom
                            (Types.all, Set_Id, Index);
                        Their_Tree : constant not null access constant
                          Syn.Tree :=
                            Tree_For (Res.Source_Of (Meanings.all, Missing));
                        Their_Node : constant Syn.Node_Id :=
                          Res.Node_Of (Meanings.all, Missing);
                     begin
                        if not Seen (Positive (Missing)) then
                           Bad.Report
                             (Item    => Bad.Variant_Case_Not_Matched,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Subject),
                              Message => "this match has no arm for `"
                                         & Spelled
                                             (Syn.Name
                                                (Their_Tree.all, Their_Node))
                                         & "`",
                              Note    => "[0640]: matching an atom union is"
                                         & " exhaustive",
                              Into    => Found);
                        end if;
                     end;
                  end loop;
               end if;
               return;
            end;
         end if;

         if not Admit_Variant_Field (Of_Tree, Subject) then
            declare
               Got : constant Ty.Type_Kind := Synthesise (Of_Tree, Subject);
            begin
               if Got /= Ty.Ill_Typed then
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Subject),
                     Message => "a match subject must directly select a"
                                & " variant part",
                     Refused => Bad.Variant_Value,
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Subject);
               end if;
            end;
            return;
         end if;

         declare
            From : constant Syn.Node_Id :=
              Syn.Target_Of (Of_Tree, Subject);
            Wrote : constant Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.Nominal_Of (Types.all, Of_Tree, From);
            Field : constant Positive := Positive
              (Landin.Checking.Field_Index (Types.all, Of_Tree, Subject));
            Body_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of
             (Meanings.all, Template_Declaration (Wrote)));
            Body_Node : constant Syn.Node_Id :=
              Syn.Declared_Type
                (Body_Tree.all, Res.Node_Of
               (Meanings.all, Template_Declaration (Wrote)));
            Part : constant Syn.Node_Id :=
              Syn.Nth_Field (Body_Tree.all, Body_Node, Field);
            Count : constant Positive := Syn.Case_Count
              (Body_Tree.all, Part);
            type Node_List is array (Positive range <>) of Syn.Node_Id;
            First : Node_List (1 .. Count) := [others => Syn.No_Node];
         begin
            for Position in 1 .. Syn.Match_Arm_Count (Of_Tree, Node) loop
               declare
                  Arm : constant Syn.Node_Id :=
                    Syn.Nth_Match_Arm (Of_Tree, Node, Position);
                  Pattern : constant Syn.Node_Id :=
                    Syn.Match_Pattern (Of_Tree, Arm);
                  Means : Res.Declaration_Id := Res.No_Declaration;
                  Which : Natural := 0;
               begin
                  if Res.Verdict_Of (Meanings.all, Of_Tree, Pattern)
                       = Res.Bound
                  then
                     Means := Res.Bound_To (Meanings.all, Of_Tree, Pattern);
                  end if;

                  if Means /= Res.No_Declaration
                    and then Res.Sort_Of (Meanings.all, Means) = Res.Case_Name
                  then
                     for Candidate in 1 .. Count loop
                        if Res.Source_Of (Meanings.all, Means)
                             = Syn.Source_Of (Body_Tree.all)
                          and then Res.Node_Of (Meanings.all, Means)
                             = Syn.Nth_Case
                                 (Body_Tree.all, Part, Candidate)
                        then
                           Which := Candidate;
                           exit;
                        end if;
                     end loop;
                  end if;

                  if Which = 0 then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Pattern),
                        Message => "this case does not belong to the"
                                   & " variant part matched here",
                        Note    => "D77: every arm names one case of the"
                                   & " selected variant part",
                        Related => Syn.Origin (Of_Tree, Subject),
                        Because => "the matched variant part",
                        Into    => Found);
                     Landin.Checking.Refuse
                       (Types.all, Of_Tree, Pattern);
                     Refuse_Bindings (Arm);
                  elsif First (Which) /= Syn.No_Node then
                     Bad.Report
                       (Item    => Bad.Variant_Case_Named_Twice,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Pattern),
                        Message => "this variant case is matched twice",
                        Note    => "D77: an exhaustive match names each"
                                   & " case exactly once",
                        Related => Syn.Origin (Of_Tree, First (Which)),
                        Because => "first matched here",
                        Into    => Found);
                     Landin.Checking.Refuse
                       (Types.all, Of_Tree, Pattern);
                     Refuse_Bindings (Arm);
                  else
                     First (Which) := Pattern;
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Pattern, Ty.Not_Typed);
                     Landin.Checking.Note_Field
                       (Types.all, Of_Tree, Pattern, Which);

                     declare
                        Expected : constant Natural :=
                          Landin.Checking.Variant_Case_Field_Count
                            (Types.all, Wrote, Field, Which);
                        Given : constant Natural :=
                          Syn.Match_Binding_Count (Of_Tree, Arm);
                     begin
                        if Given /= 0 and then Given /= Expected then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Pattern),
                              Message => "this arm binds"
                                         & Natural'Image (Given)
                                         & " payload fields, but the case"
                                         & " has" & Natural'Image (Expected),
                              Note    => "D78: parenthesized payload names"
                                         & " are positional and complete",
                              Related => Syn.Origin (Of_Tree, Subject),
                              Because => "the matched variant part",
                              Into    => Found);
                           Refuse_Bindings (Arm);
                        elsif Given /= 0 then
                           for Payload in 1 .. Given loop
                              declare
                                 Binding : constant Syn.Node_Id :=
                                   Syn.Nth_Match_Binding
                                     (Of_Tree, Arm, Payload);
                                 Id : constant Res.Declaration_Id :=
                                   Binding_Id (Binding);
                                 Shape : constant
                                   Landin.Checking.Field_Shape :=
                                     Landin.Checking.Nth_Variant_Case_Field
                                       (Types.all, Wrote, Field, Which,
                                        Payload);
                              begin
                                 case Shape.Kind is
                                    when Landin.Checking.Scalar_Field =>
                                       if Shape.Signature /=
                                            Landin.Checking.No_Signature
                                       then
                                          Landin.Checking.Settle
                                            (Types.all, Id,
                                             Ty.Function_Value);
                                          Landin.Checking.Note
                                            (Types.all, Of_Tree, Binding,
                                             Ty.Function_Value);
                                          Landin.Checking.Note_Signature
                                            (Types.all, Id, Shape.Signature);
                                          Landin.Checking.Note_Signature
                                            (Types.all, Of_Tree, Binding,
                                             Shape.Signature);
                                       else
                                          Landin.Checking.Settle
                                            (Types.all, Id, Shape.Element);
                                          Landin.Checking.Note
                                            (Types.all, Of_Tree, Binding,
                                             Shape.Element);
                                       end if;

                                    when Landin.Checking.Fixed_Array_Field =>
                                       Landin.Checking.Settle
                                         (Types.all, Id, Ty.Fixed_Array);
                                       Landin.Checking.Note
                                         (Types.all, Of_Tree, Binding,
                                          Ty.Fixed_Array);
                                       Landin.Checking.Note_Array
                                         (Types.all, Id,
                                          Shape.Length, Shape.Element);

                                    when Landin.Checking.Aggregate_Field =>
                                       --  D120: the alias names the whole
                                       --  payload struct, so it carries
                                       --  [0710]'s identity and its fields
                                       --  are reached as any struct's are.
                                       Landin.Checking.Settle
                                         (Types.all, Id, Ty.Aggregate);
                                       Landin.Checking.Note_Nominal
                                         (Types.all, Id,
                                          Shape.Nominal);
                                       Landin.Checking.Note
                                         (Types.all, Of_Tree, Binding,
                                          Ty.Aggregate);
                                       Landin.Checking.Note_Nominal
                                         (Types.all, Of_Tree, Binding,
                                          Shape.Nominal);

                                    when Landin.Checking.Variant_Field =>
                                       raise Landin.Compiler_Defect with
                                         "a variant payload reached a"
                                         & " match binding";
                                 end case;
                              end;
                           end loop;
                        end if;
                     end;
                  end if;

                  Check_Block
                    (Of_Tree, Syn.Body_Of (Of_Tree, Arm), Returns,
                     Expected, Value_Site, Value_Because);
               end;
            end loop;

            for Which in First'Range loop
               if First (Which) = Syn.No_Node then
                  declare
                     Missing : constant Syn.Node_Id :=
                       Syn.Nth_Case (Body_Tree.all, Part, Which);
                  begin
                     Bad.Report
                       (Item    => Bad.Variant_Case_Not_Matched,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Subject),
                        Message => "this match has no arm for `"
                                   & Spelled
                                       (Syn.Name (Body_Tree.all, Missing))
                                   & "`",
                        Note    => "D77: matching a variant part is"
                                   & " exhaustive",
                        Into    => Found);
                  end;
               end if;
            end loop;
         end;
      end Check_Match;

      procedure Check_Statement
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Returns : Ty.Type_Kind) is
      begin
         case Syn.Kind (Of_Tree, Node) is
            when Syn.Binding =>
               declare
                  Value : constant Syn.Node_Id :=
                    Syn.Value_Of (Of_Tree, Node);
                  --  D21's direct-name form is checked here for both a
                  --  module binding and a binding inside a body; the latter
                  --  is always local.
                  Wants : constant Ty.Type_Kind :=
                    Declared_As_Node (Of_Tree, Node);
               begin
                  if Value = Syn.No_Node or else Wants = Ty.Ill_Typed then
                     --  The declaration has already explained why this value
                     --  form is refused; checking the initializer as another
                     --  whole-array value would only repeat L0304.
                     null;
                  elsif Wants = Ty.Undecided then
                     --  [0050]: the inferred form takes the value's type,
                     --  and [0200] settles a literal that has none.  D21's
                     --  narrow array case reads the shape from a direct
                     --  storage name without making array names general
                     --  values.  D25/D26's literal was already given its
                     --  finite shape and scalar context by Infer; D33/D35 do
                     --  the same for a counted local or module repetition.
                     --  Checking either
                     --  here applies its contextual element boundary.
                     --  Every other form still goes through Synthesise and
                     --  keeps its existing refusal.
                     declare
                        Inferred_Array : constant Boolean :=
                          Syn.Kind (Of_Tree, Value)
                            in Syn.Array_Literal | Syn.Array_Repetition
                          and then Landin.Checking.Type_Of
                                     (Types.all, Of_Tree, Value)
                                   = Ty.Fixed_Array;
                        Inferred_Struct : constant Boolean :=
                          Is_Direct_Binding_Name (Of_Tree, Value)
                          and then Landin.Checking.Type_Of
                            (Types.all, Of_Tree, Value) = Ty.Aggregate;
                        Inferred_Construction : constant Boolean :=
                          Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal
                          and then Syn.Constructed_Type (Of_Tree, Value)
                                     /= Syn.No_Node
                          and then Landin.Checking.Type_Of
                            (Types.all, Of_Tree, Value) = Ty.Aggregate;
                     begin
                        if Inferred_Construction then
                           Check_Struct_Literal
                             (Of_Tree, Value,
                              Landin.Checking.Nominal_Of
                                (Types.all, Of_Tree, Value),
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        elsif Inferred_Array
                          and then Syn.Kind (Of_Tree, Value)
                                   = Syn.Array_Literal
                        then
                           Check_Array_Literal
                             (Of_Tree, Node, Value,
                              Landin.Checking.Array_Length
                                (Types.all, Of_Tree, Value),
                              Landin.Checking.Array_Element
                                (Types.all, Of_Tree, Value),
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        elsif Inferred_Array then
                           Check_Array_Repetition
                             (Of_Tree, Node, Value,
                              Landin.Checking.Array_Length
                                (Types.all, Of_Tree, Value),
                              Landin.Checking.Array_Element
                                (Types.all, Of_Tree, Value),
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        else
                           declare
                              Got : constant Ty.Type_Kind :=
                                (if Is_Direct_Array_Name (Of_Tree, Value)
                                      or else Inferred_Struct
                                 then Selected_From (Of_Tree, Value)
                                 else Synthesise (Of_Tree, Value));
                           begin
                              if Got = Ty.Untyped_Integer then
                                 Commit_To
                                   (Of_Tree, Value, Ty.Default_Integer);
                              elsif Got = Ty.No_Value then
                                 Bad.Report
                                   (Item    => Bad.Type_Mismatch,
                                    Source  => Syn.Source_Of (Of_Tree),
                                    Where   => Syn.Where (Of_Tree, Value),
                                    Message => "this hands back nothing, so"
                                               & " there is no type to infer",
                                    Note    => "[1920]: a call of a function"
                                               & " returning none has no type",
                                    Related => Syn.Origin (Of_Tree, Node),
                                    Because => "this binding",
                                    Into    => Found);
                              end if;
                           end;
                        end if;
                     end;
                  elsif Wants = Ty.Aggregate then
                     declare
                        Written : constant Syn.Node_Id :=
                          Syn.Declared_Type (Of_Tree, Node);
                     begin
                        if Syn.Kind (Of_Tree, Value)
                             in Syn.If_Statement | Syn.Match_Statement
                                | Syn.Bare_Block
                        then
                           Check_Contextual_Value
                             (Of_Tree, Value,
                              (Kind    => Ty.Aggregate,
                               Nominal => Landin.Checking.Nominal_Of
                                 (Types.all, Of_Tree, Written),
                               others  => <>),
                              Syn.Origin (Of_Tree, Node),
                              "the type declared here",
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        elsif Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal
                        then
                           declare
                              Expected : constant
                                Landin.Checking.Nominal_Type_Id :=
                                Landin.Checking.Nominal_Of
                                  (Types.all, Of_Tree, Written);
                           begin
                              if Construction_Agrees
                                (Of_Tree, Value, Expected,
                                 Syn.Origin (Of_Tree, Node),
                                 "the type declared here")
                              then
                                 Check_Struct_Literal
                                   (Of_Tree, Value, Expected,
                                    Static_Image =>
                                      not Is_Local_Binding (Of_Tree, Node));
                              end if;
                           end;
                        elsif Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal
                        then
                           Check_Aggregate_Zeroed
                             (Of_Tree, Value,
                              Landin.Checking.Nominal_Of
                                (Types.all, Of_Tree, Written),
                              Syn.Origin (Of_Tree, Written),
                              "the struct type written here");
                        else
                           --  D55: a direct storage name is the other
                           --  contextual aggregate initializer.  Identity
                           --  remains [0710]'s body declaration through
                           --  aliases on either side.
                           declare
                              Got : constant Ty.Type_Kind :=
                                (if Is_Direct_Binding_Name (Of_Tree, Value)
                                      or else Syn.Kind (Of_Tree, Value)
                                                = Syn.Member_Selection
                                 then Selected_From (Of_Tree, Value)
                                 else Synthesise (Of_Tree, Value));
                           begin
                              if Got = Ty.Ill_Typed then
                                 null;
                              elsif Got /= Ty.Aggregate
                                or else Landin.Checking.Nominal_Of
                                  (Types.all, Of_Tree, Written)
                                    /= Landin.Checking.Nominal_Of
                                      (Types.all, Of_Tree, Value)
                              then
                                 Bad.Report
                                   (Item    => Bad.Type_Mismatch,
                                    Source  => Syn.Source_Of (Of_Tree),
                                    Where   => Syn.Where (Of_Tree, Value),
                                    Message => "this is not a value of the"
                                               & " struct type written here",
                                    Note    => "[0710]: two structs are one"
                                               & " type when one declaration"
                                               & " wrote both, and never"
                                               & " otherwise",
                                    Related => Syn.Origin (Of_Tree, Node),
                                    Because => "the type declared here",
                                    Into    => Found);
                                 Landin.Checking.Refuse
                                   (Types.all, Of_Tree, Value);
                              end if;
                           end;
                        end if;
                     end;
                  elsif Wants = Ty.Fixed_Array then
                     declare
                        Written : constant Syn.Node_Id :=
                          Syn.Declared_Type (Of_Tree, Node);
                     begin
                        if Syn.Kind (Of_Tree, Value)
                             in Syn.If_Statement | Syn.Match_Statement
                                | Syn.Bare_Block
                        then
                           Check_Contextual_Value
                             (Of_Tree, Value,
                              (Kind    => Ty.Fixed_Array,
                               Length  => Landin.Checking.Array_Length
                                 (Types.all, Of_Tree, Written),
                               Element => Landin.Checking.Array_Element
                                 (Types.all, Of_Tree, Written),
                               Element_Nominal =>
                                 Landin.Checking.Array_Element_Nominal
                                   (Types.all, Of_Tree, Written),
                               others  => <>),
                              Syn.Origin (Of_Tree, Node),
                              "the type declared here",
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        elsif Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal
                        then
                           Check_Array_Zeroed
                             (Of_Tree, Value,
                              Landin.Checking.Array_Length
                                (Types.all, Of_Tree, Written),
                              Landin.Checking.Array_Element
                                (Types.all, Of_Tree, Written),
                              Landin.Checking.Array_Element_Nominal
                                (Types.all, Of_Tree, Written),
                              Syn.Origin (Of_Tree, Written),
                              "the array type written here");
                        elsif Syn.Kind (Of_Tree, Value)
                                = Syn.Mixed_Array_Repetition
                        then
                           --  D36/D38: an explicitly typed local or module
                           --  initializer gives a mixed prefix its shape; a
                           --  module image additionally requires static folds.
                           Check_Mixed_Array_Repetition
                             (Of_Tree, Node, Value,
                              Landin.Checking.Array_Length
                                (Types.all, Of_Tree, Written),
                              Landin.Checking.Array_Element
                                (Types.all, Of_Tree, Written),
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        elsif Syn.Kind (Of_Tree, Value) = Syn.Array_Repetition
                        then
                           --  D34: the written nonzero shape supplies a count
                           --  when `of` has none.  At module scope the one
                           --  scalar expression also takes D24's static-fold
                           --  boundary.
                           Check_Array_Repetition
                             (Of_Tree, Node, Value,
                              Landin.Checking.Array_Length
                                (Types.all, Of_Tree, Written),
                              Landin.Checking.Array_Element
                                (Types.all, Of_Tree, Written),
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        elsif Syn.Kind (Of_Tree, Value) = Syn.Array_Literal
                        then
                           --  D23 for a local, D24 for a module binding:
                           --  the written array type supplies the exact
                           --  count and scalar context for every element.
                           --  Check_Module_Value applies [1940] to the
                           --  literal as it does for any other module
                           --  value, so a runtime element is refused there.
                           Check_Array_Literal
                             (Of_Tree, Node, Value,
                              Landin.Checking.Array_Length
                                (Types.all, Of_Tree, Written),
                              Landin.Checking.Array_Element
                                (Types.all, Of_Tree, Written),
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        else
                           --  D21: the other initializer form is a
                           --  whole-array copy from a storage name, so the
                           --  identity check is D17's as an assignment's is.
                           --  Selected_From keeps that one direct name out
                           --  of the general-value refusal.
                           declare
                              Admitted : constant Boolean :=
                                Syn.Kind (Of_Tree, Value)
                                  = Syn.Member_Selection
                                and then Admit_Array_Field (Of_Tree, Value);
                              Got : constant Ty.Type_Kind :=
                                (if Is_Direct_Binding_Name (Of_Tree, Value)
                                      or else Admitted
                                 then Selected_From (Of_Tree, Value)
                                 else Synthesise (Of_Tree, Value));
                           begin
                              if Got = Ty.Ill_Typed then
                                 null;
                              elsif Got /= Ty.Fixed_Array
                                or else Landin.Checking.Array_Length
                                          (Types.all, Of_Tree, Value)
                                        /= Landin.Checking.Array_Length
                                             (Types.all, Of_Tree, Written)
                                or else Landin.Checking.Array_Element
                                          (Types.all, Of_Tree, Value)
                                        /= Landin.Checking.Array_Element
                                             (Types.all, Of_Tree, Written)
                              then
                                 Bad.Report
                                   (Item    => Bad.Type_Mismatch,
                                    Source  => Syn.Source_Of (Of_Tree),
                                    Where   => Syn.Where (Of_Tree, Value),
                                    Message => "this is not an array of the"
                                               & " type written here",
                                    Note    => "D17: an array's length and"
                                               & " element type are its"
                                               & " identity",
                                    Related => Syn.Origin (Of_Tree, Node),
                                    Because => "the type declared here",
                                    Into    => Found);
                                 Landin.Checking.Refuse
                                   (Types.all, Of_Tree, Value);
                              end if;
                           end;
                        end if;
                     end;
                  elsif Wants = Ty.Atom_Value then
                     declare
                        Written : constant Syn.Node_Id :=
                          Syn.Declared_Type (Of_Tree, Node);
                     begin
                        Require_Atom
                          (Of_Tree, Value,
                           Landin.Checking.Atom_Set_Of
                             (Types.all, Of_Tree, Written),
                           Syn.Origin (Of_Tree, Written),
                           "the atom type written here");
                     end;
                  elsif Wants = Ty.Function_Value then
                     declare
                        Written : constant Syn.Node_Id :=
                          Syn.Declared_Type (Of_Tree, Node);
                        Expected : constant Landin.Checking.Signature_Id :=
                          Landin.Checking.Signature_Of
                            (Types.all, Of_Tree, Written);
                     begin
                        if Syn.Kind (Of_Tree, Value)
                             in Syn.If_Statement | Syn.Match_Statement
                                | Syn.Bare_Block
                        then
                           Check_Contextual_Value
                             (Of_Tree, Value,
                              (Kind      => Ty.Function_Value,
                               Signature => Expected,
                               others    => <>),
                              Syn.Origin (Of_Tree, Written),
                              "the function type written here");
                        else
                           declare
                              Got : constant Ty.Type_Kind :=
                                Synthesise (Of_Tree, Value);
                           begin
                              if Got = Ty.Function_Value
                                and then not Signatures_Agree
                                  (Expected,
                                   Landin.Checking.Signature_Of
                                     (Types.all, Of_Tree, Value))
                              then
                                 Bad.Report
                                   (Item    => Bad.Type_Mismatch,
                                    Source  => Syn.Source_Of (Of_Tree),
                                    Where   => Syn.Where (Of_Tree, Value),
                                    Message => "this function has a"
                                               & " different signature",
                                    Note    => "[1000]: function values"
                                               & " have the signature"
                                               & " written by their type",
                                    Related => Syn.Origin (Of_Tree, Written),
                                    Because =>
                                      "the function type written here",
                                    Into    => Found);
                                 Landin.Checking.Refuse
                                   (Types.all, Of_Tree, Value);
                              elsif Got /= Ty.Function_Value then
                                 Require
                                   (Of_Tree, Value, Wants,
                                    Syn.Origin (Of_Tree, Written),
                                    "the function type written here");
                              end if;
                           end;
                        end if;
                     end;
                  elsif Wants in Ty.Scalar_Name
                    and then Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal
                  then
                     --  D39/D40: a written module or local scalar type is the
                     --  scalar context for `zeroed`; Type_At has already
                     --  resolved an alias to the enabled scalar it denotes.
                     --  Inference, assignment and general expressions still
                     --  reach the ordinary refusal.
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Value, Wants);
                  else
                     Require
                       (Of_Tree, Value, Wants, Syn.Origin (Of_Tree, Node),
                        "the type declared here");
                  end if;
               end;

            when Syn.Destructuring_Binding =>
               declare
                  Value : constant Syn.Node_Id :=
                    Syn.Destructured_Value (Of_Tree, Node);
                  Got : constant Ty.Type_Kind := Synthesise (Of_Tree, Value);
                  Shape : constant Landin.Checking.Signature_Id :=
                    Landin.Checking.Result_Shape_Of
                      (Types.all, Of_Tree, Value);
                  Seen : array
                    (1 .. (if Shape = Landin.Checking.No_Signature
                           then 1
                           else Landin.Checking.Signature_Result_Count
                             (Types.all, Shape))) of Boolean :=
                               [others => False];
                  Wildcard : Boolean := False;
               begin
                  if Got = Ty.Ill_Typed then
                     null;
                  elsif Got /= Ty.Aggregate
                    or else Shape = Landin.Checking.No_Signature
                  then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Value),
                        Message => "this does not produce multiple named"
                                   & " returns to bind",
                        Note    => "[0990]: destructuring binds an anonymous"
                                   & " result aggregate by field name",
                        Related => Syn.Origin (Of_Tree, Node),
                        Because => "this result binding",
                        Into    => Found);
                     Landin.Checking.Refuse (Types.all, Of_Tree, Value);
                  else
                     for Position in
                       1 .. Syn.Destructured_Field_Count (Of_Tree, Node)
                     loop
                        declare
                           Field : constant Syn.Node_Id :=
                             Syn.Nth_Destructured_Field
                               (Of_Tree, Node, Position);
                        begin
                           if Syn.Kind (Of_Tree, Field)
                                = Syn.Result_Wildcard
                           then
                              if Wildcard then
                                 Bad.Report
                                   (Item    => Bad.Type_Mismatch,
                                    Source  => Syn.Source_Of (Of_Tree),
                                    Where   => Syn.Where (Of_Tree, Field),
                                    Message => "a result binding needs at"
                                               & " most one `_` wildcard",
                                    Note    => "[0990]: `_` ignores the"
                                               & " unbound returned fields",
                                    Related => Syn.Origin (Of_Tree, Node),
                                    Because => "this result binding",
                                    Into    => Found);
                              end if;
                              Wildcard := True;
                           else
                              declare
                                 Which : constant Natural :=
                                   Result_Field_At
                                     (Shape, Syn.Name (Of_Tree, Field));
                              begin
                                 if Which = 0 then
                                    Bad.Report
                                      (Item    => Bad.Unresolved_Field,
                                       Source  => Syn.Source_Of (Of_Tree),
                                       Where   => Syn.Anchor (Of_Tree, Field),
                                       Message => "this result has no field"
                                                  & " called `"
                                                  & Spelled
                                                    (Syn.Name
                                                       (Of_Tree, Field))
                                                  & "`",
                                       Note    => "[0990]: result binding is"
                                                  & " by name, never by"
                                                  & " position",
                                       Into    => Found);
                                 elsif Seen (Which) then
                                    Bad.Report
                                      (Item    => Bad.Type_Mismatch,
                                       Source  => Syn.Source_Of (Of_Tree),
                                       Where   => Syn.Anchor (Of_Tree, Field),
                                       Message => "this returned field is"
                                                  & " bound twice",
                                       Note    => "[0990]: each selected"
                                                  & " field has one local",
                                       Related => Syn.Origin (Of_Tree, Node),
                                       Because => "this result binding",
                                       Into    => Found);
                                    if Syn.Destructured_Local
                                      (Of_Tree, Field) /= Syn.No_Node
                                    then
                                       declare
                                          Local : constant Syn.Node_Id :=
                                            Syn.Destructured_Local
                                              (Of_Tree, Field);
                                          Id : constant Res.Declaration_Id :=
                                            Declaration_At
                                              (Syn.Source_Of (Of_Tree), Local);
                                          Part : constant
                                            Landin.Checking.Signature_Part :=
                                              Landin.Checking
                                                .Nth_Signature_Result
                                                  (Types.all, Shape, Which);
                                       begin
                                          Landin.Checking.Settle
                                            (Types.all, Id, Part.Kind);
                                       end;
                                    end if;
                                 else
                                    Seen (Which) := True;
                                    Landin.Checking.Note_Field
                                      (Types.all, Of_Tree, Field, Which);
                                    if Syn.Destructured_Local
                                      (Of_Tree, Field) /= Syn.No_Node
                                    then
                                       declare
                                          Local : constant Syn.Node_Id :=
                                            Syn.Destructured_Local
                                              (Of_Tree, Field);
                                          Id : constant Res.Declaration_Id :=
                                            Declaration_At
                                              (Syn.Source_Of (Of_Tree), Local);
                                          Part : constant
                                            Landin.Checking.Signature_Part :=
                                              Landin.Checking
                                                .Nth_Signature_Result
                                                  (Types.all, Shape, Which);
                                       begin
                                          Landin.Checking.Settle
                                            (Types.all, Id, Part.Kind);
                                          Landin.Checking.Note
                                            (Types.all, Of_Tree, Local,
                                             Part.Kind);
                                          case Part.Kind is
                                             when Ty.Aggregate =>
                                                Landin.Checking.Note_Nominal
                                                  (Types.all, Id,
                                                   Part.Nominal);
                                                Landin.Checking.Note_Nominal
                                                  (Types.all, Of_Tree, Local,
                                                   Part.Nominal);
                                             when Ty.Fixed_Array =>
                                                Landin.Checking.Note_Array
                                                  (Types.all, Id, Part.Length,
                                                   Part.Element);
                                                Landin.Checking.Note_Array
                                                  (Types.all, Of_Tree, Local,
                                                   Part.Length, Part.Element);
                                                Landin.Checking
                                                  .Note_Array_Element_Nominal
                                                    (Types.all, Id,
                                                     Part.Nominal);
                                                Landin.Checking
                                                  .Note_Array_Element_Nominal
                                                    (Types.all, Of_Tree,
                                                     Local,
                                                     Part.Nominal);
                                             when Ty.Function_Value =>
                                                Landin.Checking.Note_Signature
                                                  (Types.all, Id,
                                                   Part.Signature);
                                                Landin.Checking.Note_Signature
                                                  (Types.all, Of_Tree, Local,
                                                   Part.Signature);
                                             when others =>
                                                null;
                                          end case;
                                       end;
                                    end if;
                                 end if;
                              end;
                           end if;
                        end;
                     end loop;
                  end if;
                  Landin.Checking.Note
                    (Types.all, Of_Tree, Node, Ty.Not_Typed);
               end;

            when Syn.Assignment =>
               --  D76 gives a directly selected variant part one contextual
               --  destination form.  It is intercepted before ordinary
               --  selection synthesis (which correctly keeps the part out
               --  of general values), while Check_Place still owns root
               --  mutability and runs before the case is inspected.
               if Admit_Variant_Field
                    (Of_Tree, Syn.Target_Of (Of_Tree, Node))
               then
                  declare
                     Place : constant Syn.Node_Id :=
                       Syn.Target_Of (Of_Tree, Node);
                     Value : constant Syn.Node_Id :=
                       Syn.Value_Of (Of_Tree, Node);
                     Base : constant Syn.Node_Id :=
                       Syn.Target_Of (Of_Tree, Place);
                  begin
                     Check_Place
                       (Of_Tree, Place, Stepping => False,
                        Variant_Context => True);
                     if Landin.Checking.Type_Of
                          (Types.all, Of_Tree, Place) = Ty.Ill_Typed
                     then
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Value);
                     else
                        Check_Variant_Value
                          (Of_Tree, Place, Value,
                           Landin.Checking.Nominal_Of
                             (Types.all, Of_Tree, Base),
                           Positive
                             (Landin.Checking.Field_Index
                                (Types.all, Of_Tree, Place)));
                     end if;
                  end;
                  return;
               end if;

               --  D49 supplies the fixed-array shape for a complete `zeroed`
               --  assignment.  D50 additionally recognizes a direct array
               --  name or a selection as copy syntax, D52 recognizes D29's
               --  literal syntax, and D53 recognizes D32/D37 repetition.
               --  The source selection is not typed until Check_Place accepts
               --  the destination, so destination diagnostics remain first
               --  and alone.
               if Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                    in Syn.Zeroed_Literal | Syn.Array_Literal
                       | Syn.Array_Repetition | Syn.Mixed_Array_Repetition
                       | Syn.Call
                 or else Is_Direct_Array_Name
                   (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                 or else Syn.Kind
                   (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                    = Syn.Member_Selection
               then
                  if Admit_Array_Field
                       (Of_Tree, Syn.Target_Of (Of_Tree, Node))
                  then
                     null;
                  end if;
               end if;

               Check_Place
                 (Of_Tree, Syn.Target_Of (Of_Tree, Node),
                  Stepping => False);

               --  The place has already explained why no assignment can be
               --  made.  Do not compare stale aggregate shape metadata and
               --  add a type mismatch to the mutability report.
               if Landin.Checking.Type_Of
                    (Types.all, Of_Tree, Syn.Target_Of (Of_Tree, Node))
                    = Ty.Ill_Typed
               then
                  --  D50 may put a selection on the source side.  Since the
                  --  destination owns this refusal, mark that unvisited
                  --  source ill-typed as well: the later flow walk must not
                  --  fall back from an undecided selection to a whole read
                  --  of its local aggregate base and add L0302.
                  Landin.Checking.Refuse
                    (Types.all, Of_Tree, Syn.Value_Of (Of_Tree, Node));
                  return;
               end if;

               declare
                  Place : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Value : constant Syn.Node_Id :=
                    Syn.Value_Of (Of_Tree, Node);
                  Wants : constant Ty.Type_Kind :=
                    Selected_From (Of_Tree, Place);
               begin
                  if Wants = Ty.Aggregate then
                     declare
                        Shape : constant Landin.Checking.Signature_Id :=
                          Landin.Checking.Result_Shape_Of
                            (Types.all, Of_Tree, Place);
                     begin
                        if Shape /= Landin.Checking.No_Signature then
                           Check_Contextual_Value
                             (Of_Tree, Value,
                              (Kind         => Ty.Aggregate,
                               Result_Shape => Shape,
                               others       => <>),
                              Syn.Origin (Of_Tree, Place),
                              "the result aggregate written here");
                           return;
                        end if;
                     end;

                     if Syn.Kind (Of_Tree, Value)
                          in Syn.If_Statement | Syn.Match_Statement
                             | Syn.Bare_Block
                     then
                        Check_Contextual_Value
                          (Of_Tree, Value,
                           (Kind    => Ty.Aggregate,
                            Nominal => Landin.Checking.Nominal_Of
                              (Types.all, Of_Tree, Place),
                            others  => <>),
                           Syn.Origin (Of_Tree, Place),
                           "the place written here");
                     elsif Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal then
                        declare
                           Expected : constant
                             Landin.Checking.Nominal_Type_Id :=
                             Landin.Checking.Nominal_Of
                               (Types.all, Of_Tree, Place);
                        begin
                           if Construction_Agrees
                             (Of_Tree, Value, Expected,
                              Syn.Origin (Of_Tree, Place),
                              "the place written here")
                           then
                              Check_Struct_Literal
                                (Of_Tree, Value, Expected,
                                 Static_Image => False);
                           end if;
                        end;
                     elsif Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal then
                        Check_Aggregate_Zeroed
                          (Of_Tree, Value,
                           Landin.Checking.Nominal_Of
                             (Types.all, Of_Tree, Place),
                           Syn.Origin (Of_Tree, Place),
                           "the struct place written here");
                     else
                        --  [0710]: a whole struct is copied into a place of
                        --  the same type.  A copy is the one expression
                        --  position a struct may stand in, because the bytes
                        --  go straight between places without a value.
                        declare
                           Got : constant Ty.Type_Kind :=
                             (if Is_Direct_Binding_Name (Of_Tree, Value)
                                   or else Is_Aggregate_Alias_Name
                                     (Of_Tree, Value)
                                   or else Syn.Kind (Of_Tree, Value)
                                             = Syn.Member_Selection
                              then Selected_From (Of_Tree, Value)
                              else Synthesise (Of_Tree, Value));
                        begin
                           if Got = Ty.Ill_Typed then
                              null;
                           elsif Got /= Ty.Aggregate
                             or else Landin.Checking.Nominal_Of
                                       (Types.all, Of_Tree, Place)
                                     /= Landin.Checking.Nominal_Of
                                          (Types.all, Of_Tree, Value)
                           then
                              Bad.Report
                                (Item    => Bad.Type_Mismatch,
                                 Source  => Syn.Source_Of (Of_Tree),
                                 Where   => Syn.Where (Of_Tree, Value),
                                 Message => "this is not a value of the"
                                            & " struct type written here",
                                 Note    => "[0710]: two structs are one"
                                            & " type when one declaration"
                                            & " wrote both, and never"
                                            & " otherwise",
                                 Related => Syn.Origin (Of_Tree, Place),
                                 Because => "the place written here",
                                 Into    => Found);
                              Landin.Checking.Refuse
                                (Types.all, Of_Tree, Value);
                           end if;
                        end;
                     end if;

                     return;
                  end if;

                  --  D20 copies an array straight from one storage place to
                  --  another.  D29's literal and D30's `zeroed` are
                  --  contextual: the destination's D17 shape supplies their
                  --  count and scalar element type without making either a
                  --  general value.
                  if Wants = Ty.Fixed_Array then
                     if Syn.Kind (Of_Tree, Value)
                          in Syn.If_Statement | Syn.Match_Statement
                             | Syn.Bare_Block
                     then
                        Check_Contextual_Value
                          (Of_Tree, Value,
                           (Kind    => Ty.Fixed_Array,
                            Length  => Landin.Checking.Array_Length
                              (Types.all, Of_Tree, Place),
                            Element => Landin.Checking.Array_Element
                              (Types.all, Of_Tree, Place),
                            Element_Nominal =>
                              Landin.Checking.Array_Element_Nominal
                                (Types.all, Of_Tree, Place),
                            others  => <>),
                           Syn.Origin (Of_Tree, Place),
                           "the place written here");
                     elsif Syn.Kind (Of_Tree, Value)
                          = Syn.Mixed_Array_Repetition
                     then
                        --  D37 gives this contextual mixed form the complete
                        --  shape of its mutable fixed-array destination.
                        Check_Mixed_Array_Repetition
                          (Of_Tree, Place, Value,
                           Landin.Checking.Array_Length
                             (Types.all, Of_Tree, Place),
                           Landin.Checking.Array_Element
                             (Types.all, Of_Tree, Place),
                           Static_Image => False);
                     elsif Syn.Kind (Of_Tree, Value)
                             = Syn.Array_Repetition
                     then
                        Check_Array_Repetition
                          (Of_Tree, Place, Value,
                           Landin.Checking.Array_Length
                             (Types.all, Of_Tree, Place),
                           Landin.Checking.Array_Element
                             (Types.all, Of_Tree, Place),
                           Static_Image => False);
                     elsif Syn.Kind (Of_Tree, Value) = Syn.Array_Literal then
                        Check_Array_Literal
                          (Of_Tree, Place, Value,
                           Landin.Checking.Array_Length
                             (Types.all, Of_Tree, Place),
                           Landin.Checking.Array_Element
                             (Types.all, Of_Tree, Place),
                           Static_Image => False);
                     elsif Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal
                     then
                        Check_Array_Zeroed
                          (Of_Tree, Value,
                           Landin.Checking.Array_Length
                             (Types.all, Of_Tree, Place),
                           Landin.Checking.Array_Element
                             (Types.all, Of_Tree, Place),
                           Landin.Checking.Array_Element_Nominal
                             (Types.all, Of_Tree, Place),
                           Syn.Origin (Of_Tree, Place),
                           "the array place written here");
                     else
                        declare
                           Admitted : constant Boolean :=
                             (Syn.Kind (Of_Tree, Value)
                                = Syn.Member_Selection
                              and then Admit_Array_Field (Of_Tree, Value));
                           Got : constant Ty.Type_Kind :=
                             (if Admitted
                                   or else Is_Direct_Binding_Name
                                     (Of_Tree, Value)
                              then Selected_From (Of_Tree, Value)
                              else Synthesise (Of_Tree, Value));
                        begin
                           if Got = Ty.Ill_Typed then
                              null;
                           elsif Got /= Ty.Fixed_Array
                             or else Landin.Checking.Array_Length
                                       (Types.all, Of_Tree, Place)
                                     /= Landin.Checking.Array_Length
                                          (Types.all, Of_Tree, Value)
                             or else Landin.Checking.Array_Element
                                       (Types.all, Of_Tree, Place)
                                     /= Landin.Checking.Array_Element
                                          (Types.all, Of_Tree, Value)
                           then
                              Bad.Report
                                (Item    => Bad.Type_Mismatch,
                                 Source  => Syn.Source_Of (Of_Tree),
                                 Where   => Syn.Where (Of_Tree, Value),
                                 Message => "this is not an array of the type"
                                            & " written here",
                                 Note    => "D17: an array's length and"
                                            & " element type are its identity",
                                 Related => Syn.Origin (Of_Tree, Place),
                                 Because => "the place written here",
                                 Into    => Found);
                              Landin.Checking.Refuse
                                (Types.all, Of_Tree, Value);
                           end if;
                        end;
                     end if;

                     return;
                  end if;

                  if Wants = Ty.Atom_Value then
                     Require_Atom
                       (Of_Tree, Value,
                        Landin.Checking.Atom_Set_Of
                          (Types.all, Of_Tree, Place),
                        Syn.Origin (Of_Tree, Place),
                        "the atom place written here");
                     return;
                  end if;

                  if Wants = Ty.Function_Value then
                     declare
                        Expected : constant Landin.Checking.Signature_Id :=
                          Landin.Checking.Signature_Of
                            (Types.all, Of_Tree, Place);
                     begin
                        if Syn.Kind (Of_Tree, Value)
                             in Syn.If_Statement | Syn.Match_Statement
                                | Syn.Bare_Block
                        then
                           Check_Contextual_Value
                             (Of_Tree, Value,
                              (Kind      => Ty.Function_Value,
                               Signature => Expected,
                               others    => <>),
                              Syn.Origin (Of_Tree, Place),
                              "the function place written here");
                        else
                           declare
                              Got : constant Ty.Type_Kind :=
                                Synthesise (Of_Tree, Value);
                           begin
                              if Got = Ty.Function_Value
                                and then not Signatures_Agree
                                  (Expected,
                                   Landin.Checking.Signature_Of
                                     (Types.all, Of_Tree, Value))
                              then
                                 Bad.Report
                                   (Item    => Bad.Type_Mismatch,
                                    Source  => Syn.Source_Of (Of_Tree),
                                    Where   => Syn.Where (Of_Tree, Value),
                                    Message => "this function has a"
                                               & " different signature",
                                    Note    => "[1000]: function values"
                                               & " have the signature"
                                               & " written by their type",
                                    Related => Syn.Origin (Of_Tree, Place),
                                    Because =>
                                      "the function place written here",
                                    Into    => Found);
                                 Landin.Checking.Refuse
                                   (Types.all, Of_Tree, Value);
                              elsif Got /= Ty.Function_Value then
                                 Require
                                   (Of_Tree, Value, Wants,
                                    Syn.Origin (Of_Tree, Place),
                                    "the place written here");
                              end if;
                           end;
                        end if;
                     end;
                     return;
                  end if;

                  --  D41--D43/D62: a mutable scalar binding, an admitted
                  --  scalar subobject, or a direct named return supplies the
                  --  contextual type for `zeroed`.  Check_Place has already
                  --  resolved aliases and refused immutable or invalid
                  --  destinations.
                  if Wants in Ty.Scalar_Name
                    and then Is_Zeroed_Scalar_Place (Of_Tree, Place)
                    and then Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal
                  then
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Value, Wants);
                  else
                     Require
                       (Of_Tree, Value, Wants, Syn.Origin (Of_Tree, Place),
                        "the place written here");
                  end if;
               end;

            when Syn.Increment | Syn.Decrement =>
               Check_Place
                 (Of_Tree, Syn.Target_Of (Of_Tree, Node), Stepping => True);

            when Syn.Discard =>
               --  [1930]: anything with a type may be thrown away, and a
               --  call that hands back nothing has none.
               declare
                  Value : constant Syn.Node_Id :=
                    Syn.Value_Of (Of_Tree, Node);
                  Got   : Ty.Type_Kind;
               begin
                  if Value = Syn.No_Node then
                     return;
                  end if;

                  Got := Synthesise (Of_Tree, Value);

                  if Got = Ty.Untyped_Integer then
                     Commit_To (Of_Tree, Value, Ty.Default_Integer);
                  elsif Got = Ty.No_Value then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Value),
                        Message => "this hands back nothing, so there is"
                                   & " no result to discard",
                        Note    => "[1930]: discarding is for a result,"
                                   & " and that call has none",
                        Related => Syn.Origin (Of_Tree, Node),
                        Because => "the discard",
                        Into    => Found);
                  end if;
               end;

            when Syn.Defer_Statement | Syn.Undo_Statement =>
               --  [1100]/[1110]: type the registered call where it is
               --  written, but leave every definite-assignment read to the
               --  selected exit where its callee and arguments run.
               declare
                  Got : constant Ty.Type_Kind :=
                    Synthesise (Of_Tree, Syn.Cleanup_Call (Of_Tree, Node));
               begin
                  pragma Unreferenced (Got);
               end;

            when Syn.Fail_Statement =>
               declare
                  Error : constant Syn.Node_Id :=
                    Syn.Value_Of (Of_Tree, Node);
                  Got : constant Ty.Type_Kind := Synthesise (Of_Tree, Error);
               begin
                  if Got /= Ty.Atom_Value and then Decidable (Got) then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Error),
                        Message => "`fail` carries one atom identity",
                        Note    => "[0940]: errors are payload-free atoms",
                        Related => Syn.Origin (Of_Tree, Node),
                        Because => "this failing exit",
                        Into    => Found);
                     Landin.Checking.Refuse (Types.all, Of_Tree, Error);
                  end if;
                  Require
                    (Of_Tree, Syn.Condition_Of (Of_Tree, Node), Ty.Bool,
                     Syn.Origin (Of_Tree, Node), "the guard of this exit");
               end;

            when Syn.Return_Statement =>
               --  [1890]: an exit's `when` is a condition, so it is a bool
               --  for [1050]'s reason asked where the exit is.
               Require
                 (Of_Tree, Syn.Condition_Of (Of_Tree, Node), Ty.Bool,
                  Syn.Origin (Of_Tree, Node), "the guard of this exit");

            when Syn.If_Statement =>
               for Arm in 1 .. Syn.Arm_Count (Of_Tree, Node) loop
                  declare
                     This : constant Syn.Node_Id :=
                       Syn.Nth_Arm (Of_Tree, Node, Arm);
                  begin
                     Require
                       (Of_Tree, Syn.Condition_Of (Of_Tree, This), Ty.Bool,
                        Syn.Origin (Of_Tree, This),
                        "the condition of this branch");
                     Check_Block
                       (Of_Tree, Syn.Body_Of (Of_Tree, This), Returns);
                  end;
               end loop;

               if Syn.Else_Body (Of_Tree, Node) /= Syn.No_Node then
                  Check_Block
                    (Of_Tree, Syn.Else_Body (Of_Tree, Node), Returns);
               end if;

            when Syn.Match_Statement =>
               Check_Match (Of_Tree, Node, Returns);

            when Syn.Bare_Block =>
               Check_Block
                 (Of_Tree, Syn.Body_Of (Of_Tree, Node), Returns);

            when Syn.Try_Expression =>
               declare
                  Got : constant Ty.Type_Kind := Synthesise (Of_Tree, Node);
               begin
                  pragma Unreferenced (Got);
               end;

            when Syn.Call =>
               --  [1920]: a call standing alone is a statement, and one
               --  that hands a value back is [1020]'s omitted discard --
               --  which R2 will refuse; the kernel accepts it because
               --  nothing in the tour refuses it yet.
               declare
                  Got : constant Ty.Type_Kind := Synthesise (Of_Tree, Node);
               begin
                  pragma Unreferenced (Got);
               end;

            when others =>
               null;
         end case;
      end Check_Statement;

      procedure Check_Block
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Returns : Ty.Type_Kind;
         Expected : Value_Context := No_Value_Context;
         Value_Site : Landin.Provenance.Origin :=
           Landin.Provenance.No_Origin;
         Value_Because : String := "")
      is
      begin
         for Index in 1 .. Syn.Statement_Count (Of_Tree, Node) loop
            Check_Statement
              (Of_Tree, Syn.Nth_Statement (Of_Tree, Node, Index), Returns);
         end loop;

         if Expected.Kind /= Ty.Undecided
           and then Syn.Block_Value (Of_Tree, Node) /= Syn.No_Node
         then
            Check_Contextual_Value
              (Of_Tree, Syn.Block_Value (Of_Tree, Node), Expected,
               (if Landin.Provenance.Is_Known (Value_Site)
                then Value_Site else Syn.Origin (Of_Tree, Node)),
               (if Value_Because /= ""
                then Value_Because
                else "the value produced by this control block"));
         elsif Syn.Block_Value (Of_Tree, Node) /= Syn.No_Node then
            --  A control form may also occupy the statement slot shared by
            --  calls.  Its final expression is still checked even though no
            --  surrounding context consumes the result.  Check it as a
            --  statement here: a syntactically final call in each arm may
            --  return none, in which case asking the control to synthesise a
            --  joined value would stop before its conditions were checked.
            declare
               Value : constant Syn.Node_Id :=
                 Syn.Block_Value (Of_Tree, Node);
            begin
               if Syn.Kind (Of_Tree, Value)
                    in Syn.If_Statement | Syn.Match_Statement
                       | Syn.Bare_Block
               then
                  Check_Statement (Of_Tree, Value, Returns);
               else
                  declare
                     Got : constant Ty.Type_Kind :=
                       Synthesise (Of_Tree, Value);
                  begin
                     if Got = Ty.Untyped_Integer then
                        Commit_To (Of_Tree, Value, Ty.Default_Integer);
                     end if;
                  end;
               end if;
            end;
         end if;
      end Check_Block;

      --  The first syntactic answer is enough to infer a control value's
      --  context.  Missing answers are deliberately skipped: flow decides
      --  whether that block can fall through, and an early return is a
      --  return-compatible edge rather than an answer of a second type.
      function First_Control_Value
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id;

      function First_Control_Value
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Syn.Node_Id
      is
      begin
         case Syn.Kind (Of_Tree, Node) is
            when Syn.If_Statement =>
               for Arm in 1 .. Syn.Arm_Count (Of_Tree, Node) loop
                  declare
                     Value : constant Syn.Node_Id :=
                       Syn.Block_Value
                         (Of_Tree,
                          Syn.Body_Of
                            (Of_Tree, Syn.Nth_Arm (Of_Tree, Node, Arm)));
                  begin
                     if Value /= Syn.No_Node then
                        return Value;
                     end if;
                  end;
               end loop;

               if Syn.Else_Body (Of_Tree, Node) /= Syn.No_Node then
                  return Syn.Block_Value
                    (Of_Tree, Syn.Else_Body (Of_Tree, Node));
               end if;
               return Syn.No_Node;

            when Syn.Match_Statement =>
               for Arm in 1 .. Syn.Match_Arm_Count (Of_Tree, Node) loop
                  declare
                     Value : constant Syn.Node_Id :=
                       Syn.Block_Value
                         (Of_Tree,
                          Syn.Body_Of
                            (Of_Tree,
                             Syn.Nth_Match_Arm (Of_Tree, Node, Arm)));
                  begin
                     if Value /= Syn.No_Node then
                        return Value;
                     end if;
                  end;
               end loop;
               return Syn.No_Node;

            when Syn.Bare_Block =>
               return Syn.Block_Value
                 (Of_Tree, Syn.Body_Of (Of_Tree, Node));

            when others =>
               return Syn.No_Node;
         end case;
      end First_Control_Value;

      procedure Note_Context
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Expected : Value_Context);

      procedure Note_Context
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Expected : Value_Context)
      is
      begin
         if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
              = Ty.Undecided
         then
            Landin.Checking.Note
              (Types.all, Of_Tree, Node, Expected.Kind);
            if Expected.Kind = Ty.Aggregate then
               if Expected.Result_Shape /= Landin.Checking.No_Signature then
                  Landin.Checking.Note_Result_Shape
                    (Types.all, Of_Tree, Node, Expected.Result_Shape);
               else
                  Landin.Checking.Note_Nominal
                    (Types.all, Of_Tree, Node, Expected.Nominal);
               end if;
            elsif Expected.Kind = Ty.Fixed_Array then
               Landin.Checking.Note_Array
                 (Types.all, Of_Tree, Node,
                  Expected.Length, Expected.Element);
               Landin.Checking.Note_Array_Element_Nominal
                 (Types.all, Of_Tree, Node, Expected.Element_Nominal);
            elsif Expected.Kind = Ty.Function_Value then
               Landin.Checking.Note_Signature
                 (Types.all, Of_Tree, Node, Expected.Signature);
            elsif Expected.Kind = Ty.Atom_Value then
               Landin.Checking.Note_Atom_Set
                 (Types.all, Of_Tree, Node, Expected.Atoms);
            end if;
         end if;
      end Note_Context;

      procedure Context_Mismatch
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Expected : Value_Context;
         Site    : Landin.Provenance.Origin;
         Because : String);

      procedure Context_Mismatch
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Expected : Value_Context;
         Site    : Landin.Provenance.Origin;
         Because : String)
      is
      begin
         Bad.Report
           (Item    => Bad.Type_Mismatch,
            Source  => Syn.Source_Of (Of_Tree),
            Where   => Syn.Where (Of_Tree, Node),
            Message => "this does not have the " & Shown (Expected.Kind)
                       & " shape required here",
            Note    => "D124: every fallthrough answer of a control"
                       & " expression has one complete type and shape",
            Related => Site,
            Because => Because,
            Into    => Found);
         Landin.Checking.Refuse (Types.all, Of_Tree, Node);
      end Context_Mismatch;

      procedure Check_Contextual_Value
        (Of_Tree      : Syn.Tree;
         Node         : Syn.Node_Id;
         Expected     : Value_Context;
         Site         : Landin.Provenance.Origin;
         Because      : String;
         Static_Image : Boolean := False)
      is
      begin
         if Node = Syn.No_Node then
            return;
         end if;

         if Syn.Kind (Of_Tree, Node)
              in Syn.If_Statement | Syn.Match_Statement | Syn.Bare_Block
         then
            Note_Context (Of_Tree, Node, Expected);

            case Syn.Kind (Of_Tree, Node) is
               when Syn.If_Statement =>
                  for Arm in 1 .. Syn.Arm_Count (Of_Tree, Node) loop
                     declare
                        This : constant Syn.Node_Id :=
                          Syn.Nth_Arm (Of_Tree, Node, Arm);
                     begin
                        Require
                          (Of_Tree, Syn.Condition_Of (Of_Tree, This), Ty.Bool,
                           Syn.Origin (Of_Tree, This),
                           "the condition of this branch");
                        Check_Block
                          (Of_Tree, Syn.Body_Of (Of_Tree, This),
                           Ty.Not_Typed, Expected, Site, Because);
                     end;
                  end loop;

                  if Syn.Else_Body (Of_Tree, Node) /= Syn.No_Node then
                     Check_Block
                       (Of_Tree, Syn.Else_Body (Of_Tree, Node),
                        Ty.Not_Typed, Expected, Site, Because);
                  end if;

               when Syn.Match_Statement =>
                  Check_Match
                    (Of_Tree, Node, Ty.Not_Typed, Expected, Site, Because);

               when Syn.Bare_Block =>
                  Check_Block
                    (Of_Tree, Syn.Body_Of (Of_Tree, Node),
                     Ty.Not_Typed, Expected, Site, Because);

               when others =>
                  raise Landin.Compiler_Defect;
            end case;
            return;
         end if;

         case Expected.Kind is
            when Ty.Aggregate =>
               if Expected.Result_Shape /= Landin.Checking.No_Signature then
                  declare
                     Got : constant Ty.Type_Kind :=
                       (if Syn.Kind (Of_Tree, Node)
                             in Syn.Name_Reference | Syn.Member_Selection
                        then Selected_From (Of_Tree, Node)
                        else Synthesise (Of_Tree, Node));
                     Actual : constant Landin.Checking.Signature_Id :=
                       Landin.Checking.Result_Shape_Of
                         (Types.all, Of_Tree, Node);
                  begin
                     if Got /= Ty.Ill_Typed
                       and then
                         (Got /= Ty.Aggregate
                          or else Actual = Landin.Checking.No_Signature
                          or else not Landin.Checking.Result_Shapes_Agree
                            (Types.all, Expected.Result_Shape, Actual))
                     then
                        Context_Mismatch
                          (Of_Tree, Node, Expected, Site, Because);
                     end if;
                  end;
                  return;
               end if;

               if Syn.Kind (Of_Tree, Node) = Syn.Struct_Literal then
                  if Construction_Agrees
                       (Of_Tree, Node, Expected.Nominal, Site, Because)
                  then
                     Check_Struct_Literal
                       (Of_Tree, Node, Expected.Nominal, Static_Image);
                  end if;
                  return;
               elsif Syn.Kind (Of_Tree, Node) = Syn.Zeroed_Literal then
                  Check_Aggregate_Zeroed
                    (Of_Tree, Node, Expected.Nominal, Site, Because);
                  return;
               end if;

               declare
                  Got : constant Ty.Type_Kind :=
                    (if Syn.Kind (Of_Tree, Node)
                          in Syn.Name_Reference | Syn.Member_Selection
                     then Selected_From (Of_Tree, Node)
                     else Synthesise (Of_Tree, Node));
               begin
                  if Got /= Ty.Ill_Typed
                    and then
                      (Got /= Ty.Aggregate
                       or else Landin.Checking.Nominal_Of
                         (Types.all, Of_Tree, Node) /= Expected.Nominal)
                  then
                     Context_Mismatch
                       (Of_Tree, Node, Expected, Site, Because);
                  end if;
               end;

            when Ty.Fixed_Array =>
               case Syn.Kind (Of_Tree, Node) is
                  when Syn.Array_Literal =>
                     Check_Array_Literal
                       (Of_Tree, Node, Node, Expected.Length,
                        Expected.Element, Static_Image);
                     return;
                  when Syn.Array_Repetition =>
                     Check_Array_Repetition
                       (Of_Tree, Node, Node, Expected.Length,
                        Expected.Element, Static_Image);
                     return;
                  when Syn.Mixed_Array_Repetition =>
                     Check_Mixed_Array_Repetition
                       (Of_Tree, Node, Node, Expected.Length,
                        Expected.Element, Static_Image);
                     return;
                  when Syn.Zeroed_Literal =>
                     Check_Array_Zeroed
                       (Of_Tree, Node, Expected.Length, Expected.Element,
                        Expected.Element_Nominal, Site, Because);
                     return;
                  when others =>
                     null;
               end case;

               declare
                  Admitted : constant Boolean :=
                    Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
                    and then Admit_Array_Field (Of_Tree, Node);
                  Got : constant Ty.Type_Kind :=
                    (if Admitted
                          or else Syn.Kind (Of_Tree, Node)
                                    = Syn.Name_Reference
                     then Selected_From (Of_Tree, Node)
                     else Synthesise (Of_Tree, Node));
               begin
                  if Got /= Ty.Ill_Typed
                    and then
                      (Got /= Ty.Fixed_Array
                       or else Landin.Checking.Array_Length
                         (Types.all, Of_Tree, Node) /= Expected.Length
                       or else Landin.Checking.Array_Element
                         (Types.all, Of_Tree, Node) /= Expected.Element
                       or else Landin.Checking.Array_Element_Nominal
                         (Types.all, Of_Tree, Node)
                           /= Expected.Element_Nominal)
                  then
                     Context_Mismatch
                       (Of_Tree, Node, Expected, Site, Because);
                  end if;
               end;

            when Ty.Atom_Value =>
               Require_Atom (Of_Tree, Node, Expected.Atoms, Site, Because);

            when Ty.Function_Value =>
               declare
                  Got : constant Ty.Type_Kind := Synthesise (Of_Tree, Node);
               begin
                  if Got /= Ty.Ill_Typed
                    and then
                      (Got /= Ty.Function_Value
                       or else not Signatures_Agree
                         (Expected.Signature,
                          Landin.Checking.Signature_Of
                            (Types.all, Of_Tree, Node)))
                  then
                     Context_Mismatch
                       (Of_Tree, Node, Expected, Site, Because);
                  end if;
               end;

            when Ty.Scalar_Name =>
               if Syn.Kind (Of_Tree, Node) = Syn.Zeroed_Literal then
                  Landin.Checking.Note
                    (Types.all, Of_Tree, Node, Expected.Kind);
               else
                  Require
                    (Of_Tree, Node, Expected.Kind, Site, Because);
               end if;

            when others =>
               Require (Of_Tree, Node, Expected.Kind, Site, Because);
         end case;
      end Check_Contextual_Value;

      function Synthesise_Control
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind
      is
         First : constant Syn.Node_Id := First_Control_Value (Of_Tree, Node);
         Got   : Ty.Type_Kind;
         Expected : Value_Context;
      begin
         if First = Syn.No_Node then
            return Ty.Not_Typed;
         end if;

         if Syn.Kind (Of_Tree, First) = Syn.Array_Literal then
            declare
               Element_Node : constant Syn.Node_Id :=
                 Syn.Nth_Element (Of_Tree, First, 1);
               Element_Type : Ty.Type_Kind :=
                 Synthesise (Of_Tree, Element_Node);
            begin
               if Element_Type = Ty.Untyped_Integer then
                  Element_Type := Ty.Default_Integer;
                  Commit_To
                    (Of_Tree, Element_Node, Ty.Default_Integer);
               end if;

               if Element_Type not in Ty.Scalar_Name then
                  return Ty.Ill_Typed;
               end if;

               Expected :=
                 (Kind    => Ty.Fixed_Array,
                  Length  => Landin.Checking.Element_Count
                    (Syn.Element_Count (Of_Tree, First)),
                  Element => Ty.Scalar_Name (Element_Type),
                  others  => <>);
            end;
         elsif Syn.Kind (Of_Tree, First) = Syn.Struct_Literal
           and then Syn.Constructed_Type (Of_Tree, First) /= Syn.No_Node
         then
            Expected :=
              (Kind => Ty.Aggregate,
               Nominal => Construction_Body (Of_Tree, First),
               others => <>);
            if Expected.Nominal = Landin.Checking.No_Nominal_Type then
               return Ty.Ill_Typed;
            end if;
         else
            Got :=
              (if Syn.Kind (Of_Tree, First)
                    in Syn.Name_Reference | Syn.Member_Selection
               then Selected_From (Of_Tree, First)
               else Synthesise (Of_Tree, First));

            if Got = Ty.Untyped_Integer then
               Got := Ty.Default_Integer;
               Commit_To (Of_Tree, First, Ty.Default_Integer);
            end if;

            Expected.Kind := Got;
            if Got = Ty.Aggregate then
               Expected.Result_Shape := Landin.Checking.Result_Shape_Of
                 (Types.all, Of_Tree, First);
               if Expected.Result_Shape = Landin.Checking.No_Signature then
                  Expected.Nominal := Landin.Checking.Nominal_Of
                    (Types.all, Of_Tree, First);
               end if;
            elsif Got = Ty.Fixed_Array then
               Expected.Length := Landin.Checking.Array_Length
                 (Types.all, Of_Tree, First);
               Expected.Element := Landin.Checking.Array_Element
                 (Types.all, Of_Tree, First);
               Expected.Element_Nominal :=
                 Landin.Checking.Array_Element_Nominal
                   (Types.all, Of_Tree, First);
            elsif Got = Ty.Function_Value then
               Expected.Signature := Landin.Checking.Signature_Of
                 (Types.all, Of_Tree, First);
            elsif Got = Ty.Atom_Value then
               Expected.Atoms := Landin.Checking.Atom_Set_Of
                 (Types.all, Of_Tree, First);
            end if;
         end if;

         if not Decidable (Expected.Kind) then
            return Ty.Ill_Typed;
         end if;

         Check_Contextual_Value
           (Of_Tree, Node, Expected, Syn.Origin (Of_Tree, Node),
            "the first value-producing edge");
         return Expected.Kind;
      end Synthesise_Control;

      ------------------------------------------------------------
      --  [1940]: a module value is known when the compiler reads it
      ------------------------------------------------------------

      --  A literal, `true`, `false`, an operator of [1820] over those, and
      --  a name bound to a module binding.  Not a call: there is no
      --  compile-time execution in this language, so a call is not a value
      --  the compiler holds.
      function Is_Known (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Boolean is
      begin
         if Node = Syn.No_Node then
            return True;
         end if;

         case Syn.Kind (Of_Tree, Node) is
            when Syn.Call =>
               return False;

            when Syn.Anonymous_Function =>
               --  Forming the code address does not execute or capture its
               --  body; the body is checked as its own routine.
               return True;

            when Syn.If_Statement | Syn.Match_Statement | Syn.Bare_Block =>
               return False;

            --  D31 measures the literal's syntax.  Its elements are checked
            --  for one scalar shape but are not module values to be folded.
            when Syn.Len_Of =>
               return True;

            when Syn.Name_Reference =>
               if Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                  /= Res.Bound
               then
                  --  Not resolved: the resolver said so and this declines
                  --  to say it again.
                  return True;
               end if;

               return Res.Sort_Of
                        (Meanings.all,
                         Res.Bound_To (Meanings.all, Of_Tree, Node))
                      in Res.Module_Function | Res.Module_Binding
                         | Res.Module_Atom;

            when others =>
               for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
                  if not Is_Known
                           (Of_Tree, Syn.Slot (Of_Tree, Node, Position))
                  then
                     return False;
                  end if;
               end loop;

               return True;
         end case;
      end Is_Known;

      procedure Check_Module_Value
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Value : constant Syn.Node_Id := Syn.Value_Of (Of_Tree, Node);
         Written : constant Syn.Node_Id :=
           Syn.Declared_Type (Of_Tree, Node);
         Contextual_Image : constant Boolean :=
           (Written /= Syn.No_Node
            and then Type_At (Of_Tree, Written) = Ty.Fixed_Array)
           or else
             (Value /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Value)
                       in Syn.Array_Literal | Syn.Array_Repetition
                          | Syn.Mixed_Array_Repetition
                          | Syn.Member_Selection
              and then Landin.Checking.Type_Of
                         (Types.all, Of_Tree, Value) = Ty.Fixed_Array);
         --  D66 checks each scalar field inside a contextual module struct
         --  literal at the literal boundary.  Do not send its labelled run
         --  through the generic subtree refusal a second time.
         Module_Struct_Literal : constant Boolean :=
           Value /= Syn.No_Node
           and then Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal
           and then
             ((Written /= Syn.No_Node
               and then Type_At (Of_Tree, Written) = Ty.Aggregate)
              or else Landin.Checking.Type_Of
                (Types.all, Of_Tree, Value) = Ty.Aggregate);

         procedure Refuse_Unreadable_Subtree (Where : Syn.Node_Id);

         procedure Refuse_Unreadable_Subtree (Where : Syn.Node_Id) is
         begin
            if Where = Syn.No_Node then
               return;
            end if;

            declare
               What : constant String :=
                 (case Syn.Kind (Of_Tree, Where) is
                     when Syn.Member_Selection => "a field selection",
                     when Syn.Element_Index    => "an array index",
                     when others               => "");
            begin
               --  Neither a measured literal nor a static anonymous routine
               --  executes its expression subtree to form this module image.
               if Syn.Kind (Of_Tree, Where)
                    in Syn.Len_Of | Syn.Anonymous_Function
               then
                  return;
               end if;

               if What /= "" then
                  Bad.Report
                    (Item    => Bad.Not_Known_At_Compile_Time,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Where),
                     Message => What & " has no static module value in this"
                                & " compiler",
                     Note    => "[1940]: a module initializer is read at"
                                & " compile time, before any storage can be"
                                & " selected",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Where);
                  return;
               end if;

               for Position in 1 .. Syn.Slot_Count (Of_Tree, Where) loop
                  Refuse_Unreadable_Subtree
                    (Syn.Slot (Of_Tree, Where, Position));
               end loop;
            end;
         end Refuse_Unreadable_Subtree;
      begin
         --  Zero is reserved to the failing-call success carrier and is no
         --  source atom.  Unlike scalar module storage, an atom binding
         --  therefore has no omitted or `zeroed` static image.
         if Landin.Checking.Type_Of
              (Types.all,
               Declaration_At (Syn.Source_Of (Of_Tree), Node))
              = Ty.Atom_Value
           and then
             (Value = Syn.No_Node
              or else Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal)
         then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "a module atom binding needs an atom initializer",
               Note    => "[0630]: every atom value is a declared identity;"
                          & " there is no implicit zero atom",
               Related => Syn.Origin
                 (Of_Tree,
                  (if Written = Syn.No_Node then Node else Written)),
               Because => "this atom binding",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
            return;
         end if;

         if Landin.Checking.Type_Of
              (Types.all,
               Declaration_At (Syn.Source_Of (Of_Tree), Node))
              = Ty.Fixed_Array
           and then Value = Syn.No_Node
           and then Landin.Checking.Array_Length
             (Types.all,
              Declaration_At (Syn.Source_Of (Of_Tree), Node)) > 0
           and then Landin.Checking.Array_Element_Nominal
             (Types.all,
              Declaration_At (Syn.Source_Of (Of_Tree), Node))
                /= Landin.Checking.No_Nominal_Type
           and then Landin.Checking.Has_Layout
             (Types.all,
              Landin.Checking.Array_Element_Nominal
                (Types.all,
                 Declaration_At (Syn.Source_Of (Of_Tree), Node)))
           and then not Has_Zero_Image
             (Landin.Checking.Array_Element_Nominal
                (Types.all,
                 Declaration_At (Syn.Source_Of (Of_Tree), Node)))
         then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "this module array needs an explicit initial"
                          & " value",
               Note    => "[0540]: its struct element contains a function"
                          & " address, which has no zero image",
               Related => Syn.Origin (Of_Tree, Written),
               Because => "the array type written here",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
            return;
         end if;

         if Landin.Checking.Type_Of
              (Types.all,
               Declaration_At (Syn.Source_Of (Of_Tree), Node))
              = Ty.Aggregate
           and then Value = Syn.No_Node
           and then Landin.Checking.Has_Layout
             (Types.all,
              Landin.Checking.Nominal_Of
                (Types.all,
                 Declaration_At (Syn.Source_Of (Of_Tree), Node)))
           and then not Has_Zero_Image
             (Landin.Checking.Nominal_Of
                (Types.all,
                 Declaration_At (Syn.Source_Of (Of_Tree), Node)))
         then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "this module struct needs an explicit initial"
                          & " value",
               Note    => "[0540]: a function address has no zero image,"
                          & " so omitted storage cannot initialize it",
               Related => Syn.Origin (Of_Tree, Written),
               Because => "the struct type written here",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
            return;
         end if;

         --  A contextual initializer boundary already owns a refused binding
         --  or value.  Every Declared_As_Node refusal marks the written type,
         --  while D51's selected field marks the value; [1940] must not add a
         --  second report after either refusal.
         if (Written /= Syn.No_Node
             and then Landin.Checking.Type_Of
                        (Types.all, Of_Tree, Written) = Ty.Ill_Typed)
           or else
             (Value /= Syn.No_Node
              and then Landin.Checking.Type_Of (Types.all, Of_Tree, Value)
                         = Ty.Ill_Typed)
         then
            return;
         end if;

         --  D24 gives array-literal elements their own more specific boundary.
         --  Scalar module values still follow [1940]: selecting storage is not
         --  a compile-time scalar image, even beneath an otherwise foldable
         --  operator.
         if Value /= Syn.No_Node
           and then not Contextual_Image
           and then not Module_Struct_Literal
         then
            Refuse_Unreadable_Subtree (Value);
         end if;

         --  D66's contextual literal walk owns per-field static exclusions
         --  and unknown-value reports.  It runs in Check_Statement just
         --  after this generic module boundary.
         if Module_Struct_Literal then
            return;
         end if;

         if Value = Syn.No_Node or else Is_Known (Of_Tree, Value) then
            return;
         end if;

         Bad.Report
           (Item    => Bad.Not_Known_At_Compile_Time,
            Source  => Syn.Source_Of (Of_Tree),
            Where   => Syn.Where (Of_Tree, Value),
            Message => "a module value has to be one the compiler knows"
                       & " when it reads it, and this needs runtime control",
            Note    => "[1940]: nothing runs before the entry point"
                       & " [1460], and there is no compile-time execution",
            Into    => Found);
         Landin.Checking.Refuse (Types.all, Of_Tree, Value);
      end Check_Module_Value;

      procedure Infer (Id : Res.Declaration_Id) is
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Id));
         Node    : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Id);
         Value   : constant Syn.Node_Id := Syn.Value_Of (Of_Tree.all, Node);
      begin
         Landin.Checking.Begin_Inference (Types.all, Id);

         if Value = Syn.No_Node then
            Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
            return;
         end if;

         --  D72: unlike a bare inferred literal, construction supplies the
         --  nominal body before the declaration is settled.  The field walk
         --  remains contextual and runs in Check_Statement.
         if Res.Sort_Of (Meanings.all, Id)
              in Res.Local_Binding | Res.Module_Binding
           and then Syn.Kind (Of_Tree.all, Value) = Syn.Struct_Literal
           and then Syn.Constructed_Type (Of_Tree.all, Value) /= Syn.No_Node
         then
            declare
               Wrote : constant Landin.Checking.Nominal_Type_Id :=
                 Construction_Body (Of_Tree.all, Value);
            begin
               if Wrote = Landin.Checking.No_Nominal_Type then
                  Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
               else
                  Landin.Checking.Note
                    (Types.all, Of_Tree.all, Value, Ty.Aggregate);
                  Landin.Checking.Note_Nominal
                    (Types.all, Of_Tree.all, Value, Wrote);
                  Landin.Checking.Note_Nominal (Types.all, Id, Wrote);
                  Landin.Checking.Settle (Types.all, Id, Ty.Aggregate);
               end if;
            end;
            return;
         end if;

         --  [0530]: a nonempty literal in an inferred binding supplies D17's
         --  length and takes its scalar element type from the first element.
         --  [0200] gives an otherwise untyped integer expression its default
         --  context; that settled scalar then checks every later element.
         --  D25 uses the shape for a local source-order initializer; D26 uses
         --  the same shape for D24's separate [1940] module image boundary.
         if Res.Sort_Of (Meanings.all, Id)
              in Res.Local_Binding | Res.Module_Binding
           and then Syn.Kind (Of_Tree.all, Value) = Syn.Array_Literal
         then
            declare
               Count : constant Landin.Checking.Element_Count :=
                 Landin.Checking.Element_Count
                   (Syn.Element_Count (Of_Tree.all, Value));
               First : constant Syn.Node_Id :=
                 Syn.Nth_Element (Of_Tree.all, Value, 1);
               Got : constant Ty.Type_Kind :=
                 Synthesise (Of_Tree.all, First);
               Element : Ty.Scalar_Name;
            begin
               if Got = Ty.Untyped_Integer then
                  Element := Ty.Default_Integer;
                  Commit_To (Of_Tree.all, First, Element);
               elsif Got in Ty.Scalar_Name then
                  Element := Ty.Scalar_Name (Got);
               else
                  if Got = Ty.No_Value then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree.all),
                        Where   => Syn.Where (Of_Tree.all, First),
                        Message => "this hands back nothing, so it cannot"
                                   & " supply an array element type",
                        Note    => "[0530]: the literal supplies one scalar"
                                   & " element type for the inferred array",
                        Related => Syn.Origin (Of_Tree.all, Node),
                        Because => "this inferred binding",
                        Into    => Found);
                  end if;

                  Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
                  return;
               end if;

               declare
                  Element_Bytes : constant Ty.Magnitude :=
                    Ty.Magnitude
                      (Landin.Targets.Bytes
                         (Ty.Storage_Size (Element, Facts)));
                  Maximum_Bytes : constant Ty.Magnitude :=
                    Ty.Magnitude
                      (Landin.Targets.Maximum_Object_Size (Facts));
               begin
                  if Element_Bytes /= 0
                    and then Ty.Magnitude (Count)
                               > Maximum_Bytes / Element_Bytes
                  then
                     Bad.Report
                       (Item    => Bad.Literal_Out_Of_Range,
                        Source  => Syn.Source_Of (Of_Tree.all),
                        Where   => Syn.Where (Of_Tree.all, Value),
                        Message => "this inferred array is larger than the"
                                   & " target can address",
                        Note    => "D18: an array's byte extent must fit the"
                                   & " target's usize",
                        Into    => Found);
                     Landin.Checking.Refuse (Types.all, Of_Tree.all, Value);
                     Landin.Checking.Settle
                       (Types.all, Id, Ty.Ill_Typed);
                     return;
                  end if;
               end;

               Landin.Checking.Note
                 (Types.all, Of_Tree.all, Value, Ty.Fixed_Array);
               Landin.Checking.Note_Array
                 (Types.all, Of_Tree.all, Value, Count, Element);
               Landin.Checking.Note_Array
                 (Types.all, Id, Count, Element);
               Landin.Checking.Settle (Types.all, Id, Ty.Fixed_Array);

               for Position in 2 .. Syn.Element_Count (Of_Tree.all, Value) loop
                  Require
                    (Of_Tree.all,
                     Syn.Nth_Element (Of_Tree.all, Value, Position), Element,
                     Syn.Origin (Of_Tree.all, Node),
                     "the first inferred array element");
               end loop;
            end;

            return;
         end if;

         --  D33/D35: a counted repetition directly initializing an inferred
         --  local or module binding supplies D17's length and takes its scalar
         --  element type from its
         --  one expression.  Like D25, an untyped integer takes [0200]'s
         --  default; unlike a literal, no source run needs a common context.
         --  D136 admits an explicitly typed zero-length array. A repetition
         --  that must infer its shape still has no element-bearing source run,
         --  so D33/D35 continue to refuse a zero count.
         if Res.Sort_Of (Meanings.all, Id)
              in Res.Local_Binding | Res.Module_Binding
           and then Syn.Kind (Of_Tree.all, Value) = Syn.Array_Repetition
           and then Syn.Repetition_Count (Of_Tree.all, Value) /= Syn.No_Node
         then
            declare
               Count_Node : constant Syn.Node_Id :=
                 Syn.Repetition_Count (Of_Tree.all, Value);
               Repeated : constant Syn.Node_Id :=
                 Syn.Repeated_Element (Of_Tree.all, Value);
               Snap : constant Landin.Source.Snapshot :=
                 Source (Context, Syn.Source_Of (Of_Tree.all));
               Text : constant String :=
                 Landin.Source.Slice
                   (Snap, Syn.Digit_Span (Of_Tree.all, Count_Node));
               Count_Value : Ty.Magnitude;
               Overflowed  : Boolean;
            begin
               Ty.Evaluate
                 (Text, Syn.Base (Of_Tree.all, Count_Node),
                  Count_Value, Overflowed);

               if Overflowed then
                  Bad.Report
                    (Item    => Bad.Literal_Out_Of_Range,
                     Source  => Syn.Source_Of (Of_Tree.all),
                     Where   => Syn.Where (Of_Tree.all, Count_Node),
                     Message => "this is more elements than an array may have",
                     Note    => "D18: an array's byte extent must fit the"
                                & " target's usize",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree.all, Value);
                  Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
                  return;
               elsif Count_Value = 0 then
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree.all),
                     Where   => Syn.Where (Of_Tree.all, Count_Node),
                     Message => "inferring a zero-element array is not"
                                & " enabled yet",
                     Refused => Bad.Array_Value,
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree.all, Value);
                  Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
                  return;
               end if;

               declare
                  Count : constant Landin.Checking.Element_Count :=
                    Landin.Checking.Element_Count (Count_Value);
                  Got : constant Ty.Type_Kind :=
                    Synthesise (Of_Tree.all, Repeated);
                  Element : Ty.Scalar_Name;
               begin
                  if Got = Ty.Untyped_Integer then
                     Element := Ty.Default_Integer;
                     Commit_To (Of_Tree.all, Repeated, Element);
                  elsif Got in Ty.Scalar_Name then
                     Element := Ty.Scalar_Name (Got);
                  else
                     if Got = Ty.No_Value then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree.all),
                           Where   => Syn.Where (Of_Tree.all, Repeated),
                           Message => "this hands back nothing, so it cannot"
                                      & " supply an array element type",
                           Note    => "D33: repetition supplies one scalar"
                                      & " element type for the inferred array",
                           Related => Syn.Origin (Of_Tree.all, Node),
                           Because => "this inferred binding",
                           Into    => Found);
                     end if;

                     Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
                     return;
                  end if;

                  declare
                     Element_Bytes : constant Ty.Magnitude :=
                       Ty.Magnitude
                         (Landin.Targets.Bytes
                            (Ty.Storage_Size (Element, Facts)));
                     Maximum_Bytes : constant Ty.Magnitude :=
                       Ty.Magnitude
                         (Landin.Targets.Maximum_Object_Size (Facts));
                  begin
                     if Element_Bytes /= 0
                       and then Count_Value > Maximum_Bytes / Element_Bytes
                     then
                        Bad.Report
                          (Item    => Bad.Literal_Out_Of_Range,
                           Source  => Syn.Source_Of (Of_Tree.all),
                           Where   => Syn.Where (Of_Tree.all, Value),
                           Message => "this inferred array is larger than the"
                                      & " target can address",
                           Note    => "D18: an array's byte extent must fit"
                                      & " the target's usize",
                           Into    => Found);
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree.all, Value);
                        Landin.Checking.Settle
                          (Types.all, Id, Ty.Ill_Typed);
                        return;
                     end if;
                  end;

                  Landin.Checking.Note
                    (Types.all, Of_Tree.all, Value, Ty.Fixed_Array);
                  Landin.Checking.Note_Array
                    (Types.all, Of_Tree.all, Value, Count, Element);
                  Landin.Checking.Note_Array
                    (Types.all, Id, Count, Element);
                  Landin.Checking.Settle
                    (Types.all, Id, Ty.Fixed_Array);
               end;
            end;

            return;
         end if;

         declare
            --  D21 infers D17's shape from a direct storage name for a local
            --  or module binding.  D56/D61 admit an aggregate source only
            --  after carrying its nominal body identity.  Settling an
            --  untouched source is intentional for a forward module name;
            --  the Underway guard preserves an inferred cycle's single
            --  report.  A type declaration is a name but owns no storage.
            Named_Storage : constant Boolean :=
              Res.Sort_Of (Meanings.all, Id)
                in Res.Local_Binding | Res.Module_Binding
              and then Syn.Kind (Of_Tree.all, Value) = Syn.Name_Reference
              and then Res.Verdict_Of (Meanings.all, Of_Tree.all, Value)
                       = Res.Bound
              and then Res.Sort_Of
                (Meanings.all,
                 Res.Bound_To (Meanings.all, Of_Tree.all, Value))
                  in Res.Local_Binding | Res.Module_Binding;
            Named : constant Res.Declaration_Id :=
              (if Named_Storage
               then Res.Bound_To (Meanings.all, Of_Tree.all, Value)
               else Res.No_Declaration);
            Named_Type : constant Ty.Type_Kind :=
              (if Named_Storage
                    and then Landin.Checking.State_Of (Types.all, Named)
                               /= Landin.Checking.Underway
               then Settled_Type (Named)
               else Ty.Ill_Typed);
            Direct_Name : constant Boolean :=
              Named_Storage and then Named_Type = Ty.Fixed_Array;
            --  D120: a local may infer from a source however many
            --  selections reach it.  A module binding still takes only a
            --  direct name or one field of one, because its initializer is
            --  a folded image rather than a copy.
            Direct_Field : constant Boolean :=
              Syn.Kind (Of_Tree.all, Value) = Syn.Member_Selection
              and then
                (Syn.Kind
                   (Of_Tree.all, Syn.Target_Of (Of_Tree.all, Value))
                   = Syn.Name_Reference
                 or else Res.Sort_Of (Meanings.all, Id) = Res.Local_Binding)
              and then Admit_Array_Field (Of_Tree.all, Value);
            Direct_Child : constant Boolean :=
              not Direct_Field
              and then Res.Sort_Of (Meanings.all, Id) = Res.Local_Binding
              and then Syn.Kind (Of_Tree.all, Value)
                         in Syn.Member_Selection | Syn.Element_Index
              and then Chain_Names_Element_Storage (Of_Tree.all, Value)
              and then Selected_From (Of_Tree.all, Value) = Ty.Aggregate;
            Direct_Struct : constant Boolean :=
              (Named_Storage
               and then Named_Type = Ty.Aggregate
               and then
                 (Landin.Checking.Nominal_Of (Types.all, Named)
                    /= Landin.Checking.No_Nominal_Type
                  or else Landin.Checking.Result_Shape_Of (Types.all, Named)
                    /= Landin.Checking.No_Signature))
              or else Direct_Child;
            Direct_Source : constant Boolean :=
              Direct_Name or else Direct_Field or else Direct_Struct;
            Got : constant Ty.Type_Kind :=
              (if Direct_Source
               then Selected_From (Of_Tree.all, Value)
               else Synthesise (Of_Tree.all, Value));
            Direct_Array : constant Boolean :=
              (Direct_Name or else Direct_Field)
              and then Got = Ty.Fixed_Array;
            Control_Source : constant Boolean :=
              Syn.Kind (Of_Tree.all, Value)
                in Syn.If_Statement | Syn.Match_Statement | Syn.Bare_Block;
         begin
            if Got = Ty.Untyped_Integer then
               Commit_To (Of_Tree.all, Value, Ty.Default_Integer);
               Landin.Checking.Settle
                 (Types.all, Id, Ty.Type_Kind (Ty.Default_Integer));
            else
               if Got = Ty.Fixed_Array
                 and then (Direct_Array
                           or else Syn.Kind (Of_Tree.all, Value) = Syn.Call
                           or else Control_Source)
               then
                  Landin.Checking.Note_Array
                    (Types.all, Id,
                     Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Value),
                     Landin.Checking.Array_Element
                       (Types.all, Of_Tree.all, Value));
                  Landin.Checking.Note_Array_Element_Nominal
                    (Types.all, Id,
                     Landin.Checking.Array_Element_Nominal
                       (Types.all, Of_Tree.all, Value));
               end if;

               if Got = Ty.Function_Value then
                  Landin.Checking.Note_Signature
                    (Types.all, Id,
                     Landin.Checking.Signature_Of
                       (Types.all, Of_Tree.all, Value));
               elsif Got = Ty.Atom_Value then
                  Landin.Checking.Note_Atom_Set
                    (Types.all, Id,
                     Landin.Checking.Atom_Set_Of
                       (Types.all, Of_Tree.all, Value));
               end if;

               if Got = Ty.Aggregate
                 and then (Direct_Struct
                           or else Syn.Kind (Of_Tree.all, Value) = Syn.Call
                           or else Control_Source)
               then
                  declare
                     Shape : constant Landin.Checking.Signature_Id :=
                       Landin.Checking.Result_Shape_Of
                         (Types.all, Of_Tree.all, Value);
                  begin
                     if Shape /= Landin.Checking.No_Signature then
                        Landin.Checking.Note_Result_Shape
                          (Types.all, Id, Shape);
                     else
                        --  D56/D61: an inferred nominal aggregate carries
                        --  the declaration that wrote its body.
                        Landin.Checking.Note_Nominal
                          (Types.all, Id,
                           Landin.Checking.Nominal_Of
                             (Types.all, Of_Tree.all, Value));
                     end if;
                  end;
               end if;

               Landin.Checking.Settle (Types.all, Id, Got);
            end if;
         end;
      end Infer;

      ------------------------------------------------------------
      --  Static function-value images
      ------------------------------------------------------------

      type Function_Image_State is
        (Function_Unseen, Function_Visiting, Function_Valid,
         Function_Invalid);
      Function_Images : array
        (Res.Declaration_Id'(1)
         .. Res.Declaration_Id (Res.Declaration_Count (Meanings.all)))
        of Function_Image_State := [others => Function_Unseen];

      function Validate_Function_Image
        (Id : Res.Declaration_Id) return Boolean;
      procedure Validate_Function_Images;

      function Validate_Function_Image
        (Id : Res.Declaration_Id) return Boolean
      is
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Id));
         Node : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Id);
         Value : constant Syn.Node_Id := Syn.Value_Of (Of_Tree.all, Node);
      begin
         case Function_Images (Id) is
            when Function_Valid =>
               return True;
            when Function_Invalid =>
               return False;
            when Function_Visiting =>
               Bad.Report
                 (Item    => Bad.Not_Known_At_Compile_Time,
                  Source  => Res.Source_Of (Meanings.all, Id),
                  Where   => Syn.Anchor (Of_Tree.all, Node),
                  Message => "the function address of `"
                             & Spelled (Syn.Name (Of_Tree.all, Node))
                             & "` is worked out from itself",
                  Note    => "[1940]: a static value chain has to reach a"
                             & " value rather than return to itself",
                  Into    => Found);
               Function_Images (Id) := Function_Invalid;
               return False;
            when Function_Unseen =>
               null;
         end case;

         Function_Images (Id) := Function_Visiting;
         if Value /= Syn.No_Node
           and then Syn.Kind (Of_Tree.all, Value) = Syn.Anonymous_Function
         then
            Function_Images (Id) := Function_Valid;
            return True;
         end if;

         if Value /= Syn.No_Node
           and then Syn.Kind (Of_Tree.all, Value) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree.all, Value)
                      = Res.Bound
         then
            declare
               Source_Id : constant Res.Declaration_Id :=
                 Res.Bound_To (Meanings.all, Of_Tree.all, Value);
               Reaches : Boolean := False;
            begin
               if Res.Sort_Of (Meanings.all, Source_Id)
                    = Res.Module_Function
               then
                  Reaches := True;
               elsif Res.Sort_Of (Meanings.all, Source_Id)
                       = Res.Module_Binding
                 and then Landin.Checking.Type_Of (Types.all, Source_Id)
                            = Ty.Function_Value
               then
                  Reaches := Validate_Function_Image (Source_Id);
               end if;
               Function_Images (Id) :=
                 (if Reaches then Function_Valid else Function_Invalid);
               return Reaches;
            end;
         end if;

         Function_Images (Id) := Function_Invalid;
         return False;
      end Validate_Function_Image;

      procedure Validate_Function_Images is
      begin
         for Id in Res.Declaration_Id'(1)
                   .. Res.Declaration_Id
                        (Res.Declaration_Count (Meanings.all))
         loop
            if Res.Sort_Of (Meanings.all, Id) = Res.Module_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                         = Ty.Function_Value
            then
               declare
                  Reaches : constant Boolean := Validate_Function_Image (Id);
               begin
                  pragma Unreferenced (Reaches);
               end;
            end if;
         end loop;
      end Validate_Function_Images;

      ------------------------------------------------------------
      --  R2.20: every module array or struct image reaches static storage
      ------------------------------------------------------------

      type Image_State is (Unseen, Visiting, Valid, Invalid);
      Image_States : array
        (Res.Declaration_Id'(1)
         .. Res.Declaration_Id (Res.Declaration_Count (Meanings.all)))
        of Image_State := [others => Unseen];

      function Validate_Module_Image
        (Id : Res.Declaration_Id) return Boolean;

      function Validate_Recursive_Struct_Image
        (Of_Tree : Syn.Tree;
         Wrote   : Landin.Checking.Nominal_Type_Id;
         Literal : Syn.Node_Id) return Boolean;

      function Body_Image_Contains_Aggregate
        (Wrote : Landin.Checking.Nominal_Type_Id) return Boolean;

      procedure Validate_Module_Images;

      function Body_Image_Contains_Aggregate
        (Wrote : Landin.Checking.Nominal_Type_Id) return Boolean
      is
      begin
         for Field in
           1 .. Landin.Checking.Layout_Field_Count (Types.all, Wrote)
         loop
            declare
               Shape : constant Landin.Checking.Field_Shape :=
                 Landin.Checking.Field_Shape_Of
                   (Types.all, Wrote, Field);
            begin
               if Shape.Kind = Landin.Checking.Aggregate_Field then
                  return True;
               elsif Shape.Kind = Landin.Checking.Variant_Field then
                  for Variant_Case in 1 .. Shape.Cases loop
                     for Payload in
                       1 .. Landin.Checking.Variant_Case_Field_Count
                              (Types.all, Wrote, Field, Variant_Case)
                     loop
                        if Landin.Checking.Nth_Variant_Case_Field
                          (Types.all, Wrote, Field, Variant_Case,
                           Payload).Kind
                             = Landin.Checking.Aggregate_Field
                        then
                           return True;
                        end if;
                     end loop;
                  end loop;
               end if;
            end;
         end loop;
         return False;
      end Body_Image_Contains_Aggregate;

      function Validate_Recursive_Struct_Image
        (Of_Tree : Syn.Tree;
         Wrote   : Landin.Checking.Nominal_Type_Id;
         Literal : Syn.Node_Id) return Boolean
      is
         function Validate_Aggregate_Value
           (Given : Syn.Node_Id;
            Expected : Landin.Checking.Nominal_Type_Id) return Boolean;

         function Selected_Case
           (Given : Syn.Node_Id;
            Field : Positive) return Natural;

         function Selected_Case
           (Given : Syn.Node_Id;
            Field : Positive) return Natural
         is
            Body_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of
             (Meanings.all, Template_Declaration (Wrote)));
            Body_Node : constant Syn.Node_Id := Syn.Declared_Type
              (Body_Tree.all, Res.Node_Of
               (Meanings.all, Template_Declaration (Wrote)));
            Part : constant Syn.Node_Id :=
              Syn.Nth_Field (Body_Tree.all, Body_Node, Field);
            Nominal : constant Syn.Node_Id :=
              (if Syn.Kind (Of_Tree, Given) = Syn.Name_Reference
               then Given else Syn.Constructed_Type (Of_Tree, Given));
            Means : constant Res.Declaration_Id :=
              (if Nominal /= Syn.No_Node
                 and then Res.Verdict_Of
                   (Meanings.all, Of_Tree, Nominal) = Res.Bound
               then Res.Bound_To (Meanings.all, Of_Tree, Nominal)
               else Res.No_Declaration);
         begin
            if Means = Res.No_Declaration
              or else Res.Sort_Of (Meanings.all, Means) /= Res.Case_Name
            then
               return 0;
            end if;
            for Candidate in 1 .. Syn.Case_Count (Body_Tree.all, Part) loop
               if Res.Source_Of (Meanings.all, Means)
                    = Syn.Source_Of (Body_Tree.all)
                 and then Res.Node_Of (Meanings.all, Means)
                    = Syn.Nth_Case (Body_Tree.all, Part, Candidate)
               then
                  return Candidate;
               end if;
            end loop;
            return 0;
         end Selected_Case;

         function Validate_Aggregate_Value
           (Given : Syn.Node_Id;
            Expected : Landin.Checking.Nominal_Type_Id) return Boolean
         is
         begin
            if Syn.Kind (Of_Tree, Given) = Syn.Zeroed_Literal then
               return True;
            elsif Syn.Kind (Of_Tree, Given) = Syn.Struct_Literal then
               return Validate_Recursive_Struct_Image
                 (Of_Tree, Expected, Given);
            elsif Syn.Kind (Of_Tree, Given) = Syn.Name_Reference
              and then Res.Verdict_Of (Meanings.all, Of_Tree, Given)
                         = Res.Bound
            then
               declare
                  Source_Id : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Given);
               begin
                  return Res.Sort_Of (Meanings.all, Source_Id)
                           = Res.Module_Binding
                    and then Landin.Checking.Type_Of
                      (Types.all, Source_Id) = Ty.Aggregate
                    and then Landin.Checking.Nominal_Of
                      (Types.all, Source_Id) = Expected
                    and then Validate_Module_Image (Source_Id);
               end;
            elsif Is_Direct_Module_Field (Of_Tree, Given) then
               declare
                  Root : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Given);
                  Source_Id : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Root);
                  Source_Body : constant Landin.Checking.Nominal_Type_Id :=
                    Landin.Checking.Nominal_Of (Types.all, Source_Id);
                  Which : constant Natural :=
                    (if Source_Body = Landin.Checking.No_Nominal_Type
                     then 0
                     else Field_At
                       (Source_Body, Syn.Name (Of_Tree, Given)));
               begin
                  return Source_Body /= Landin.Checking.No_Nominal_Type
                    and then Landin.Checking.Has_Layout
                      (Types.all, Source_Body)
                    and then Which /= 0
                    and then Landin.Checking.Field_Kind_Of
                      (Types.all, Source_Body, Which)
                        = Landin.Checking.Aggregate_Field
                    and then Landin.Checking.Field_Shape_Of
                      (Types.all, Source_Body, Which).Nominal
                        = Expected
                    and then Validate_Module_Image (Source_Id);
               end;
            end if;
            return False;
         end Validate_Aggregate_Value;

         Reaches : Boolean := True;
      begin
         for Position in
           1 .. Syn.Field_Value_Count (Of_Tree, Literal)
         loop
            declare
               Label : constant Syn.Node_Id :=
                 Syn.Nth_Field_Value (Of_Tree, Literal, Position);
               Given : constant Syn.Node_Id :=
                 Syn.Value_Of (Of_Tree, Label);
               Which : constant Natural :=
                 Field_At (Wrote, Syn.Name (Of_Tree, Label));
            begin
               if Which = 0 then
                  Reaches := False;
               else
                  declare
                     Shape : constant Landin.Checking.Field_Shape :=
                       Landin.Checking.Field_Shape_Of
                         (Types.all, Wrote, Which);
                  begin
                     case Shape.Kind is
                        when Landin.Checking.Scalar_Field =>
                           null;

                        when Landin.Checking.Fixed_Array_Field =>
                           if Syn.Kind (Of_Tree, Given)
                                = Syn.Name_Reference
                             and then Res.Verdict_Of
                               (Meanings.all, Of_Tree, Given) = Res.Bound
                           then
                              declare
                                 Source_Id : constant Res.Declaration_Id :=
                                   Res.Bound_To
                                     (Meanings.all, Of_Tree, Given);
                              begin
                                 if Res.Sort_Of (Meanings.all, Source_Id)
                                      = Res.Module_Binding
                                   and then Landin.Checking.Type_Of
                                     (Types.all, Source_Id) = Ty.Fixed_Array
                                   and then Landin.Checking.Array_Length
                                     (Types.all, Source_Id) = Shape.Length
                                   and then Landin.Checking.Array_Element
                                     (Types.all, Source_Id) = Shape.Element
                                 then
                                    Reaches := Validate_Module_Image
                                      (Source_Id) and then Reaches;
                                 else
                                    Reaches := False;
                                 end if;
                              end;
                           elsif Syn.Kind (Of_Tree, Given)
                                   = Syn.Member_Selection
                           then
                              declare
                                 Root : constant Syn.Node_Id :=
                                   Syn.Target_Of (Of_Tree, Given);
                              begin
                                 if Is_Module_Array_Field
                                   (Of_Tree, Given, Shape.Length,
                                    Shape.Element)
                                 then
                                    Reaches := Validate_Module_Image
                                      (Res.Bound_To
                                         (Meanings.all, Of_Tree, Root))
                                      and then Reaches;
                                 else
                                    Reaches := False;
                                 end if;
                              end;
                           end if;

                        when Landin.Checking.Aggregate_Field =>
                           Reaches := Validate_Aggregate_Value
                             (Given, Shape.Nominal)
                             and then Reaches;

                        when Landin.Checking.Variant_Field =>
                           declare
                              Selected : constant Natural :=
                                Selected_Case (Given, Positive (Which));
                           begin
                              if Selected = 0 then
                                 Reaches := False;
                              elsif Syn.Kind (Of_Tree, Given)
                                      = Syn.Struct_Literal
                              then
                                 for Payload_Position in
                                   1 .. Syn.Field_Value_Count
                                          (Of_Tree, Given)
                                 loop
                                    declare
                                       Payload_Label : constant Syn.Node_Id :=
                                         Syn.Nth_Field_Value
                                           (Of_Tree, Given,
                                            Payload_Position);
                                       Payload : Natural := 0;
                                       Given_Payload : constant Syn.Node_Id :=
                                         Syn.Value_Of
                                           (Of_Tree, Payload_Label);
                                       Body_Tree : constant not null access
                                         constant Syn.Tree := Tree_For
                                           (Res.Source_Of
                                              (Meanings.all,
                                               Template_Declaration
                                                 (Wrote)));
                                       Body_Node : constant Syn.Node_Id :=
                                         Syn.Declared_Type
                                           (Body_Tree.all,
                                            Res.Node_Of
                                              (Meanings.all,
                                               Template_Declaration
                                                 (Wrote)));
                                       Part : constant Syn.Node_Id :=
                                         Syn.Nth_Field
                                           (Body_Tree.all, Body_Node,
                                            Positive (Which));
                                       Case_Node : constant Syn.Node_Id :=
                                         Syn.Nth_Case
                                           (Body_Tree.all, Part, Selected);
                                    begin
                                       for Candidate in
                                         1 .. Syn.Payload_Field_Count
                                                (Body_Tree.all, Case_Node)
                                       loop
                                          if Syn.Name
                                               (Of_Tree, Payload_Label)
                                            = Syn.Name
                                                (Body_Tree.all,
                                                 Syn.Nth_Payload_Field
                                                   (Body_Tree.all,
                                                    Case_Node, Candidate))
                                          then
                                             Payload := Candidate;
                                             exit;
                                          end if;
                                       end loop;
                                       if Payload = 0 then
                                          Reaches := False;
                                       else
                                          declare
                                             Payload_Shape : constant
                                               Landin.Checking.Field_Shape :=
                                                 Landin.Checking
                                                   .Nth_Variant_Case_Field
                                                   (Types.all, Wrote,
                                                    Positive (Which),
                                                    Positive (Selected),
                                                    Positive (Payload));
                                          begin
                                             if Payload_Shape.Kind =
                                                  Landin.Checking
                                                    .Aggregate_Field
                                             then
                                                Reaches :=
                                                  Validate_Aggregate_Value
                                                    (Given_Payload,
                                                     Payload_Shape
                                                       .Nominal)
                                                  and then Reaches;
                                             elsif Payload_Shape.Kind =
                                                Landin.Checking
                                                  .Fixed_Array_Field
                                               and then Syn.Kind
                                                 (Of_Tree, Given_Payload)
                                                   = Syn.Name_Reference
                                               and then Res.Verdict_Of
                                                 (Meanings.all, Of_Tree,
                                                  Given_Payload) = Res.Bound
                                             then
                                                declare
                                                   Source_Id : constant
                                                     Res.Declaration_Id :=
                                                       Res.Bound_To
                                                         (Meanings.all,
                                                          Of_Tree,
                                                          Given_Payload);
                                                begin
                                                   if Res.Sort_Of
                                                     (Meanings.all, Source_Id)
                                                       = Res.Module_Binding
                                                     and then Landin.Checking
                                                       .Type_Of
                                                       (Types.all, Source_Id)
                                                         = Ty.Fixed_Array
                                                     and then Landin.Checking
                                                       .Array_Length
                                                       (Types.all, Source_Id)
                                                         = Payload_Shape.Length
                                                     and then Landin.Checking
                                                       .Array_Element
                                                       (Types.all, Source_Id)
                                                         = Payload_Shape
                                                             .Element
                                                   then
                                                      Reaches :=
                                                        Validate_Module_Image
                                                          (Source_Id)
                                                        and then Reaches;
                                                   else
                                                      Reaches := False;
                                                   end if;
                                                end;
                                             elsif Payload_Shape.Kind =
                                                Landin.Checking
                                                  .Fixed_Array_Field
                                               and then Syn.Kind
                                                 (Of_Tree, Given_Payload)
                                                   = Syn.Member_Selection
                                               and then Is_Module_Array_Field
                                                 (Of_Tree, Given_Payload,
                                                  Payload_Shape.Length,
                                                  Payload_Shape.Element)
                                             then
                                                Reaches :=
                                                  Validate_Module_Image
                                                    (Res.Bound_To
                                                       (Meanings.all,
                                                        Of_Tree,
                                                        Syn.Target_Of
                                                          (Of_Tree,
                                                           Given_Payload)))
                                                  and then Reaches;
                                             end if;
                                          end;
                                       end if;
                                    end;
                                 end loop;
                              end if;
                           end;
                     end case;
                  end;
               end if;
            end;
         end loop;
         return Reaches;
      end Validate_Recursive_Struct_Image;

      function Validate_Module_Image
        (Id : Res.Declaration_Id) return Boolean
      is
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Id));
         Node  : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Id);
         Value : constant Syn.Node_Id := Syn.Value_Of (Of_Tree.all, Node);
      begin
         case Image_States (Id) is
            when Valid =>
               return True;

            when Invalid =>
               return False;

            when Visiting =>
               --  Declaration order chooses the first root, and marking the
               --  entire path Invalid on the way out means this cycle earns
               --  one [1940] report rather than one report per member.
               Bad.Report
                 (Item    => Bad.Not_Known_At_Compile_Time,
                  Source  => Res.Source_Of (Meanings.all, Id),
                  Where   => Syn.Anchor (Of_Tree.all, Node),
                  Message => "the initial image of `"
                             & Spelled (Syn.Name (Of_Tree.all, Node))
                             & "` is worked out from itself",
                  Note    => "[1940]: a chain that comes back to where it"
                             & " began names nothing at all",
                  Into    => Found);
               Image_States (Id) := Invalid;
               return False;

            when Unseen =>
               null;
         end case;

         Image_States (Id) := Visiting;

         --  An omitted initializer is D10's zero image; D24 admits an array
         --  literal terminal image, while D27 and D59 spell array and struct
         --  zero images explicitly.
         --  Refused or mismatched initializer forms are left to their existing
         --  diagnostics rather than producing graph fallout.
         if Value = Syn.No_Node then
            Image_States (Id) := Valid;
            return True;
         end if;

         if Syn.Kind (Of_Tree.all, Value)
              in Syn.Array_Literal | Syn.Zeroed_Literal
         then
            Image_States (Id) := Valid;
            return True;
         end if;

         if Syn.Kind (Of_Tree.all, Value) = Syn.Struct_Literal then
            --  D69 follows a direct module array datum; D71 follows one
            --  directly selected field by way of its containing module
            --  struct.  Follow only well-shaped edges.  Every malformed
            --  label keeps Check_Struct_Literal's diagnostic owner, while
            --  the shared Visiting state owns every array/struct mixture that
            --  comes back to a declaration already on the image path.
            declare
               Wrote : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Nominal_Of (Types.all, Id);
               Reaches_Image : Boolean := True;
            begin
               if Wrote = Landin.Checking.No_Nominal_Type
                 or else not Landin.Checking.Has_Layout (Types.all, Wrote)
               then
                  Image_States (Id) := Invalid;
                  return False;
               end if;

               if Body_Image_Contains_Aggregate (Wrote) then
                  Reaches_Image := Validate_Recursive_Struct_Image
                    (Of_Tree.all, Wrote, Value);
                  Image_States (Id) :=
                    (if Reaches_Image then Valid else Invalid);
                  return Reaches_Image;
               end if;

               for Position in
                 1 .. Syn.Field_Value_Count (Of_Tree.all, Value)
               loop
                  declare
                     Field : constant Syn.Node_Id :=
                       Syn.Nth_Field_Value
                         (Of_Tree.all, Value, Position);
                     Image_Value : constant Syn.Node_Id :=
                       Syn.Value_Of (Of_Tree.all, Field);
                     Which : constant Natural :=
                       Field_At (Wrote, Syn.Name (Of_Tree.all, Field));
                  begin
                     if Which /= 0
                       and then Landin.Checking.Field_Kind_Of
                         (Types.all, Wrote, Which)
                           = Landin.Checking.Fixed_Array_Field
                       and then Syn.Kind (Of_Tree.all, Image_Value)
                                  = Syn.Name_Reference
                       and then Res.Verdict_Of
                         (Meanings.all, Of_Tree.all, Image_Value)
                           = Res.Bound
                     then
                        declare
                           Source_Id : constant Res.Declaration_Id :=
                             Res.Bound_To
                               (Meanings.all, Of_Tree.all, Image_Value);
                           Edge_Is_Valid : constant Boolean :=
                             Res.Sort_Of (Meanings.all, Source_Id)
                               = Res.Module_Binding
                             and then Landin.Checking.Type_Of
                               (Types.all, Source_Id) = Ty.Fixed_Array
                             and then Landin.Checking.Array_Length
                               (Types.all, Source_Id)
                                 = Landin.Checking.Field_Array_Length
                                     (Types.all, Wrote, Which)
                             and then Landin.Checking.Array_Element
                               (Types.all, Source_Id)
                                 = Landin.Checking.Field_Array_Element
                                     (Types.all, Wrote, Which);
                        begin
                           if Edge_Is_Valid then
                              Reaches_Image :=
                                Validate_Module_Image (Source_Id)
                                and then Reaches_Image;
                           else
                              Reaches_Image := False;
                           end if;
                        end;
                     elsif Which /= 0
                       and then Landin.Checking.Field_Kind_Of
                         (Types.all, Wrote, Which)
                           = Landin.Checking.Fixed_Array_Field
                       and then Syn.Kind (Of_Tree.all, Image_Value)
                                  = Syn.Member_Selection
                     then
                        declare
                           Source : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree.all, Image_Value);
                           Edge_Is_Valid : constant Boolean :=
                             Is_Module_Array_Field
                               (Of_Tree.all, Image_Value,
                                Landin.Checking.Field_Array_Length
                                  (Types.all, Wrote, Which),
                                Landin.Checking.Field_Array_Element
                                  (Types.all, Wrote, Which));
                        begin
                           if Edge_Is_Valid then
                              Reaches_Image :=
                                Validate_Module_Image
                                  (Res.Bound_To
                                     (Meanings.all, Of_Tree.all, Source))
                                and then Reaches_Image;
                           else
                              Reaches_Image := False;
                           end if;
                        end;
                     elsif Which /= 0
                       and then Landin.Checking.Field_Kind_Of
                         (Types.all, Wrote, Which)
                           = Landin.Checking.Variant_Field
                       and then Syn.Kind (Of_Tree.all, Image_Value)
                                  = Syn.Struct_Literal
                       and then Landin.Checking.Type_Of
                         (Types.all, Of_Tree.all, Image_Value)
                           /= Ty.Ill_Typed
                     then
                        declare
                           Body_Tree : constant not null access constant
                             Syn.Tree :=
                               Tree_For
                                 (Res.Source_Of
                                    (Meanings.all,
                                     Template_Declaration (Wrote)));
                           Body_Node : constant Syn.Node_Id :=
                             Syn.Declared_Type
                               (Body_Tree.all,
                                Res.Node_Of
                                  (Meanings.all,
                                   Template_Declaration (Wrote)));
                           Part : constant Syn.Node_Id :=
                             Syn.Nth_Field
                               (Body_Tree.all, Body_Node,
                                Positive (Which));
                           Nominal : constant Syn.Node_Id :=
                             Syn.Constructed_Type
                               (Of_Tree.all, Image_Value);
                           Means : constant Res.Declaration_Id :=
                             (if Nominal /= Syn.No_Node
                                and then Res.Verdict_Of
                                  (Meanings.all, Of_Tree.all, Nominal)
                                    = Res.Bound
                              then Res.Bound_To
                                (Meanings.all, Of_Tree.all, Nominal)
                              else Res.No_Declaration);
                           Selected : Natural := 0;
                        begin
                           if Means /= Res.No_Declaration
                             and then Res.Sort_Of (Meanings.all, Means)
                               = Res.Case_Name
                           then
                              for Candidate in
                                1 .. Syn.Case_Count (Body_Tree.all, Part)
                              loop
                                 if Res.Source_Of (Meanings.all, Means)
                                      = Syn.Source_Of (Body_Tree.all)
                                   and then Res.Node_Of (Meanings.all, Means)
                                     = Syn.Nth_Case
                                         (Body_Tree.all, Part, Candidate)
                                 then
                                    Selected := Candidate;
                                    exit;
                                 end if;
                              end loop;
                           end if;

                           if Selected /= 0 then
                              declare
                                 Case_Node : constant Syn.Node_Id :=
                                   Syn.Nth_Case
                                     (Body_Tree.all, Part, Selected);
                              begin
                                 for Payload_Position in
                                   1 .. Syn.Field_Value_Count
                                          (Of_Tree.all, Image_Value)
                                 loop
                                    declare
                                       Label : constant Syn.Node_Id :=
                                         Syn.Nth_Field_Value
                                           (Of_Tree.all, Image_Value,
                                            Payload_Position);
                                       Payload : Natural := 0;
                                       Given : constant Syn.Node_Id :=
                                         Syn.Value_Of (Of_Tree.all, Label);
                                    begin
                                       for Candidate in
                                         1 .. Syn.Payload_Field_Count
                                                (Body_Tree.all, Case_Node)
                                       loop
                                          if Syn.Name (Of_Tree.all, Label)
                                            = Syn.Name
                                                (Body_Tree.all,
                                                 Syn.Nth_Payload_Field
                                                   (Body_Tree.all,
                                                    Case_Node, Candidate))
                                          then
                                             Payload := Candidate;
                                             exit;
                                          end if;
                                       end loop;

                                       if Payload = 0 then
                                          Reaches_Image := False;
                                       else
                                          declare
                                             Shape : constant
                                               Landin.Checking.Field_Shape :=
                                                 Landin.Checking
                                                   .Nth_Variant_Case_Field
                                                   (Types.all, Wrote,
                                                    Positive (Which),
                                                    Positive (Selected),
                                                    Positive (Payload));
                                          begin
                                             if Shape.Kind =
                                                  Landin.Checking
                                                    .Fixed_Array_Field
                                               and then Syn.Kind
                                                 (Of_Tree.all, Given)
                                                   = Syn.Name_Reference
                                               and then Res.Verdict_Of
                                                 (Meanings.all, Of_Tree.all,
                                                  Given) = Res.Bound
                                             then
                                                declare
                                                   Source_Id : constant
                                                     Res.Declaration_Id :=
                                                       Res.Bound_To
                                                         (Meanings.all,
                                                          Of_Tree.all,
                                                          Given);
                                                   Edge_Is_Valid : constant
                                                     Boolean :=
                                                       Res.Sort_Of
                                                         (Meanings.all,
                                                          Source_Id)
                                                           = Res.Module_Binding
                                                       and then
                                                         Landin.Checking
                                                           .Type_Of
                                                           (Types.all,
                                                            Source_Id)
                                                           = Ty.Fixed_Array
                                                       and then
                                                         Landin.Checking
                                                           .Array_Length
                                                           (Types.all,
                                                            Source_Id)
                                                           = Shape.Length
                                                       and then
                                                         Landin.Checking
                                                           .Array_Element
                                                           (Types.all,
                                                            Source_Id)
                                                           = Shape.Element;
                                                begin
                                                   if Edge_Is_Valid then
                                                      Reaches_Image :=
                                                        Validate_Module_Image
                                                          (Source_Id)
                                                        and then
                                                          Reaches_Image;
                                                   else
                                                      Reaches_Image := False;
                                                   end if;
                                                end;
                                             elsif Shape.Kind =
                                                     Landin.Checking
                                                       .Fixed_Array_Field
                                               and then Syn.Kind
                                                 (Of_Tree.all, Given)
                                                   = Syn.Member_Selection
                                             then
                                                declare
                                                   Source : constant
                                                     Syn.Node_Id :=
                                                       Syn.Target_Of
                                                         (Of_Tree.all,
                                                          Given);
                                                   Edge_Is_Valid : constant
                                                     Boolean :=
                                                       Is_Module_Array_Field
                                                         (Of_Tree.all, Given,
                                                          Shape.Length,
                                                          Shape.Element);
                                                begin
                                                   if Edge_Is_Valid then
                                                      Reaches_Image :=
                                                        Validate_Module_Image
                                                          (Res.Bound_To
                                                             (Meanings.all,
                                                              Of_Tree.all,
                                                              Source))
                                                        and then
                                                          Reaches_Image;
                                                   else
                                                      Reaches_Image := False;
                                                   end if;
                                                end;
                                             end if;
                                          end;
                                       end if;
                                    end;
                                 end loop;
                              end;
                           else
                              Reaches_Image := False;
                           end if;
                        end;
                     end if;
                  end;
               end loop;

               Image_States (Id) :=
                 (if Reaches_Image then Valid else Invalid);
               return Reaches_Image;
            end;
         end if;

         if Syn.Kind (Of_Tree.all, Value) = Syn.Member_Selection then
            --  D70 adds the reverse static-image edge: an array datum may
            --  take one fixed-array field from a module struct.  Validation
            --  runs before the statement walk, so perform the same silent
            --  contextual admission here before following the containing
            --  declaration.  The later binding check still owns any D17
            --  disagreement.  A malformed or already refused edge is invalid
            --  silently because its contextual owner reports later.
            declare
               From : constant Syn.Node_Id :=
                 Syn.Target_Of (Of_Tree.all, Value);
               Edge_Is_Valid : constant Boolean :=
                 Landin.Checking.Type_Of (Types.all, Id) = Ty.Fixed_Array
                 and then Is_Module_Array_Field
                   (Of_Tree.all, Value,
                    Landin.Checking.Array_Length (Types.all, Id),
                    Landin.Checking.Array_Element (Types.all, Id));
               Reaches_Image : Boolean := False;
            begin
               if Edge_Is_Valid then
                  Reaches_Image :=
                    Validate_Module_Image
                      (Res.Bound_To (Meanings.all, Of_Tree.all, From));
               end if;

               Image_States (Id) :=
                 (if Reaches_Image then Valid else Invalid);
               return Reaches_Image;
            end;
         end if;

         if Syn.Kind (Of_Tree.all, Value) /= Syn.Name_Reference
           or else Res.Verdict_Of (Meanings.all, Of_Tree.all, Value)
                   /= Res.Bound
         then
            Image_States (Id) := Invalid;
            return False;
         end if;

         declare
            Source_Id : constant Res.Declaration_Id :=
              Res.Bound_To (Meanings.all, Of_Tree.all, Value);
            Reaches_Image : Boolean := False;
         begin
            if Res.Sort_Of (Meanings.all, Source_Id) = Res.Module_Binding
            then
               if Landin.Checking.Type_Of (Types.all, Id) = Ty.Fixed_Array
                 and then Landin.Checking.Type_Of (Types.all, Source_Id)
                          = Ty.Fixed_Array
                 and then Landin.Checking.Array_Length (Types.all, Source_Id)
                          = Landin.Checking.Array_Length (Types.all, Id)
                 and then Landin.Checking.Array_Element (Types.all, Source_Id)
                          = Landin.Checking.Array_Element (Types.all, Id)
               then
                  Reaches_Image := Validate_Module_Image (Source_Id);
               elsif Landin.Checking.Type_Of (Types.all, Id) = Ty.Aggregate
                 and then Landin.Checking.Type_Of (Types.all, Source_Id)
                          = Ty.Aggregate
                 and then Landin.Checking.Nominal_Of (Types.all, Source_Id)
                          = Landin.Checking.Nominal_Of (Types.all, Id)
               then
                  --  D60/D61 follow either D10/D59's absent zero image or
                  --  D66--D68's labelled folded image.  Following identities
                  --  still rejects a value chain that returns to itself.  A
                  --  body with no layout has already refused the compilation;
                  --  this graph walk adds no fallout for it.
                  Reaches_Image := Validate_Module_Image (Source_Id);
               end if;
            end if;

            Image_States (Id) :=
              (if Reaches_Image then Valid else Invalid);
            return Reaches_Image;
         end;
      end Validate_Module_Image;

      procedure Validate_Module_Images is
      begin
         for Id in Res.Declaration_Id'(1)
                   .. Res.Declaration_Id
                        (Res.Declaration_Count (Meanings.all))
         loop
            if Res.Sort_Of (Meanings.all, Id) = Res.Module_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                       in Ty.Fixed_Array | Ty.Aggregate
            then
               declare
                  Reaches_Image : constant Boolean :=
                    Validate_Module_Image (Id);
               begin
                  pragma Unreferenced (Reaches_Image);
               end;
            end if;
         end loop;
      end Validate_Module_Images;

      ------------------------------------------------------------
      --  [1940]: a module value is folded, because it cannot trap
      ------------------------------------------------------------

      --  [0300] says overflow traps, and inside a body it does.  A module
      --  value has no body to trap in: [1460] says nothing runs before the
      --  entry point, so `over: u8 = 200 + 100` has no moment at which to
      --  trap and no value to stand for it.  So it is folded here and
      --  refused if no type holds the answer.
      --
      --  Known is False when the fold met something it cannot evaluate --
      --  a name that resolved to nothing, a subtree already refused, a
      --  chain [1940] reported, or an impossible operand [1950] will report.
      --  Overflowed is distinct: it says the mathematical answer walked past
      --  Folded and Check_Module_Fold must report it before lowering.
      procedure Fold
        (Of_Tree    : Syn.Tree;
         Node       : Syn.Node_Id;
         Depth      : Natural;
         Value      : out Ty.Folded;
         Known      : out Boolean;
         Overflowed : out Boolean);

      --  Which module bindings this fold is standing inside.  [1940] says a
      --  chain that comes back to where it began names nothing at all, and
      --  the inference guard above catches only the chains that have a type
      --  to infer: `a: i32 = b + 1` beside `b: i32 = a + 1` writes both
      --  types down, so nothing is ever Underway and the cycle reached this
      --  walk unreported.  It was found by the backend meeting it, which is
      --  three stages too late for a rule the checker owns.
      Folding : array (Res.Declaration_Id'(1)
                       .. Res.Declaration_Id
                            (Res.Declaration_Count (Meanings.all)))
                  of Boolean := [others => False];

      procedure Fold
        (Of_Tree    : Syn.Tree;
         Node       : Syn.Node_Id;
         Depth      : Natural;
         Value      : out Ty.Folded;
         Known      : out Boolean;
         Overflowed : out Boolean)
      is
         --  Guarded rather than caught, which is the rule
         --  Landin.Types.Evaluate already keeps: a sum too wide is
         --  entirely in the bytes being looked at.  Overflow is a
         --  distinct outcome from "undecided": an impossible operand
         --  arrives with Known=False and Overflowed=False for [1950], while
         --  an Add whose sum walks past Folded arrives with Known=False and
         --  Overflowed=True.
         --  The two demand different diagnostics at Check_Module_Fold.
         --
         --  [0300]'s wrapping arithmetic answers at the target type's
         --  own width: `u8 = 255 +% 1` is 0, and every other unsigned or
         --  signed size wraps the same way.  So the checker asks the
         --  node its result type and applies pattern arithmetic exactly
         --  as the lowering and the backend's folder do -- one semantic
         --  source for the answer bytes, three fold walks that see it.
         type Pattern is mod 2 ** 64;

         function Mask
           (V : Pattern; Bits : Landin.Targets.Bit_Width) return Pattern
           is (if Bits >= 64 then V
               else V and (2 ** Natural (Bits) - 1));

         function Is_Neg_Pattern
           (V : Pattern; Bits : Landin.Targets.Bit_Width) return Boolean
           is ((V and 2 ** (Natural (Bits) - 1)) /= 0);

         function To_Pattern
           (V : Ty.Folded; Bits : Landin.Targets.Bit_Width) return Pattern
           is (if V < 0
               then Mask (0 - Pattern (-V), Bits)
               else Mask (Pattern (V), Bits));

         function As_Number
           (V : Pattern; Bits : Landin.Targets.Bit_Width;
            Signed : Boolean) return Ty.Folded
           is (if Signed and then Is_Neg_Pattern (V, Bits)
               then -Ty.Folded (Mask (0 - V, Bits))
               else Ty.Folded (V));

         function Fold_Width
           (Kind : Ty.Scalar_Name) return Landin.Targets.Bit_Width
           is (if Kind in Ty.Integer_Name
               then Ty.Width (Ty.Integer_Name (Kind), Facts)
               else 8);

         function Is_Signed_Type (Kind : Ty.Scalar_Name) return Boolean
           is (Kind in Ty.Integer_Name
               and then Ty.Is_Signed (Ty.Integer_Name (Kind)));

         --  The wrapping form of an [1820] operator turned into an
         --  answer at the argument's own width.  Wrapping never
         --  overflows Ty.Folded because the mask bounds every pattern
         --  before it is read back.
         procedure Wrap_Combine
           (Left, Right : Ty.Folded;
            Of_Kind     : Syn.Node_Kind;
            Bits        : Landin.Targets.Bit_Width;
            Signed      : Boolean;
            Answer      : out Ty.Folded);

         procedure Wrap_Combine
           (Left, Right : Ty.Folded;
            Of_Kind     : Syn.Node_Kind;
            Bits        : Landin.Targets.Bit_Width;
            Signed      : Boolean;
            Answer      : out Ty.Folded)
         is
            L : constant Pattern := To_Pattern (Left, Bits);
            R : constant Pattern := To_Pattern (Right, Bits);
         begin
            case Of_Kind is
               when Syn.Wrapping_Add =>
                  Answer := As_Number (Mask (L + R, Bits), Bits, Signed);
               when Syn.Wrapping_Subtract =>
                  Answer := As_Number (Mask (L - R, Bits), Bits, Signed);
               when Syn.Wrapping_Multiply =>
                  Answer := As_Number (Mask (L * R, Bits), Bits, Signed);
               when others =>
                  raise Landin.Compiler_Defect with
                    "Wrap_Combine reached with a non-wrapping opcode";
            end case;
         end Wrap_Combine;

         procedure Combine
           (Left, Right : Ty.Folded;
            Of_Kind     : Syn.Node_Kind;
            Answer      : out Ty.Folded;
            Fits        : out Boolean;
            Overflows   : out Boolean);

         procedure Combine
           (Left, Right : Ty.Folded;
            Of_Kind     : Syn.Node_Kind;
            Answer      : out Ty.Folded;
            Fits        : out Boolean;
            Overflows   : out Boolean) is
         begin
            Answer     := 0;
            Fits       := True;
            Overflows  := False;

            case Of_Kind is
               when Syn.Add =>
                  Fits := (if Right > 0
                           then Left <= Ty.Folded'Last - Right
                           else Left >= Ty.Folded'First - Right);
                  Overflows := not Fits;

               when Syn.Subtract =>
                  Fits := (if Right > 0
                           then Left >= Ty.Folded'First + Right
                           else Left <= Ty.Folded'Last + Right);
                  Overflows := not Fits;

               when Syn.Multiply =>
                  Fits := Left = 0
                          or else abs Right
                                  <= Ty.Folded'Last / abs Left;
                  Overflows := not Fits;

               when Syn.Divide | Syn.Remainder =>
                  --  Declining rather than dividing, because there is
                  --  nothing to divide by.  Check_Operands is what turns
                  --  this into a diagnostic: [1950] refuses a divisor the
                  --  compiler knows is zero, and at module level [1940]'s
                  --  whole fold is what knowing means.  Before that rule
                  --  existed the decline was silent, and `d: u32 = 7 / 0`
                  --  was accepted.  Divide-by-zero is not overflow --
                  --  [1950] owns it -- so Overflows stays False.
                  Fits := Right /= 0;

               when others =>
                  Fits := True;
            end case;

            if not Fits then
               return;
            end if;

            case Of_Kind is
               when Syn.Add =>
                  Answer := Left + Right;

               when Syn.Subtract =>
                  Answer := Left - Right;

               when Syn.Multiply =>
                  Answer := Left * Right;

               when Syn.Divide =>
                  Answer := Left / Right;

               when Syn.Remainder =>
                  Answer := Left rem Right;

               when others =>
                  --  Width-dependent operators are handled by their own
                  --  target-aware branch below rather than by this arithmetic
                  --  helper.
                  Fits := False;
            end case;
         end Combine;
      begin
         Value      := 0;
         Known      := False;
         Overflowed := False;

         if Node = Syn.No_Node then
            return;
         end if;

         if not Syn.Is_Sound (Of_Tree, Node) then
            return;
         end if;

         case Syn.Kind (Of_Tree, Node) is
            when Syn.Integer_Literal =>
               declare
                  Snap : constant Landin.Source.Snapshot :=
                    Source (Context, Syn.Source_Of (Of_Tree));
                  Text : constant String :=
                    Landin.Source.Slice
                      (Snap, Syn.Digit_Span (Of_Tree, Node));
                  Held        : Ty.Magnitude;
                  Overflow    : Boolean;
               begin
                  Ty.Evaluate
                    (Text, Syn.Base (Of_Tree, Node), Held, Overflow);

                  if not Overflow then
                     Value := Ty.Folded (Held);
                     Known := True;
                  else
                     Overflowed := True;
                  end if;
               end;

            when Syn.True_Literal =>
               Value := 1;
               Known := True;

            when Syn.False_Literal =>
               Value := 0;
               Known := True;

            when Syn.Negation =>
               declare
                  Under : Ty.Folded;
                  Under_Overflowed : Boolean;
               begin
                  Fold (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                        Depth + 1, Under, Known, Under_Overflowed);
                  Overflowed := Under_Overflowed;

                  if Known then
                     Value := -Under;
                  end if;
               end;

            when Syn.Name_Reference =>
               --  [1940]: a name bound to a module binding whose value is
               --  known is itself known.
               if Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
               then
                  declare
                     Means : constant Res.Declaration_Id :=
                       Res.Bound_To (Meanings.all, Of_Tree, Node);
                  begin
                     if Res.Sort_Of (Meanings.all, Means)
                        = Res.Module_Binding
                     then
                        declare
                           Their_Tree : constant
                             not null access constant Syn.Tree :=
                               Tree_For
                                 (Res.Source_Of (Meanings.all, Means));
                           Theirs : constant Syn.Node_Id :=
                             Res.Node_Of (Meanings.all, Means);
                           Their_Value : constant Syn.Node_Id :=
                             Syn.Value_Of (Their_Tree.all, Theirs);
                        begin
                           --  D10 gives an omitted module scalar its zero
                           --  image.  It is as compile-time-known here as it
                           --  is in lowering and in the backend.
                           if Their_Value = Syn.No_Node then
                              Value := 0;
                              Known := True;
                              return;
                           end if;

                           if Folding (Means) then
                              --  [1940]: the report names the declaration
                              --  the chain came back to, because that is
                              --  the one place in it the reader is
                              --  standing.
                              Bad.Report
                                (Item    =>
                                   Bad.Not_Known_At_Compile_Time,
                                 Source  =>
                                   Res.Source_Of (Meanings.all, Means),
                                 Where   =>
                                   Syn.Anchor (Their_Tree.all, Theirs),
                                 Message => "the value of `"
                                            & Spelled
                                                (Syn.Name
                                                   (Their_Tree.all,
                                                    Theirs))
                                            & "` is worked out from"
                                            & " itself",
                                 Note    => "[1940]: a chain that comes"
                                            & " back to where it began"
                                            & " names nothing at all",
                                 Into    => Found);
                              Known := False;
                              return;
                           end if;

                           Folding (Means) := True;
                           Fold
                             (Their_Tree.all, Their_Value, Depth + 1,
                              Value, Known, Overflowed);
                           Folding (Means) := False;
                        end;
                     end if;
                  end;
               end if;

            when Syn.Add | Syn.Subtract | Syn.Multiply | Syn.Divide
               | Syn.Remainder | Syn.Wrapping_Add | Syn.Wrapping_Subtract
               | Syn.Wrapping_Multiply =>
               declare
                  Op : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
                  Left, Right : Ty.Folded;
                  Left_Known, Right_Known : Boolean;
                  Left_Overflowed, Right_Overflowed : Boolean;
                  Fits, Overflows : Boolean;
                  Result_Type : constant Ty.Type_Kind :=
                    Landin.Checking.Type_Of (Types.all, Of_Tree, Node);
               begin
                  Fold (Of_Tree, Syn.Left_Of (Of_Tree, Node), Depth + 1,
                        Left, Left_Known, Left_Overflowed);
                  Fold (Of_Tree, Syn.Right_Of (Of_Tree, Node), Depth + 1,
                        Right, Right_Known, Right_Overflowed);

                  --  An overflow in either operand still counts as an
                  --  overflow of the enclosing fold: the answer cannot be
                  --  produced without walking through the overflowing
                  --  subtree.  Report once at the outermost place a
                  --  caller decides to speak, which is Check_Module_Fold.
                  if Left_Overflowed or else Right_Overflowed then
                     Overflowed := True;
                  elsif Left_Known and then Right_Known then
                     if Op in Syn.Wrapping_Add | Syn.Wrapping_Subtract
                                | Syn.Wrapping_Multiply
                       and then Result_Type in Ty.Integer_Name
                     then
                        --  [0300]: wrapping arithmetic answers at the
                        --  operand type's own width, so 255 +% 1 on u8
                        --  is 0 and every unsigned or signed size wraps
                        --  the same way.  The pattern helpers keep the
                        --  answer inside the type's range.
                        Wrap_Combine
                          (Left, Right, Op,
                           Ty.Width
                             (Ty.Integer_Name (Result_Type), Facts),
                           Ty.Is_Signed (Ty.Integer_Name (Result_Type)),
                           Value);
                        Known := True;
                     else
                        Combine (Left, Right, Op, Value, Fits, Overflows);
                        Known := Fits;
                        Overflowed := Overflows;
                     end if;
                  end if;
               end;

            when Syn.Bitwise_And | Syn.Bitwise_Xor | Syn.Bitwise_Or
               | Syn.Shift_Left | Syn.Shift_Right =>
               declare
                  Op : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
                  Left, Right : Ty.Folded;
                  Left_Known, Right_Known : Boolean;
                  Left_Overflowed, Right_Overflowed : Boolean;
                  Kind : constant Ty.Type_Kind :=
                    Landin.Checking.Type_Of (Types.all, Of_Tree, Node);
               begin
                  Fold (Of_Tree, Syn.Left_Of (Of_Tree, Node), Depth + 1,
                        Left, Left_Known, Left_Overflowed);
                  Fold (Of_Tree, Syn.Right_Of (Of_Tree, Node), Depth + 1,
                        Right, Right_Known, Right_Overflowed);

                  if Left_Overflowed or else Right_Overflowed then
                     Overflowed := True;
                  elsif Left_Known and then Right_Known
                    and then Right >= 0
                    and then Kind in Ty.Scalar_Name
                  then
                     declare
                        Bits : constant Landin.Targets.Bit_Width :=
                          Fold_Width (Ty.Scalar_Name (Kind));
                        Signed : constant Boolean :=
                          Is_Signed_Type (Ty.Scalar_Name (Kind));
                        LP : constant Pattern := To_Pattern (Left, Bits);
                        RP : constant Pattern := To_Pattern (Right, Bits);
                        Answer : Pattern := 0;
                        Exhausted : constant Boolean :=
                          Op in Syn.Shift_Left | Syn.Shift_Right
                            and then Right >= Ty.Folded (Bits);
                     begin
                        case Op is
                           when Syn.Bitwise_And =>
                              Answer := Mask (LP and RP, Bits);
                           when Syn.Bitwise_Xor =>
                              Answer := Mask (LP xor RP, Bits);
                           when Syn.Bitwise_Or =>
                              Answer := Mask (LP or RP, Bits);
                           when Syn.Shift_Left =>
                              Answer :=
                                (if Exhausted then 0
                                 else Mask
                                        (LP * 2 ** Natural (Right), Bits));
                           when Syn.Shift_Right =>
                              Answer :=
                                (if Exhausted then 0
                                 elsif Signed and then Left < 0
                                 then Mask
                                        (not
                                           (Mask (not LP, Bits)
                                            / 2 ** Natural (Right)),
                                         Bits)
                                 else Mask
                                        (LP / 2 ** Natural (Right), Bits));
                           when others =>
                              raise Landin.Compiler_Defect with
                                "unreachable width-op fold";
                        end case;
                        Value := As_Number (Answer, Bits, Signed);
                        Known := True;
                     end;
                  end if;
               end;

            when Syn.Complement =>
               declare
                  Under : Ty.Folded;
                  Under_Known, Under_Overflowed : Boolean;
                  Kind : constant Ty.Type_Kind :=
                    Landin.Checking.Type_Of (Types.all, Of_Tree, Node);
               begin
                  Fold (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Depth + 1,
                        Under, Under_Known, Under_Overflowed);
                  if Under_Overflowed then
                     Overflowed := True;
                  elsif Under_Known and then Kind in Ty.Scalar_Name then
                     declare
                        Bits : constant Landin.Targets.Bit_Width :=
                          Fold_Width (Ty.Scalar_Name (Kind));
                        Signed : constant Boolean :=
                          Is_Signed_Type (Ty.Scalar_Name (Kind));
                     begin
                        Value :=
                          As_Number
                            (Mask (not To_Pattern (Under, Bits), Bits),
                             Bits, Signed);
                        Known := True;
                     end;
                  end if;
               end;

            when Syn.Logical_Not =>
               declare
                  Under : Ty.Folded;
                  Under_Known, Under_Overflowed : Boolean;
               begin
                  Fold (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Depth + 1,
                        Under, Under_Known, Under_Overflowed);
                  Overflowed := Under_Overflowed;
                  if Under_Known then
                     Value := 1 - Under;
                     Known := True;
                  end if;
               end;

            when Syn.Logical_And | Syn.Logical_Or =>
               declare
                  Op : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
                  Left, Right : Ty.Folded;
                  Left_Known, Right_Known : Boolean;
                  Left_Overflowed, Right_Overflowed : Boolean;
               begin
                  Fold (Of_Tree, Syn.Left_Of (Of_Tree, Node), Depth + 1,
                        Left, Left_Known, Left_Overflowed);
                  if Left_Overflowed then
                     Overflowed := True;
                  elsif Left_Known
                    and then ((Op = Syn.Logical_And and then Left = 0)
                              or else
                                (Op = Syn.Logical_Or and then Left = 1))
                  then
                     Value := Left;
                     Known := True;
                  elsif Left_Known then
                     Fold (Of_Tree, Syn.Right_Of (Of_Tree, Node), Depth + 1,
                           Right, Right_Known, Right_Overflowed);
                     Overflowed := Right_Overflowed;
                     if Right_Known then
                        Value := Right;
                        Known := True;
                     end if;
                  end if;
               end;

            when Syn.Equal_To | Syn.Not_Equal_To
               | Syn.Less_Than | Syn.Less_Or_Equal
               | Syn.Greater_Than | Syn.Greater_Or_Equal =>
               declare
                  Op : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
                  Left, Right : Ty.Folded;
                  Left_Known, Right_Known : Boolean;
                  Left_Overflowed, Right_Overflowed : Boolean;
               begin
                  Fold (Of_Tree, Syn.Left_Of (Of_Tree, Node), Depth + 1,
                        Left, Left_Known, Left_Overflowed);
                  Fold (Of_Tree, Syn.Right_Of (Of_Tree, Node), Depth + 1,
                        Right, Right_Known, Right_Overflowed);
                  if Left_Overflowed or else Right_Overflowed then
                     Overflowed := True;
                  elsif Left_Known and then Right_Known then
                     Value :=
                       (case Op is
                           when Syn.Equal_To =>
                             (if Left = Right then 1 else 0),
                           when Syn.Not_Equal_To =>
                             (if Left /= Right then 1 else 0),
                           when Syn.Less_Than =>
                             (if Left < Right then 1 else 0),
                           when Syn.Less_Or_Equal =>
                             (if Left <= Right then 1 else 0),
                           when Syn.Greater_Than =>
                             (if Left > Right then 1 else 0),
                           when others =>
                             (if Left >= Right then 1 else 0));
                     Known := True;
                  end if;
               end;

            when Syn.Size_Of | Syn.Align_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Measured_Type (Of_Tree, Node);
                  Held : constant Ty.Type_Kind :=
                    Landin.Checking.Type_Of (Types.all, Of_Tree, Asked);
               begin
                  if Held in Ty.Scalar_Name then
                     declare
                        Size : constant Landin.Targets.Scalar_Size :=
                          Ty.Storage_Size (Ty.Scalar_Name (Held), Facts);
                     begin
                        Value :=
                          (if Syn.Kind (Of_Tree, Node) = Syn.Size_Of
                           then Ty.Folded (Landin.Targets.Bytes (Size))
                           else Ty.Folded
                                  (Landin.Targets.Alignment_Of
                                     (Facts, Size)));
                        Known := True;
                     end;
                  elsif Held = Ty.Fixed_Array then
                     declare
                        Length : constant Landin.Checking.Element_Count :=
                          Landin.Checking.Array_Length
                            (Types.all, Of_Tree, Asked);
                        Element : constant Ty.Scalar_Name :=
                          Landin.Checking.Array_Element
                            (Types.all, Of_Tree, Asked);
                        Size : constant Landin.Targets.Scalar_Size :=
                          Ty.Storage_Size (Element, Facts);
                     begin
                        Value :=
                          (if Syn.Kind (Of_Tree, Node) = Syn.Align_Of
                           then (if Length = 0 then 1
                                 else Ty.Folded
                                        (Landin.Targets.Alignment_Of
                                           (Facts, Size)))
                           else Ty.Folded
                                  (Landin.Targets.Byte_Count (Length)
                                   * Landin.Targets.Byte_Count
                                       (Landin.Targets.Bytes (Size))));
                        Known := True;
                     end;
                  elsif Held = Ty.Aggregate then
                     declare
                        Declared : constant Landin.Checking.Nominal_Type_Id :=
                          Landin.Checking.Nominal_Of
                            (Types.all, Of_Tree, Asked);
                     begin
                        if Declared /= Landin.Checking.No_Nominal_Type
                          and then Landin.Checking.Has_Layout
                            (Types.all, Declared)
                        then
                           Value :=
                             Ty.Folded
                               (if Syn.Kind (Of_Tree, Node) = Syn.Size_Of
                                then Landin.Checking.Layout_Size
                                       (Types.all, Declared)
                                else Landin.Checking.Layout_Alignment
                                       (Types.all, Declared));
                           Known := True;
                        end if;
                     end;
                  end if;
               end;

            when Syn.Len_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Operand_Of (Of_Tree, Node);
               begin
                  if Syn.Kind (Of_Tree, Asked) = Syn.Array_Literal then
                     Value := Ty.Folded (Syn.Element_Count (Of_Tree, Asked));
                     Known := True;
                  elsif Syn.Kind (Of_Tree, Asked) = Syn.Name_Reference
                    and then Res.Verdict_Of (Meanings.all, Of_Tree, Asked)
                             = Res.Bound
                  then
                     declare
                        Named : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, Asked);
                     begin
                        if Landin.Checking.Type_Of (Types.all, Named)
                             = Ty.Fixed_Array
                        then
                           Value :=
                             Ty.Folded
                               (Landin.Checking.Array_Length
                                  (Types.all, Named));
                           Known := True;
                        end if;
                     end;
                  end if;
               end;

            when others =>
               null;
         end case;
      end Fold;

      --  [1940]'s refusal, applied to one module binding.
      procedure Check_Module_Fold
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

      procedure Check_Module_Fold
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Value      : constant Syn.Node_Id := Syn.Value_Of (Of_Tree, Node);
         Wanted     : Ty.Type_Kind;
         Held       : Ty.Folded;
         Known      : Boolean;
         Overflowed : Boolean;

         procedure Check_Image_Scalar
           (Each : Syn.Node_Id; Element : Ty.Scalar_Name);

         procedure Check_Array_Image
           (Given : Syn.Node_Id; Element : Ty.Scalar_Name);

         procedure Check_Struct_Image
           (Literal : Syn.Node_Id; Wrote : Landin.Checking.Nominal_Type_Id);

         procedure Check_Variant_Image
           (Value : Syn.Node_Id;
            Wrote : Landin.Checking.Nominal_Type_Id;
            Field : Positive);

         function Body_Contains_Aggregate
           (Wrote : Landin.Checking.Nominal_Type_Id) return Boolean;

         procedure Check_Image_Scalar
           (Each : Syn.Node_Id; Element : Ty.Scalar_Name)
         is
            Element_Held      : Ty.Folded;
            Element_Known     : Boolean;
            Element_Overflowed : Boolean;
         begin
            --  A literal on its own was already checked by Require's
            --  Commit_To; skip it to keep the report from doubling.  A subtree
            --  the checker already refused likewise carries its own report.
            if not
                 (Syn.Kind (Of_Tree, Each) = Syn.Integer_Literal
                  or else
                    (Syn.Kind (Of_Tree, Each) = Syn.Negation
                     and then Syn.Kind
                       (Of_Tree, Syn.Operand_Of (Of_Tree, Each))
                         = Syn.Integer_Literal))
              and then Landin.Checking.Type_Of
                         (Types.all, Of_Tree, Each) /= Ty.Ill_Typed
            then
               Fold (Of_Tree, Each, 0, Element_Held,
                     Element_Known, Element_Overflowed);

               if Element_Overflowed then
                  Bad.Report
                    (Item    => Bad.Literal_Out_Of_Range,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Each),
                     Message => "this image value's fold overflows the widest"
                                & " value the compiler holds",
                     Note    => "[1940]: a module value has no moment in"
                                & " which to trap, so a fold whose result"
                                & " walks past the compiler's widest kernel"
                                & " value is refused",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Each);
               elsif Element_Known
                 and then not Ty.Holds (Element_Held, Element, Facts)
               then
                  Bad.Report
                    (Item    => Bad.Literal_Out_Of_Range,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Each),
                     Message => "this image value works out to "
                                & Written (Element_Held) & ", and no "
                                & Shown (Element) & " holds it",
                     Note    => "D24/D34/D35/D66/D132: every module image"
                                & " value has to fit its contextual scalar"
                                & " type",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Each);
               end if;
            end if;
         end Check_Image_Scalar;

         procedure Check_Array_Image
           (Given : Syn.Node_Id; Element : Ty.Scalar_Name)
         is
         begin
            if Element not in Ty.Integer_Name then
               return;
            elsif Syn.Kind (Of_Tree, Given) = Syn.Array_Repetition then
               Check_Image_Scalar
                 (Syn.Repeated_Element (Of_Tree, Given), Element);
            elsif Syn.Kind (Of_Tree, Given)
                    in Syn.Array_Literal | Syn.Mixed_Array_Repetition
            then
               for Position in 1 .. Syn.Element_Count (Of_Tree, Given) loop
                  Check_Image_Scalar
                    (Syn.Nth_Element (Of_Tree, Given, Position), Element);
               end loop;
               if Syn.Kind (Of_Tree, Given)
                    = Syn.Mixed_Array_Repetition
               then
                  Check_Image_Scalar
                    (Syn.Repeated_Element (Of_Tree, Given), Element);
               end if;
            end if;
         end Check_Array_Image;

         procedure Check_Variant_Image
           (Value : Syn.Node_Id;
            Wrote : Landin.Checking.Nominal_Type_Id;
            Field : Positive)
         is
         begin
            if Syn.Kind (Of_Tree, Value) /= Syn.Struct_Literal then
               return;
            end if;

            declare
               Selected : constant Positive := Positive
                 (Landin.Checking.Field_Index (Types.all, Of_Tree, Value));
            begin
               for Position in
                 1 .. Syn.Field_Value_Count (Of_Tree, Value)
               loop
                  declare
                     Label : constant Syn.Node_Id :=
                       Syn.Nth_Field_Value (Of_Tree, Value, Position);
                     Payload : constant Positive := Positive
                       (Landin.Checking.Field_Index
                          (Types.all, Of_Tree, Label));
                     Given : constant Syn.Node_Id :=
                       Syn.Value_Of (Of_Tree, Label);
                     Shape : constant Landin.Checking.Field_Shape :=
                       Landin.Checking.Nth_Variant_Case_Field
                         (Types.all, Wrote, Field, Selected, Payload);
                  begin
                     case Shape.Kind is
                        when Landin.Checking.Scalar_Field =>
                           if Shape.Element in Ty.Integer_Name then
                              Check_Image_Scalar (Given, Shape.Element);
                           end if;
                        when Landin.Checking.Fixed_Array_Field =>
                           Check_Array_Image (Given, Shape.Element);
                        when Landin.Checking.Aggregate_Field =>
                           if Syn.Kind (Of_Tree, Given)
                                = Syn.Struct_Literal
                           then
                              Check_Struct_Image
                                (Given, Shape.Nominal);
                           end if;
                        when Landin.Checking.Variant_Field =>
                           raise Landin.Compiler_Defect with
                             "a nested variant payload reached image folding";
                     end case;
                  end;
               end loop;
            end;
         end Check_Variant_Image;

         procedure Check_Struct_Image
           (Literal : Syn.Node_Id; Wrote : Landin.Checking.Nominal_Type_Id)
         is
         begin
            for Position in
              1 .. Syn.Field_Value_Count (Of_Tree, Literal)
            loop
               declare
                  Field : constant Syn.Node_Id :=
                    Syn.Nth_Field_Value (Of_Tree, Literal, Position);
                  Which : constant Positive := Positive
                    (Landin.Checking.Field_Index
                       (Types.all, Of_Tree, Field));
                  Given : constant Syn.Node_Id :=
                    Syn.Value_Of (Of_Tree, Field);
                  Shape : constant Landin.Checking.Field_Shape :=
                    Landin.Checking.Field_Shape_Of
                      (Types.all, Wrote, Which);
               begin
                  case Shape.Kind is
                     when Landin.Checking.Scalar_Field =>
                        if Shape.Element in Ty.Integer_Name then
                           Check_Image_Scalar (Given, Shape.Element);
                        end if;
                     when Landin.Checking.Fixed_Array_Field =>
                        Check_Array_Image (Given, Shape.Element);
                     when Landin.Checking.Aggregate_Field =>
                        if Syn.Kind (Of_Tree, Given) = Syn.Struct_Literal then
                           Check_Struct_Image
                             (Given, Shape.Nominal);
                        end if;
                     when Landin.Checking.Variant_Field =>
                        Check_Variant_Image (Given, Wrote, Which);
                  end case;
               end;
            end loop;
         end Check_Struct_Image;

         function Body_Contains_Aggregate
           (Wrote : Landin.Checking.Nominal_Type_Id) return Boolean
         is
         begin
            for Field in
              1 .. Landin.Checking.Layout_Field_Count (Types.all, Wrote)
            loop
               declare
                  Shape : constant Landin.Checking.Field_Shape :=
                    Landin.Checking.Field_Shape_Of
                      (Types.all, Wrote, Field);
               begin
                  if Shape.Kind = Landin.Checking.Aggregate_Field then
                     return True;
                  elsif Shape.Kind = Landin.Checking.Variant_Field then
                     for Variant_Case in 1 .. Shape.Cases loop
                        for Payload in
                          1 .. Landin.Checking.Variant_Case_Field_Count
                                 (Types.all, Wrote, Field, Variant_Case)
                        loop
                           if Landin.Checking.Nth_Variant_Case_Field
                             (Types.all, Wrote, Field, Variant_Case,
                              Payload).Kind
                                = Landin.Checking.Aggregate_Field
                           then
                              return True;
                           end if;
                        end loop;
                     end loop;
                  end if;
               end;
            end loop;
            return False;
         end Body_Contains_Aggregate;
      begin
         if Value = Syn.No_Node then
            return;
         end if;

         Wanted := Declared_As_Node (Of_Tree, Node);

         --  [0050]'s inferred form has no declared type, so [0200]'s
         --  default is what the fold has to fit.
         if Wanted = Ty.Undecided then
            Wanted := Landin.Checking.Type_Of
                        (Types.all, Of_Tree, Value);
         end if;

         --  D24/D26 fold every module array literal element.  D34/D35 fold
         --  one repetition pattern; D38 folds every finite prefix expression
         --  and its one suffix pattern through the same target-aware boundary.
         --  The contextual shape checks have already run.
         if Wanted = Ty.Fixed_Array
           and then Syn.Kind (Of_Tree, Value)
                    in Syn.Array_Literal | Syn.Array_Repetition
                       | Syn.Mixed_Array_Repetition
         then
            declare
               Element : constant Ty.Scalar_Name :=
                 Landin.Checking.Array_Element
                   (Types.all, Of_Tree, Value);
            begin
               if Element in Ty.Integer_Name then
                  if Syn.Kind (Of_Tree, Value) = Syn.Array_Repetition then
                     Check_Image_Scalar
                       (Syn.Repeated_Element (Of_Tree, Value), Element);
                  else
                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Value)
                     loop
                        Check_Image_Scalar
                          (Syn.Nth_Element (Of_Tree, Value, Position),
                           Element);
                     end loop;
                     if Syn.Kind (Of_Tree, Value)
                          = Syn.Mixed_Array_Repetition
                     then
                        Check_Image_Scalar
                          (Syn.Repeated_Element (Of_Tree, Value), Element);
                     end if;
                  end if;
               end if;
            end;
            return;
         end if;

         --  D66 folds each written scalar field independently in the
         --  labelled literal's nominal context.  D67 applies the same D24
         --  fold and range owner to every finite array-field element.  Labels
         --  map to layout order through Note_Field/Field_Index.
         if Wanted = Ty.Aggregate
           and then Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal
           and then Landin.Checking.Type_Of (Types.all, Of_Tree, Value)
                    = Ty.Aggregate
         then
            declare
               Wrote : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Nominal_Of (Types.all, Of_Tree, Value);
            begin
               if Body_Contains_Aggregate (Wrote) then
                  Check_Struct_Image (Value, Wrote);
                  return;
               end if;

               for Position in
                 1 .. Syn.Field_Value_Count (Of_Tree, Value)
               loop
                  declare
                     Field : constant Syn.Node_Id :=
                       Syn.Nth_Field_Value (Of_Tree, Value, Position);
                     Which : constant Positive :=
                       Landin.Checking.Field_Index
                         (Types.all, Of_Tree, Field);
                     Image_Value : constant Syn.Node_Id :=
                       Syn.Value_Of (Of_Tree, Field);
                  begin
                     case Landin.Checking.Field_Kind_Of
                       (Types.all, Wrote, Which)
                     is
                        when Landin.Checking.Scalar_Field =>
                           declare
                              Element : constant Ty.Scalar_Name :=
                                Landin.Checking.Field_Type
                                  (Types.all, Wrote, Which);
                           begin
                              if Element in Ty.Integer_Name then
                                 Check_Image_Scalar (Image_Value, Element);
                              end if;
                           end;

                        when Landin.Checking.Fixed_Array_Field =>
                           if Syn.Kind (Of_Tree, Image_Value)
                                in Syn.Array_Literal
                                   | Syn.Array_Repetition
                                   | Syn.Mixed_Array_Repetition
                           then
                              declare
                                 Element : constant Ty.Scalar_Name :=
                                   Landin.Checking.Field_Array_Element
                                     (Types.all, Wrote, Which);
                              begin
                                 if Element in Ty.Integer_Name then
                                    if Syn.Kind (Of_Tree, Image_Value)
                                         = Syn.Array_Repetition
                                    then
                                       Check_Image_Scalar
                                         (Syn.Repeated_Element
                                            (Of_Tree, Image_Value),
                                          Element);
                                    else
                                       for Each in
                                         1 .. Syn.Element_Count
                                                (Of_Tree, Image_Value)
                                       loop
                                          Check_Image_Scalar
                                            (Syn.Nth_Element
                                               (Of_Tree, Image_Value, Each),
                                             Element);
                                       end loop;

                                       if Syn.Kind (Of_Tree, Image_Value)
                                            = Syn.Mixed_Array_Repetition
                                       then
                                          Check_Image_Scalar
                                            (Syn.Repeated_Element
                                               (Of_Tree, Image_Value),
                                             Element);
                                       end if;
                                    end if;
                                 end if;
                              end;
                           end if;

                        when Landin.Checking.Aggregate_Field =>
                           raise Landin.Compiler_Defect with
                             "a nested aggregate image reached checking";

                        when Landin.Checking.Variant_Field =>
                           declare
                              Selected : constant Positive :=
                                Positive
                                  (Landin.Checking.Field_Index
                                     (Types.all, Of_Tree, Image_Value));
                           begin
                              if Syn.Kind (Of_Tree, Image_Value)
                                   = Syn.Struct_Literal
                              then
                                 for Each in
                                   1 .. Syn.Field_Value_Count
                                          (Of_Tree, Image_Value)
                                 loop
                                    declare
                                       Label : constant Syn.Node_Id :=
                                         Syn.Nth_Field_Value
                                           (Of_Tree, Image_Value, Each);
                                       Payload : constant Positive :=
                                         Positive
                                           (Landin.Checking.Field_Index
                                              (Types.all, Of_Tree, Label));
                                       Shape : constant
                                         Landin.Checking.Field_Shape :=
                                           Landin.Checking
                                             .Nth_Variant_Case_Field
                                               (Types.all, Wrote, Which,
                                                Selected, Payload);
                                    begin
                                       if Shape.Kind =
                                            Landin.Checking.Scalar_Field
                                         and then Shape.Element
                                           in Ty.Integer_Name
                                       then
                                          Check_Image_Scalar
                                            (Syn.Value_Of (Of_Tree, Label),
                                             Shape.Element);
                                       elsif Shape.Kind =
                                         Landin.Checking.Fixed_Array_Field
                                         and then Shape.Element
                                           in Ty.Integer_Name
                                       then
                                          declare
                                             Given : constant Syn.Node_Id :=
                                               Syn.Value_Of
                                                 (Of_Tree, Label);
                                          begin
                                             if Syn.Kind (Of_Tree, Given)
                                                  = Syn.Array_Repetition
                                             then
                                                Check_Image_Scalar
                                                  (Syn.Repeated_Element
                                                     (Of_Tree, Given),
                                                   Shape.Element);
                                             elsif Syn.Kind (Of_Tree, Given)
                                               in Syn.Array_Literal
                                                  | Syn
                                                    .Mixed_Array_Repetition
                                             then
                                                for Position in
                                                  1 .. Syn.Element_Count
                                                         (Of_Tree, Given)
                                                loop
                                                   Check_Image_Scalar
                                                     (Syn.Nth_Element
                                                        (Of_Tree, Given,
                                                         Position),
                                                      Shape.Element);
                                                end loop;

                                                if Syn.Kind (Of_Tree, Given)
                                                     = Syn
                                                       .Mixed_Array_Repetition
                                                then
                                                   Check_Image_Scalar
                                                     (Syn.Repeated_Element
                                                        (Of_Tree, Given),
                                                      Shape.Element);
                                                end if;
                                             end if;
                                          end;
                                       end if;
                                    end;
                                 end loop;
                              end if;
                           end;
                     end case;
                  end;
               end loop;
            end;
            return;
         end if;

         if Wanted not in Ty.Integer_Name then
            return;
         end if;

         Fold (Of_Tree, Value, 0, Held, Known, Overflowed);

         --  A literal on its own is already checked where its context gave
         --  it a type, so this only speaks about a fold the checker has
         --  not otherwise seen.
         if Syn.Kind (Of_Tree, Value) = Syn.Integer_Literal
           or else
             (Syn.Kind (Of_Tree, Value) = Syn.Negation
              and then Syn.Kind
                (Of_Tree, Syn.Operand_Of (Of_Tree, Value))
                  = Syn.Integer_Literal)
         then
            return;
         end if;

         if Overflowed then
            Bad.Report
              (Item    => Bad.Literal_Out_Of_Range,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Value),
               Message => "this fold overflows the widest value the"
                          & " compiler holds",
               Note    => "[1940]: a module value has no moment in which"
                          & " to trap, so a fold whose result walks past"
                          & " the compiler's widest kernel value is refused",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Value);
         elsif Known and then not Ty.Holds (Held, Wanted, Facts) then
            Bad.Report
              (Item    => Bad.Literal_Out_Of_Range,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Value),
               Message => "this works out to " & Written (Held)
                          & ", and no " & Shown (Wanted) & " holds it",
               Note    => "[1940]: a module value has no moment in which"
                          & " to trap, so a fold no type holds is refused",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Value);
         end if;
      end Check_Module_Fold;

      ------------------------------------------------------------
      --  [1950]: an operand the operation cannot take
      ------------------------------------------------------------

      --  What [1880] calls known inside a body: a literal, or a unary
      --  minus over one, and nothing else.  Deliberately not Fold, which
      --  is [1940]'s and reaches through a module binding.  [1950] says
      --  the two knowns are different on purpose, and the difference is
      --  what keeps a program's legality still while an implementation
      --  gets better at folding -- D7's objection, asked about a value
      --  rather than about a condition.
      procedure Known_Literal
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Value   : out Ty.Folded;
         Known   : out Boolean);

      procedure Known_Literal
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Value   : out Ty.Folded;
         Known   : out Boolean) is
      begin
         Value := 0;
         Known := False;

         if Node = Syn.No_Node
           or else not Syn.Is_Sound (Of_Tree, Node)
         then
            return;
         end if;

         case Syn.Kind (Of_Tree, Node) is
            when Syn.Integer_Literal =>
               declare
                  Snap : constant Landin.Source.Snapshot :=
                    Source (Context, Syn.Source_Of (Of_Tree));
                  Text : constant String :=
                    Landin.Source.Slice
                      (Snap, Syn.Digit_Span (Of_Tree, Node));
                  Held       : Ty.Magnitude;
                  Overflowed : Boolean;
               begin
                  Ty.Evaluate
                    (Text, Syn.Base (Of_Tree, Node), Held, Overflowed);

                  if not Overflowed then
                     Value := Ty.Folded (Held);
                     Known := True;
                  end if;
               end;

            when Syn.Negation =>
               declare
                  Under : Ty.Folded;
               begin
                  Known_Literal
                    (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                     Under, Known);

                  if Known then
                     Value := -Under;
                  end if;
               end;

            when others =>
               null;
         end case;
      end Known_Literal;

      --  Whether [1880] or anything before it has already refused any part
      --  of this operand.  Recursive rather than a look at the root: a
      --  literal out of range is refused where the literal is, and a unary
      --  minus over it keeps the type it correctly had.
      function Refused_Already
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Refused_Already
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean is
      begin
         if Node = Syn.No_Node
           or else not Syn.Is_Sound (Of_Tree, Node)
         then
            return True;
         end if;

         if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
            = Ty.Ill_Typed
         then
            return True;
         end if;

         for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            if Refused_Already
                 (Of_Tree, Syn.Slot (Of_Tree, Node, Position))
            then
               return True;
            end if;
         end loop;

         return False;
      end Refused_Already;

      --  The walk.  Whole_Fold picks which paragraph decides what known
      --  means -- [1940]'s fold for a module value, [1880]'s literal
      --  inside a body -- and nothing else about the two differs.
      procedure Check_Operands
        (Of_Tree    : Syn.Tree;
         Node       : Syn.Node_Id;
         Whole_Fold : Boolean)
      is
         Amount : Ty.Folded;
         Known  : Boolean;
      begin
         if Node = Syn.No_Node
           or else not Syn.Is_Sound (Of_Tree, Node)
         then
            return;
         end if;

         for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            Check_Operands
              (Of_Tree, Syn.Slot (Of_Tree, Node, Position), Whole_Fold);
         end loop;

         if Syn.Kind (Of_Tree, Node) not in
              Syn.Divide | Syn.Remainder | Syn.Shift_Left | Syn.Shift_Right
         then
            return;
         end if;

         declare
            Right : constant Syn.Node_Id := Syn.Right_Of (Of_Tree, Node);
         begin
            if Right = Syn.No_Node
              or else not Syn.Is_Sound (Of_Tree, Right)
            then
               return;
            end if;

            --  Already refused, and one mistake earns one diagnostic.
            --  `x: u8` shifted by -1 is [1880]'s refusal of a literal no
            --  u8 holds, and saying so twice would name two faults where
            --  a reader made one.  The whole operand and not its root:
            --  [1880] refuses the literal inside the unary minus, so the
            --  minus above it is still holding a settled type.
            if Refused_Already (Of_Tree, Right) then
               return;
            end if;

            if Whole_Fold then
               declare
                  Ignored_Overflow : Boolean;
               begin
                  Fold (Of_Tree, Right, 0, Amount, Known, Ignored_Overflow);
                  --  Check_Module_Fold has already reported an overflowing
                  --  divisor or shift amount; nothing further to say here.
                  if Ignored_Overflow then
                     Known := False;
                  end if;
               end;
            else
               Known_Literal (Of_Tree, Right, Amount, Known);
            end if;

            if not Known then
               return;
            end if;

            case Syn.Kind (Of_Tree, Node) is
               when Syn.Divide | Syn.Remainder =>
                  if Amount /= 0 then
                     return;
                  end if;

                  Bad.Report
                    (Item    => Bad.Impossible_Operand,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Right),
                     Message => "this divisor is zero, and there is no"
                                & " quotient for it to produce",
                     Note    => "[1950]: an operand the operation cannot"
                                & " take is refused where the compiler"
                                & " knows it",
                     Into    => Found);

               when others =>
                  if Amount >= 0 then
                     return;
                  end if;

                  Bad.Report
                    (Item    => Bad.Impossible_Operand,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Right),
                     Message => "this shift amount is negative, and"
                                & " [0320] gives a shift one form only",
                     Note    => "[1950]: an operand the operation cannot"
                                & " take is refused where the compiler"
                                & " knows it",
                     Into    => Found);
            end case;

            Landin.Checking.Refuse (Types.all, Of_Tree, Right);
         end;
      end Check_Operands;

      ------------------------------------------------------------
      --  [0940]/[0960]: whole-module error-set inference
      ------------------------------------------------------------

      procedure Finalize_Error_Sets;

      procedure Finalize_Error_Sets is
         Signature_Total : constant Natural :=
           Landin.Checking.Signature_Count (Types.all);
         Declaration_Total : constant Natural :=
           Res.Declaration_Count (Meanings.all);
         Signature_Last : constant Positive :=
           Positive'Max (1, Signature_Total);
         Declaration_Last : constant Positive :=
           Positive'Max (1, Declaration_Total);

         type Effect_Matrix is array
           (Positive range <>, Positive range <>) of Boolean;
         Effects : Effect_Matrix
           (1 .. Signature_Last, 1 .. Declaration_Last) :=
             [others => [others => False]];
         Required : Effect_Matrix
           (1 .. Signature_Last, 1 .. Declaration_Last) :=
             [others => [others => False]];
         Edges : Effect_Matrix
           (1 .. Signature_Last, 1 .. Signature_Last) :=
             [others => [others => False]];
         Owns_Body : array (1 .. Signature_Last) of Boolean :=
           [others => False];
         Recovery_Signatures : array (1 .. Declaration_Last) of
           Landin.Checking.Signature_Id :=
             [others => Landin.Checking.No_Signature];

         type Call_Issue is record
            Source : Landin.Source.Source_Id := Landin.Source.No_Source;
            Node : Syn.Node_Id := Syn.No_Node;
            Signature : Landin.Checking.Signature_Id :=
              Landin.Checking.No_Signature;
         end record;

         function Total_Nodes return Natural;

         function Total_Nodes return Natural is
            Total : Natural := 0;
         begin
            for Index in 1 .. Source_Count (Context) loop
               Total := Total + Syn.Node_Count
                 (Tree_For (Nth_Source (Context, Index)).all);
            end loop;
            return Total;
         end Total_Nodes;

         Issues : array (1 .. Positive'Max (1, Total_Nodes)) of Call_Issue :=
           [others => (others => <>)];
         Deferred_Recoveries : array
           (1 .. Positive'Max (1, Total_Nodes)) of Call_Issue :=
             [others => (others => <>)];
         Issue_Count : Natural := 0;
         Deferred_Recovery_Count : Natural := 0;

         function Signature_For_Call
           (Of_Tree : Syn.Tree; Call : Syn.Node_Id)
            return Landin.Checking.Signature_Id;
         procedure Include_Set
           (Into : in out Effect_Matrix;
            Row : Positive;
            Set_Id : Landin.Checking.Atom_Set_Id);
         procedure Include_Expression
           (Of_Tree : Syn.Tree;
            Node : Syn.Node_Id;
            Caller : Positive;
            Into : in out Effect_Matrix);
         procedure Scan
           (Of_Tree : Syn.Tree;
            Node : Syn.Node_Id;
            Caller : Positive);

         function Signature_For_Call
           (Of_Tree : Syn.Tree; Call : Syn.Node_Id)
            return Landin.Checking.Signature_Id
         is
            Callee : constant Syn.Node_Id :=
              Syn.Callee_Of (Of_Tree, Call);
         begin
            if Res.Verdict_Of (Meanings.all, Of_Tree, Callee) = Res.Bound
            then
               return Landin.Checking.Signature_Of
                 (Types.all, Res.Bound_To (Meanings.all, Of_Tree, Callee));
            end if;
            return Landin.Checking.Signature_Of
              (Types.all, Of_Tree, Callee);
         end Signature_For_Call;

         procedure Include_Set
           (Into : in out Effect_Matrix;
            Row : Positive;
            Set_Id : Landin.Checking.Atom_Set_Id) is
         begin
            if Set_Id = Landin.Checking.No_Atom_Set then
               return;
            end if;
            for Index in 1 .. Landin.Checking.Atom_Count
              (Types.all, Set_Id)
            loop
               declare
                  Atom : constant Res.Declaration_Id :=
                    Landin.Checking.Nth_Atom (Types.all, Set_Id, Index);
               begin
                  Into (Row, Positive (Atom)) := True;
               end;
            end loop;
         end Include_Set;

         procedure Include_Expression
           (Of_Tree : Syn.Tree;
            Node : Syn.Node_Id;
            Caller : Positive;
            Into : in out Effect_Matrix)
         is
         begin
            if Node = Syn.No_Node then
               return;
            end if;

            case Syn.Kind (Of_Tree, Node) is
               when Syn.Name_Reference =>
                  if Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
                  then
                     declare
                        Id : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, Node);
                     begin
                        if Res.Sort_Of (Meanings.all, Id) = Res.Error_Binding
                          and then Recovery_Signatures (Positive (Id))
                                     /= Landin.Checking.No_Signature
                        then
                           Edges
                             (Caller,
                              Positive
                                (Recovery_Signatures (Positive (Id)))) :=
                               True;
                        else
                           Include_Set
                             (Into, Caller,
                              Landin.Checking.Atom_Set_Of (Types.all, Id));
                        end if;
                     end;
                  end if;

               when Syn.Call =>
                  declare
                     Signature : constant Landin.Checking.Signature_Id :=
                       Signature_For_Call (Of_Tree, Node);
                  begin
                     if Signature /= Landin.Checking.No_Signature
                       and then Landin.Checking.Signature_Result_Count
                         (Types.all, Signature) = 1
                     then
                        Include_Set
                          (Into, Caller,
                           Landin.Checking.Nth_Signature_Result
                             (Types.all, Signature, 1).Atoms);
                     end if;
                  end;

               when Syn.Try_Expression =>
                  Include_Expression
                    (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Caller, Into);

               when Syn.If_Statement =>
                  for Index in 1 .. Syn.Arm_Count (Of_Tree, Node) loop
                     declare
                        Runs : constant Syn.Node_Id :=
                          Syn.Body_Of
                            (Of_Tree, Syn.Nth_Arm (Of_Tree, Node, Index));
                     begin
                        Include_Expression
                          (Of_Tree, Syn.Block_Value (Of_Tree, Runs),
                           Caller, Into);
                     end;
                  end loop;
                  if Syn.Else_Body (Of_Tree, Node) /= Syn.No_Node then
                     Include_Expression
                       (Of_Tree,
                        Syn.Block_Value
                          (Of_Tree, Syn.Else_Body (Of_Tree, Node)),
                        Caller, Into);
                  end if;

               when Syn.Match_Statement =>
                  for Index in 1 .. Syn.Match_Arm_Count
                    (Of_Tree, Node)
                  loop
                     declare
                        Runs : constant Syn.Node_Id :=
                          Syn.Body_Of
                            (Of_Tree,
                             Syn.Nth_Match_Arm (Of_Tree, Node, Index));
                     begin
                        Include_Expression
                          (Of_Tree, Syn.Block_Value (Of_Tree, Runs),
                           Caller, Into);
                     end;
                  end loop;

               when Syn.Bare_Block =>
                  Include_Expression
                    (Of_Tree,
                     Syn.Block_Value
                       (Of_Tree, Syn.Body_Of (Of_Tree, Node)),
                     Caller, Into);

               when others =>
                  declare
                     Set_Id : constant Landin.Checking.Atom_Set_Id :=
                       Landin.Checking.Atom_Set_Of
                         (Types.all, Of_Tree, Node);
                  begin
                     Include_Set (Into, Caller, Set_Id);
                  end;
            end case;
         end Include_Expression;

         procedure Scan
           (Of_Tree : Syn.Tree;
            Node : Syn.Node_Id;
            Caller : Positive)
         is
         begin
            if Node = Syn.No_Node then
               return;
            end if;

            case Syn.Kind (Of_Tree, Node) is
               when Syn.Anonymous_Function =>
                  --  Its body has its own signature and is scanned below.
                  return;

               when Syn.Fail_Statement =>
                  Include_Expression
                    (Of_Tree, Syn.Value_Of (Of_Tree, Node), Caller,
                     Required);
                  Scan (Of_Tree, Syn.Value_Of (Of_Tree, Node), Caller);
                  Scan
                    (Of_Tree, Syn.Condition_Of (Of_Tree, Node), Caller);
                  return;

               when Syn.Try_Expression =>
                  declare
                     Call : constant Syn.Node_Id :=
                       Syn.Operand_Of (Of_Tree, Node);
                  begin
                     if Syn.Kind (Of_Tree, Call) = Syn.Call
                       and then Syn.Recovery_Of (Of_Tree, Call) = Syn.No_Node
                     then
                        declare
                           Signature : constant
                             Landin.Checking.Signature_Id :=
                               Signature_For_Call (Of_Tree, Call);
                        begin
                           if Signature /= Landin.Checking.No_Signature then
                              Edges (Caller, Positive (Signature)) := True;
                           end if;
                        end;
                        for Index in 1 .. Syn.Argument_Count
                          (Of_Tree, Call)
                        loop
                           Scan
                             (Of_Tree,
                              Syn.Nth_Argument (Of_Tree, Call, Index),
                              Caller);
                        end loop;
                     end if;
                  end;
                  return;

               when Syn.Call =>
                  for Index in 1 .. Syn.Argument_Count (Of_Tree, Node) loop
                     Scan
                       (Of_Tree, Syn.Nth_Argument (Of_Tree, Node, Index),
                        Caller);
                  end loop;

                  declare
                     Signature : constant Landin.Checking.Signature_Id :=
                       Signature_For_Call (Of_Tree, Node);
                     Recovery : constant Syn.Node_Id :=
                       Syn.Recovery_Of (Of_Tree, Node);
                  begin
                     if Recovery /= Syn.No_Node then
                        if Signature /= Landin.Checking.No_Signature
                          and then Landin.Checking.Signature_Error_Form
                            (Types.all, Signature) = Landin.Checking.Inferred
                        then
                           Deferred_Recovery_Count :=
                             Deferred_Recovery_Count + 1;
                           Deferred_Recoveries (Deferred_Recovery_Count) :=
                             (Source => Syn.Source_Of (Of_Tree),
                              Node => Node,
                              Signature => Signature);
                        end if;
                        if Syn.Name (Of_Tree, Recovery)
                             /= Landin.Source.Names.No_Name
                          and then Signature
                                     /= Landin.Checking.No_Signature
                        then
                           declare
                              Id : constant Res.Declaration_Id :=
                                Declaration_At
                                  (Syn.Source_Of (Of_Tree), Recovery);
                           begin
                              Recovery_Signatures (Positive (Id)) :=
                                Signature;
                           end;
                        end if;
                        Scan
                          (Of_Tree, Syn.Else_Body (Of_Tree, Recovery),
                           Caller);
                     elsif Signature /= Landin.Checking.No_Signature then
                        Issue_Count := Issue_Count + 1;
                        Issues (Issue_Count) :=
                          (Source => Syn.Source_Of (Of_Tree),
                           Node => Node,
                           Signature => Signature);
                     end if;
                  end;
                  return;

               when others =>
                  null;
            end case;

            for Index in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
               Scan (Of_Tree, Syn.Slot (Of_Tree, Node, Index), Caller);
            end loop;
         end Scan;

         Changed : Boolean;
      begin
         if Signature_Total = 0 then
            return;
         end if;

         --  A concrete callee promises its whole written set, independent
         --  of which atoms its present body happens to use.
         for Signature in 1 .. Signature_Total loop
            if Landin.Checking.Signature_Error_Form
                 (Types.all, Landin.Checking.Signature_Id (Signature))
                 = Landin.Checking.Concrete
            then
               Include_Set
                 (Effects, Signature,
                  Landin.Checking.Signature_Errors
                    (Types.all,
                     Landin.Checking.Signature_Id (Signature)));
            end if;
         end loop;

         for Index in 1 .. Source_Count (Context) loop
            declare
               Of_Tree : constant not null access constant Syn.Tree :=
                 Tree_For (Nth_Source (Context, Index));
            begin
               for Position in 1 .. Syn.Declaration_Count (Of_Tree.all) loop
                  declare
                     Node : constant Syn.Node_Id :=
                       Syn.Nth_Declaration (Of_Tree.all, Position);
                  begin
                     if Syn.Kind (Of_Tree.all, Node)
                          = Syn.Function_Declaration
                     then
                        declare
                           Id : constant Res.Declaration_Id :=
                             Declaration_At
                               (Syn.Source_Of (Of_Tree.all), Node);
                           Signature : constant
                             Landin.Checking.Signature_Id :=
                               Landin.Checking.Signature_Of
                                 (Types.all, Id);
                        begin
                           if Signature /= Landin.Checking.No_Signature then
                              Owns_Body (Positive (Signature)) := True;
                              Scan
                                (Of_Tree.all, Syn.Body_Of (Of_Tree.all, Node),
                                 Positive (Signature));
                           end if;
                        end;
                     end if;
                  end;
               end loop;

               for Node in Syn.Node_Id'(1) .. Syn.Last_Node (Of_Tree.all)
               loop
                  if Syn.Kind (Of_Tree.all, Node) = Syn.Anonymous_Function
                  then
                     declare
                        Signature : constant Landin.Checking.Signature_Id :=
                          Landin.Checking.Signature_Of
                            (Types.all, Of_Tree.all, Node);
                     begin
                        if Signature /= Landin.Checking.No_Signature then
                           Owns_Body (Positive (Signature)) := True;
                           Scan
                             (Of_Tree.all, Syn.Body_Of (Of_Tree.all, Node),
                              Positive (Signature));
                        end if;
                     end;
                  end if;
               end loop;
            end;
         end loop;

         for Signature in 1 .. Signature_Total loop
            if Landin.Checking.Signature_Error_Form
                 (Types.all, Landin.Checking.Signature_Id (Signature))
                 = Landin.Checking.Inferred
            then
               for Atom in 1 .. Declaration_Total loop
                  Effects (Signature, Atom) := Required (Signature, Atom);
               end loop;
            end if;
         end loop;

         loop
            Changed := False;
            for Caller in 1 .. Signature_Total loop
               for Callee in 1 .. Signature_Total loop
                  if Edges (Caller, Callee) then
                     for Atom in 1 .. Declaration_Total loop
                        if Effects (Callee, Atom) then
                           if not Required (Caller, Atom) then
                              Required (Caller, Atom) := True;
                              Changed := True;
                           end if;
                           if Landin.Checking.Signature_Error_Form
                             (Types.all,
                              Landin.Checking.Signature_Id (Caller))
                                = Landin.Checking.Inferred
                             and then not Effects (Caller, Atom)
                           then
                              Effects (Caller, Atom) := True;
                              Changed := True;
                           end if;
                        end if;
                     end loop;
                  end if;
               end loop;
            end loop;
            exit when not Changed;
         end loop;

         for Signature in 1 .. Signature_Total loop
            if Landin.Checking.Signature_Error_Form
                 (Types.all, Landin.Checking.Signature_Id (Signature))
                 = Landin.Checking.Inferred
            then
               declare
                  Count : Natural := 0;
               begin
                  for Atom in 1 .. Declaration_Total loop
                     if Effects (Signature, Atom) then
                        Count := Count + 1;
                     end if;
                  end loop;

                  if Count = 0 then
                     Landin.Checking.Finalize_Inferred_Errors
                       (Types.all,
                        Landin.Checking.Signature_Id (Signature),
                        Landin.Checking.No_Atom_Set);
                  else
                     declare
                        Members : Landin.Checking.Atom_Array (1 .. Count);
                        Next : Natural := 0;
                     begin
                        for Atom in 1 .. Declaration_Total loop
                           if Effects (Signature, Atom) then
                              Next := Next + 1;
                              Members (Next) := Res.Declaration_Id (Atom);
                           end if;
                        end loop;
                        Landin.Checking.Finalize_Inferred_Errors
                          (Types.all,
                           Landin.Checking.Signature_Id (Signature),
                           Landin.Checking.Add_Atom_Set
                             (Types.all, Members));
                     end;
                  end if;
               end;
            end if;
         end loop;

         --  Recovery names become ordinary immutable atom values only after
         --  recursive inference has made their call's set concrete.
         for Id in Res.Declaration_Id'(1)
                   .. Res.Declaration_Id (Declaration_Total)
         loop
            if Res.Sort_Of (Meanings.all, Id) = Res.Error_Binding then
               Landin.Checking.Begin_Inference (Types.all, Id);
               declare
                  Signature : constant Landin.Checking.Signature_Id :=
                    Recovery_Signatures (Positive (Id));
                  Errors : constant Landin.Checking.Atom_Set_Id :=
                    (if Signature = Landin.Checking.No_Signature
                     then Landin.Checking.No_Atom_Set
                     else Landin.Checking.Signature_Errors
                       (Types.all, Signature));
               begin
                  if Errors = Landin.Checking.No_Atom_Set then
                     Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
                  else
                     Landin.Checking.Note_Atom_Set (Types.all, Id, Errors);
                     Landin.Checking.Settle
                       (Types.all, Id, Ty.Atom_Value);
                  end if;
               end;
            end if;
         end loop;

         for Index in 1 .. Deferred_Recovery_Count loop
            declare
               Of_Tree : constant not null access constant Syn.Tree :=
                 Tree_For (Deferred_Recoveries (Index).Source);
               Checked : constant Ty.Type_Kind :=
                 Check_Call
                   (Of_Tree.all, Deferred_Recoveries (Index).Node,
                    Deferred_Recoveries (Index).Signature);
            begin
               pragma Unreferenced (Checked);
            end;
         end loop;

         for Signature in 1 .. Signature_Total loop
            if Owns_Body (Signature) then
               for Atom in 1 .. Declaration_Total loop
                  if Required (Signature, Atom)
                    and then not Effects (Signature, Atom)
                  then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Landin.Checking.Signature_Origin
                          (Types.all,
                           Landin.Checking.Signature_Id (Signature)).Source,
                        Where   => Landin.Checking.Signature_Origin
                          (Types.all,
                           Landin.Checking.Signature_Id (Signature)).Where,
                        Message => "this body can fail with an atom outside"
                                   & " its declared error set",
                        Note    => "[0940]: every failing path belongs to"
                                   & " the function's `!` set",
                        Related => Landin.Checking.Signature_Origin
                          (Types.all,
                           Landin.Checking.Signature_Id (Signature)),
                        Because => "this declared signature",
                        Into    => Found);
                     exit;
                  end if;
               end loop;
            end if;
         end loop;

         for Index in 1 .. Issue_Count loop
            if Landin.Checking.Signature_Errors
                 (Types.all, Issues (Index).Signature)
                 /= Landin.Checking.No_Atom_Set
            then
               declare
                  Of_Tree : constant not null access constant Syn.Tree :=
                    Tree_For (Issues (Index).Source);
               begin
                  Bad.Report
                    (Item    => Bad.Type_Mismatch,
                     Source  => Issues (Index).Source,
                     Where   => Syn.Where
                       (Of_Tree.all, Issues (Index).Node),
                     Message => "this failing call is neither tried nor"
                                & " recovered with `else`",
                     Note    => "[0960]/[1030]: write `try` to propagate or"
                                & " `else` to handle the declared error",
                     Related => Landin.Checking.Signature_Origin
                       (Types.all, Issues (Index).Signature),
                     Because => "this failing signature",
                     Into    => Found);
               end;
            end if;
         end loop;
      end Finalize_Error_Sets;

      --  Declared and anonymous functions share one body rule.  The latter
      --  reaches this procedure when its expression is synthesized, while a
      --  module declaration reaches it in pass three below.
      procedure Check_Routine_Body
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Count : constant Natural := Syn.Return_Count (Of_Tree, Node);
         Result : constant Syn.Node_Id :=
           (if Count = 1 then Syn.Nth_Return (Of_Tree, Node, 1)
            else Syn.No_Node);
         Gives : constant Ty.Type_Kind :=
           (if Count = 0 then Ty.No_Value
            elsif Count = 1 then Declared_As_Node (Of_Tree, Result)
            else Ty.Aggregate);
         Runs : constant Syn.Node_Id := Syn.Body_Of (Of_Tree, Node);
         Signature : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Signature_Of (Types.all, Of_Tree, Node);
         Expected : Value_Context := (Kind => Gives, others => <>);
         Result_Site : constant Landin.Provenance.Origin :=
           (if Syn.Returns_Of (Of_Tree, Node) = Syn.No_Node
            then Syn.Origin (Of_Tree, Node)
            else Syn.Origin
              (Of_Tree, Syn.Returns_Of (Of_Tree, Node)));
      begin
         --  The signature first records identity-only parts so recursive
         --  function types do not form by-value edges.  Parameters and
         --  results become ABI carriers only with this routine body, so now
         --  request their layouts before checking or lowering can use them.
         for Which in 1 .. Syn.Parameter_Count (Of_Tree, Node) loop
            declare
               Parameter : constant Syn.Node_Id :=
                 Syn.Nth_Parameter (Of_Tree, Node, Which);
               Held : constant Ty.Type_Kind :=
                 Declared_As_Node (Of_Tree, Parameter);
            begin
               pragma Unreferenced (Held);
            end;
         end loop;

         --  Ensure every return declaration is settled even when the
         --  anonymous structural aggregate, rather than one return, is the
         --  body's surrounding result context.
         for Which in 1 .. Count loop
            declare
               Returned : constant Syn.Node_Id :=
                 Syn.Nth_Return (Of_Tree, Node, Which);
               Held : constant Ty.Type_Kind :=
                 Declared_As_Node (Of_Tree, Returned);
            begin
               pragma Unreferenced (Held);
            end;
         end loop;

         if Count > 1 then
            Expected.Result_Shape := Signature;
         elsif Gives = Ty.Atom_Value then
            Expected.Atoms := Landin.Checking.Atom_Set_Of
              (Types.all, Declaration_At (Syn.Source_Of (Of_Tree), Result));
         elsif Gives = Ty.Aggregate then
            Expected.Nominal := Landin.Checking.Nominal_Of
              (Types.all, Of_Tree, Syn.Declared_Type (Of_Tree, Result));
         elsif Gives = Ty.Fixed_Array then
            Expected.Length := Landin.Checking.Array_Length
              (Types.all, Of_Tree, Syn.Declared_Type (Of_Tree, Result));
            Expected.Element := Landin.Checking.Array_Element
              (Types.all, Of_Tree, Syn.Declared_Type (Of_Tree, Result));
            Expected.Element_Nominal := Landin.Checking.Array_Element_Nominal
              (Types.all, Of_Tree, Syn.Declared_Type (Of_Tree, Result));
         elsif Gives = Ty.Function_Value then
            Expected.Signature := Landin.Checking.Signature_Of
              (Types.all,
               Declaration_At (Syn.Source_Of (Of_Tree), Result));
         end if;

         if Syn.Kind (Of_Tree, Runs) = Syn.Block then
            if Gives = Ty.No_Value then
               Check_Block (Of_Tree, Runs, Gives);
            else
               Check_Block
                 (Of_Tree, Runs, Gives, Expected,
                  Result_Site, "the returns this fills");
            end if;
         else
            Check_Contextual_Value
              (Of_Tree, Runs, Expected, Result_Site,
               "the returns this fills");
         end if;

         --  D124 extends [1910]'s edge walk through direct expression bodies
         --  too.  D128 asks the same question independently of every named
         --  return on each returning and final edge.
         Landin.Stages.Checking.Flow.Check_Function
           (Context, Of_Tree, Node, Runs,
            Syn.Returns_Of (Of_Tree, Node), Found);

         Check_Operands (Of_Tree, Runs, Whole_Fold => False);
      end Check_Routine_Body;

      ------------------------------------------------------------

   begin
      Landin.Checking.Prepare
        (Types.all, Trees.all, Meanings.all, Spellings.all);

      --  D135 declarations are checked even when no application reaches
      --  them.  Symbolic formals leave only actual-dependent questions open;
      --  free names, decidable formal kinds, terminal shape and unconditional
      --  expansion cycles are properties of the declaration itself.
      for Id in Res.Declaration_Id'(1)
                .. Res.Declaration_Id (Res.Declaration_Count (Meanings.all))
      loop
         if Res.Sort_Of (Meanings.all, Id) = Res.Module_Type
           and then Syn.Type_Formal_Count
             (Tree_For (Res.Source_Of (Meanings.all, Id)).all,
              Res.Node_Of (Meanings.all, Id)) /= 0
         then
            Validate_Template (Id);
         end if;
      end loop;

      --  Generic routine templates are source declarations even before one
      --  call supplies actuals.  Reject body defects that are unconditional
      --  on those actuals (the closed impossible-operand walk needs no
      --  guessed type), while dependent operations wait for an instance.
      for Id in Res.Declaration_Id'(1)
                .. Res.Declaration_Id (Res.Declaration_Count (Meanings.all))
      loop
         if Res.Sort_Of (Meanings.all, Id) = Res.Module_Function
           and then Syn.Generic_Formal_Count
             (Tree_For (Res.Source_Of (Meanings.all, Id)).all,
              Res.Node_Of (Meanings.all, Id)) /= 0
         then
            declare
               Of_Tree : constant not null access constant Syn.Tree :=
                 Tree_For (Res.Source_Of (Meanings.all, Id));
               Node : constant Syn.Node_Id :=
                 Res.Node_Of (Meanings.all, Id);
            begin
               Check_Operands
                 (Of_Tree.all, Syn.Body_Of (Of_Tree.all, Node),
                  Whole_Fold => False);
            end;
         end if;
      end loop;

      --  Pass one: every declaration that writes its type down, over every
      --  tree, before any body is read.  [1840]'s module scope is a set and
      --  crosses files, so this cannot wait for the walk that meets it.
      for Id in Res.Declaration_Id'(1)
                .. Res.Declaration_Id (Res.Declaration_Count (Meanings.all))
      loop
         if Landin.Checking.State_Of (Types.all, Id)
              = Landin.Checking.Untouched
           and then
             (Generic_Routine_Owner (Id) = Res.No_Declaration
              or else Generic_Routine_Owner (Id) = Id)
         then
            if Res.Sort_Of (Meanings.all, Id) = Res.Module_Type then
               --  A parameterized alias is compile-time-only template
               --  syntax.  Its individual applications settle concrete
               --  descriptors, so the declaration itself has no runtime
               --  type or layout to materialize.
               if Syn.Type_Formal_Count
                    (Tree_For (Res.Source_Of (Meanings.all, Id)).all,
                     Res.Node_Of (Meanings.all, Id)) /= 0
               then
                  Landin.Checking.Settle (Types.all, Id, Ty.Not_Typed);
               else
                  --  Settled_Type marks an alias before following it, so a
                  --  cycle returns to an Underway declaration rather than
                  --  recursively settling the declaration the outer pass is
                  --  still visiting.
                  declare
                     Written : constant Ty.Type_Kind := Settled_Type (Id);
                  begin
                     pragma Unreferenced (Written);
                  end;
               end if;
            elsif Res.Sort_Of (Meanings.all, Id) = Res.Module_Function
              and then Syn.Generic_Formal_Count
                (Tree_For (Res.Source_Of (Meanings.all, Id)).all,
                 Res.Node_Of (Meanings.all, Id)) /= 0
            then
               --  D138's routine template has no standalone function value
               --  or signature. A later direct call supplies its checker
               --  owned instance; until then it is only symbolic syntax.
               Landin.Checking.Settle (Types.all, Id, Ty.Not_Typed);
            elsif Res.Sort_Of (Meanings.all, Id)
                    in Res.Type_Parameter | Res.Fixed_Parameter
            then
               --  D135 retains these binders for substitution, but this
               --  increment has no compile-time type/value carrier yet.
               --  Marking them prevents Declared_As from asking a type
               --  formal for its deliberately absent declared type.
               Landin.Checking.Settle (Types.all, Id, Ty.Not_Typed);
            elsif Res.Sort_Of (Meanings.all, Id) = Res.Case_Name then
               --  D74 gives a case a declaration identity so forward uses,
               --  duplicates and module collisions have ordinary name
               --  semantics.  D75/D76 deliberately keep that identity
               --  without a general value type, so it must not enter
               --  Declared_As or Infer: both are paths for declarations that
               --  carry storage.
               Landin.Checking.Settle (Types.all, Id, Ty.Not_Typed);
            elsif Res.Sort_Of (Meanings.all, Id)
                    in Res.Pattern_Binding | Res.Result_Binding
                       | Res.Error_Binding
            then
               --  Payload aliases, selected multiple-result locals and
               --  recovery error names receive their contextual type when
               --  their owning construct is checked.
               null;
            else
               declare
                  Written : constant Ty.Type_Kind := Declared_As (Id);
               begin
                  if Written /= Ty.Undecided then
                     Landin.Checking.Settle (Types.all, Id, Written);
                  end if;
               end;
            end if;
         end if;
      end loop;

      --  Pass two: [1790]'s `:=` form, in declaration order so a cycle is
      --  reported at the same declaration every time.
      for Id in Res.Declaration_Id'(1)
                .. Res.Declaration_Id (Res.Declaration_Count (Meanings.all))
      loop
         if Landin.Checking.State_Of (Types.all, Id)
              = Landin.Checking.Untouched
           and then Generic_Routine_Owner (Id) = Res.No_Declaration
           and then Res.Sort_Of (Meanings.all, Id)
             not in Res.Pattern_Binding | Res.Result_Binding
                | Res.Error_Binding
         then
            Infer (Id);
         end if;
      end loop;

      --  Materialize every anonymous signature before error inference.  Its
      --  body is checked only after the recursive `! ...` graph is final.
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Nth_Source (Context, Index));
         begin
            for Node in Syn.Node_Id'(1) .. Syn.Last_Node (Of_Tree.all) loop
               if Syn.Kind (Of_Tree.all, Node) = Syn.Anonymous_Function then
                  declare
                     Held : constant Ty.Type_Kind :=
                       Synthesise (Of_Tree.all, Node);
                  begin
                     pragma Assert
                       (Held in Ty.Function_Value | Ty.Ill_Typed);
                  end;
               end if;
            end loop;
         end;
      end loop;

      Finalize_Error_Sets;

      --  Anonymous bodies can now check calls and `fail` against finalized
      --  concrete sets, including mutually recursive private inference.
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Nth_Source (Context, Index));
         begin
            for Node in Syn.Node_Id'(1) .. Syn.Last_Node (Of_Tree.all) loop
               if Syn.Kind (Of_Tree.all, Node) = Syn.Anonymous_Function
                 and then Landin.Checking.Signature_Of
                   (Types.all, Of_Tree.all, Node)
                     /= Landin.Checking.No_Signature
               then
                  Check_Routine_Body (Of_Tree.all, Node);
               end if;
            end loop;
         end;
      end loop;

      --  Module function values, arrays and structs have no run-before-main
      --  copy.  Their image chains therefore have to terminate at a static
      --  code address or data image rather than returning to a declaration
      --  already being visited.
      Validate_Function_Images;
      Validate_Module_Images;

      --  Pass three: the bodies, one tree at a time in source order.
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Nth_Source (Context, Index));
         begin
            for Position in
              1 .. Syn.Declaration_Count (Of_Tree.all)
            loop
               declare
                  Node : constant Syn.Node_Id :=
                    Syn.Nth_Declaration (Of_Tree.all, Position);
               begin
                  case Syn.Kind (Of_Tree.all, Node) is
                     --  [1795] declares no value, so there is nothing
                     --  here to fold, to assign or to read.  Asking what
                     --  it names settles its type and reports a name that
                     --  is not a type, which is the whole of its check.
                     when Syn.Type_Declaration =>
                        declare
                           Ignored : constant Ty.Type_Kind :=
                             Settled_Type (Declaration_At
                                             (Syn.Source_Of (Of_Tree.all),
                                              Node));
                        begin
                           pragma Assert (Ignored = Ignored);
                        end;

                     when Syn.Binding =>
                        Check_Module_Value (Of_Tree.all, Node);
                        Check_Statement
                          (Of_Tree.all, Node, Ty.Not_Typed);
                        Check_Module_Fold (Of_Tree.all, Node);
                        Check_Operands
                          (Of_Tree.all,
                           Syn.Value_Of (Of_Tree.all, Node),
                           Whole_Fold => True);

                     when Syn.Function_Declaration =>
                        if Syn.Generic_Formal_Count (Of_Tree.all, Node) = 0
                        then
                           Check_Routine_Body (Of_Tree.all, Node);
                        end if;

                     when others =>
                        null;
                  end case;
               end;
            end loop;
         end;
      end loop;

      declare
         Ordered : constant Landin.Diagnostics.Diagnostic_List :=
           Landin.Diagnostics.Sorted (Found);
      begin
         for Position in 1 .. Landin.Diagnostics.Count (Ordered) loop
            Report (Context, Landin.Diagnostics.Get (Ordered, Position));
         end loop;
      end;

      Outcome := (if Failed (Context) then Stop else Continue);
   end Run;

end Landin.Stages.Checking;
