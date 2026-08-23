with Landin.Checking;
with Landin.IR;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Types;

package body Landin.Stages.Lowering is

   package Syn renames Landin.Syntax;
   package Res renames Landin.Resolution;
   package Ty  renames Landin.Types;
   package IR  renames Landin.IR;

   use type IR.Block_Id;
   use type IR.Item_Id;
   use type IR.Slot_Id;
   use type IR.Value_Id;
   use type Landin.Source.Source_Id;
   use type Res.Declaration_Id;
   use type Res.Declaration_Sort;
   use type Syn.Node_Id;
   use type Syn.Node_Kind;
   use type Ty.Type_Kind;

   overriding function Name (Item : Instance) return String is
      pragma Unreferenced (Item);
   begin
      return "lowering";
   end Name;

   overriding procedure Run
     (Item    : Instance;
      Context : in out Compilation;
      Outcome : out Stage_Outcome)
   is
      pragma Unreferenced (Item);

      Meanings : constant not null access Res.Table :=
        Landin.Stages.Meanings (Context);
      Types : constant not null access Landin.Checking.Table :=
        Landin.Stages.Types (Context);
      Unit : constant not null access IR.Unit :=
        Landin.Stages.Code (Context);

      function Tree_For (Id : Landin.Source.Source_Id)
        return not null access constant Syn.Tree
        is (Landin.Syntax.Forest.Tree_Of
              (Landin.Stages.Trees (Context).all, Id));

      --  Which declaration a declaring node is.  A scan, for the reason
      --  Landin.Stages.Checking gives for its own: Landin.Resolution
      --  publishes the other direction only, and the list is short.
      function Declaration_At
        (Src : Landin.Source.Source_Id; Node : Syn.Node_Id)
        return Res.Declaration_Id;

      function Declaration_At
        (Src : Landin.Source.Source_Id; Node : Syn.Node_Id)
        return Res.Declaration_Id is
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

         raise Landin.Compiler_Defect with
           "a declaring node the resolver never recorded";
      end Declaration_At;

      --  Where a declaration's value lives inside the item being filled.
      --  Dense and indexed by Declaration_Id, which is the bargain
      --  Landin.Checking already struck: no map anywhere.
      --  The resolver's count and not IR.Declaration_Limit, which asks a
      --  Unit that Prepare has not reached yet: this is elaborated before
      --  the statements below run.  Prepare takes the same number from
      --  the same table, so the two cannot disagree.
      subtype Declared is Positive range
        1 .. Positive'Max (1, Res.Declaration_Count (Meanings.all));

      type Slot_Map is array (Declared) of IR.Slot_Id;

      No_Slots : constant Slot_Map := [others => IR.No_Slot];

      Slots : Slot_Map := No_Slots;

      --  The item being filled, and the block instructions go into.
      --  Current is No_Block when the flow has been terminated and
      --  nothing further is reachable.  One block at a time: Enter allows
      --  one open block per item and refuses one that already holds
      --  something, so a block is filled once, in one go, and never
      --  returned to.
      Filling : IR.Item_Id  := IR.No_Item;
      Current : IR.Block_Id := IR.No_Block;

      function Site_Of (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Landin.Provenance.Origin
        is (Syn.Origin (Of_Tree, Node));

      function Type_At (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Ty.Type_Kind
        is (Landin.Checking.Type_Of (Types.all, Of_Tree, Node));

      function Scalar_At (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Ty.Scalar_Name;

      --  [1820]'s operators onto Landin.IR's opcodes, one to one.  The
      --  two missing are the logical words: [0410] makes them
      --  short-circuit, so they are control flow and there is no opcode
      --  for this table to name.
      function Opcode_For (Of_Kind : Syn.Node_Kind) return IR.Opcode
        is (case Of_Kind is
               when Syn.Multiply          => IR.Multiply,
               when Syn.Divide            => IR.Divide,
               when Syn.Remainder         => IR.Remainder,
               when Syn.Wrapping_Multiply => IR.Wrapping_Multiply,
               when Syn.Add               => IR.Add,
               when Syn.Subtract          => IR.Subtract,
               when Syn.Wrapping_Add      => IR.Wrapping_Add,
               when Syn.Wrapping_Subtract => IR.Wrapping_Subtract,
               when Syn.Shift_Left        => IR.Shift_Left,
               when Syn.Shift_Right       => IR.Shift_Right,
               when Syn.Bitwise_And       => IR.Bitwise_And,
               when Syn.Bitwise_Xor       => IR.Bitwise_Xor,
               when Syn.Bitwise_Or        => IR.Bitwise_Or,
               when Syn.Equal_To          => IR.Equal_To,
               when Syn.Not_Equal_To      => IR.Not_Equal_To,
               when Syn.Less_Than         => IR.Less_Than,
               when Syn.Less_Or_Equal     => IR.Less_Or_Equal,
               when Syn.Greater_Than      => IR.Greater_Than,
               when Syn.Greater_Or_Equal  => IR.Greater_Or_Equal,
               when others                =>
                  raise Landin.Compiler_Defect with
                    "this operator has no opcode");

      procedure Open (Block : IR.Block_Id);

      procedure Close_With_Jump
        (To : IR.Block_Id; Site : Landin.Provenance.Origin);

      function Fresh
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Block_Id;

      function Slot_For
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : Res.Declaration_Id) return IR.Slot_Id;

      function Lower_Expression
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id;

      function Lower_Call
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id;

      function Lower_Short_Circuit
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id;

      procedure Lower_Statements
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id);

      procedure Lower_If
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id);

      procedure Leave_With
        (Result : IR.Slot_Id; Site : Landin.Provenance.Origin);

      function Scalar_At (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Ty.Scalar_Name
      is
         Held : constant Ty.Type_Kind := Type_At (Of_Tree, Node);
      begin
         if Held not in Ty.Scalar_Name then
            raise Landin.Compiler_Defect with
              "an expression reached the lowering with no scalar type";
         end if;

         return Held;
      end Scalar_At;

      procedure Open (Block : IR.Block_Id) is
      begin
         IR.Enter (Unit.all, Filling, Block);
         Current := Block;
      end Open;

      procedure Close_With_Jump
        (To : IR.Block_Id; Site : Landin.Provenance.Origin) is
      begin
         IR.Emit_Jump (Unit.all, Filling, To, Site);
         IR.Leave_Block (Unit.all, Filling);
         Current := IR.No_Block;
      end Close_With_Jump;

      --  [1810]'s `return`, and the end of a body [0930].  The value is a
      --  load of the named return, because the return is a place the body
      --  assigned rather than an expression the exit carried.
      procedure Leave_With
        (Result : IR.Slot_Id; Site : Landin.Provenance.Origin)
      is
         Value : IR.Value_Id := IR.No_Value;
      begin
         if Result /= IR.No_Slot then
            Value := IR.Emit_Load (Unit.all, Filling, Result, Site);
         end if;

         IR.Emit_Leave (Unit.all, Filling, Value, Site);
         IR.Leave_Block (Unit.all, Filling);
         Current := IR.No_Block;
      end Leave_With;

      function Fresh
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Block_Id
        is (IR.Add_Block
              (Unit.all, Filling, Scope, Site_Of (Of_Tree, Node)));

      --  A declaration's slot, made the first time it is wanted.  A local
      --  [1810], a parameter and the named return [1840] all become one;
      --  a module binding does not, and Lower_Expression sends those to
      --  Load_Datum instead.
      function Slot_For
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : Res.Declaration_Id) return IR.Slot_Id
      is
         Held : Ty.Type_Kind;
      begin
         if Slots (Positive (Id)) /= IR.No_Slot then
            return Slots (Positive (Id));
         end if;

         Held := Landin.Checking.Type_Of (Types.all, Id);

         if Held not in Ty.Scalar_Name then
            raise Landin.Compiler_Defect with
              "a declaration reached the lowering with no scalar type";
         end if;

         Slots (Positive (Id)) :=
           IR.Add_Slot
             (Unit.all, Filling, Held, Id, Site_Of (Of_Tree, Node));
         return Slots (Positive (Id));
      end Slot_For;

      ------------------------------------------------------------
      --  [0410]: `and` and `or` short-circuit, so they are blocks
      ------------------------------------------------------------

      --  The answer crosses a merge and Landin.IR has no phi, so it
      --  crosses through a slot -- exactly as a declared name does.  The
      --  slot carries no Declaration_Id, because no name declared it.
      function Lower_Short_Circuit
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Answer : constant IR.Slot_Id :=
           IR.Add_Slot
             (Unit.all, Filling, Ty.Bool, Res.No_Declaration, Site);
         Rest : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
         Join : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
         Left : constant IR.Value_Id :=
           Lower_Expression (Of_Tree, Syn.Left_Of (Of_Tree, Node), Scope);
      begin
         IR.Emit_Store (Unit.all, Filling, Answer, Left, Site);

         --  `and` evaluates the right only when the left was true, `or`
         --  only when it was false.  One Branch says both.
         if Syn.Kind (Of_Tree, Node) = Syn.Logical_And then
            IR.Emit_Branch (Unit.all, Filling, Left, Rest, Join, Site);
         else
            IR.Emit_Branch (Unit.all, Filling, Left, Join, Rest, Site);
         end if;

         IR.Leave_Block (Unit.all, Filling);
         Current := IR.No_Block;

         Open (Rest);

         declare
            Right : constant IR.Value_Id :=
              Lower_Expression
                (Of_Tree, Syn.Right_Of (Of_Tree, Node), Scope);
         begin
            IR.Emit_Store (Unit.all, Filling, Answer, Right, Site);
         end;

         Close_With_Jump (Join, Site);

         Open (Join);
         return IR.Emit_Load (Unit.all, Filling, Answer, Site);
      end Lower_Short_Circuit;

      ------------------------------------------------------------
      --  [1920]: a call
      ------------------------------------------------------------

      function Lower_Call
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Callee : constant Syn.Node_Id := Syn.Callee_Of (Of_Tree, Node);
         Means : constant Res.Declaration_Id :=
           Res.Bound_To (Meanings.all, Of_Tree, Callee);
         Target : constant IR.Item_Id := IR.Item_For (Unit.all, Means);
         Count : constant Natural := Syn.Argument_Count (Of_Tree, Node);
         Given : array (1 .. Positive'Max (1, Count)) of IR.Value_Id :=
           [others => IR.No_Value];
         Made : IR.Value_Id;
      begin
         --  Every argument before the call, because Add_Argument requires
         --  the call to still be the last instruction emitted: an
         --  argument evaluated after it would have to be emitted between
         --  the two.
         for Which in 1 .. Count loop
            Given (Which) :=
              Lower_Expression
                (Of_Tree, Syn.Nth_Argument (Of_Tree, Node, Which), Scope);
         end loop;

         Made :=
           IR.Emit_Call
             (Unit.all, Filling, Target, Type_At (Of_Tree, Node), Site);

         for Which in 1 .. Count loop
            IR.Add_Argument (Unit.all, Filling, Made, Given (Which));
         end loop;

         return Made;
      end Lower_Call;

      ------------------------------------------------------------
      --  Expressions [1820]
      ------------------------------------------------------------

      function Lower_Expression
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id) return IR.Value_Id
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);

         --  [1880]: a unary minus over a literal is part of the value the
         --  literal check read, which is what makes `i8 = -128` the
         --  smallest i8 rather than 128 refused and then negated.  So it
         --  is one Number here, and not a Negation over one.
         function Magnitude_Of (Literal : Syn.Node_Id) return Ty.Magnitude;

         function Magnitude_Of (Literal : Syn.Node_Id) return Ty.Magnitude
         is
            Text : constant String :=
              Landin.Source.Slice
                (Landin.Stages.Source (Context, Syn.Source_Of (Of_Tree)),
                 Syn.Digit_Span (Of_Tree, Literal));
            Value      : Ty.Magnitude;
            Overflowed : Boolean;
         begin
            Ty.Evaluate
              (Text, Syn.Base (Of_Tree, Literal), Value, Overflowed);

            if Overflowed then
               raise Landin.Compiler_Defect with
                 "a literal the checker accepted does not fit Magnitude";
            end if;

            return Value;
         end Magnitude_Of;

      begin
         case Syn.Kind (Of_Tree, Node) is
            when Syn.Integer_Literal =>
               return IR.Emit_Number
                        (Unit.all, Filling, Scalar_At (Of_Tree, Node),
                         Magnitude_Of (Node), False, Site);

            when Syn.True_Literal =>
               return IR.Emit_Truth (Unit.all, Filling, True, Site);

            when Syn.False_Literal =>
               return IR.Emit_Truth (Unit.all, Filling, False, Site);

            when Syn.Negation =>
               declare
                  Under : constant Syn.Node_Id :=
                    Syn.Operand_Of (Of_Tree, Node);
               begin
                  if Syn.Kind (Of_Tree, Under) = Syn.Integer_Literal then
                     return IR.Emit_Number
                              (Unit.all, Filling,
                               Scalar_At (Of_Tree, Node),
                               Magnitude_Of (Under), True, Site);
                  end if;

                  return IR.Emit_Unary
                           (Unit.all, Filling, IR.Negation,
                            Lower_Expression (Of_Tree, Under, Scope),
                            Scalar_At (Of_Tree, Node), Site);
               end;

            when Syn.Complement =>
               return IR.Emit_Unary
                        (Unit.all, Filling, IR.Complement,
                         Lower_Expression
                           (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                            Scope),
                         Scalar_At (Of_Tree, Node), Site);

            when Syn.Logical_Not =>
               return IR.Emit_Unary
                        (Unit.all, Filling, IR.Logical_Not,
                         Lower_Expression
                           (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                            Scope),
                         Scalar_At (Of_Tree, Node), Site);

            when Syn.Logical_And | Syn.Logical_Or =>
               return Lower_Short_Circuit (Of_Tree, Node, Scope);

            when Syn.Name_Reference =>
               declare
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
               begin
                  if Res.Sort_Of (Meanings.all, Means)
                     = Res.Module_Binding
                  then
                     return IR.Emit_Load_Datum
                              (Unit.all, Filling,
                               IR.Item_For (Unit.all, Means), Site);
                  end if;

                  return IR.Emit_Load
                           (Unit.all, Filling,
                            Slot_For (Of_Tree, Node, Means), Site);
               end;

            when Syn.Call =>
               return Lower_Call (Of_Tree, Node, Scope);

            when others =>
               --  [0410] fixes the order: the left, then the right, and a
               --  linear run of instructions is that order.
               declare
                  Left : constant IR.Value_Id :=
                    Lower_Expression
                      (Of_Tree, Syn.Left_Of (Of_Tree, Node), Scope);
                  Right : constant IR.Value_Id :=
                    Lower_Expression
                      (Of_Tree, Syn.Right_Of (Of_Tree, Node), Scope);
               begin
                  return IR.Emit_Binary
                           (Unit.all, Filling,
                            Opcode_For (Syn.Kind (Of_Tree, Node)),
                            Left, Right, Scalar_At (Of_Tree, Node), Site);
               end;
         end case;
      end Lower_Expression;

      ------------------------------------------------------------
      --  [1810]: a branch
      ------------------------------------------------------------

      procedure Lower_If
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id)
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Merge : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
      begin
         for Which in 1 .. Syn.Arm_Count (Of_Tree, Node) loop
            declare
               This : constant Syn.Node_Id :=
                 Syn.Nth_Arm (Of_Tree, Node, Which);
               Runs : constant Syn.Node_Id := Syn.Body_Of (Of_Tree, This);
               Inside : constant Res.Scope_Id :=
                 Res.Scope_At (Meanings.all, Of_Tree, Runs);
               Taken : constant IR.Block_Id :=
                 Fresh (Of_Tree, Runs, Inside);
               Next : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);
               Test : constant IR.Value_Id :=
                 Lower_Expression
                   (Of_Tree, Syn.Condition_Of (Of_Tree, This), Scope);
            begin
               IR.Emit_Branch
                 (Unit.all, Filling, Test, Taken, Next, Site);
               IR.Leave_Block (Unit.all, Filling);
               Current := IR.No_Block;

               Open (Taken);
               Lower_Statements (Of_Tree, Runs, Inside, Result);

               if Current /= IR.No_Block then
                  Close_With_Jump (Merge, Site);
               end if;

               --  The next arm's test, or the `else`, is written here.
               Open (Next);
            end;
         end loop;

         if Syn.Else_Body (Of_Tree, Node) /= Syn.No_Node then
            declare
               Runs : constant Syn.Node_Id :=
                 Syn.Else_Body (Of_Tree, Node);
               Inside : constant Res.Scope_Id :=
                 Res.Scope_At (Meanings.all, Of_Tree, Runs);
               Otherwise : constant IR.Block_Id :=
                 Fresh (Of_Tree, Runs, Inside);
            begin
               --  A block of its own, because [1840] makes the `else` a
               --  scope of its own and a block carries one scope.
               Close_With_Jump (Otherwise, Site);
               Open (Otherwise);
               Lower_Statements (Of_Tree, Runs, Inside, Result);
            end;
         end if;

         if Current /= IR.No_Block then
            Close_With_Jump (Merge, Site);
         end if;

         --  Always entered, even when every path returned.  A block that
         --  was created and never filled has no terminator, and an
         --  unreachable block that is well formed costs one jump nobody
         --  executes.
         Open (Merge);
      end Lower_If;

      ------------------------------------------------------------
      --  [1810]: statements
      ------------------------------------------------------------

      procedure Lower_Statements
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id) is
      begin
         for Which in 1 .. Syn.Statement_Count (Of_Tree, Block) loop
            exit when Current = IR.No_Block;

            declare
               Stmt : constant Syn.Node_Id :=
                 Syn.Nth_Statement (Of_Tree, Block, Which);
               Site : constant Landin.Provenance.Origin :=
                 Site_Of (Of_Tree, Stmt);

               --  [1900]: a place is a name, and which of the two kinds
               --  it is decides whether a Store or a Store_Datum says it.
               procedure Write (Place : Syn.Node_Id; Value : IR.Value_Id);

               procedure Write (Place : Syn.Node_Id; Value : IR.Value_Id)
               is
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Place);
               begin
                  if Res.Sort_Of (Meanings.all, Means)
                     = Res.Module_Binding
                  then
                     IR.Emit_Store_Datum
                       (Unit.all, Filling,
                        IR.Item_For (Unit.all, Means), Value, Site);
                  else
                     IR.Emit_Store
                       (Unit.all, Filling,
                        Slot_For (Of_Tree, Place, Means), Value, Site);
                  end if;
               end Write;

            begin
               case Syn.Kind (Of_Tree, Stmt) is
                  when Syn.Binding =>
                     declare
                        Id : constant Res.Declaration_Id :=
                          Declaration_At (Syn.Source_Of (Of_Tree), Stmt);
                        Where : constant IR.Slot_Id :=
                          Slot_For (Of_Tree, Stmt, Id);
                        Value : constant Syn.Node_Id :=
                          Syn.Value_Of (Of_Tree, Stmt);
                     begin
                        if Value /= Syn.No_Node then
                           IR.Emit_Store
                             (Unit.all, Filling, Where,
                              Lower_Expression (Of_Tree, Value, Scope),
                              Site);
                        end if;
                     end;

                  when Syn.Assignment =>
                     Write
                       (Syn.Target_Of (Of_Tree, Stmt),
                        Lower_Expression
                          (Of_Tree, Syn.Value_Of (Of_Tree, Stmt), Scope));

                  when Syn.Increment | Syn.Decrement =>
                     --  [1900]: `inc` says what `x += 1` says, which is a
                     --  load, a one, a trapping add and a store.
                     declare
                        Place : constant Syn.Node_Id :=
                          Syn.Target_Of (Of_Tree, Stmt);
                        Held : constant Ty.Scalar_Name :=
                          Scalar_At (Of_Tree, Place);
                        Was : constant IR.Value_Id :=
                          Lower_Expression (Of_Tree, Place, Scope);
                        One : constant IR.Value_Id :=
                          IR.Emit_Number
                            (Unit.all, Filling, Held, 1, False, Site);
                        Op : constant IR.Opcode :=
                          (if Syn.Kind (Of_Tree, Stmt) = Syn.Increment
                           then IR.Add else IR.Subtract);
                     begin
                        Write
                          (Place,
                           IR.Emit_Binary
                             (Unit.all, Filling, Op, Was, One, Held,
                              Site));
                     end;

                  when Syn.Discard =>
                     --  [1930]: the value is thrown away, which is an
                     --  unused value and needs no opcode to say so.
                     declare
                        Ignored : constant IR.Value_Id :=
                          Lower_Expression
                            (Of_Tree, Syn.Value_Of (Of_Tree, Stmt),
                             Scope);
                     begin
                        pragma Assert (Ignored /= IR.No_Value);
                     end;

                  when Syn.Call =>
                     declare
                        Ignored : constant IR.Value_Id :=
                          Lower_Call (Of_Tree, Stmt, Scope);
                     begin
                        pragma Assert (Ignored /= IR.No_Value);
                     end;

                  when Syn.Return_Statement =>
                     if Syn.Condition_Of (Of_Tree, Stmt) = Syn.No_Node
                     then
                        Leave_With (Result, Site);
                     else
                        --  [1810]: only an exit carries `when`, so the
                        --  flow below it is reachable and the guard is a
                        --  branch into a block that leaves.
                        declare
                           Goes : constant IR.Block_Id :=
                             Fresh (Of_Tree, Stmt, Scope);
                           Stays : constant IR.Block_Id :=
                             Fresh (Of_Tree, Stmt, Scope);
                           Test : constant IR.Value_Id :=
                             Lower_Expression
                               (Of_Tree,
                                Syn.Condition_Of (Of_Tree, Stmt), Scope);
                        begin
                           IR.Emit_Branch
                             (Unit.all, Filling, Test, Goes, Stays, Site);
                           IR.Leave_Block (Unit.all, Filling);
                           Current := IR.No_Block;

                           Open (Goes);
                           Leave_With (Result, Site);

                           Open (Stays);
                        end;
                     end if;

                  when Syn.If_Statement =>
                     Lower_If (Of_Tree, Stmt, Scope, Result);

                  when others =>
                     raise Landin.Compiler_Defect with
                       "a statement the lowering does not know";
               end case;
            end;
         end loop;
      end Lower_Statements;

      ------------------------------------------------------------
      --  [1800]: a function
      ------------------------------------------------------------

      procedure Lower_Routine (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

      procedure Lower_Routine (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Src : constant Landin.Source.Source_Id := Syn.Source_Of (Of_Tree);
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Signature : constant Res.Scope_Id :=
           Res.Scope_At (Meanings.all, Of_Tree, Node);
         Runs : constant Syn.Node_Id := Syn.Body_Of (Of_Tree, Node);
         Gives : constant Syn.Node_Id := Syn.Return_Of (Of_Tree, Node);
         Result : IR.Slot_Id := IR.No_Slot;
      begin
         Filling := IR.Item_For (Unit.all, Declaration_At (Src, Node));
         Slots := No_Slots;

         --  [1920] names the parameters in order, so the run is that
         --  order and the ABI has somewhere to put an argument.
         for Which in 1 .. Syn.Parameter_Count (Of_Tree, Node) loop
            declare
               Param : constant Syn.Node_Id :=
                 Syn.Nth_Parameter (Of_Tree, Node, Which);
               Id : constant Res.Declaration_Id :=
                 Declaration_At (Src, Param);
               Held : constant Ty.Type_Kind :=
                 Landin.Checking.Type_Of (Types.all, Id);
            begin
               if Held not in Ty.Scalar_Name then
                  raise Landin.Compiler_Defect with
                    "a parameter reached the lowering with no scalar type";
               end if;

               Slots (Positive (Id)) :=
                 IR.Add_Parameter
                   (Unit.all, Filling, Held, Id, Site_Of (Of_Tree, Param));
            end;
         end loop;

         if Gives /= Syn.No_Node then
            declare
               Id : constant Res.Declaration_Id :=
                 Declaration_At (Src, Gives);
            begin
               Result := Slot_For (Of_Tree, Gives, Id);
               IR.Set_Result_Slot (Unit.all, Filling, Result);
            end;
         end if;

         if Syn.Kind (Of_Tree, Runs) = Syn.Block then
            declare
               Inside : constant Res.Scope_Id :=
                 Res.Scope_At (Meanings.all, Of_Tree, Runs);
            begin
               Open (Fresh (Of_Tree, Runs, Inside));
               Lower_Statements (Of_Tree, Runs, Inside, Result);

               --  [0930]: the named return is assigned by every path that
               --  reaches the end, so falling off it leaves with the
               --  value that is in it.
               if Current /= IR.No_Block then
                  Leave_With (Result, Site);
               end if;
            end;
         else
            --  [0880]: the expression fills the named return, and [1840]
            --  says it opens no scope, so its block is the signature's.
            Open (Fresh (Of_Tree, Runs, Signature));

            declare
               Value : constant IR.Value_Id :=
                 Lower_Expression (Of_Tree, Runs, Signature);
            begin
               if Result /= IR.No_Slot then
                  IR.Emit_Store
                    (Unit.all, Filling, Result, Value, Site);
               end if;
            end;

            Leave_With (Result, Site);
         end if;

         Filling := IR.No_Item;
      end Lower_Routine;

   begin
      --  Nothing that was refused is lowered, and this stage says so
      --  itself rather than trusting the order it was queued in.  R1.70
      --  assigns no diagnostic code because malformed IR cannot come from
      --  a source program, and that is only true while this holds.
      if Failed (Context) then
         Outcome := Stop;
         return;
      end if;

      IR.Prepare (Unit.all, Meanings.all);

      --  Pass one: every item, over every tree, before any is filled.
      --  [1740] makes a module a set, so `f` may call `g` written below
      --  it, and Emit_Call needs `g`'s item to exist by then.
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Nth_Source (Context, Index));
            Src : constant Landin.Source.Source_Id :=
              Syn.Source_Of (Of_Tree.all);
         begin
            for Which in
              1 .. Syn.Declaration_Count (Of_Tree.all)
            loop
               declare
                  Node : constant Syn.Node_Id :=
                    Syn.Nth_Declaration (Of_Tree.all, Which);
                  Id : constant Res.Declaration_Id :=
                    Declaration_At (Src, Node);
                  Made : IR.Item_Id;
               begin
                  case Syn.Kind (Of_Tree.all, Node) is
                     when Syn.Function_Declaration =>
                        declare
                           Gives : constant Syn.Node_Id :=
                             Syn.Return_Of (Of_Tree.all, Node);
                           Held : constant Ty.Type_Kind :=
                             (if Gives = Syn.No_Node then Ty.No_Value
                              else Landin.Checking.Type_Of
                                     (Types.all,
                                      Declaration_At (Src, Gives)));
                        begin
                           Made :=
                             IR.Add_Item
                               (Unit.all, IR.Routine, Id, Held,
                                Site_Of (Of_Tree.all, Node));
                        end;

                     when Syn.Binding =>
                        Made :=
                          IR.Add_Item
                            (Unit.all, IR.Datum, Id,
                             Landin.Checking.Type_Of (Types.all, Id),
                             Site_Of (Of_Tree.all, Node));

                     when others =>
                        Made := IR.No_Item;
                  end case;

                  pragma Assert (Made /= IR.No_Item or else True);
               end;
            end loop;
         end;
      end loop;

      --  Pass two: fill them, one at a time.  An item's slots, blocks and
      --  instructions are runs in shared vectors, and Landin.IR.Open_Run
      --  refuses an interleaved fill.
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Nth_Source (Context, Index));
         begin
            for Which in
              1 .. Syn.Declaration_Count (Of_Tree.all)
            loop
               declare
                  Node : constant Syn.Node_Id :=
                    Syn.Nth_Declaration (Of_Tree.all, Which);
               begin
                  if Syn.Kind (Of_Tree.all, Node)
                     = Syn.Function_Declaration
                  then
                     Lower_Routine (Of_Tree.all, Node);
                  end if;
               end;
            end loop;
         end;
      end loop;

      Outcome := Continue;
   end Run;

end Landin.Stages.Lowering;
