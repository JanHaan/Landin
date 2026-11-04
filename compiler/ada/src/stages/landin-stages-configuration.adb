with Landin.Targets.Capabilities;
with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Checking;
with Landin.Configuration;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Checking;
with Landin.Diagnostics.Modules;
with Landin.Modules;
with Landin.Modules.Availability;
with Landin.Diagnostics.Resolution;
with Landin.Machine;
with Landin.Source;
with Landin.Source.Names;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;
with Landin.Targets.Assembly;
with Landin.Targets.Firmware;
with Landin.Targets.Levels;
with Landin.Types;
with Landin.Tokens.Text;

package body Landin.Stages.Configuration is

   package Bad renames Landin.Diagnostics.Checking;
   package Syn renames Landin.Syntax;
   package Ty renames Landin.Types;
   package Firmware renames Landin.Targets.Firmware;

   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Targets.Architecture;
   use type Landin.Targets.C_ABI_Kind;
   use type Landin.Targets.Capabilities.Hosted_System;
   use type Landin.Types.Folded;
   use type Landin.Types.Type_Kind;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Configuration.Build_Mode;
   use type Landin.Targets.Endianness;
   use type Landin.Tokens.Text.Problem;
   use type Landin.Modules.Module_Id;
   use type Landin.Source.Source_Id;
   use type Landin.Machine.Convention;

   overriding function Name (Item : Instance) return String is
      pragma Unreferenced (Item);
   begin
      return "configuration";
   end Name;

   procedure Configure
     (Whole   : in out Compilation'Class;
      Outcome : out Stage_Outcome;
      Late    : Boolean);

   overriding procedure Run
     (Item    : Instance;
      Whole   : in out Compilation'Class;
      Outcome : out Stage_Outcome)
   is
      pragma Unreferenced (Item);
   begin
      Configure (Whole, Outcome, Late => False);
   end Run;

   procedure Check_Layout_Assertions (Whole : in out Compilation'Class) is
      Ignored : Stage_Outcome;
   begin
      if Landin.Configuration.Deferred_Count
        (Configurations (Compilation (Whole)).all) > 0
      then
         Configure (Whole, Ignored, Late => True);
      end if;
   end Check_Layout_Assertions;

   --  Late is D412's second pass: options are gathered again so the
   --  deferred assertions read the same values, but only those assertions'
   --  reports are kept, and the configuration table is not changed.
   procedure Configure
     (Whole   : in out Compilation'Class;
      Outcome : out Stage_Outcome;
      Late    : Boolean)
   is
      --  The one view every helper below takes; see Landin.Stages.Run.
      Context : Compilation renames Compilation (Whole);

      Trees : constant not null access Landin.Syntax.Forest.Table :=
        Landin.Stages.Trees (Context);
      Names : constant not null access Landin.Source.Names.Table :=
        Identities (Context);
      Activity : constant not null access Landin.Configuration.Table :=
        Configurations (Context);
      Found : Landin.Diagnostics.Diagnostic_List;
      Unavailable_Import : Boolean := False;
      --  D615: the float unit of the description the program reaches,
      --  which `compiler.feature.fp` and `fp_dp` read.  A description's
      --  directives stand outside every fixed arm, so it is read from them
      --  before any option or fixed condition is evaluated.
      Float_Facts : Landin.Targets.Firmware.Float_Unit :=
        Landin.Targets.Firmware.No_Float_Unit;

      type Fixed_Kind is
        (Bad_Value, Truth, Number, Machine, Byte_Order, Build_Kind,
         Operating_System);
      type Fixed_Value (Kind : Fixed_Kind := Bad_Value) is record
         case Kind is
            when Truth => Boolean_Value : Boolean;
            when Number => Integer_Value : Ty.Folded;
            when Machine => Architecture_Value : Landin.Targets.Architecture;
            when Byte_Order => Order_Value : Landin.Targets.Endianness;
            when Build_Kind => Mode_Value : Landin.Configuration.Build_Mode;
            when Operating_System =>
               System_Value : Landin.Targets.Capabilities.Hosted_System;
            when Bad_Value => null;
         end case;
      end record;

      type Evaluation_State is (Pending, Evaluating, Evaluated);
      type Option_Entry is record
         Name   : Landin.Source.Names.Name_Id;
         Source : Landin.Source.Source_Id;
         Node   : Syn.Node_Id;
         State  : Evaluation_State := Pending;
         Value  : Fixed_Value;
      end record;
      package Option_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Option_Entry);
      Options : Option_Vectors.Vector;

      function Option_Index (Name : Landin.Source.Names.Name_Id)
        return Natural;
      function Evaluate_Option (Index : Positive) return Fixed_Value;
      procedure Gather_Options
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Conditional : Boolean);
      procedure Configure_Directive (Of_Tree : Syn.Tree; Node : Syn.Node_Id);
      function Scalar_Type (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Ty.Type_Kind;

      procedure Report_Not_Fixed
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Message : String;
         Note : String := "D202: configuration expressions use only closed"
           & " fixed forms; no user routine runs");
      procedure Report_Configuration_Rule
        (Item : Bad.Failure; Of_Tree : Syn.Tree; Node : Syn.Node_Id;
         Message : String; Note : String);
      procedure Report_Type
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Message : String;
         Related_Node : Syn.Node_Id := Syn.No_Node;
         Because : String := "";
         Note : String := "D202: fixed operands must have the types"
           & " required by their operator or declaration");
      procedure Report_Range
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Message : String;
         Note : String := "D139: every mathematical fixed-expression"
           & " intermediate must remain representable");
      procedure Report_Impossible
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Message : String);
      procedure Mark_Subtree_Inactive
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);
      procedure Configure_Declaration
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);
      function Fixed_Type (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Fixed_Kind;
      function Validate (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Boolean;
      function Evaluate (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Fixed_Value;

      --  D412: whether Validate admits a declared type's measurement, as
      --  it does inside a compiler assertion, and whether a subtree makes
      --  one; and the measurement's answer, which the late pass reads from
      --  the checked layout.
      Measuring_Layout : Boolean := False;
      function Measures_Layout (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Boolean;
      function Layout_Measure (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Fixed_Value;

      function Spelled (Name : Landin.Source.Names.Name_Id) return String
        is (Landin.Source.Names.Spelling (Names.all, Name));

      --  Whether NODE is `compiler.WORD`, and what it reads when it is.
      function Is_Compiler_Member
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
        is (Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
            and then Syn.Kind (Of_Tree, Syn.Target_Of (Of_Tree, Node))
              = Syn.Name_Reference
            and then Spelled (Syn.Name
              (Of_Tree, Syn.Target_Of (Of_Tree, Node))) = "compiler");

      --  D255: `compiler.feature.NAME` is one member selection further out
      --  than every other fact, so it is recognised by its shape before a
      --  member's own word is read.
      function Is_Feature_Fact
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
        is (Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
            and then Is_Compiler_Member
              (Of_Tree, Syn.Target_Of (Of_Tree, Node))
            and then Spelled (Syn.Name
              (Of_Tree, Syn.Target_Of (Of_Tree, Node))) = "feature");

      function Measures_Layout (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Boolean is
      begin
         if Node = Syn.No_Node then
            return False;
         elsif Syn.Kind (Of_Tree, Node) = Syn.Offset_Of then
            return True;
         elsif Syn.Kind (Of_Tree, Node) in Syn.Size_Of | Syn.Align_Of then
            return Scalar_Type (Of_Tree, Syn.Measured_Type (Of_Tree, Node))
              not in Ty.Scalar_Name;
         end if;
         for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            if Measures_Layout (Of_Tree, Syn.Slot (Of_Tree, Node, Position))
            then
               return True;
            end if;
         end loop;
         return False;
      end Measures_Layout;

      function Layout_Measure (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Fixed_Value
      is
         use type Landin.Checking.Nominal_Type_Id;
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Context);
      begin
         --  Only the late pass evaluates one; the checker has reported
         --  every measured type or path it refused.
         if not Late then
            return (Kind => Bad_Value);
         end if;
         if Syn.Kind (Of_Tree, Node) = Syn.Offset_Of then
            declare
               Offset : Landin.Targets.Byte_Count;
               Known : Boolean;
            begin
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                 /= Ty.Usize
               then
                  return (Kind => Bad_Value);
               end if;
               Landin.Checking.Offset_Value
                 (Types.all, Of_Tree, Node, Offset, Known);
               return (if Known
                       then (Kind => Number,
                             Integer_Value => Ty.Folded (Offset))
                       else (Kind => Bad_Value));
            end;
         end if;
         declare
            Asked : constant Syn.Node_Id := Syn.Measured_Type (Of_Tree, Node);
            Sizing : constant Boolean :=
              Syn.Kind (Of_Tree, Node) = Syn.Size_Of;
         begin
            case Landin.Checking.Type_Of (Types.all, Of_Tree, Asked) is
               when Ty.Aggregate =>
                  declare
                     Declared : constant Landin.Checking.Nominal_Type_Id :=
                       Landin.Checking.Nominal_Of (Types.all, Of_Tree, Asked);
                  begin
                     if Declared = Landin.Checking.No_Nominal_Type
                       or else not Landin.Checking.Has_Layout
                         (Types.all, Declared)
                     then
                        return (Kind => Bad_Value);
                     end if;
                     return (Kind => Number, Integer_Value =>
                       (if Sizing
                        then Ty.Folded (Landin.Checking.Layout_Size
                          (Types.all, Declared))
                        else Ty.Folded (Landin.Checking.Layout_Alignment
                          (Types.all, Declared))));
                  end;
               when Ty.Fixed_Array =>
                  declare
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Checking.Array_Type_Extent
                       (Types.all, Of_Tree, Asked, Target (Context), Size,
                        Alignment);
                     return (Kind => Number, Integer_Value =>
                       (if Sizing then Ty.Folded (Size)
                        else Ty.Folded (Alignment)));
                  end;
               when Ty.Scalar_Name =>
                  declare
                     Size : constant Landin.Targets.Scalar_Size :=
                       Ty.Storage_Size
                         (Landin.Checking.Type_Of (Types.all, Of_Tree, Asked),
                          Target (Context));
                  begin
                     return (Kind => Number, Integer_Value =>
                       (if Sizing then Ty.Folded (Landin.Targets.Bytes (Size))
                        else Ty.Folded (Landin.Targets.Alignment_Of
                          (Target (Context), Size))));
                  end;
               when Ty.Pointer_Value | Ty.Function_Value | Ty.Slice_Value
                  | Ty.Any_Value | Ty.Atom_Value =>
                  declare
                     Carrier : constant Ty.Scalar_Name :=
                       (if Landin.Checking.Type_Of (Types.all, Of_Tree, Asked)
                             = Ty.Atom_Value
                        then Ty.U32 else Ty.Usize);
                     Words : constant Ty.Folded :=
                       (if Landin.Checking.Type_Of (Types.all, Of_Tree, Asked)
                             in Ty.Slice_Value | Ty.Any_Value
                        then 2 else 1);
                     Size : constant Landin.Targets.Scalar_Size :=
                       Ty.Storage_Size (Carrier, Target (Context));
                  begin
                     return (Kind => Number, Integer_Value =>
                       (if Sizing
                        then Ty.Folded (Landin.Targets.Bytes (Size)) * Words
                        else Ty.Folded (Landin.Targets.Alignment_Of
                          (Target (Context), Size))));
                  end;
               when others =>
                  return (Kind => Bad_Value);
            end case;
         end;
      end Layout_Measure;

      function Option_Index (Name : Landin.Source.Names.Name_Id)
        return Natural is
      begin
         for Index in 1 .. Natural (Options.Length) loop
            if Options.Element (Index).Name = Name then
               return Index;
            end if;
         end loop;
         return 0;
      end Option_Index;

      function Scalar_Type (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Ty.Type_Kind is
      begin
         if Node /= Syn.No_Node and then Syn.Kind (Of_Tree, Node)
           in Syn.Type_Name | Syn.Name_Reference
         then
            for Kind in Ty.Scalar_Name loop
               if Spelled (Syn.Name (Of_Tree, Node)) = Ty.Spelling (Kind) then
                  return Kind;
               end if;
            end loop;
         end if;
         return Ty.Ill_Typed;
      end Scalar_Type;

      procedure Report_Not_Fixed
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Message : String;
         Note : String := "D202: configuration expressions use only closed"
           & " fixed forms; no user routine runs") is
      begin
         Bad.Report
           (Item    => Bad.Not_Known_At_Compile_Time,
            Source  => Syn.Source_Of (Of_Tree),
            Where   => Syn.Where (Of_Tree, Node),
            Message => Message,
            Note    => Note,
            Into    => Found);
      end Report_Not_Fixed;

      procedure Report_Configuration_Rule
        (Item : Bad.Failure; Of_Tree : Syn.Tree; Node : Syn.Node_Id;
         Message : String; Note : String) is
      begin
         Bad.Report
           (Item    => Item,
            Source  => Syn.Source_Of (Of_Tree),
            Where   => Syn.Where (Of_Tree, Node),
            Message => Message,
            Note    => Note,
            Into    => Found);
      end Report_Configuration_Rule;

      procedure Report_Type
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Message : String;
         Related_Node : Syn.Node_Id := Syn.No_Node;
         Because : String := "";
         Note : String := "D202: fixed operands must have the types"
           & " required by their operator or declaration")
      is
         Primary : Syn.Node_Id := Node;
         Related : Syn.Node_Id := Related_Node;
      begin
         if Related = Syn.No_Node then
            if Syn.Kind (Of_Tree, Node) in Syn.Binary_Kind then
               Primary := Syn.Right_Of (Of_Tree, Node);
               Related := Syn.Left_Of (Of_Tree, Node);
            else
               Primary := Syn.Operand_Of (Of_Tree, Node);
               Related := Node;
            end if;
         end if;
         Bad.Report
           (Item    => Bad.Type_Mismatch,
            Source  => Syn.Source_Of (Of_Tree),
            Where   => (if Syn.Kind (Of_Tree, Primary)
                          = Syn.Option_Declaration
                        then Syn.Anchor (Of_Tree, Primary)
                        else Syn.Where (Of_Tree, Primary)),
            Message => Message,
            Note    => Note,
            Related => Syn.Origin (Of_Tree, Related),
            Because => (if Because /= "" then Because
                        elsif Syn.Kind (Of_Tree, Node) in Syn.Binary_Kind
                        then "the other operand of this fixed operator"
                        else "this fixed operator requires a different type"),
            Into    => Found);
      end Report_Type;

      procedure Report_Range
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Message : String;
         Note : String := "D139: every mathematical fixed-expression"
           & " intermediate must remain representable") is
      begin
         Bad.Report
           (Item    => Bad.Literal_Out_Of_Range,
            Source  => Syn.Source_Of (Of_Tree),
            Where   => Syn.Where (Of_Tree, Node),
            Message => Message,
            Note    => Note,
            Into    => Found);
      end Report_Range;

      procedure Report_Impossible
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Message : String) is
      begin
         Bad.Report
           (Item    => Bad.Impossible_Operand,
            Source  => Syn.Source_Of (Of_Tree),
            Where   => Syn.Where (Of_Tree, Node),
            Message => Message,
            Note    => "[1950]: an operand the operation cannot take is"
                       & " refused where the compiler knows it",
            Into    => Found);
      end Report_Impossible;

      procedure Mark_Subtree_Inactive
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) is
      begin
         if Node = Syn.No_Node then
            return;
         end if;
         Landin.Configuration.Mark_Inactive
           (Activity.all, Syn.Source_Of (Of_Tree), Node);
         for Index in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            Mark_Subtree_Inactive (Of_Tree, Syn.Slot (Of_Tree, Node, Index));
         end loop;
      end Mark_Subtree_Inactive;

      --  Type inference never computes arithmetic. It checks a dead logical
      --  operand without turning a short-circuited divide by zero into an
      --  evaluated operation. Validate has already checked every child.
      function Fixed_Type (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Fixed_Kind is
      begin
         case Syn.Kind (Of_Tree, Node) is
            when Syn.Integer_Literal | Syn.Size_Of | Syn.Align_Of
               | Syn.Offset_Of | Syn.Negation | Syn.Add | Syn.Subtract
               | Syn.Multiply | Syn.Divide | Syn.Remainder =>
               return Number;
            when Syn.True_Literal | Syn.False_Literal | Syn.Logical_Not
               | Syn.Equal_To | Syn.Not_Equal_To | Syn.Less_Than
               | Syn.Less_Or_Equal | Syn.Greater_Than | Syn.Greater_Or_Equal
               | Syn.Logical_And | Syn.Logical_Or =>
               return Truth;
            when Syn.Name_Reference =>
               declare
                  Index : constant Natural :=
                    Option_Index (Syn.Name (Of_Tree, Node));
                  Word : constant String := Spelled (Syn.Name (Of_Tree, Node));
               begin
                  if Index > 0 then
                     return Options.Element (Index).Value.Kind;
                  elsif Word in "linux" | "darwin" | "freebsd"
                              | "freestanding"
                  then
                     return Operating_System;
                  elsif Word in "little" | "big" then
                     return Byte_Order;
                  elsif Word in "debug" | "release" then
                     return Build_Kind;
                  elsif Landin.Targets.Is_Architecture_Atom (Word) then
                     return Machine;
                  else
                     return Bad_Value;
                  end if;
               end;
            when Syn.Member_Selection =>
               declare
                  Word : constant String := Spelled (Syn.Name (Of_Tree, Node));
               begin
                  --  Every fact is named, and only `arch` is a machine: an
                  --  unnamed one is not typed as the nearest fact there is.
                  if Is_Feature_Fact (Of_Tree, Node) then
                     return Truth;
                  elsif Landin.Configuration.Is_Fact_Name (Word) then
                     return
                       (case Landin.Configuration.Fact_Named (Word) is
                          when Landin.Configuration.Arch_Fact => Machine,
                          when Landin.Configuration.OS_Fact =>
                             Operating_System,
                          when Landin.Configuration.Byte_Order_Fact =>
                             Byte_Order,
                          when Landin.Configuration.Build_Mode_Fact =>
                             Build_Kind,
                          when Landin.Configuration.Word_Size_Fact => Number,
                          when Landin.Configuration.C_ABI_Fact
                             | Landin.Configuration.C_Runtime_Fact => Truth);
                  else
                     return Bad_Value;
                  end if;
               end;
            when others =>
               return Bad_Value;
         end case;
      end Fixed_Type;

      --  This validates every subtree before evaluation.  In particular an
      --  invalid right operand of `false and ...` remains a diagnostic even
      --  though evaluation itself correctly short-circuits.
      function Validate (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Boolean
      is
         Valid : Boolean := True;
         Kind : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
      begin
         case Kind is
            when Syn.Integer_Literal | Syn.True_Literal | Syn.False_Literal =>
               null;

            when Syn.Name_Reference =>
               declare
                  Word : constant String := Spelled (Syn.Name (Of_Tree, Node));
               begin
                  if not Landin.Configuration.Is_Configuration_Atom (Word)
                    and then Option_Index (Syn.Name (Of_Tree, Node)) = 0
                  then
                     Report_Not_Fixed
                       (Of_Tree, Node,
                        "this name is not a compiler-owned fixed value");
                     Valid := False;
                  elsif Option_Index (Syn.Name (Of_Tree, Node)) > 0 then
                     declare
                        Value : constant Fixed_Value := Evaluate_Option
                          (Option_Index (Syn.Name (Of_Tree, Node)));
                     begin
                        Valid := Value.Kind /= Bad_Value;
                     end;
                  end if;
               end;

            when Syn.Member_Selection =>
               if Is_Feature_Fact (Of_Tree, Node) then
                  if not Landin.Targets.Levels.Is_Feature_Name
                    (Spelled (Syn.Name (Of_Tree, Node)))
                    and then not Firmware.Is_Float_Feature_Name
                      (Spelled (Syn.Name (Of_Tree, Node)))
                  then
                     Report_Not_Fixed
                       (Of_Tree, Node,
                        "unknown CPU feature: "
                        & Spelled (Syn.Name (Of_Tree, Node)),
                        Note => "D255: compiler.feature names a feature of"
                          & " a level a target can select");
                     Valid := False;
                  end if;
               elsif not Is_Compiler_Member (Of_Tree, Node)
                 or else not Landin.Configuration.Is_Fact_Name
                   (Spelled (Syn.Name (Of_Tree, Node)))
               then
                  Report_Not_Fixed
                    (Of_Tree, Node,
                     "unknown compiler fixed fact");
                  Valid := False;
               end if;

            when Syn.Size_Of | Syn.Align_Of | Syn.Offset_Of =>
               if (Syn.Kind (Of_Tree, Node) = Syn.Offset_Of
                   or else Scalar_Type
                     (Of_Tree, Syn.Measured_Type (Of_Tree, Node))
                       not in Ty.Scalar_Name)
                 and then not Measuring_Layout
               then
                  Report_Not_Fixed
                    (Of_Tree, Node,
                     "a declared type's layout is not known when fixed"
                     & " arms and options are chosen",
                     Note => "D412: only compiler.assert measures a"
                       & " declared type, after checking has laid it out;"
                       & " a fixed condition or option default measures"
                       & " scalar types");
                  Valid := False;
               end if;

            when Syn.Negation | Syn.Logical_Not =>
               Valid := Validate (Of_Tree, Syn.Operand_Of (Of_Tree, Node));

            when Syn.Add | Syn.Subtract | Syn.Multiply | Syn.Divide
               | Syn.Remainder | Syn.Equal_To | Syn.Not_Equal_To
               | Syn.Less_Than | Syn.Less_Or_Equal | Syn.Greater_Than
               | Syn.Greater_Or_Equal | Syn.Logical_And | Syn.Logical_Or =>
               Valid := Validate (Of_Tree, Syn.Left_Of (Of_Tree, Node));
               Valid := Validate (Of_Tree, Syn.Right_Of (Of_Tree, Node))
                 and then Valid;

            when others =>
               Report_Not_Fixed
                 (Of_Tree, Node,
                  "this is not one of the closed fixed configuration forms");
               Valid := False;
         end case;
         if Valid then
            if Kind in Syn.Negation | Syn.Logical_Not then
               Valid := Fixed_Type (Of_Tree, Syn.Operand_Of (Of_Tree, Node))
                 = (if Kind = Syn.Negation then Number else Truth);
            elsif Kind in Syn.Binary_Kind then
               declare
                  Left : constant Fixed_Kind :=
                    Fixed_Type (Of_Tree, Syn.Left_Of (Of_Tree, Node));
                  Right : constant Fixed_Kind :=
                    Fixed_Type (Of_Tree, Syn.Right_Of (Of_Tree, Node));
               begin
                  Valid := Left = Right and then Left /= Bad_Value;
                  if Kind in Syn.Logical_And | Syn.Logical_Or then
                     Valid := Valid and then Left = Truth;
                  elsif Kind not in Syn.Equal_To | Syn.Not_Equal_To then
                     Valid := Valid and then Left = Number;
                  end if;
               end;
            end if;
            if not Valid then
               Report_Type (Of_Tree, Node,
                 "fixed expression operands have incompatible types");
            end if;
         end if;
         return Valid;
      end Validate;

      function Evaluate (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Fixed_Value
      is
         Kind : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
         Left, Right : Fixed_Value;

         function Same_Kind return Boolean
           is (Left.Kind = Right.Kind);

         function Boolean_Result (Value : Boolean) return Fixed_Value
           is (Kind => Truth, Boolean_Value => Value);
      begin
         case Kind is
            when Syn.True_Literal =>
               return (Kind => Truth, Boolean_Value => True);
            when Syn.False_Literal =>
               return (Kind => Truth, Boolean_Value => False);
            when Syn.Integer_Literal =>
               declare
                  Text : constant String := Landin.Source.Slice
                    (Source (Context, Syn.Source_Of (Of_Tree)),
                     Syn.Digit_Span (Of_Tree, Node));
                  Magnitude : Ty.Magnitude;
                  Overflowed : Boolean;
               begin
                  Ty.Evaluate (Text, Syn.Base (Of_Tree, Node), Magnitude,
                               Overflowed);
                  if Overflowed then
                     Report_Range
                       (Of_Tree, Node,
                        "this fixed integer is outside the mathematical"
                        & " fixed-expression range");
                     return (Kind => Bad_Value);
                  end if;
                  return (Kind => Number,
                          Integer_Value => Ty.Folded (Magnitude));
               end;
            when Syn.Name_Reference =>
               declare
                  Word : constant String := Spelled (Syn.Name (Of_Tree, Node));
               begin
                  if Option_Index (Syn.Name (Of_Tree, Node)) > 0 then
                     return Evaluate_Option
                       (Option_Index (Syn.Name (Of_Tree, Node)));
                  elsif Word in "linux" | "darwin" | "freebsd"
                              | "freestanding"
                  then
                     return (Kind => Operating_System, System_Value =>
                       (if Word = "linux"
                        then Landin.Targets.Capabilities.Linux
                        elsif Word = "darwin"
                        then Landin.Targets.Capabilities.Darwin
                        elsif Word = "freebsd"
                        then Landin.Targets.Capabilities.FreeBSD
                        else Landin.Targets.Capabilities.No_Hosted_System));
                  elsif Word in "little" | "big" then
                     return (Kind => Byte_Order,
                             Order_Value => (if Word = "little"
                               then Landin.Targets.Little
                               else Landin.Targets.Big));
                  elsif Word in "debug" | "release" then
                     return (Kind => Build_Kind,
                             Mode_Value => (if Word = "debug"
                               then Landin.Configuration.Debug
                               else Landin.Configuration.Release));
                  end if;
                  if Landin.Targets.Is_Architecture_Atom (Word) then
                     return (Kind => Machine, Architecture_Value =>
                               Landin.Targets.Architecture_Named (Word));
                  end if;
                  raise Compiler_Defect
                    with "an unvalidated fixed name was evaluated: " & Word;
               end;
            when Syn.Member_Selection =>
               declare
                  Word : constant String := Spelled (Syn.Name (Of_Tree, Node));
               begin
                  if Is_Feature_Fact (Of_Tree, Node)
                    and then Firmware.Is_Float_Feature_Name (Word)
                  then
                     --  D615: the selected description's float unit,
                     --  read before any fixed expression is.
                     return Boolean_Result
                       (if Word = "fp"
                        then Firmware.Single_Precision (Float_Facts)
                        else Firmware.Double_Precision (Float_Facts));
                  elsif Is_Feature_Fact (Of_Tree, Node) then
                     return Boolean_Result
                       (Landin.Targets.Levels.Has
                          (Level (Context),
                           Landin.Targets.Levels.Feature_Named (Word)));
                  elsif Landin.Configuration.Is_Fact_Name (Word) then
                     case Landin.Configuration.Fact_Named (Word) is
                        when Landin.Configuration.C_ABI_Fact =>
                           return Boolean_Result
                             (Landin.Targets.C_ABI_Of (Target (Context))
                                = Landin.Configuration.ABI_Of
                                    (Landin.Configuration.Fact_Named
                                       (Word)));
                        when Landin.Configuration.C_Runtime_Fact =>
                           --  Darwin and FreeBSD reach their systems only
                           --  through their C libraries; Linux links one
                           --  when the request asks, and firmware never
                           --  does.
                           declare
                              System : constant
                                Landin.Targets.Capabilities.Hosted_System :=
                                  Landin.Targets.Capabilities.Hosted_System_Of
                                    (Target (Context));
                           begin
                              return Boolean_Result
                                (System in Landin.Targets.Capabilities.Darwin
                                         | Landin.Targets.Capabilities.FreeBSD
                                 or else
                                   (System = Landin.Targets.Capabilities.Linux
                                    and then
                                      Landin.Configuration.C_Runtime_Requested
                                        (Activity.all)));
                           end;
                        when Landin.Configuration.OS_Fact =>
                           return (Kind => Operating_System, System_Value =>
                             Landin.Targets.Capabilities.Hosted_System_Of
                               (Target (Context)));
                        when Landin.Configuration.Word_Size_Fact =>
                           return (Kind => Number, Integer_Value => Ty.Folded
                             (Landin.Targets.Pointer_Width
                                (Target (Context))));
                        when Landin.Configuration.Byte_Order_Fact =>
                           return (Kind => Byte_Order, Order_Value =>
                             Landin.Targets.Byte_Order (Target (Context)));
                        when Landin.Configuration.Build_Mode_Fact =>
                           return (Kind => Build_Kind, Mode_Value =>
                             Landin.Configuration.Mode (Activity.all));
                        when Landin.Configuration.Arch_Fact =>
                           return (Kind => Machine,
                                   Architecture_Value =>
                                     Landin.Targets.Architecture_Of
                                       (Target (Context)));
                     end case;
                  end if;
                  raise Compiler_Defect
                    with "an unvalidated compiler fact was evaluated: "
                      & Word;
               end;
            when Syn.Offset_Of =>
               return Layout_Measure (Of_Tree, Node);
            when Syn.Size_Of | Syn.Align_Of =>
               if Scalar_Type (Of_Tree, Syn.Measured_Type (Of_Tree, Node))
                 not in Ty.Scalar_Name
               then
                  return Layout_Measure (Of_Tree, Node);
               end if;
               declare
                  Kind_Of_Type : constant Ty.Scalar_Name := Scalar_Type
                    (Of_Tree, Syn.Measured_Type (Of_Tree, Node));
                  Size : constant Landin.Targets.Scalar_Size :=
                    Ty.Storage_Size (Kind_Of_Type, Target (Context));
               begin
                  return (Kind => Number, Integer_Value =>
                    (if Kind = Syn.Size_Of then
                        Ty.Folded (Landin.Targets.Bytes (Size))
                     else Ty.Folded (Landin.Targets.Alignment_Of
                       (Target (Context), Size))));
               end;
            when Syn.Negation =>
               Left := Evaluate (Of_Tree, Syn.Operand_Of (Of_Tree, Node));
               if Left.Kind /= Number
                 or else Left.Integer_Value = Ty.Folded'First
               then
                  Report_Range
                    (Of_Tree, Node,
                     "this fixed negation overflows the mathematical range");
                  return (Kind => Bad_Value);
               end if;
               return (Kind => Number, Integer_Value => -Left.Integer_Value);
            when Syn.Logical_Not =>
               Left := Evaluate (Of_Tree, Syn.Operand_Of (Of_Tree, Node));
               if Left.Kind /= Truth then
                  Report_Type (Of_Tree, Node, "`not` needs a bool operand");
                  return (Kind => Bad_Value);
               end if;
               return Boolean_Result (not Left.Boolean_Value);
            when others =>
               Left := Evaluate (Of_Tree, Syn.Left_Of (Of_Tree, Node));
               if Kind = Syn.Logical_And and then Left.Kind = Truth
                 and then not Left.Boolean_Value
               then
                  return Boolean_Result (False);
               elsif Kind = Syn.Logical_Or and then Left.Kind = Truth
                 and then Left.Boolean_Value
               then
                  return Boolean_Result (True);
               end if;
               Right := Evaluate (Of_Tree, Syn.Right_Of (Of_Tree, Node));
               if Left.Kind = Bad_Value or else Right.Kind = Bad_Value then
                  return (Kind => Bad_Value);
               end if;

               case Kind is
                  when Syn.Logical_And | Syn.Logical_Or =>
                     if not Same_Kind or else Left.Kind /= Truth then
                        Report_Type
                          (Of_Tree, Node,
                           "logical fixed operators need bool operands");
                        return (Kind => Bad_Value);
                     end if;
                     return Boolean_Result
                       ((if Kind = Syn.Logical_And then
                           Left.Boolean_Value and Right.Boolean_Value
                         else Left.Boolean_Value or Right.Boolean_Value));
                  when Syn.Equal_To | Syn.Not_Equal_To =>
                     if not Same_Kind then
                        Report_Type
                          (Of_Tree, Node,
                           "fixed equality needs operands in one domain");
                        return (Kind => Bad_Value);
                     end if;
                     declare
                        Equal : constant Boolean :=
                          (case Left.Kind is
                             when Truth => Left.Boolean_Value
                               = Right.Boolean_Value,
                             when Number => Left.Integer_Value
                               = Right.Integer_Value,
                             when Machine => Left.Architecture_Value
                               = Right.Architecture_Value,
                             when Byte_Order => Left.Order_Value
                               = Right.Order_Value,
                             when Build_Kind => Left.Mode_Value
                               = Right.Mode_Value,
                             when Operating_System => Left.System_Value
                               = Right.System_Value,
                             when Bad_Value => False);
                     begin
                        return Boolean_Result
                          (if Kind = Syn.Equal_To then Equal else not Equal);
                     end;
                  when Syn.Less_Than | Syn.Less_Or_Equal | Syn.Greater_Than
                     | Syn.Greater_Or_Equal =>
                     if not Same_Kind or else Left.Kind /= Number then
                        Report_Type
                          (Of_Tree, Node,
                           "fixed ordering comparisons need integers");
                        return (Kind => Bad_Value);
                     end if;
                     return Boolean_Result
                       (case Kind is
                          when Syn.Less_Than => Left.Integer_Value
                            < Right.Integer_Value,
                          when Syn.Less_Or_Equal => Left.Integer_Value
                            <= Right.Integer_Value,
                          when Syn.Greater_Than => Left.Integer_Value
                            > Right.Integer_Value,
                          when others => Left.Integer_Value
                            >= Right.Integer_Value);
                  when Syn.Add | Syn.Subtract | Syn.Multiply | Syn.Divide
                     | Syn.Remainder =>
                     if not Same_Kind or else Left.Kind /= Number then
                        Report_Type
                          (Of_Tree, Node,
                           "fixed arithmetic needs integer operands");
                        return (Kind => Bad_Value);
                     end if;
                     if Kind in Syn.Divide | Syn.Remainder
                       and then Right.Integer_Value = 0
                     then
                        Report_Impossible
                          (Of_Tree, Syn.Right_Of (Of_Tree, Node),
                           "this fixed-expression divisor is zero");
                        return (Kind => Bad_Value);
                     end if;
                     --  The checked arithmetic below is intentionally
                     --  mathematical, never target-width or wrapping.
                     if (Kind = Syn.Add and then
                           ((Right.Integer_Value > 0
                             and then Left.Integer_Value
                               > Ty.Folded'Last - Right.Integer_Value)
                            or else (Right.Integer_Value < 0 and then
                                     Left.Integer_Value < Ty.Folded'First
                                     - Right.Integer_Value)))
                       or else (Kind = Syn.Subtract and then
                                ((Right.Integer_Value > 0 and then
                                  Left.Integer_Value < Ty.Folded'First
                                  + Right.Integer_Value)
                                 or else (Right.Integer_Value < 0 and then
                                          Left.Integer_Value > Ty.Folded'Last
                                          + Right.Integer_Value)))
                       or else (Kind = Syn.Multiply and then
                                --  Folded is symmetric: -M * -1 is +M.
                                --  Only every other non-unit factor escapes.
                                ((Left.Integer_Value = Ty.Folded'First
                                  and then Right.Integer_Value
                                    not in -1 | 0 | 1)
                                 or else
                                   (Right.Integer_Value = Ty.Folded'First
                                    and then Left.Integer_Value
                                      not in -1 | 0 | 1)
                                 or else
                                   (Left.Integer_Value /= Ty.Folded'First
                                    and then Right.Integer_Value
                                      /= Ty.Folded'First
                                    and then Left.Integer_Value /= 0
                                    and then abs Right.Integer_Value
                                      > Ty.Folded'Last
                                        / abs Left.Integer_Value)))
                     then
                        Report_Range
                          (Of_Tree, Node,
                           "this fixed arithmetic result overflows the"
                           & " mathematical range");
                        return (Kind => Bad_Value);
                     end if;
                     return (Kind => Number,
                             Integer_Value =>
                               (case Kind is
                                  when Syn.Add => Left.Integer_Value
                                    + Right.Integer_Value,
                                  when Syn.Subtract => Left.Integer_Value
                                    - Right.Integer_Value,
                                  when Syn.Multiply => Left.Integer_Value
                                    * Right.Integer_Value,
                                  when Syn.Divide => Left.Integer_Value
                                    / Right.Integer_Value,
                                  when others => Left.Integer_Value
                                    rem Right.Integer_Value));
                  when others =>
                     return (Kind => Bad_Value);
               end case;
         end case;
      end Evaluate;

      procedure Gather_Options
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Conditional : Boolean) is
      begin
         if Syn.Kind (Of_Tree, Node) = Syn.Option_Declaration then
            if Conditional then
               Report_Configuration_Rule
                 (Bad.Invalid_Option_Declaration, Of_Tree, Node,
                  "an option must be declared outside every fixed arm",
                  Note => "[1530]/D202: all options must be declared"
                    & " unconditionally before arm selection");
            elsif Option_Index (Syn.Name (Of_Tree, Node)) /= 0 then
               Landin.Diagnostics.Resolution.Report
                 (Item => Landin.Diagnostics.Resolution.Duplicate_Declaration,
                  Source => Syn.Source_Of (Of_Tree),
                  Where => Syn.Anchor (Of_Tree, Node),
                  Message => "option `" & Spelled (Syn.Name (Of_Tree, Node))
                    & "` is declared twice",
                  Note => "[1530]: each option is declared exactly once"
                    & " in the whole program",
                  Related => Landin.Configuration.Option_Origin
                    (Activity.all, Syn.Name (Of_Tree, Node)),
                  Because => "the option that keeps the name",
                  Into => Found);
            elsif Spelled (Syn.Name (Of_Tree, Node))
              in "compiler" | "assembler" | "linker"
            then
               Landin.Diagnostics.Resolution.Report
                 (Item => Landin.Diagnostics.Resolution.Reserved_Tool_Name,
                  Source => Syn.Source_Of (Of_Tree),
                  Where => Syn.Where (Of_Tree, Node),
                  Message => "this option name is a reserved tool namespace",
                  Note => "[1560]: compiler, assembler and linker"
                    & " are implicitly available builtin modules",
                  Into => Found);
            elsif Landin.Configuration.Is_Configuration_Atom
                    (Spelled (Syn.Name (Of_Tree, Node)))
            then
               --  D855: an option of an atom's name would be read in the
               --  atom's place, so `compiler.os == linux` would compare a
               --  system with the option.
               Report_Configuration_Rule
                 (Bad.Invalid_Option_Declaration, Of_Tree, Node,
                  "this option name is compiler-owned",
                  Note => "D855: an option cannot take a configuration"
                    & " atom's name: "
                    & Landin.Configuration.Configuration_Atom_List);
            else
               if not Late then
                  Landin.Configuration.Record_Option
                    (Activity.all, Syn.Name (Of_Tree, Node),
                     Syn.Origin (Of_Tree, Node));
               end if;
               Options.Append
                 (Option_Entry'(Name => Syn.Name (Of_Tree, Node),
                   Source => Syn.Source_Of (Of_Tree), Node => Node,
                   State => Pending, Value => (Kind => Bad_Value)));
            end if;
         elsif Syn.Kind (Of_Tree, Node) = Syn.Fixed_Conditional then
            for Index in 1 .. Syn.Fixed_Arm_Count (Of_Tree, Node) loop
               declare
                  Arm : constant Syn.Node_Id :=
                    Syn.Nth_Fixed_Arm (Of_Tree, Node, Index);
               begin
                  for Which in 1 .. Syn.Fixed_Declaration_Count (Of_Tree, Arm)
                  loop
                     Gather_Options (Of_Tree,
                       Syn.Nth_Fixed_Declaration (Of_Tree, Arm, Which), True);
                  end loop;
               end;
            end loop;
         end if;
      end Gather_Options;

      function Evaluate_Option (Index : Positive) return Fixed_Value is
         Setting : Option_Entry := Options.Element (Index);
         Of_Tree : constant not null access constant Syn.Tree :=
           Landin.Syntax.Forest.Tree_Of (Trees.all, Setting.Source);
         Kind : constant Ty.Type_Kind := Scalar_Type
           (Of_Tree.all, Syn.Declared_Type (Of_Tree.all, Setting.Node));
         Value : Fixed_Value;

         function Fits_Type
           (Value : Fixed_Value; Override : String := "") return Boolean;
         function Fits_Type
           (Value : Fixed_Value; Override : String := "") return Boolean
         is
            Primary : constant Syn.Node_Id :=
              (if Override = "" then Syn.Value_Of (Of_Tree.all, Setting.Node)
               else Setting.Node);
            Subject : constant String := "option `" & Spelled (Setting.Name)
              & "`" & (if Override = "" then " value"
                       else ": --option=" & Spelled (Setting.Name)
                            & "=" & Override);
         begin
            if Value.Kind = Bad_Value then
               return False;
            elsif (Kind = Ty.Bool and then Value.Kind /= Truth)
              or else (Kind in Ty.Integer_Name and then Value.Kind /= Number)
            then
               Report_Type
                 (Of_Tree.all, Primary,
                  Subject & " does not match its declared type "
                    & Ty.Spelling (Kind),
                  Related_Node => Syn.Declared_Type
                    (Of_Tree.all, Setting.Node),
                  Because => "the declared option type",
                  Note => "[1530]: an option default and override must"
                    & " match its declared scalar type");
               return False;
            elsif Kind in Ty.Integer_Name and then not Ty.Holds
              (Value.Integer_Value, Kind, Target (Context))
            then
               Report_Range
                 (Of_Tree.all, Primary,
                  Subject & " is outside its type range ("
                    & Ty.Spelling (Kind) & ")",
                  Note => "[1530]/D202: the option value must fit its declared"
                    & " scalar type on the selected target");
               return False;
            end if;
            return True;
         end Fits_Type;
      begin
         if Setting.State = Evaluated then
            return Setting.Value;
         elsif Setting.State = Evaluating then
            Report_Not_Fixed (Of_Tree.all, Setting.Node,
                              "cyclic option defaults have no fixed value",
                              Note => "[1530]/D202: option default"
                                & " dependencies must be acyclic, even"
                                & " when overridden");
            return (Kind => Bad_Value);
         end if;
         Setting.State := Evaluating;
         Options.Replace_Element (Index, Setting);
         if Kind not in Ty.Bool | Ty.Integer_Name then
            Report_Configuration_Rule
              (Bad.Invalid_Option_Declaration, Of_Tree.all, Setting.Node,
               "an option needs bool or an integer scalar",
               Note => "[1530]/D202: only bool and enabled"
                 & " integer scalar names are option types");
         elsif Validate (Of_Tree.all, Syn.Value_Of (Of_Tree.all, Setting.Node))
         then
            Value := Evaluate
              (Of_Tree.all, Syn.Value_Of (Of_Tree.all, Setting.Node));
            if not Fits_Type (Value) then
               Value := (Kind => Bad_Value);
            end if;
         end if;
         --  Overrides never make an invalid default acceptable.
         if Value.Kind /= Bad_Value then
            for Which in 1 .. Landin.Configuration.Override_Count
              (Activity.all)
            loop
               if Landin.Configuration.Override_Name (Activity.all, Which)
                 = Spelled (Setting.Name)
               then
                  declare
                     Text : constant String :=
                       Landin.Configuration.Override_Value
                         (Activity.all, Which);
                     Parsed : Ty.Folded := 0;
                     Negative : constant Boolean := Text'Length > 0
                       and then Text (Text'First) = '-';
                     First : constant Integer :=
                       Text'First + (if Negative then 1 else 0);
                     Valid : Boolean := First <= Text'Last;
                  begin
                     if Kind = Ty.Bool then
                        Valid := Text in "true" | "false";
                        Value := (Kind => Truth,
                                  Boolean_Value => Text = "true");
                     else
                        for Position in First .. Text'Last loop
                           if Text (Position) not in '0' .. '9' then
                              Valid := False;
                              exit;
                           end if;
                           declare
                              Digit : constant Ty.Folded := Ty.Folded
                                (Character'Pos (Text (Position))
                                 - Character'Pos ('0'));
                           begin
                              if Parsed > (Ty.Folded'Last - Digit) / 10 then
                                 Valid := False;
                                 exit;
                              end if;
                              Parsed := Parsed * 10 + Digit;
                           end;
                        end loop;
                        Value := (Kind => Number, Integer_Value =>
                          (if Negative then -Parsed else Parsed));
                     end if;
                     if not Valid then
                        Report_Type
                          (Of_Tree.all, Setting.Node,
                           "option `" & Spelled (Setting.Name)
                             & "`: --option=" & Spelled (Setting.Name)
                             & "=" & Text & " is not a typed literal for "
                             & Ty.Spelling (Kind),
                           Related_Node => Syn.Declared_Type
                             (Of_Tree.all, Setting.Node),
                           Because => "the declared option type",
                           Note => "[1530]/D202: overrides use true or false"
                             & " for bool, or optional minus and decimal"
                             & " digits for an integer");
                        Value := (Kind => Bad_Value);
                     elsif not Fits_Type (Value, Text) then
                        Value := (Kind => Bad_Value);
                     end if;
                  end;
               end if;
            end loop;
         end if;
         Setting.State := Evaluated;
         Setting.Value := Value;
         Options.Replace_Element (Index, Setting);
         return Value;
      end Evaluate_Option;

      --  D542/D543: the one description the program reaches, its module,
      --  where each of its directives stands, and the profile it builds.
      type Site is record
         Source : Landin.Source.Source_Id := Landin.Source.No_Source;
         Node : Syn.Node_Id := Syn.No_Node;
      end record;
      No_Site : constant Site := (others => <>);
      type Interrupt_Entry is record
         Name : Ada.Strings.Unbounded.Unbounded_String;
         IRQ : Natural := 0;
         At_Site : Site;
      end record;
      package Interrupt_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Interrupt_Entry);
      type Region_Sites is array (Firmware.Region_Index) of Site;
      type Place_Sites is array (Firmware.Section_Kind) of Site;
      type Place_Names is array (Firmware.Section_Kind)
        of Ada.Strings.Unbounded.Unbounded_String;
      Described : Landin.Modules.Module_Id := Landin.Modules.No_Module;
      Device_Site, Core_Site, Vectors_Site, Boot_Site : Site;
      --  D615: the description's compiler.float_unit, if any.
      Float_Site : Site;
      --  D683: the description's compiler.esp_image, if any.
      ESP_Site : Site;
      --  D587: the description's `link(boot_stage)` routine, if any.
      Stage_Site : Site;
      Regions_At : Region_Sites := [others => No_Site];
      Placed_At : Place_Sites := [others => No_Site];
      Placed_Names : Place_Names;
      Interrupts : Interrupt_Vectors.Vector;
      Built : Firmware.Profile;
      Arm_Depth : Natural := 0;
      --  A directive refused for its own arguments leaves the description
      --  short of it; Finish_Profile does not report that again.
      Description_Refused : Boolean := False;

      function Module_For
        (Source : Landin.Source.Source_Id) return Landin.Modules.Module_Id
        is (if Natural (Source) <= Landin.Modules.Source_Count
              (Landin.Stages.Modules (Context).all)
            then Landin.Modules.Module_Of
              (Landin.Stages.Modules (Context).all, Source)
            else Landin.Modules.Entry_Module);

      function Description_Directive
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      function Description_Directive
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
         Callee : Syn.Node_Id;
      begin
         if Syn.Kind (Of_Tree, Node) /= Syn.Tool_Directive then
            return False;
         end if;
         Callee := Syn.Callee_Of (Of_Tree, Syn.Directive_Call (Of_Tree, Node));
         return Landin.Configuration.Is_Description_Member
           (Spelled (Syn.Name (Of_Tree, Syn.Target_Of (Of_Tree, Callee))),
            Spelled (Syn.Name (Of_Tree, Callee)));
      end Description_Directive;

      function Names_Device
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
        is (Description_Directive (Of_Tree, Node)
            and then Spelled (Syn.Name (Of_Tree, Syn.Callee_Of
              (Of_Tree, Syn.Directive_Call (Of_Tree, Node)))) = "device");

      procedure Report_At
        (Item : Bad.Failure; At_Site : Site; Message, Note : String;
         Related : Site := No_Site; Because : String := "");
      procedure Report_At
        (Item : Bad.Failure; At_Site : Site; Message, Note : String;
         Related : Site := No_Site; Because : String := "")
      is
         Of_Tree : constant not null access constant Syn.Tree :=
           Landin.Syntax.Forest.Tree_Of (Trees.all, At_Site.Source);
      begin
         --  L0513 and L0514 point at one place; the one already written
         --  is named in the message (D543).
         Bad.Report
           (Item => Item, Source => At_Site.Source,
            Where => Syn.Where (Of_Tree.all, At_Site.Node),
            Message => Message
              & (if Related.Source = Landin.Source.No_Source then ""
                 else "; " & Because & " is at "
                   & Landin.Source.Name (Source (Context, Related.Source))
                   & ":" & Ada.Strings.Fixed.Trim
                     (Landin.Source.Position_Of
                        (Source (Context, Related.Source),
                         Syn.Where (Landin.Syntax.Forest.Tree_Of
                           (Trees.all, Related.Source).all,
                          Related.Node).First).Line'Image,
                      Ada.Strings.Both)),
            Note => Note, Into => Found);
      end Report_At;

      --  A description directive is unconditional, in an active arm or
      --  not, as an option is (D202).
      procedure Refuse_In_Arms (Of_Tree : Syn.Tree; Node : Syn.Node_Id);
      procedure Refuse_In_Arms (Of_Tree : Syn.Tree; Node : Syn.Node_Id) is
      begin
         if Syn.Kind (Of_Tree, Node) /= Syn.Fixed_Conditional then
            return;
         end if;
         for Index in 1 .. Syn.Fixed_Arm_Count (Of_Tree, Node) loop
            declare
               Arm : constant Syn.Node_Id :=
                 Syn.Nth_Fixed_Arm (Of_Tree, Node, Index);
            begin
               for Which in 1 .. Syn.Fixed_Declaration_Count (Of_Tree, Arm)
               loop
                  declare
                     Inner : constant Syn.Node_Id :=
                       Syn.Nth_Fixed_Declaration (Of_Tree, Arm, Which);
                  begin
                     if Description_Directive (Of_Tree, Inner) then
                        Report_At
                          (Bad.Description_Structure,
                           (Syn.Source_Of (Of_Tree), Inner),
                           "a device description's directive is"
                           & " unconditional",
                           "D543: a description is selected by import, not"
                           & " by a fixed arm; import a different"
                           & " description instead");
                     else
                        Refuse_In_Arms (Of_Tree, Inner);
                     end if;
                  end;
               end loop;
            end;
         end loop;
      end Refuse_In_Arms;

      --  D587: whether NODE is written `link(boot_stage)`.
      function Marks_Boot_Stage
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
        is (Syn.Kind (Of_Tree, Node) in Syn.Function_Declaration
              | Syn.Binding
            and then Syn.Attributes (Of_Tree, Node).Boot_Stage);

      --  Which module is the description, refusing a second one and
      --  whatever else a description module holds.
      procedure Find_Description;
      procedure Find_Description is
         First_Device : Site;
      begin
         for Index in 1 .. Source_Count (Context) loop
            declare
               Id : constant Landin.Source.Source_Id :=
                 Nth_Source (Context, Index);
               Of_Tree : constant not null access constant Syn.Tree :=
                 Landin.Syntax.Forest.Tree_Of (Trees.all, Id);
            begin
               for Which in 1 .. Syn.Declaration_Count (Of_Tree.all) loop
                  declare
                     Node : constant Syn.Node_Id :=
                       Syn.Nth_Declaration (Of_Tree.all, Which);
                  begin
                     if Names_Device (Of_Tree.all, Node) then
                        if Described = Landin.Modules.No_Module then
                           Described := Module_For (Id);
                           First_Device := (Id, Node);
                        elsif Module_For (Id) /= Described then
                           Report_At
                             (Bad.Description_Structure, (Id, Node),
                              "this program reaches a second device"
                              & " description, "
                              & Landin.Modules.Logical_Path
                                  (Landin.Stages.Modules (Context).all,
                                   Module_For (Id)),
                              "D543: a program is built for one device;"
                              & " import one description, directly or"
                              & " through another module",
                              Related => First_Device,
                              Because => "the description it already"
                                & " reaches");
                        end if;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         for Index in 1 .. Source_Count (Context) loop
            declare
               Of_Tree : constant not null access constant Syn.Tree :=
                 Landin.Syntax.Forest.Tree_Of
                   (Trees.all, Nth_Source (Context, Index));
            begin
               for Which in 1 .. Syn.Declaration_Count (Of_Tree.all) loop
                  exit when Described /= Landin.Modules.No_Module
                    and then Module_For (Nth_Source (Context, Index))
                      = Described;
                  Refuse_In_Arms
                    (Of_Tree.all, Syn.Nth_Declaration (Of_Tree.all, Which));
               end loop;
            end;
         end loop;
         if Described = Landin.Modules.No_Module then
            return;
         end if;
         for Index in 1 .. Source_Count (Context) loop
            declare
               Id : constant Landin.Source.Source_Id :=
                 Nth_Source (Context, Index);
               Of_Tree : constant not null access constant Syn.Tree :=
                 Landin.Syntax.Forest.Tree_Of (Trees.all, Id);
            begin
               if Module_For (Id) = Described then
                  for Which in 1 .. Syn.Import_Count (Of_Tree.all) loop
                     Report_At
                       (Bad.Description_Structure,
                        (Id, Syn.Nth_Import (Of_Tree.all, Which)),
                        "a device description imports nothing",
                        "D542: a description is made only of its"
                        & " directives; import it from the program instead");
                  end loop;
                  for Which in 1 .. Syn.Declaration_Count (Of_Tree.all) loop
                     declare
                        Node : constant Syn.Node_Id :=
                          Syn.Nth_Declaration (Of_Tree.all, Which);
                     begin
                        if not Description_Directive (Of_Tree.all, Node)
                          and then not Marks_Boot_Stage (Of_Tree.all, Node)
                        then
                           Report_At
                             (Bad.Description_Structure, (Id, Node),
                              "a device description holds only its"
                              & " directives, unconditionally, and its boot"
                              & " stage",
                              "D542/D587: a description is compiler.device,"
                              & " compiler.core, compiler.vectors,"
                              & " compiler.interrupt, compiler.boot,"
                              & " compiler.float_unit,"
                              & " linker.region and linker.place, and at"
                              & " most one link(boot_stage) naked routine;"
                              & " move this declaration to another module");
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;
      end Find_Description;

      --  D587: every `link(boot_stage)` the program holds is one naked
      --  routine with no other placement, in the description's own module,
      --  and there is at most one.  An arm of the description is refused
      --  whole by Find_Description, so a stage inside one is not counted.
      procedure Find_Boot_Stages;
      procedure Find_Boot_Stages is
         procedure Scan
           (Id : Landin.Source.Source_Id; Of_Tree : Syn.Tree;
            Node : Syn.Node_Id; Nested : Boolean);
         procedure Scan
           (Id : Landin.Source.Source_Id; Of_Tree : Syn.Tree;
            Node : Syn.Node_Id; Nested : Boolean)
         is
            Here : constant Site := (Id, Node);
            In_Description : constant Boolean :=
              Described /= Landin.Modules.No_Module
              and then Module_For (Id) = Described;
         begin
            if Syn.Kind (Of_Tree, Node) = Syn.Fixed_Conditional then
               for Index in 1 .. Syn.Fixed_Arm_Count (Of_Tree, Node) loop
                  declare
                     Arm : constant Syn.Node_Id :=
                       Syn.Nth_Fixed_Arm (Of_Tree, Node, Index);
                  begin
                     for Which in 1 .. Syn.Fixed_Declaration_Count
                       (Of_Tree, Arm)
                     loop
                        Scan (Id, Of_Tree, Syn.Nth_Fixed_Declaration
                          (Of_Tree, Arm, Which), Nested => True);
                     end loop;
                  end;
               end loop;
               return;
            elsif not Marks_Boot_Stage (Of_Tree, Node)
              or else (Nested and then In_Description)
            then
               return;
            end if;
            declare
               use type Landin.Source.Span;
               Attr : constant Syn.Machine_Attributes :=
                 Syn.Attributes (Of_Tree, Node);
               Reference : constant String :=
                 Firmware.Reference_Module (Target (Context));
               --  Whether the program imports a description of its own,
               --  rather than being given the library's reference.
               Imported : constant Boolean :=
                 Described /= Landin.Modules.No_Module
                 and then Landin.Modules.Logical_Path
                   (Landin.Stages.Modules (Context).all, Described)
                   /= Reference;
               Naked : constant Boolean :=
                 Syn.Kind (Of_Tree, Node) = Syn.Function_Declaration
                 and then Syn.Machine_Convention (Of_Tree, Node)
                   = Landin.Machine.Naked_Routine;
            begin
               if not Naked then
                  Report_At
                    (Bad.Boot_Stage_Form, Here,
                     "link(boot_stage) marks a naked routine, and this is "
                     & (if Syn.Kind (Of_Tree, Node) = Syn.Binding
                        then "a module binding"
                        elsif Syn.Machine_Convention (Of_Tree, Node)
                          = Landin.Machine.Interrupt_Handler
                        then "an interrupt handler"
                        else "an ordinary routine"),
                     "D587: a boot stage is `link(boot_stage)"
                     & " extern(naked) NAME: () -> none`, whose body is the"
                     & " one assembler.block the boot ROM enters");
               elsif Attr.Section /= Landin.Source.Empty_Span
                 or else Attr.Alignment /= Landin.Source.Empty_Span
                 or else Attr.Vector /= Landin.Source.Empty_Span
                 or else Attr.Region /= Landin.Source.Empty_Span
                 or else Attr.Keep or else Attr.Thread
                 or else Syn.Link_Symbol_Span (Of_Tree, Node)
                   /= Landin.Source.Empty_Span
               then
                  Report_At
                    (Bad.Boot_Stage_Form, Here,
                     "a boot stage takes no other link attribute",
                     "D587: the boot kind places its stage at the start of"
                     & " its slot, so it has no section, symbol, region,"
                     & " vector, alignment, keep or thread; write"
                     & " link(boot_stage) alone");
               end if;
               if not In_Description then
                  Report_At
                    (Bad.Boot_Stage_Outside, Here,
                     (if not Imported
                      then "a boot stage belongs in a device description,"
                        & " and this program imports none"
                      else "a boot stage belongs in the device description,"
                        & " "
                        & Landin.Modules.Logical_Path
                            (Landin.Stages.Modules (Context).all, Described)
                        & ", not in "
                        & Landin.Modules.Logical_Path
                            (Landin.Stages.Modules (Context).all,
                             Module_For (Id))),
                     "D587: the second stage is the device's, so it is"
                     & " declared in the description's module beside"
                     & " compiler.boot; move it there",
                     Related => (if Imported then Device_Site
                                 else No_Site),
                     Because => "the description's device");
               elsif Stage_Site /= No_Site then
                  Report_At
                    (Bad.Boot_Stage_Repeated, Here,
                     "this description holds a second boot stage",
                     "D587: the boot kind's slot holds one stage; remove"
                     & " one of them",
                     Related => Stage_Site, Because => "the first");
               else
                  Stage_Site := Here;
               end if;
            end;
         end Scan;
      begin
         for Index in 1 .. Source_Count (Context) loop
            declare
               Id : constant Landin.Source.Source_Id :=
                 Nth_Source (Context, Index);
               Of_Tree : constant not null access constant Syn.Tree :=
                 Landin.Syntax.Forest.Tree_Of (Trees.all, Id);
            begin
               for Which in 1 .. Syn.Declaration_Count (Of_Tree.all) loop
                  Scan (Id, Of_Tree.all,
                        Syn.Nth_Declaration (Of_Tree.all, Which),
                        Nested => False);
               end loop;
            end;
         end loop;
      end Find_Boot_Stages;

      --  D653: a stage the reset vector enters before compiler-owned
      --  reset runs on the stack pointer the core loaded and may not use
      --  the stack, and it ends by branching to the compiler's reset, which
      --  it names.  Its text is read only when it has the shape [1570]
      --  requires, one assembler.block of a literal, which checking holds.
      function Reset_Stage_Holds return Boolean;
      function Reset_Stage_Holds return Boolean is
         Of_Tree : constant not null access constant Syn.Tree :=
           Landin.Syntax.Forest.Tree_Of (Trees.all, Stage_Site.Source);
         Node : constant Syn.Node_Id := Stage_Site.Node;
         Body_Node, Statement, Argument : Syn.Node_Id;
      begin
         if Syn.Kind (Of_Tree.all, Node) /= Syn.Function_Declaration then
            return True;
         end if;
         Body_Node := Syn.Body_Of (Of_Tree.all, Node);
         if Syn.Kind (Of_Tree.all, Body_Node) /= Syn.Block
           or else Syn.Statement_Count (Of_Tree.all, Body_Node) /= 1
         then
            return True;
         end if;
         Statement := Syn.Nth_Statement (Of_Tree.all, Body_Node, 1);
         if Syn.Kind (Of_Tree.all, Statement) /= Syn.Call
           or else Syn.Argument_Count (Of_Tree.all, Statement) /= 1
         then
            return True;
         end if;
         Argument := Syn.Nth_Argument (Of_Tree.all, Statement, 1);
         if Syn.Kind (Of_Tree.all, Argument)
           not in Syn.Text_Literal | Syn.Raw_Literal
         then
            return True;
         end if;
         declare
            RV32 : constant Boolean :=
              Landin.Targets.Architecture_Of (Target (Context))
                = Landin.Targets.RV32;
            Xtensa : constant Boolean :=
              Landin.Targets.Architecture_Of (Target (Context))
                = Landin.Targets.Xtensa;
            Lines : constant String :=
              Landin.Targets.Assembly.Uncommented
                (Landin.Targets.Architecture_Of (Target (Context)),
                 Landin.Configuration.Fixed_Text
                   (Source (Context, Syn.Source_Of (Of_Tree.all)),
                    Of_Tree.all, Argument));
            Stack_Word : Ada.Strings.Unbounded.Unbounded_String;
            Names_Reset : Boolean := False;
            Cursor : Natural := Lines'First;
         begin
            while Cursor <= Lines'Last loop
               if Lines (Cursor) in 'a' .. 'z' | 'A' .. 'Z' | '_' then
                  declare
                     First : constant Natural := Cursor;
                  begin
                     while Cursor <= Lines'Last and then Lines (Cursor) in
                       'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_'
                     loop
                        Cursor := Cursor + 1;
                     end loop;
                     declare
                        Word : constant String := Lines (First .. Cursor - 1);
                        Lower : String := Word;
                     begin
                        for C of Lower loop
                           if C in 'A' .. 'Z' then
                              C := Character'Val (Character'Pos (C) + 32);
                           end if;
                        end loop;
                        if Word = Firmware.Reset_Symbol then
                           Names_Reset := True;
                        elsif (if Xtensa then Lower in "a1" | "sp"
                               elsif RV32
                               then Lower in "sp" | "x2" | "lwsp" | "swsp"
                                 | "addi16sp" | "addi4spn"
                               else Lower in "push" | "pop" | "sp" | "r13"
                                 | "msp" | "psp")
                          and then Ada.Strings.Unbounded.Length (Stack_Word)
                            = 0
                        then
                           Stack_Word :=
                             Ada.Strings.Unbounded.To_Unbounded_String (Lower);
                        end if;
                     end;
                  end;
               else
                  Cursor := Cursor + 1;
               end if;
            end loop;
            if Ada.Strings.Unbounded.Length (Stack_Word) /= 0 then
               Report_At
                 (Bad.Reset_Stage_Stack, Stage_Site,
                  "this stage runs before reset and uses the stack, through "
                  & Ada.Strings.Unbounded.To_String (Stack_Word),
                  (if RV32
                   then "D653, D684: the entry word enters the stage before"
                     & " any memory may be written, before reset has set"
                     & " the stack pointer; keep what it needs in registers"
                   else "D653: a vector-table image's stage runs before any"
                     & " memory may be written, on the stack pointer the"
                     & " core loaded from the table; keep what it needs in"
                     & " registers"));
               return False;
            elsif not Names_Reset then
               Report_At
                 (Bad.Reset_Stage_Return, Stage_Site,
                  "this stage runs before reset and does not branch to "
                  & Firmware.Reset_Symbol,
                  (if RV32
                   then "D653, D684: the entry word enters the stage, and"
                     & " the stage ends in compiler-owned reset; finish it"
                     & " with j " & Firmware.Reset_Symbol
                   else "D653: the reset vector enters the stage, and the"
                     & " stage ends in compiler-owned reset; finish it with"
                     & " ldr r0, =" & Firmware.Reset_Symbol & " and bx r0"));
               return False;
            end if;
            return True;
         end;
      end Reset_Stage_Holds;

      --  A text argument, decoded as linker.library's is; "" refused.
      function Text_Argument
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return String;
      function Text_Argument
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return String is
      begin
         if Syn.Kind (Of_Tree, Node) /= Syn.Text_Literal then
            return "";
         end if;
         declare
            Text : constant String := Landin.Source.Slice
              (Source (Context, Syn.Source_Of (Of_Tree)),
               Syn.Where (Of_Tree, Node));
            Bytes : String (1 .. Text'Length);
            Length, Fault_First, Fault_Last : Natural;
            Fault : Landin.Tokens.Text.Problem;
         begin
            Landin.Tokens.Text.Decode
              (Text, Bytes, Length, Fault, Fault_First, Fault_Last);
            if Fault /= Landin.Tokens.Text.Well_Formed then
               return "";
            end if;
            return Bytes (1 .. Length);
         end;
      end Text_Argument;

      --  A fixed integer argument in D202's fold, or -1 when it is none
      --  or lies outside a 32-bit address space.
      function Integer_Argument
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Folded;
      function Integer_Argument
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Folded
      is
         Value : Fixed_Value;
      begin
         if not Validate (Of_Tree, Node) then
            Description_Refused := True;
            return -2;
         end if;
         Value := Evaluate (Of_Tree, Node);
         if Value.Kind = Bad_Value then
            Description_Refused := True;
            return -2;
         elsif Value.Kind /= Number
           or else Value.Integer_Value < 0
           or else Value.Integer_Value > 2 ** 32
         then
            return -1;
         end if;
         return Value.Integer_Value;
      end Integer_Argument;

      function Name_Form (Text : String; Capacity : Positive)
        return Boolean
        is (Text'Length in 1 .. Capacity
            and then Text (Text'First) in 'a' .. 'z' | 'A' .. 'Z'
            and then (for all C of Text =>
                        C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_'));

      --  D542: one description directive, recorded once its arguments are
      --  the forms its row says.  What it means beside the others is
      --  Finish_Profile's.
      --  D615: the float unit the description names, for the feature
      --  facts, before any fixed expression is read.  Configure_Description
      --  refuses a name that is no unit; this reads only one that is.
      procedure Read_Float_Unit;
      procedure Read_Float_Unit is
      begin
         if Described = Landin.Modules.No_Module then
            return;
         end if;
         for Index in 1 .. Source_Count (Context) loop
            declare
               Id : constant Landin.Source.Source_Id :=
                 Nth_Source (Context, Index);
               Of_Tree : constant not null access constant Syn.Tree :=
                 Landin.Syntax.Forest.Tree_Of (Trees.all, Id);
            begin
               if Module_For (Id) = Described then
                  for Which in 1 .. Syn.Declaration_Count (Of_Tree.all) loop
                     declare
                        Node : constant Syn.Node_Id :=
                          Syn.Nth_Declaration (Of_Tree.all, Which);
                        Call, Callee : Syn.Node_Id;
                     begin
                        if Description_Directive (Of_Tree.all, Node) then
                           Call := Syn.Directive_Call (Of_Tree.all, Node);
                           Callee := Syn.Callee_Of (Of_Tree.all, Call);
                           if Spelled (Syn.Name (Of_Tree.all, Callee))
                               = "float_unit"
                             and then Syn.Argument_Count (Of_Tree.all, Call)
                               = 1
                             and then Firmware.Is_Float_Unit_Name
                               (Text_Argument (Of_Tree.all, Syn.Nth_Argument
                                  (Of_Tree.all, Call, 1)))
                           then
                              Float_Facts := Firmware.Float_Unit_Named
                                (Text_Argument (Of_Tree.all, Syn.Nth_Argument
                                   (Of_Tree.all, Call, 1)));
                           end if;
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;
      end Read_Float_Unit;

      procedure Configure_Description
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);
      procedure Configure_Description
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Call : constant Syn.Node_Id := Syn.Directive_Call (Of_Tree, Node);
         Callee : constant Syn.Node_Id := Syn.Callee_Of (Of_Tree, Call);
         Base : constant String :=
           Spelled (Syn.Name (Of_Tree, Syn.Target_Of (Of_Tree, Callee)));
         Member : constant String := Spelled (Syn.Name (Of_Tree, Callee));
         Directive : constant String := Base & "." & Member;
         Here : constant Site := (Syn.Source_Of (Of_Tree), Node);
         Count : constant Natural := Syn.Argument_Count (Of_Tree, Call);
         Shape : constant String :=
           (if Member = "device" then "(""name"")"
            elsif Member = "core" then "(""cortex-m0plus"")"
            elsif Member = "vectors" then "(count)"
            elsif Member = "interrupt" then "(""NAME"", irq)"
            elsif Member = "boot" then "(""vector-table"")"
            elsif Member = "float_unit" then "(""fpv5-d16"")"
            elsif Member = "esp_image"
            then "(chip, min_revision, max_revision, flash_offset)"
            elsif Member = "region"
            then "(""NAME"", origin, length, ""rx"")"
            else "(""text"", ""REGION"")");

         function Argument (Position : Positive) return Syn.Node_Id
           is (Syn.Nth_Argument (Of_Tree, Call, Position));

         procedure Refuse (At_Node : Syn.Node_Id; Message, Note : String);
         procedure Refuse (At_Node : Syn.Node_Id; Message, Note : String) is
         begin
            Description_Refused := True;
            Report_Configuration_Rule
              (Bad.Invalid_Description_Directive, Of_Tree, At_Node,
               Message, "D542: " & Note);
         end Refuse;

         procedure Repeated (First : Site);
         procedure Repeated (First : Site) is
         begin
            Report_At
              (Bad.Description_Structure, Here,
               "this description says " & Directive & " twice",
               "D543: a description names its " & Member & " once;"
               & " remove one of them",
               Related => First, Because => "the one it already has");
         end Repeated;

         Lowest, Highest : Natural;
      begin
         if Arm_Depth > 0 then
            --  Gather_Options has refused it, active or not.
            return;
         elsif Module_For (Here.Source) /= Described then
            Report_At
              (Bad.Description_Structure, Here,
               Directive & " is a device description's directive, and this"
               & " module names no device",
               "D542: a description is the module that holds"
               & " compiler.device(""NAME""); write this beside it");
            return;
         end if;
         if Member = "interrupt" then
            Lowest := 2;
            Highest := 2;
         elsif Member = "region" then
            Lowest := 4;
            Highest := 4;
         elsif Member = "place" then
            Lowest := 2;
            Highest := 3;
         elsif Member = "esp_image" then
            Lowest := 4;
            Highest := 4;
         else
            Lowest := 1;
            Highest := 1;
         end if;
         if Count not in Lowest .. Highest then
            Description_Refused := True;
            Report_Configuration_Rule
              (Bad.Invalid_Description_Directive, Of_Tree, Node,
               Directive & " takes "
               & (if Lowest = Highest
                  then Ada.Strings.Fixed.Trim (Lowest'Image, Ada.Strings.Both)
                  else Ada.Strings.Fixed.Trim (Lowest'Image, Ada.Strings.Both)
                    & " or "
                    & Ada.Strings.Fixed.Trim (Highest'Image, Ada.Strings.Both))
               & (if Highest = 1 then " argument" else " arguments")
               & ", and this has"
               & (if Count = 0 then " none"
                  else Natural'Image (Count)),
               "D542: write it as " & Directive & Shape);
            return;
         end if;

         if Member = "device" then
            declare
               Name : constant String := Text_Argument (Of_Tree, Argument (1));
            begin
               if Name'Length not in 1 .. 32
                 or else Name (Name'First) not in 'a' .. 'z'
                 or else (for some C of Name =>
                            C not in 'a' .. 'z' | '0' .. '9' | '-')
               then
                  Refuse (Argument (1), "a device is named by a quoted"
                    & " lowercase identity",
                    "compiler.device takes lowercase ASCII letters, digits"
                    & " and hyphens, beginning with a letter and at most 32"
                    & " bytes, such as compiler.device(""rp2040"")");
               elsif Device_Site /= No_Site then
                  Repeated (Device_Site);
               else
                  Device_Site := Here;
                  Built.Device := Firmware.To_Name (Name);
               end if;
            end;
         elsif Member = "core" then
            declare
               Name : constant String := Text_Argument (Of_Tree, Argument (1));
            begin
               if not Firmware.Is_Core_Name (Name) then
                  Refuse (Argument (1), "this is not a core refine builds"
                    & " for",
                    "compiler.core names " & Firmware.Core_Names);
               elsif Core_Site /= No_Site then
                  Repeated (Core_Site);
               else
                  Core_Site := Here;
                  Built.Core := Firmware.Core_Named (Name);
               end if;
            end;
         elsif Member = "float_unit" then
            declare
               Name : constant String := Text_Argument (Of_Tree, Argument (1));
            begin
               if not Firmware.Is_Float_Unit_Name (Name) then
                  Description_Refused := True;
                  Report_Configuration_Rule
                    (Bad.Float_Unit_Unsupported, Of_Tree, Argument (1),
                     "this is not a float unit refine builds",
                     "D615: refine builds ""fpv5-d16"", the Cortex-M7's"
                     & " single- and double-precision unit, on a cortex-m7;"
                     & " write compiler.float_unit(""fpv5-d16""), or leave"
                     & " the directive out for a core with no float unit");
               elsif Float_Site /= No_Site then
                  Repeated (Float_Site);
               else
                  Float_Site := Here;
                  Built.Float := Firmware.Float_Unit_Named (Name);
               end if;
            end;
         elsif Member = "vectors" then
            declare
               Value : constant Ty.Folded :=
                 Integer_Argument (Of_Tree, Argument (1));
            begin
               if Value = -2 then
                  null;
               elsif Value < 16 or else Value > Firmware.Slot_Capacity then
                  Refuse (Argument (1), "a vector table holds 16 to 512"
                    & " words",
                    "compiler.vectors counts the whole table, the initial"
                    & " SP, reset and the core's exceptions included, so"
                    & " it is 16 plus the external interrupts");
               elsif Vectors_Site /= No_Site then
                  Repeated (Vectors_Site);
               else
                  Vectors_Site := Here;
                  Built.Vector_Count := Natural (Value);
               end if;
            end;
         elsif Member = "interrupt" then
            declare
               Name : constant String := Text_Argument (Of_Tree, Argument (1));
               Value : constant Ty.Folded :=
                 Integer_Argument (Of_Tree, Argument (2));
            begin
               if not Name_Form (Name, 64) then
                  Refuse (Argument (1), "an interrupt is named by a quoted"
                    & " identifier",
                    "compiler.interrupt's name is an ASCII letter, then"
                    & " letters, digits and underscores, at most 64 bytes,"
                    & " as the SVD names it");
               elsif Value = -2 then
                  null;
               elsif Value < 0 or else Value > Firmware.Slot_Capacity - 17
               then
                  Refuse (Argument (2), "an external interrupt number is 0"
                    & " to 495",
                    "compiler.interrupt takes the IRQ number, and its"
                    & " vector slot is 16 plus that number");
               else
                  for Prior of Interrupts loop
                     if Ada.Strings.Unbounded.To_String (Prior.Name) = Name
                       or else Prior.IRQ = Natural (Value)
                     then
                        Report_At
                          (Bad.Description_Structure, Here,
                           (if Prior.IRQ = Natural (Value)
                            then "IRQ" & Natural'Image (Prior.IRQ)
                              & " is already named "
                              & Ada.Strings.Unbounded.To_String (Prior.Name)
                            else "interrupt " & Name
                              & " is already IRQ"
                              & Natural'Image (Prior.IRQ)),
                           "D543: each interrupt has one name and one"
                           & " number; remove one of them",
                           Related => Prior.At_Site,
                           Because => "the one it already has");
                        return;
                     end if;
                  end loop;
                  Interrupts.Append
                    (Interrupt_Entry'
                       (Ada.Strings.Unbounded.To_Unbounded_String (Name),
                        Natural (Value), Here));
               end if;
            end;
         elsif Member = "boot" then
            declare
               Name : constant String := Text_Argument (Of_Tree, Argument (1));
            begin
               if not Firmware.Is_Boot_Name (Name) then
                  Refuse (Argument (1), "this is not a boot image kind",
                    "compiler.boot names ""vector-table"","
                    & " ""rp2040-boot2"", ""rp2350-image-block"" or"
                    & " ""esp-app-image""");
               elsif Boot_Site /= No_Site then
                  Repeated (Boot_Site);
               else
                  Boot_Site := Here;
                  Built.Boot := Firmware.Boot_Named (Name);
               end if;
            end;
         elsif Member = "esp_image" then
            declare
               Chip : constant Ty.Folded :=
                 Integer_Argument (Of_Tree, Argument (1));
               Minimum : constant Ty.Folded :=
                 Integer_Argument (Of_Tree, Argument (2));
               Maximum : constant Ty.Folded :=
                 Integer_Argument (Of_Tree, Argument (3));
               Offset : constant Ty.Folded :=
                 Integer_Argument (Of_Tree, Argument (4));
            begin
               if Chip = -2 or else Minimum = -2 or else Maximum = -2
                 or else Offset = -2
               then
                  null;
               elsif Chip not in 0 .. Ty.Folded (Firmware.ESP_Number'Last)
               then
                  Refuse (Argument (1), "an ESP chip id is 0 to 65535",
                    "compiler.esp_image's first argument is the image"
                    & " header's chip id, which ESP-IDF's esp_chip_id_t"
                    & " gives: 5 for the ESP32-C3");
               elsif Minimum
                 not in 0 .. Ty.Folded (Firmware.ESP_Number'Last)
               then
                  Refuse (Argument (2), "a chip revision is 0 to 65535",
                    "compiler.esp_image's revisions are major * 100 +"
                    & " minor, as ESP-IDF's min_chip_rev_full is: 3 is"
                    & " v0.3");
               elsif Maximum < Minimum
                 or else Maximum > Ty.Folded (Firmware.ESP_Number'Last)
               then
                  Refuse (Argument (3), "the maximum revision is below the"
                    & " minimum or above 65535",
                    "compiler.esp_image's revisions are major * 100 +"
                    & " minor, the minimum first: 199 is v1.99");
               elsif Offset < 0 or else Offset >= 2 ** 32
                 or else Offset mod Firmware.ESP_Offset_Alignment /= 0
               then
                  Refuse (Argument (4), "the flash offset is not a multiple"
                    & " of 4096 in the 32-bit address space",
                    "compiler.esp_image's last argument is where the ROM"
                    & " reads the image in flash: 0x0 on the ESP32-C3,"
                    & " 0x2000 on the ESP32-C5");
               elsif ESP_Site /= No_Site then
                  Repeated (ESP_Site);
               else
                  ESP_Site := Here;
                  Built.ESP_Chip := Firmware.ESP_Number (Chip);
                  Built.ESP_Minimum := Firmware.ESP_Number (Minimum);
                  Built.ESP_Maximum := Firmware.ESP_Number (Maximum);
                  Built.ESP_Offset := Landin.Targets.Byte_Count (Offset);
               end if;
            end;
         elsif Member = "region" then
            declare
               Name : constant String := Text_Argument (Of_Tree, Argument (1));
               Origin : constant Ty.Folded :=
                 Integer_Argument (Of_Tree, Argument (2));
               Length : constant Ty.Folded :=
                 Integer_Argument (Of_Tree, Argument (3));
               Mode : constant String := Text_Argument (Of_Tree, Argument (4));
            begin
               if not Name_Form (Name, 32) then
                  Refuse (Argument (1), "a region is named by a quoted"
                    & " identifier",
                    "linker.region's name is an ASCII letter, then letters,"
                    & " digits and underscores, at most 32 bytes, such as"
                    & " ""FLASH""");
               elsif Origin = -2 or else Length = -2 then
                  null;
               elsif Origin < 0 or else Origin >= 2 ** 32 then
                  Refuse (Argument (2), "a region's origin is an address in"
                    & " the 32-bit address space",
                    "linker.region takes its origin and length in bytes");
               elsif Length <= 0 or else Origin + Length > 2 ** 32 then
                  Refuse (Argument (3), "a region's length is at least one"
                    & " byte and ends inside the 32-bit address space",
                    "linker.region takes its origin and length in bytes");
               elsif not Firmware.Is_Access_Name (Mode) then
                  Refuse (Argument (4), "a region's access is ""rx"","
                    & " ""rw"" or ""rwx""",
                    "linker.region's last argument says whether code may"
                    & " run in it and data be written to it");
               elsif Built.Count = Firmware.Region_Capacity then
                  Refuse (Node, "a description has at most 16 regions",
                    "merge adjacent regions of the same access");
               else
                  for Index in 1 .. Built.Count loop
                     if Firmware.Spelling (Built.Regions (Index).Name) = Name
                     then
                        Report_At
                          (Bad.Description_Structure, Here,
                           "this description already has a region named "
                           & Name,
                           "D543: each region has its own name; rename or"
                           & " remove one of them",
                           Related => Regions_At (Index),
                           Because => "the region of that name");
                        return;
                     end if;
                  end loop;
                  Built.Count := Built.Count + 1;
                  Built.Regions (Built.Count) :=
                    (Name => Firmware.To_Name (Name),
                     Origin => Landin.Targets.Byte_Count (Origin),
                     Length => Landin.Targets.Byte_Count (Length),
                     Mode => Firmware.Access_Named (Mode));
                  Regions_At (Built.Count) := Here;
               end if;
            end;
         else
            declare
               Kind : constant String := Text_Argument (Of_Tree, Argument (1));
               Region : constant String :=
                 Text_Argument (Of_Tree, Argument (2));
               Size : Ty.Folded := 0;
            begin
               if not Firmware.Is_Section_Name (Kind) then
                  Refuse (Argument (1), "this is not a part of the image a"
                    & " description places",
                    "linker.place places ""vectors"", ""text"", ""rodata"","
                    & " ""data"", ""bss"" or ""stack""");
                  return;
               elsif not Name_Form (Region, 32) then
                  Refuse (Argument (2), "a placement names its region in"
                    & " quotes",
                    "linker.place's second argument is the name of one of"
                    & " this description's linker.region directives");
                  return;
               end if;
               declare
                  Section : constant Firmware.Section_Kind :=
                    Firmware.Section_Named (Kind);
                  use type Firmware.Section_Kind;
               begin
                  if Section = Firmware.Stack and then Count /= 3 then
                     Refuse (Node, "the stack's placement gives its size",
                       "write linker.place(""stack"", """ & Region
                       & """, SIZE), SIZE being the bytes reserved at the"
                       & " top of the region");
                     return;
                  elsif Section /= Firmware.Stack and then Count = 3 then
                     Refuse (Argument (3), "only the stack's placement"
                       & " takes a size",
                       "every other part of the image is as large as what"
                       & " the program places in it");
                     return;
                  elsif Count = 3 then
                     Size := Integer_Argument (Of_Tree, Argument (3));
                     if Size = -2 then
                        return;
                     elsif Size <= 0
                       or else Size mod Ty.Folded
                         (Landin.Targets.Stack_Alignment (Target (Context)))
                         /= 0
                     then
                        --  D660: RV32 keeps the psABI's sixteen.
                        Refuse (Argument (3), "a stack is a positive"
                          & " multiple of"
                          & Landin.Targets.Byte_Alignment'Image
                              (Landin.Targets.Stack_Alignment
                                 (Target (Context)))
                          & " bytes",
                          (if Landin.Targets.Architecture_Of
                                (Target (Context))
                                  in Landin.Targets.RV32
                                    | Landin.Targets.Xtensa
                           then "the stack's top stays aligned to sixteen"
                             & " bytes, as the target ABI requires"
                           else "the stack's top stays aligned to eight"
                             & " bytes, as the AAPCS requires at a call"));
                        return;
                     end if;
                  end if;
                  if Placed_At (Section) /= No_Site then
                     Report_At
                       (Bad.Description_Structure, Here,
                        "this description places " & Kind & " twice",
                        "D543: each part of the image is placed once;"
                        & " remove one of them",
                        Related => Placed_At (Section),
                        Because => "the placement it already has");
                     return;
                  end if;
                  Placed_At (Section) := Here;
                  Placed_Names (Section) :=
                    Ada.Strings.Unbounded.To_Unbounded_String (Region);
                  if Section = Firmware.Stack then
                     Built.Stack_Size := Landin.Targets.Byte_Count (Size);
                  end if;
               end;
            end;
         end if;
      end Configure_Description;

      --  D543: what a description must hold, how its parts fit, and that
      --  its core is the request's.  Run once every directive is read.
      procedure Finish_Profile;
      procedure Finish_Profile is
         use type Firmware.Section_Kind;
         use type Firmware.Float_Unit;
         use type Firmware.Layout_Kind;
         use type Landin.Targets.Byte_Count;
         Complete : Boolean := True;
         Logical : constant String :=
           (if Described = Landin.Modules.No_Module then ""
            else Landin.Modules.Logical_Path
              (Landin.Stages.Modules (Context).all, Described));

         procedure Missing (What, Write : String);
         procedure Missing (What, Write : String) is
         begin
            Complete := False;
            Report_At
              (Bad.Description_Structure, Device_Site,
               "this description names no " & What,
               "D543: a description holds one each of compiler.device,"
               & " compiler.core, compiler.vectors and compiler.boot, and"
               & " places every part of the image; add " & Write);
         end Missing;

         procedure Layout (At_Site : Site; Message, Note : String);
         procedure Layout (At_Site : Site; Message, Note : String) is
         begin
            Complete := False;
            Report_At
              (Bad.Description_Layout, At_Site, Message, "D543: " & Note);
         end Layout;
      begin
         if Described = Landin.Modules.No_Module
           or else Device_Site = No_Site
           or else Description_Refused
         then
            return;
         end if;
         Built.Reference :=
           Logical = Firmware.Reference_Module (Target (Context));
         if Core_Site = No_Site then
            Missing ("core", "compiler.core(""cortex-m0plus""), naming its"
              & " core");
         end if;
         if Vectors_Site = No_Site then
            Missing ("vector table", "compiler.vectors(COUNT), the table's"
              & " words");
         end if;
         if Boot_Site = No_Site then
            Missing ("boot image kind", "compiler.boot(""vector-table""),"
              & " or the kind its boot ROM reads");
         end if;
         for Section in Firmware.Section_Kind loop
            if Placed_At (Section) = No_Site then
               Missing ("place for " & Firmware.Spelling (Section),
                 "linker.place(""" & Firmware.Spelling (Section)
                 & """, ""REGION""" & (if Section = Firmware.Stack
                                      then ", SIZE)" else ")"));
            end if;
         end loop;
         if not Complete then
            return;
         end if;

         --  Regions do not overlap.
         for Later in 2 .. Built.Count loop
            for Earlier in 1 .. Later - 1 loop
               declare
                  A : Firmware.Region renames Built.Regions (Earlier);
                  B : Firmware.Region renames Built.Regions (Later);
               begin
                  if A.Origin < B.Origin + B.Length
                    and then B.Origin < A.Origin + A.Length
                  then
                     Complete := False;
                     Report_At
                       (Bad.Description_Layout, Regions_At (Later),
                        "region " & Firmware.Spelling (B.Name)
                        & " overlaps region " & Firmware.Spelling (A.Name),
                        "D543: no byte is in two regions; make one end"
                        & " where the next begins",
                        Related => Regions_At (Earlier),
                        Because => "the region it overlaps");
                  end if;
               end;
            end loop;
         end loop;

         --  Each placement names a region whose access fits it.
         for Section in Firmware.Section_Kind loop
            declare
               Name : constant String := Ada.Strings.Unbounded.To_String
                 (Placed_Names (Section));
               Index : constant Firmware.Region_Count :=
                 Firmware.Region_Named (Built, Name);
            begin
               if Index = 0 then
                  Layout (Placed_At (Section),
                    "this description has no region named " & Name,
                    "linker.place names one of the description's"
                    & " linker.region directives");
               elsif Section in Firmware.Vectors | Firmware.Text
                 and then not Firmware.Executable
                   (Built.Regions (Index).Mode)
               then
                  Layout (Placed_At (Section),
                    Firmware.Spelling (Section) & " needs a region code runs"
                    & " in, and " & Name & " is "
                    & Firmware.Spelling (Built.Regions (Index).Mode),
                    "place " & Firmware.Spelling (Section)
                    & " in an ""rx"" or ""rwx"" region");
               elsif Section in Firmware.Data | Firmware.BSS | Firmware.Stack
                 and then not Firmware.Writable (Built.Regions (Index).Mode)
               then
                  Layout (Placed_At (Section),
                    Firmware.Spelling (Section) & " needs a writable region,"
                    & " and " & Name & " is "
                    & Firmware.Spelling (Built.Regions (Index).Mode),
                    "place " & Firmware.Spelling (Section)
                    & " in an ""rw"" or ""rwx"" region");
               else
                  Built.Placed (Section) := Index;
               end if;
            end;
         end loop;
         if not Complete then
            return;
         end if;

         if Built.Vector_Count > Firmware.Vector_Limit (Built.Core)
           and then Built.Core in Firmware.Arm_Core
         then
            Layout (Vectors_Site,
              Firmware.A_Core (Built.Core) & " vector table holds"
              & " at most"
              & Positive'Image (Firmware.Vector_Limit (Built.Core))
              & " words",
              Firmware.Level_Name (Built.Core) & " has"
              & Positive'Image (Firmware.Vector_Limit (Built.Core) - 16)
              & " external interrupts at most");
         elsif Built.Vector_Count > Firmware.Vector_Limit (Built.Core) then
            Layout (Vectors_Site,
              Firmware.A_Core (Built.Core) & " takes interrupts"
              & " at codes below"
              & Positive'Image (Firmware.Vector_Limit (Built.Core))
              & ", so its table holds at most"
              & Positive'Image (Firmware.Vector_Limit (Built.Core))
              & " slots",
              (if Built.Core in Firmware.Xtensa_Core
               then "a slot is an Xtensa CPU interrupt line, and "
               else "a slot is an mcause interrupt code (D662), and ")
              & Firmware.A_Core (Built.Core) & " takes "
              & Firmware.Core_Slots_Text (Built.Core)
              & (if Firmware.Interrupts_Are_Slots (Built.Core)
                 then " and 16 + IRQ" else ""));
         end if;
         for Item of Interrupts loop
            if not Firmware.Interrupts_Are_Slots (Built.Core) then
               null;
            elsif 16 + Item.IRQ >= Built.Vector_Count then
               Layout (Item.At_Site,
                 "IRQ" & Natural'Image (Item.IRQ) & " is slot"
                 & Natural'Image (16 + Item.IRQ) & ", past the"
                 & Natural'Image (Built.Vector_Count) & "-word vector table",
                 "compiler.vectors counts every slot, so it is at least 17"
                 & " plus the highest IRQ");
            else
               Built.Interrupts (16 + Item.IRQ) := True;
            end if;
         end loop;
         declare
            Vectors_Region : constant Firmware.Region :=
              Firmware.Placed_Region (Built, Firmware.Vectors);
            Stack_Region : constant Firmware.Region :=
              Firmware.Placed_Region (Built, Firmware.Stack);
         begin
            if Firmware.Vector_Address (Built)
              mod Firmware.Vector_Alignment (Built) /= 0
            then
               Layout (Placed_At (Firmware.Vectors),
                 "the vector table would start at an address not"
                 & " aligned to its"
                 & Landin.Targets.Byte_Count'Image
                     (Firmware.Vector_Alignment (Built))
                 & " bytes",
                 "the table is aligned to its length rounded up to a"
                 & " power of two; place vectors in a region whose"
                 & " origin is");
            elsif Firmware.Vector_Address (Built) - Vectors_Region.Origin
              + Firmware.Vector_Bytes (Built) > Vectors_Region.Length
            then
               Layout (Placed_At (Firmware.Vectors),
                 "the vector table does not fit in region "
                 & Firmware.Spelling (Vectors_Region.Name),
                 "place vectors in a larger region");
            end if;
            if Built.Stack_Size > Stack_Region.Length then
               Layout (Placed_At (Firmware.Stack),
                 "the stack is larger than region "
                 & Firmware.Spelling (Stack_Region.Name),
                 "make the stack smaller or place it in a larger region");
            end if;
         end;
         --  D587: the boot kind says whether the image begins with the
         --  description's second stage.
         if Firmware.Takes_Stage (Built.Boot)
           and then Stage_Site = No_Site
         then
            Complete := False;
            Report_At
              (Bad.Boot_Stage_Missing, Boot_Site,
               "an " & Firmware.Spelling (Built.Boot) & " image begins with"
               & " a second stage, and this description holds none",
               "D587: add the stage to the description as a"
               & " link(boot_stage) extern(naked) routine, at most"
               & Natural'Image (Firmware.Stage_Limit) & " bytes once"
               & " assembled, which the boot ROM enters at its first"
               & " instruction");
         elsif not Firmware.Admits_Stage (Built.Boot)
           and then Stage_Site /= No_Site
         then
            Complete := False;
            Report_At
              (Bad.Boot_Stage_Unwanted, Stage_Site,
               "boot kind " & Firmware.Spelling (Built.Boot) & " runs no"
               & " stage, and this description holds one",
               "D587, D653: an rp2040-boot2 image begins with a second"
               & " stage, and a vector-table one may run one before"
               & " reset; remove this routine, or select a boot kind that"
               & " runs it",
               Related => Boot_Site, Because => "the boot kind");
         elsif Firmware.Stage_Before_Reset (Built.Boot)
           and then Stage_Site /= No_Site
           and then not Reset_Stage_Holds
         then
            Complete := False;
         end if;
         Built.Has_Stage := Stage_Site /= No_Site;
         --  D681: a boot kind is read by one family's ROMs: RP2040's
         --  second stage is Thumb code, and an ESP32's application image
         --  is RISC-V's here.  RP2350's block names either.
         if not Firmware.Boots (Built.Core, Built.Boot) then
            Complete := False;
            Report_At
              (Bad.Boot_Kind_Family, Boot_Site,
               "boot kind " & Firmware.Spelling (Built.Boot) & " is read by "
               & (if Built.Core not in Firmware.Arm_Core
                  then "an Arm core's boot ROM"
                  else "a RISC-V core's boot ROM")
               & ", and this description's core is "
               & Firmware.A_Core (Built.Core),
               "D681: " & Firmware.Spelling (Built.Boot) & " is "
               & (if Built.Core not in Firmware.Arm_Core
                  then "RP2040's" else "an ESP32's")
               & "; write compiler.boot(""vector-table""), or the kind the"
               & " core's boot ROM reads",
               Related => Core_Site, Because => "the core");
         end if;
         --  D683: the ESP chip's facts go with its image and nowhere else.
         if Firmware.Takes_ESP_Image (Built.Boot) and then ESP_Site = No_Site
         then
            Complete := False;
            Report_At
              (Bad.ESP_Image_Facts, Boot_Site,
               "an esp-app-image names its chip and the revisions it runs"
               & " on, and this description says neither",
               "D683: write compiler.esp_image(chip, min_revision,"
               & " max_revision, flash_offset) beside compiler.boot, as the"
               & " chip's technical reference manual gives them");
         elsif not Firmware.Takes_ESP_Image (Built.Boot)
           and then ESP_Site /= No_Site
         then
            Complete := False;
            Report_At
              (Bad.ESP_Image_Facts, ESP_Site,
               "compiler.esp_image describes an esp-app-image, and this"
               & " description's boot kind is "
               & Firmware.Spelling (Built.Boot),
               "D683: remove compiler.esp_image, or write"
               & " compiler.boot(""esp-app-image"")",
               Related => Boot_Site, Because => "the boot kind");
         end if;

         --  D543: the core is the request's, but for the library's
         --  constrained reference, which every level is tested on.
         if Landin.Targets.Architecture_Of (Target (Context))
           /= Firmware.Family (Built.Core)
         then
            Complete := False;
            Report_At
              (Bad.Description_Core_Mismatch, Core_Site,
               "this description is for " & Firmware.A_Core (Built.Core)
               & ", and this build is for "
               & Landin.Targets.Name (Target (Context)),
               "D543: build it with --target="
               & (if Built.Core in Firmware.RISC_V_Core
                  then "rv32"
                  elsif Built.Core in Firmware.Xtensa_Core then "xtensa"
                  else "cortex-m0")
               & " --level=" & Firmware.Level_Name (Built.Core)
               & ", or import no description on this target");
         elsif not Built.Reference
           and then not Firmware.Executes
             (Built.Core, Landin.Targets.Levels.Name (Level (Context)))
         then
            Complete := False;
            Report_At
              (Bad.Description_Core_Mismatch, Core_Site,
               "this description's core is "
               & Firmware.A_Core (Built.Core) & ", an "
               & Firmware.Level_Name (Built.Core) & " core, and this build"
               & " is at --level="
               & Landin.Targets.Levels.Name (Level (Context))
               & ", which it does not execute",
               "D543: " & Firmware.A_Core (Built.Core)
               & (if Built.Core in Firmware.Xtensa_Core
                  then " executes its exact chip configuration, --level="
                  else " executes its own level and the "
               & (if Built.Core in Firmware.RISC_V_Core
                  then "RV32" else "M-profile")
               & " levels below it, --level=")
               & Firmware.Lower_Levels (Built.Core)
               & "; build at one of them");
         elsif Built.Float /= Firmware.No_Float_Unit
           and then not Firmware.May_Have (Built.Core, Built.Float)
         then
            Complete := False;
            Report_At
              (Bad.Float_Unit_Unsupported, Float_Site,
               "this description's core is "
               & Firmware.A_Core (Built.Core) & ", which refine builds"
               & " with no " & Firmware.Spelling (Built.Float) & " unit",
               "D615: a float unit is a fact of the core; refine builds"
               & " ""fpv5-d16"" on a cortex-m7, and "
               & Firmware.A_Core (Built.Core) & " with "
               & Firmware.Float_Units_Of (Built.Core)
               & "; remove compiler.float_unit or name the core it is"
               & " built into");
         elsif Built.Float /= Firmware.No_Float_Unit
           and then Landin.Targets.Levels.Name (Level (Context))
             /= Firmware.Float_Level (Built.Float)
         then
            Complete := False;
            Report_At
              (Bad.Float_Unit_Level, Float_Site,
               "this description's float unit, "
               & Firmware.Spelling (Built.Float) & ", needs --level="
               & Firmware.Float_Level (Built.Float) & ", and this build is"
               & " at --level=" & Landin.Targets.Levels.Name (Level (Context)),
               "D615: a float unit changes the C ABI, so a description that"
               & " has one is built at the level whose architecture holds"
               & " it; build with --level="
               & Firmware.Float_Level (Built.Float));
         end if;
         if Complete then
            Built.Present := True;
            if Landin.Configuration.Firmware_Layout (Activity.all)
              = Firmware.RAM_Layout
              and then Firmware.RAM_Text_Region (Built) = 0
            then
               Report_At
                 (Bad.Description_Layout, Core_Site,
                  "--firmware-layout=ram needs an executable writable"
                  & " region in the description",
                  "use --firmware-layout=boot for the board boot check");
            else
               Landin.Configuration.Set_Profile
                 (Activity.all, Firmware.For_Layout
                    (Built, Landin.Configuration.Firmware_Layout
                       (Activity.all)));
            end if;
         end if;
      end Finish_Profile;

      procedure Configure_Directive (Of_Tree : Syn.Tree; Node : Syn.Node_Id) is
         Call : constant Syn.Node_Id := Syn.Directive_Call (Of_Tree, Node);
         Callee : constant Syn.Node_Id := Syn.Callee_Of (Of_Tree, Call);
         Base : constant String :=
           Spelled (Syn.Name (Of_Tree, Syn.Target_Of (Of_Tree, Callee)));
         Member : constant String := Spelled (Syn.Name (Of_Tree, Callee));
         Argument : Syn.Node_Id;
         Value : Fixed_Value;
      begin
         if Landin.Configuration.Is_Description_Member (Base, Member) then
            if not Late then
               Configure_Description (Of_Tree, Node);
            end if;
         elsif (Base /= "compiler" or else Member /= "assert")
           and then (Base /= "linker"
                     or else Member not in "library" | "directory")
         then
            Landin.Diagnostics.Resolution.Report
              (Item => Landin.Diagnostics.Resolution.Reserved_Tool_Name,
               Source => Syn.Source_Of (Of_Tree),
               Where => Syn.Where (Of_Tree, Node),
               Message => "unavailable tool directive: " & Base & "." & Member,
               Note => Landin.Configuration.Tool_Advice (Base, Member),
               Into => Found);
         elsif Syn.Argument_Count (Of_Tree, Call) /= 1 then
            Report_Configuration_Rule
              (Bad.Invalid_Tool_Directive, Of_Tree, Node,
               "this tool directive needs one fixed argument",
               Note =>
                 (if Member = "directory"
                  then "D524: linker.directory takes exactly one positional"
                    & " argument"
                  else "D202: " & Base & "." & Member
                    & " takes exactly one positional argument"));
         else
            Argument := Syn.Nth_Argument (Of_Tree, Call, 1);
            if Base = "compiler"
              and then not Late
              and then Measures_Layout (Of_Tree, Argument)
            then
               --  D412: validated now, folded once checking has laid out
               --  the declared types it measures.
               Measuring_Layout := True;
               if Validate (Of_Tree, Argument) then
                  Landin.Configuration.Defer_Assertion
                    (Activity.all, Syn.Source_Of (Of_Tree), Node);
               end if;
               Measuring_Layout := False;
            elsif Base = "compiler" then
               Measuring_Layout := Late;
               if Validate (Of_Tree, Argument) then
                  Value := Evaluate (Of_Tree, Argument);
                  if Value.Kind = Bad_Value then
                     null;
                  elsif Value.Kind /= Truth then
                     Report_Type (Of_Tree, Argument,
                                  "compiler.assert needs bool",
                                  Related_Node => Callee,
                                  Because => "this directive requires bool",
                                  Note => "[1510]: compiler.assert requires"
                                    & " one fixed bool expression");
                  elsif not Value.Boolean_Value then
                     Bad.Report
                       (Item => Bad.Compile_Time_Assertion_Failed,
                        Source => Syn.Source_Of (Of_Tree),
                        Where => Syn.Where (Of_Tree, Argument),
                        Message => "compile-time assertion is false",
                        Note => "[1510]: compiler.assert requires a true"
                          & " fixed bool expression",
                        Into => Found);
                  end if;
               end if;
               Measuring_Layout := False;
            elsif Syn.Kind (Of_Tree, Argument) /= Syn.Text_Literal then
               Report_Configuration_Rule
                 (Bad.Invalid_Tool_Directive, Of_Tree, Argument,
                  "linker." & Member & " needs a fixed text literal",
                  Note =>
                    (if Member = "directory"
                     then "[1590]/D524: linker.directory takes one quoted"
                       & " directory, relative to this file's or absolute"
                     else "[1590]/D202: linker.library takes"
                       & " one quoted library name"));
            elsif Member = "directory" then
               --  D524: the text as written; the driver resolves it
               --  against this file's directory and asks whether it is
               --  one, since only the driver asks the host.
               declare
                  Text : constant String := Landin.Source.Slice
                    (Source (Context, Syn.Source_Of (Of_Tree)),
                     Syn.Where (Of_Tree, Argument));
                  Bytes : String (1 .. Text'Length);
                  Length, Fault_First, Fault_Last : Natural;
                  Fault : Landin.Tokens.Text.Problem;
               begin
                  Landin.Tokens.Text.Decode
                    (Text, Bytes, Length, Fault, Fault_First, Fault_Last);
                  if Fault /= Landin.Tokens.Text.Well_Formed
                    or else Length = 0
                    or else (for some Index in 1 .. Length =>
                               Bytes (Index) = ASCII.NUL)
                  then
                     Report_Configuration_Rule
                       (Bad.Invalid_Tool_Directive, Of_Tree, Argument,
                        "this is not a directory name",
                        Note => "[1590]/D524: name the directory that holds"
                          & " the library, nonempty and without a NUL byte,"
                          & " relative to this file's directory or"
                          & " absolute");
                  else
                     Landin.Configuration.Add_Directory
                       (Activity.all, Bytes (1 .. Length),
                        Syn.Source_Of (Of_Tree),
                        Syn.Where (Of_Tree, Node));
                  end if;
               end;
            else
               declare
                  Text : constant String := Landin.Source.Slice
                    (Source (Context, Syn.Source_Of (Of_Tree)),
                     Syn.Where (Of_Tree, Argument));
                  Bytes : String (1 .. Text'Length);
                  Length, Fault_First, Fault_Last : Natural;
                  Fault : Landin.Tokens.Text.Problem;
                  Valid : Boolean;
                  Has_Name : Boolean := False;
               begin
                  Landin.Tokens.Text.Decode
                    (Text, Bytes, Length, Fault, Fault_First, Fault_Last);
                  Valid := Fault = Landin.Tokens.Text.Well_Formed
                    and then Length > 0 and then Bytes (1) /= '-';
                  for Index in 1 .. Length loop
                     if Bytes (Index) not in 'a' .. 'z' | 'A' .. 'Z'
                       | '0' .. '9' | '_' | '-' | '.'
                     then
                        Valid := False;
                     end if;
                     Has_Name := Has_Name or else Bytes (Index) /= '.';
                  end loop;
                  if not Valid or else not Has_Name then
                     Report_Configuration_Rule
                       (Bad.Invalid_Tool_Directive, Of_Tree, Argument,
                        "this is not a portable library name",
                        Note => "[1590]/D202: use ASCII letters, digits, _, -"
                          & " and .; the name must be nonempty, must not start"
                          & " with -, and must not consist only of dots");
                  else
                     Landin.Configuration.Add_Library
                       (Activity.all, Bytes (1 .. Length),
                        Syn.Source_Of (Of_Tree),
                        Syn.Where (Of_Tree, Node));
                  end if;
               end;
            end if;
         end if;
         Mark_Subtree_Inactive (Of_Tree, Node);
      end Configure_Directive;

      --  D437: a module value may read a compiler fact, [1940]'s "known
      --  when the compiler reads it".  A bool or integer fact stands for
      --  its value; an atom fact, which has no value outside this stage,
      --  is read only compared with `==` or `<>`, and the comparison's
      --  other operand is a configuration atom as it is in a condition,
      --  so `compiler.os == linux` means the system even where `linux`
      --  also names an imported module.  Options stay configuration-only,
      --  and a routine body, an anonymous one included, reads no fact.
      procedure Record_Module_Facts
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);
      procedure Record_Module_Facts
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         function Atom_Fact (Operand : Syn.Node_Id) return Boolean
           is (Is_Compiler_Member (Of_Tree, Operand)
               and then Landin.Configuration.Is_Atom_Fact_Name
                 (Spelled (Syn.Name (Of_Tree, Operand))));
         function Atom_Operand (Operand : Syn.Node_Id) return Boolean
           is (Atom_Fact (Operand)
               or else (Syn.Kind (Of_Tree, Operand) = Syn.Name_Reference
                        and then Landin.Configuration.Is_Configuration_Atom
                          (Spelled (Syn.Name (Of_Tree, Operand)))));

         procedure Keep;
         procedure Keep is
            Value : Fixed_Value := (Kind => Bad_Value);
         begin
            if Validate (Of_Tree, Node) then
               Value := Evaluate (Of_Tree, Node);
            end if;
            Landin.Configuration.Record_Fact
              (Activity.all, Syn.Source_Of (Of_Tree), Node,
               (case Value.Kind is
                  when Truth => Landin.Configuration.Bool_Fact,
                  when Number => Landin.Configuration.Integer_Fact,
                  when others => Landin.Configuration.Refused_Fact),
               (case Value.Kind is
                  when Truth => Boolean'Pos (Value.Boolean_Value),
                  when Number => Value.Integer_Value,
                  when others => 0));
         end Keep;
      begin
         if Node = Syn.No_Node
           or else Syn.Kind (Of_Tree, Node) = Syn.Anonymous_Function
         then
            return;
         elsif Is_Feature_Fact (Of_Tree, Node)
           or else (Is_Compiler_Member (Of_Tree, Node)
                    and then Landin.Configuration.Is_Valued_Fact_Name
                      (Spelled (Syn.Name (Of_Tree, Node))))
         then
            Keep;
            return;
         elsif Syn.Kind (Of_Tree, Node) in Syn.Equal_To | Syn.Not_Equal_To
           and then (Atom_Fact (Syn.Left_Of (Of_Tree, Node))
                     or else Atom_Fact (Syn.Right_Of (Of_Tree, Node)))
           and then Atom_Operand (Syn.Left_Of (Of_Tree, Node))
           and then Atom_Operand (Syn.Right_Of (Of_Tree, Node))
         then
            Keep;
            return;
         end if;
         for Index in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            Record_Module_Facts (Of_Tree, Syn.Slot (Of_Tree, Node, Index));
         end loop;
      end Record_Module_Facts;

      procedure Configure_Declaration
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Selected : Natural := 0;
      begin
         if Syn.Kind (Of_Tree, Node) = Syn.Tool_Directive then
            Configure_Directive (Of_Tree, Node);
            return;
         elsif Syn.Kind (Of_Tree, Node) = Syn.Binding then
            Record_Module_Facts (Of_Tree, Syn.Value_Of (Of_Tree, Node));
            return;
         elsif Syn.Kind (Of_Tree, Node) = Syn.Option_Declaration then
            Mark_Subtree_Inactive (Of_Tree, Node);
            return;
         elsif Syn.Kind (Of_Tree, Node) /= Syn.Fixed_Conditional then
            return;
         end if;

         for Index in 1 .. Syn.Fixed_Arm_Count (Of_Tree, Node) loop
            declare
               Arm : constant Syn.Node_Id := Syn.Nth_Fixed_Arm
                 (Of_Tree, Node, Index);
               Condition : constant Syn.Node_Id := Syn.Fixed_Condition
                 (Of_Tree, Arm);
               Value : Fixed_Value;
            begin
               if Condition = Syn.No_Node then
                  if Selected = 0 then
                     Selected := Index;
                  end if;
               elsif Validate (Of_Tree, Condition) then
                  Value := Evaluate (Of_Tree, Condition);
                  if Value.Kind = Bad_Value then
                     null;
                  elsif Value.Kind /= Truth then
                     Report_Type
                       (Of_Tree, Condition,
                        "this fixed conditional condition is not bool",
                        Related_Node => Arm,
                        Because => "this fixed arm requires a bool condition",
                        Note => "[1500]: a fixed conditional condition must"
                          & " produce bool");
                  elsif Value.Boolean_Value and then Selected = 0 then
                     Selected := Index;
                  end if;
               end if;
            end;
         end loop;

         for Index in 1 .. Syn.Fixed_Arm_Count (Of_Tree, Node) loop
            declare
               Arm : constant Syn.Node_Id := Syn.Nth_Fixed_Arm
                 (Of_Tree, Node, Index);
            begin
               for Which in 1 .. Syn.Fixed_Declaration_Count (Of_Tree, Arm)
               loop
                  declare
                     Declaration : constant Syn.Node_Id :=
                       Syn.Nth_Fixed_Declaration (Of_Tree, Arm, Which);
                  begin
                     if Index = Selected then
                        Arm_Depth := Arm_Depth + 1;
                        Configure_Declaration (Of_Tree, Declaration);
                        Arm_Depth := Arm_Depth - 1;
                     else
                        Mark_Subtree_Inactive (Of_Tree, Declaration);
                     end if;
                  end;
               end loop;
            end;
         end loop;
      end Configure_Declaration;

   begin
      if Late then
         Float_Facts := Landin.Configuration.Profile (Activity.all).Float;
         for Index in 1 .. Source_Count (Context) loop
            declare
               Of_Tree : constant not null access constant Syn.Tree :=
                 Landin.Syntax.Forest.Tree_Of
                   (Trees.all, Nth_Source (Context, Index));
            begin
               for Which in 1 .. Syn.Declaration_Count (Of_Tree.all) loop
                  Gather_Options
                    (Of_Tree.all,
                     Syn.Nth_Declaration (Of_Tree.all, Which), False);
               end loop;
            end;
         end loop;
         for Index in 1 .. Natural (Options.Length) loop
            declare
               Value : constant Fixed_Value := Evaluate_Option (Index);
               pragma Unreferenced (Value);
            begin
               null;
            end;
         end loop;
         --  The first pass reported every option; keep only what the
         --  deferred assertions say.
         declare
            Fresh : Landin.Diagnostics.Diagnostic_List;
         begin
            Found := Fresh;
         end;
         for Index in 1 .. Landin.Configuration.Deferred_Count
           (Activity.all)
         loop
            Configure_Directive
              (Landin.Syntax.Forest.Tree_Of
                 (Trees.all,
                  Landin.Configuration.Deferred_Source
                    (Activity.all, Index)).all,
               Landin.Configuration.Deferred_Node (Activity.all, Index));
         end loop;
         declare
            Ordered : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Diagnostics.Sorted (Found);
         begin
            for Index in 1 .. Landin.Diagnostics.Count (Ordered) loop
               Report (Context, Landin.Diagnostics.Get (Ordered, Index));
            end loop;
         end;
         Outcome := (if Failed (Context) then Stop else Continue);
         return;
      end if;
      Landin.Configuration.Prepare (Activity.all);
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Trees.all, Nth_Source (Context, Index));
         begin
            for Which in 1 .. Syn.Import_Count (Of_Tree.all) loop
               declare
                  Node : constant Syn.Node_Id :=
                    Syn.Nth_Import (Of_Tree.all, Which);
                  Logical : Ada.Strings.Unbounded.Unbounded_String;
               begin
                  for Segment in
                    1 .. Syn.Import_Segment_Count (Of_Tree.all, Node)
                  loop
                     if Segment > 1 then
                        Ada.Strings.Unbounded.Append (Logical, "/");
                     end if;
                     Ada.Strings.Unbounded.Append
                       (Logical, Landin.Source.Names.Spelling
                          (Names.all, Syn.Name (Of_Tree.all,
                             Syn.Nth_Import_Segment
                               (Of_Tree.all, Node, Segment))));
                  end loop;
                  if not Landin.Modules.Availability.Permitted
                    (Ada.Strings.Unbounded.To_String (Logical),
                     Target (Context))
                  then
                     Unavailable_Import := True;
                     Landin.Diagnostics.Modules.Report
                       (Item => Landin.Diagnostics.Modules
                          .Module_Unavailable_For_Target,
                        Source => Syn.Source_Of (Of_Tree.all),
                        Where => Syn.Where (Of_Tree.all, Node),
                        Message => "module unavailable for target: " &
                          Ada.Strings.Unbounded.To_String (Logical),
                        Note => Landin.Modules.Availability.Requirement
                          (Ada.Strings.Unbounded.To_String (Logical)),
                        Into => Found);
                  end if;
                  --  Explicit-file requests have no driver root walk.
                  if Landin.Configuration.Is_Builtin_Import
                    (Names.all, Of_Tree.all, Node)
                  then
                     Landin.Diagnostics.Resolution.Report
                       (Item => Landin.Diagnostics.Resolution
                          .Reserved_Tool_Name,
                        Source => Syn.Source_Of (Of_Tree.all),
                        Where => Syn.Where (Of_Tree.all, Node),
                        Message => "builtin module cannot be explicitly"
                          & " imported",
                        Note => "[1560]: compiler, assembler and linker"
                          & " are in scope without imports",
                        Into => Found);
                  end if;
               end;
            end loop;
         end;
      end loop;
      if Unavailable_Import then
         declare
            Ordered : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Diagnostics.Sorted (Found);
         begin
            for Index in 1 .. Landin.Diagnostics.Count (Ordered) loop
               Report (Context, Landin.Diagnostics.Get (Ordered, Index));
            end loop;
         end;
         Outcome := Stop;
         return;
      end if;
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Trees.all, Nth_Source (Context, Index));
         begin
            for Which in 1 .. Syn.Declaration_Count (Of_Tree.all) loop
               Gather_Options
                 (Of_Tree.all,
                  Syn.Nth_Declaration (Of_Tree.all, Which), False);
            end loop;
         end;
      end loop;
      --  D615: the description, and its float unit, before any option
      --  or fixed condition reads compiler.feature.fp.
      Find_Description;
      Read_Float_Unit;
      for Index in 1 .. Natural (Options.Length) loop
         declare
            Value : constant Fixed_Value := Evaluate_Option (Index);
            pragma Unreferenced (Value);
         begin
            null;
         end;
      end loop;
      for Index in 1 .. Landin.Configuration.Override_Count (Activity.all) loop
         declare
            Word : constant String := Landin.Configuration.Override_Name
              (Activity.all, Index);
            Found_Name : Boolean := False;
         begin
            for Setting of Options loop
               Found_Name := Found_Name or else Spelled (Setting.Name) = Word;
            end loop;
            if not Found_Name then
               Report (Context, Landin.Diagnostics.Make
                 (Code => Landin.Diagnostics.Catalogue.Code
                    (Landin.Diagnostics.Catalogue.Unknown_Option),
                  Level => Landin.Diagnostics.Error,
                  Source => Landin.Source.No_Source,
                  Where => Landin.Source.Empty_Span,
                  Message => "unknown build option: " & Word));
            end if;
         end;
      end loop;
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Trees.all, Nth_Source (Context, Index));
         begin
            for Which in 1 .. Syn.Declaration_Count (Of_Tree.all) loop
               Configure_Declaration
                 (Of_Tree.all, Syn.Nth_Declaration (Of_Tree.all, Which));
            end loop;
         end;
      end loop;
      Find_Boot_Stages;
      Finish_Profile;

      declare
         Ordered : constant Landin.Diagnostics.Diagnostic_List :=
           Landin.Diagnostics.Sorted (Found);
      begin
         for Index in 1 .. Landin.Diagnostics.Count (Ordered) loop
            Report (Context, Landin.Diagnostics.Get (Ordered, Index));
         end loop;
      end;
      Outcome := (if Failed (Context) then Stop else Continue);
   end Configure;

end Landin.Stages.Configuration;
