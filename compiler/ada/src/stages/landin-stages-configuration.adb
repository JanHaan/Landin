with Landin.Configuration;
with Landin.Diagnostics.Checking;
with Landin.Source;
with Landin.Source.Names;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;
with Landin.Types;

package body Landin.Stages.Configuration is

   package Bad renames Landin.Diagnostics.Checking;
   package Syn renames Landin.Syntax;
   package Ty renames Landin.Types;

   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Targets.Architecture;
   use type Landin.Types.Folded;

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

      type Fixed_Kind is (Bad_Value, Truth, Number, Machine);
      type Fixed_Value (Kind : Fixed_Kind := Bad_Value) is record
         case Kind is
            when Truth => Boolean_Value : Boolean;
            when Number => Integer_Value : Ty.Folded;
            when Machine => Architecture_Value : Landin.Targets.Architecture;
            when Bad_Value => null;
         end case;
      end record;

      procedure Report_Not_Fixed
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Message : String);
      procedure Report_Type
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Message : String);
      procedure Mark_Subtree_Inactive
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);
      procedure Configure_Declaration
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);
      function Validate (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Boolean;
      function Evaluate (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Fixed_Value;

      function Spelled (Name : Landin.Source.Names.Name_Id) return String
        is (Landin.Source.Names.Spelling (Names.all, Name));

      procedure Report_Not_Fixed
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Message : String) is
      begin
         Bad.Report
           (Item    => Bad.Not_Known_At_Compile_Time,
            Source  => Syn.Source_Of (Of_Tree),
            Where   => Syn.Where (Of_Tree, Node),
            Message => Message,
            Note    => "D138: a fixed conditional uses only the closed"
                       & " fixed-expression forms; no user routine runs",
            Into    => Found);
      end Report_Not_Fixed;

      procedure Report_Type
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Message : String) is
      begin
         Bad.Report
           (Item    => Bad.Type_Mismatch,
            Source  => Syn.Source_Of (Of_Tree),
            Where   => Syn.Where (Of_Tree, Node),
            Message => Message,
            Note    => "D138: a fixed conditional condition must produce"
                       & " bool",
            Related => Syn.Origin (Of_Tree, Node),
            Because => "this fixed conditional condition",
            Into    => Found);
      end Report_Type;

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
                               | "synthetic_32"
                  then
                     Report_Not_Fixed
                       (Of_Tree, Node,
                        "this name is not a compiler-owned fixed value");
                     Valid := False;
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
                    or else Spelled (Syn.Name (Of_Tree, Node)) /= "arch"
                  then
                     Report_Not_Fixed
                       (Of_Tree, Node,
                        "only intrinsic fixed `compiler.arch` is available");
                     Valid := False;
                  end if;
               end;

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
                  "this is not one of the closed fixed conditional forms");
               Valid := False;
         end case;
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
                     Report_Not_Fixed
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
                  return (Kind => Machine,
                          Architecture_Value =>
                            (if Word = "x86_64" then Landin.Targets.X86_64
                             elsif Word = "arm64" then Landin.Targets.Arm64
                             elsif Word = "cortex_m0" then
                                Landin.Targets.Cortex_M0
                             else Landin.Targets.Synthetic_32_Architecture));
               end;
            when Syn.Member_Selection =>
               return (Kind => Machine,
                       Architecture_Value => Landin.Targets.Architecture_Of
                         (Target (Context)));
            when Syn.Negation =>
               Left := Evaluate (Of_Tree, Syn.Operand_Of (Of_Tree, Node));
               if Left.Kind /= Number
                 or else Left.Integer_Value = Ty.Folded'First
               then
                  Report_Not_Fixed
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
                        Report_Not_Fixed
                          (Of_Tree, Node,
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
                     then
                        Report_Not_Fixed
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

      procedure Configure_Declaration
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Selected : Natural := 0;
      begin
         if Syn.Kind (Of_Tree, Node) /= Syn.Fixed_Conditional then
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
                  if Value.Kind /= Truth then
                     Report_Type
                       (Of_Tree, Condition,
                        "this fixed conditional condition is not bool");
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
