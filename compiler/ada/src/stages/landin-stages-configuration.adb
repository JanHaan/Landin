with Ada.Containers.Vectors;

with Landin.Configuration;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Checking;
with Landin.Diagnostics.Resolution;
with Landin.Source;
with Landin.Source.Names;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;
with Landin.Types;
with Landin.Tokens.Text;

package body Landin.Stages.Configuration is

   package Bad renames Landin.Diagnostics.Checking;
   package Syn renames Landin.Syntax;
   package Ty renames Landin.Types;

   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Targets.Architecture;
   use type Landin.Targets.C_ABI_Kind;
   use type Landin.Types.Folded;
   use type Landin.Types.Type_Kind;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Configuration.Build_Mode;
   use type Landin.Targets.Endianness;
   use type Landin.Tokens.Text.Problem;

   overriding function Name (Item : Instance) return String is
      pragma Unreferenced (Item);
   begin
      return "configuration";
   end Name;

   overriding procedure Run
     (Item    : Instance;
      Context : in out Compilation;
      Outcome : out Stage_Outcome)
   is
      pragma Unreferenced (Item);

      Trees : constant not null access Landin.Syntax.Forest.Table :=
        Landin.Stages.Trees (Context);
      Names : constant not null access Landin.Source.Names.Table :=
        Identities (Context);
      Activity : constant not null access Landin.Configuration.Table :=
        Configurations (Context);
      Found : Landin.Diagnostics.Diagnostic_List;

      type Fixed_Kind is
        (Bad_Value, Truth, Number, Machine, Byte_Order, Build_Kind);
      type Fixed_Value (Kind : Fixed_Kind := Bad_Value) is record
         case Kind is
            when Truth => Boolean_Value : Boolean;
            when Number => Integer_Value : Ty.Folded;
            when Machine => Architecture_Value : Landin.Targets.Architecture;
            when Byte_Order => Order_Value : Landin.Targets.Endianness;
            when Build_Kind => Mode_Value : Landin.Configuration.Build_Mode;
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

      function Spelled (Name : Landin.Source.Names.Name_Id) return String
        is (Landin.Source.Names.Spelling (Names.all, Name));

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
               | Syn.Negation | Syn.Add | Syn.Subtract | Syn.Multiply
               | Syn.Divide | Syn.Remainder =>
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
                  elsif Word in "little" | "big" then
                     return Byte_Order;
                  elsif Word in "debug" | "release" then
                     return Build_Kind;
                  else
                     return Machine;
                  end if;
               end;
            when Syn.Member_Selection =>
               declare
                  Word : constant String := Spelled (Syn.Name (Of_Tree, Node));
               begin
                  if Word = "c_sysv_lp64" then
                     return Truth;
                  elsif Word = "word_size" then
                     return Number;
                  elsif Word = "byte_order" then
                     return Byte_Order;
                  elsif Word = "build_mode" then
                     return Build_Kind;
                  else
                     return Machine;
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
                  if Word not in "x86_64" | "arm64" | "cortex_m0"
                               | "synthetic_32" | "little" | "big"
                               | "debug" | "release"
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
               declare
                  Base : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
                  Is_Compiler : constant Boolean :=
                    Syn.Kind (Of_Tree, Base) = Syn.Name_Reference
                    and then Spelled (Syn.Name (Of_Tree, Base)) = "compiler";
               begin
                  if not Is_Compiler
                    or else Spelled (Syn.Name (Of_Tree, Node))
                      not in "arch" | "word_size" | "byte_order"
                           | "build_mode" | "c_sysv_lp64"
                  then
                     Report_Not_Fixed
                       (Of_Tree, Node,
                        "unknown compiler fixed fact");
                     Valid := False;
                  end if;
               end;

            when Syn.Size_Of | Syn.Align_Of =>
               if Scalar_Type (Of_Tree, Syn.Measured_Type (Of_Tree, Node))
                 not in Ty.Scalar_Name
               then
                  Report_Not_Fixed
                    (Of_Tree, Node,
                     "D202: fixed measurements need a scalar name,"
                     & " not a declared type");
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
                  return (Kind => Machine,
                          Architecture_Value =>
                            (if Word = "x86_64" then Landin.Targets.X86_64
                             elsif Word = "arm64" then Landin.Targets.Arm64
                             elsif Word = "cortex_m0" then
                                Landin.Targets.Cortex_M0
                             else Landin.Targets.Synthetic_32_Architecture));
               end;
            when Syn.Member_Selection =>
               declare
                  Word : constant String := Spelled (Syn.Name (Of_Tree, Node));
               begin
                  if Word = "c_sysv_lp64" then
                     return Boolean_Result
                       (Landin.Targets.C_ABI_Of (Target (Context))
                          = Landin.Targets.SysV_AMD64_LP64);
                  elsif Word = "word_size" then
                     return (Kind => Number, Integer_Value => Ty.Folded
                       (Landin.Targets.Pointer_Width (Target (Context))));
                  elsif Word = "byte_order" then
                     return (Kind => Byte_Order, Order_Value =>
                       Landin.Targets.Byte_Order (Target (Context)));
                  elsif Word = "build_mode" then
                     return (Kind => Build_Kind, Mode_Value =>
                       Landin.Configuration.Mode (Activity.all));
                  else
                     return (Kind => Machine,
                             Architecture_Value =>
                               Landin.Targets.Architecture_Of
                                 (Target (Context)));
                  end if;
               end;
            when Syn.Size_Of | Syn.Align_Of =>
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
               Report_Not_Fixed
                 (Of_Tree, Node,
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
            elsif Spelled (Syn.Name (Of_Tree, Node))
              in "x86_64" | "arm64" | "cortex_m0" | "synthetic_32"
                 | "little" | "big" | "debug" | "release"
            then
               Report_Not_Fixed
                 (Of_Tree, Node, "this option name is compiler-owned",
                  Note => "D202: configuration atom names cannot be reused"
                    & " by options");
            else
               Landin.Configuration.Record_Option
                 (Activity.all, Syn.Name (Of_Tree, Node),
                  Syn.Origin (Of_Tree, Node));
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
            Report_Not_Fixed (Of_Tree.all, Setting.Node,
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

      procedure Configure_Directive (Of_Tree : Syn.Tree; Node : Syn.Node_Id) is
         Call : constant Syn.Node_Id := Syn.Directive_Call (Of_Tree, Node);
         Callee : constant Syn.Node_Id := Syn.Callee_Of (Of_Tree, Call);
         Base : constant String :=
           Spelled (Syn.Name (Of_Tree, Syn.Target_Of (Of_Tree, Callee)));
         Member : constant String := Spelled (Syn.Name (Of_Tree, Callee));
         Argument : Syn.Node_Id;
         Value : Fixed_Value;
      begin
         if (Base /= "compiler" or else Member /= "assert")
           and then (Base /= "linker" or else Member /= "library")
         then
            Landin.Diagnostics.Resolution.Report
              (Item => Landin.Diagnostics.Resolution.Reserved_Tool_Name,
               Source => Syn.Source_Of (Of_Tree),
               Where => Syn.Where (Of_Tree, Node),
               Message => "unavailable tool directive: " & Base & "." & Member,
               Note => Landin.Configuration.Tool_Advice (Base, Member),
               Into => Found);
         elsif Syn.Argument_Count (Of_Tree, Call) /= 1 then
            Report_Not_Fixed (Of_Tree, Node,
                             "this tool directive needs one fixed argument",
                             Note => "D202: " & Base & "." & Member
                               & " takes exactly one positional argument");
         else
            Argument := Syn.Nth_Argument (Of_Tree, Call, 1);
            if Base = "compiler" then
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
            elsif Syn.Kind (Of_Tree, Argument) /= Syn.Text_Literal then
               Report_Not_Fixed (Of_Tree, Argument,
                                 "linker.library needs a fixed text literal",
                                 Note => "[1590]/D202: linker.library takes"
                                   & " one quoted library name");
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
                     Report_Not_Fixed (Of_Tree, Argument,
                       "this is not a portable static library name",
                       Note => "[1590]/D202: use ASCII letters, digits, _, -"
                         & " and .; the name must be nonempty, must not start"
                         & " with -, and must not consist only of dots");
                  else
                     Landin.Configuration.Add_Library
                       (Activity.all, Bytes (1 .. Length));
                  end if;
               end;
            end if;
         end if;
         Mark_Subtree_Inactive (Of_Tree, Node);
      end Configure_Directive;

      procedure Configure_Declaration
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Selected : Natural := 0;
      begin
         if Syn.Kind (Of_Tree, Node) = Syn.Tool_Directive then
            Configure_Directive (Of_Tree, Node);
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
                        Configure_Declaration (Of_Tree, Declaration);
                     else
                        Mark_Subtree_Inactive (Of_Tree, Declaration);
                     end if;
                  end;
               end loop;
            end;
         end loop;
      end Configure_Declaration;

   begin
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
               begin
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

      declare
         Ordered : constant Landin.Diagnostics.Diagnostic_List :=
           Landin.Diagnostics.Sorted (Found);
      begin
         for Index in 1 .. Landin.Diagnostics.Count (Ordered) loop
            Report (Context, Landin.Diagnostics.Get (Ordered, Index));
         end loop;
      end;
      Outcome := (if Failed (Context) then Stop else Continue);
   end Run;

end Landin.Stages.Configuration;
