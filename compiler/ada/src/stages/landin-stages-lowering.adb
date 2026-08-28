with Landin.Checking;
with Landin.IR;
with Landin.IR.Verifier;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;
with Landin.Types;

package body Landin.Stages.Lowering is

   package Syn renames Landin.Syntax;
   package Res renames Landin.Resolution;
   package Ty  renames Landin.Types;
   package IR  renames Landin.IR;

   use type IR.Block_Id;
   use type IR.Element_Total;
   use type IR.Field_Image_Form;
   use type IR.Field_Shape_Kind;
   use type IR.Item_Id;
   use type IR.Slot_Id;
   use type IR.Part_Position;
   use type IR.Value_Id;
   use type Landin.Checking.Element_Count;
   use type Landin.Checking.Field_Kind;
   use type Landin.Source.Source_Id;
   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Count;
   use type Res.Declaration_Id;
   use type Res.Declaration_Sort;
   use type Res.Verdict;
   use type Ty.Folded;
   use type Ty.Magnitude;
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
      Facts : constant Landin.Targets.Target_Facts :=
        Landin.Stages.Target (Context);

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

      --  D78's arm bindings are aliases into the selected payload, not
      --  copied frame locals.  The declaration identity is arm-local; the
      --  source storage and three source-order identities remain target
      --  neutral until the backend derives an offset.
      type Payload_Alias is record
         Active        : Boolean := False;
         Source        : IR.Storage;
         Field         : Natural := 0;
         Which         : Natural := 0;
         Payload_Field : Natural := 0;
      end record;

      type Alias_Map is array (Declared) of Payload_Alias;
      Aliases : Alias_Map := [others => (others => <>)];

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

      --  D75 uses D74's one variant carrier for both storage classes.
      --  Exactly one destination identity is supplied; payload leaves remain
      --  scalar or fixed-array shapes, and all offsets stay target-owned.
      procedure Add_Stored_Field
        (Wrote : Res.Declaration_Id;
         Field : Positive;
         Datum : IR.Item_Id := IR.No_Item;
         Slot  : IR.Slot_Id := IR.No_Slot);

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

      procedure Lower_Match
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

      --  [1880]'s known index: a literal, or unary minus over one.  The
      --  checker has refused every such value outside the array; every
      --  other expression becomes [1950]'s checked runtime operand.
      function Is_Constant_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Is_Constant_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
         Written : constant Syn.Node_Id := Syn.Index_Of (Of_Tree, Node);
      begin
         return Syn.Kind (Of_Tree, Written) = Syn.Integer_Literal
           or else
             (Syn.Kind (Of_Tree, Written) = Syn.Negation
              and then Syn.Kind
                         (Of_Tree, Syn.Operand_Of (Of_Tree, Written))
                         = Syn.Integer_Literal);
      end Is_Constant_Index;

      --  What known brackets held, as the position it names.
      function Constant_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Part_Position;

      function Constant_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Part_Position
      is
         Written : constant Syn.Node_Id := Syn.Index_Of (Of_Tree, Node);

         --  `-0` is an index like any other: [1880] makes it known, its
         --  value is zero, and the checker refused every other negated
         --  one as outside the length.  So the minus is read through.
         Where : constant Syn.Node_Id :=
           (if Syn.Kind (Of_Tree, Written) = Syn.Negation
            then Syn.Operand_Of (Of_Tree, Written)
            else Written);
         Snap  : constant Landin.Source.Snapshot :=
           Source (Context, Syn.Source_Of (Of_Tree));
         Text  : constant String :=
           Landin.Source.Slice (Snap, Syn.Digit_Span (Of_Tree, Where));
         Value      : Ty.Magnitude;
         Overflowed : Boolean;
      begin
         if Syn.Kind (Of_Tree, Where) /= Syn.Integer_Literal then
            raise Landin.Compiler_Defect with
              "an index the checker did not settle reached the lowering";
         end if;

         Ty.Evaluate (Text, Syn.Base (Of_Tree, Where), Value, Overflowed);

         --  One-based here, zero-based in the source: [0520] counts an
         --  array's elements from zero and every run in this compiler
         --  counts from one, and this is the one place the two meet.
         --  Zero-based in the source [0520] and one-based in every run
         --  this compiler keeps, and this is the one place the two meet.
         --  Added before converting, because a Part_Position starts at
         --  one and index zero is the first element.
         return IR.Part_Position (Value + 1);
      end Constant_Index;

      procedure Add_Stored_Field
        (Wrote : Res.Declaration_Id;
         Field : Positive;
         Datum : IR.Item_Id := IR.No_Item;
         Slot  : IR.Slot_Id := IR.No_Slot)
      is
         procedure Add (Shape : IR.Field_Shape);

         procedure Add (Shape : IR.Field_Shape) is
         begin
            if Datum /= IR.No_Item then
               IR.Add_Field (Unit.all, Datum, Shape);
            else
               IR.Add_Slot_Field (Unit.all, Filling, Slot, Shape);
            end if;
         end Add;
      begin
         pragma Assert ((Datum = IR.No_Item) /= (Slot = IR.No_Slot));

         case Landin.Checking.Field_Kind_Of (Types.all, Wrote, Field) is
            when Landin.Checking.Scalar_Field =>
               Add
                 ((Kind    => IR.Scalar_Field_Shape,
                   Element => Landin.Checking.Field_Type
                     (Types.all, Wrote, Field),
                   Length  => 1,
                   others  => <>));

            when Landin.Checking.Fixed_Array_Field =>
               Add
                 ((Kind    => IR.Array_Field_Shape,
                   Element => Landin.Checking.Field_Array_Element
                     (Types.all, Wrote, Field),
                   Length  => IR.Element_Total
                     (Landin.Checking.Field_Array_Length
                        (Types.all, Wrote, Field)),
                   others  => <>));

            when Landin.Checking.Aggregate_Field =>
               declare
                  Source : constant Landin.Checking.Field_Shape :=
                    Landin.Checking.Field_Shape_Of
                      (Types.all, Wrote, Field);
                  Child : constant Res.Declaration_Id :=
                    Source.Aggregate_Body;
                  Count : constant Natural :=
                    Landin.Checking.Layout_Field_Count
                      (Types.all, Child);
                  Payloads : IR.Field_Shape_Array (1 .. Count) :=
                    [others => (others => <>)];
               begin
                  for Position in 1 .. Count loop
                     declare
                        Part : constant Landin.Checking.Field_Shape :=
                          Landin.Checking.Field_Shape_Of
                            (Types.all, Child, Position);
                     begin
                        Payloads (Position) :=
                          (Kind =>
                             (if Part.Kind = Landin.Checking.Scalar_Field
                              then IR.Scalar_Field_Shape
                              else IR.Array_Field_Shape),
                           Element => Part.Element,
                           Length  => IR.Element_Total (Part.Length),
                           others  => <>);
                     end;
                  end loop;

                  if Datum /= IR.No_Item then
                     IR.Add_Field
                       (Unit.all, Datum,
                        (Kind           => IR.Aggregate_Field_Shape,
                         Element        => Ty.Bool,
                         Length         => 1,
                         Cases          => Count,
                         Payloads_First => 1),
                        IR.No_Case_Runs, Payloads);
                  else
                     IR.Add_Slot_Field
                       (Unit.all, Filling, Slot,
                        (Kind           => IR.Aggregate_Field_Shape,
                         Element        => Ty.Bool,
                         Length         => 1,
                         Cases          => Count,
                         Payloads_First => 1),
                        IR.No_Case_Runs, Payloads);
                  end if;
               end;

            when Landin.Checking.Variant_Field =>
               declare
                  Source : constant Landin.Checking.Field_Shape :=
                    Landin.Checking.Field_Shape_Of
                      (Types.all, Wrote, Field);
                  Total : Natural := 0;
               begin
                  for Which in 1 .. Source.Cases loop
                     Total := Total
                       + Landin.Checking.Variant_Case_Field_Count
                           (Types.all, Wrote, Field, Which);
                  end loop;

                  declare
                     Cases : IR.Case_Run_Array (1 .. Source.Cases) :=
                       [others => (others => 0)];
                     Payloads : IR.Field_Shape_Array (1 .. Total) :=
                       [others => (others => <>)];
                     Next : Natural := 1;
                  begin
                     for Which in 1 .. Source.Cases loop
                        declare
                           Count : constant Natural :=
                             Landin.Checking.Variant_Case_Field_Count
                               (Types.all, Wrote, Field, Which);
                        begin
                           Cases (Which) :=
                             (First => (if Count = 0 then 0 else Next),
                              Count => Count);
                           for Position in 1 .. Count loop
                              declare
                                 Part : constant Landin.Checking.Field_Shape :=
                                   Landin.Checking.Nth_Variant_Case_Field
                                     (Types.all, Wrote, Field, Which,
                                      Position);
                              begin
                                 Payloads (Next) :=
                                   (Kind =>
                                      (if Part.Kind =
                                            Landin.Checking.Scalar_Field
                                       then IR.Scalar_Field_Shape
                                       else IR.Array_Field_Shape),
                                    Element => Part.Element,
                                    Length  => IR.Element_Total (Part.Length),
                                    others  => <>);
                                 Next := Next + 1;
                              end;
                           end loop;
                        end;
                     end loop;

                     if Datum /= IR.No_Item then
                        IR.Add_Field
                          (Unit.all, Datum,
                           (Kind           => IR.Variant_Field_Shape,
                            Element        => Source.Element,
                            Length         => 1,
                            Cases          => Source.Cases,
                            Payloads_First => 1),
                           Cases, Payloads);
                     else
                        IR.Add_Slot_Field
                          (Unit.all, Filling, Slot,
                           (Kind           => IR.Variant_Field_Shape,
                            Element        => Source.Element,
                            Length         => 1,
                            Cases          => Source.Cases,
                            Payloads_First => 1),
                           Cases, Payloads);
                     end if;
                  end;
               end;
         end case;
      end Add_Stored_Field;

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

         --  D19's local array is one compact frame cell.  Its shape derives
         --  every known element operation without one IR field per element.
         if Held = Ty.Fixed_Array then
            Slots (Positive (Id)) :=
              IR.Add_Array_Slot
                (Unit.all, Filling,
                 Landin.Checking.Array_Element (Types.all, Id),
                 IR.Element_Total
                   (Landin.Checking.Array_Length (Types.all, Id)),
                 Id,
                 Site_Of (Of_Tree, Node));
            return Slots (Positive (Id));
         end if;

         --  [0670]'s local: a cell holding a whole struct, carrying its
         --  fields' types the way an aggregate datum does.
         if Held = Ty.Aggregate then
            Slots (Positive (Id)) :=
              IR.Add_Aggregate_Slot
                (Unit.all, Filling, Id, Site_Of (Of_Tree, Node));

            for Field in
              1 .. Landin.Checking.Layout_Field_Count (Types.all, Id)
            loop
               Add_Stored_Field
                 (Id, Field, Slot => Slots (Positive (Id)));
            end loop;

            return Slots (Positive (Id));
         end if;

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
         Saved : array (1 .. Positive'Max (1, Count)) of IR.Slot_Id :=
           [others => IR.No_Slot];
         Made : IR.Value_Id;
      begin
         --  [0410] fixes argument evaluation left to right.  Every argument
         --  with another after it crosses through a slot before that later
         --  expression runs: a short circuit there can change blocks, and
         --  operands are block-local.  The last argument is already in the
         --  block where the call will be emitted.
         for Which in 1 .. Count loop
            declare
               Argument : constant Syn.Node_Id :=
                 Syn.Nth_Argument (Of_Tree, Node, Which);
            begin
               Given (Which) := Lower_Expression (Of_Tree, Argument, Scope);

               if Which < Count then
                  Saved (Which) :=
                    IR.Add_Slot
                      (Unit.all, Filling, Scalar_At (Of_Tree, Argument),
                       Res.No_Declaration, Site_Of (Of_Tree, Argument));
                  IR.Emit_Store
                    (Unit.all, Filling, Saved (Which), Given (Which),
                     Site_Of (Of_Tree, Argument));
               end if;
            end;
         end loop;

         --  Every argument must precede the call, because Add_Argument
         --  requires the call to remain the last instruction emitted.
         for Which in 1 .. Count loop
            if Which < Count then
               Given (Which) :=
                 IR.Emit_Load (Unit.all, Filling, Saved (Which), Site);
            end if;
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

            when Syn.Zeroed_Literal =>
               --  D40--D43: the checker admits this expression only where a
               --  scalar initializer or assignment destination supplies its
               --  type.  Reuse D10/D39's constants; the surrounding binding or
               --  assignment path emits its ordinary store.
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Node) = Ty.Bool
               then
                  return IR.Emit_Truth (Unit.all, Filling, False, Site);
               else
                  return IR.Emit_Number
                           (Unit.all, Filling, Scalar_At (Of_Tree, Node),
                            0, False, Site);
               end if;

            --  [0370]: the type asked about is carried into the IR and the
            --  target-dependent answer is not.  D17 decomposes a fixed array
            --  into operations the IR already has; D44/D45 carry an ordinary
            --  struct as its declaration-order scalar or compact fixed-array
            --  field run; D74/D75 also carry shared variant case payload
            --  runs.  A nonempty array has its element's alignment;
            --  the internal empty shape has size zero and alignment one.
            when Syn.Size_Of | Syn.Align_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Measured_Type (Of_Tree, Node);
                  Held : constant Ty.Type_Kind :=
                    Landin.Checking.Type_Of (Types.all, Of_Tree, Asked);
                  Result : constant Ty.Scalar_Name :=
                    Scalar_At (Of_Tree, Node);
               begin
                  if Held = Ty.Aggregate then
                     declare
                        Declared : constant Res.Declaration_Id :=
                          Landin.Checking.Body_Of
                            (Types.all, Of_Tree, Asked);
                        function Total_Cases return Natural;
                        function Total_Payload_Fields return Natural;

                        function Total_Cases return Natural is
                           Total : Natural := 0;
                        begin
                           for Field in 1 .. Landin.Checking.Layout_Field_Count
                             (Types.all, Declared)
                           loop
                              if Landin.Checking.Field_Kind_Of
                                (Types.all, Declared, Field)
                                  = Landin.Checking.Variant_Field
                              then
                                 Total := Total
                                   + Landin.Checking.Field_Shape_Of
                                      (Types.all, Declared, Field).Cases;
                              end if;
                           end loop;
                           return Total;
                        end Total_Cases;

                        function Total_Payload_Fields return Natural is
                           Total : Natural := 0;
                        begin
                           for Field in 1 .. Landin.Checking.Layout_Field_Count
                             (Types.all, Declared)
                           loop
                              if Landin.Checking.Field_Kind_Of
                                (Types.all, Declared, Field)
                                  = Landin.Checking.Variant_Field
                              then
                                 for Which in 1 ..
                                   Landin.Checking.Field_Shape_Of
                                     (Types.all, Declared, Field).Cases
                                 loop
                                    Total := Total +
                                      Landin.Checking.Variant_Case_Field_Count
                                        (Types.all, Declared, Field, Which);
                                 end loop;
                              elsif Landin.Checking.Field_Kind_Of
                                (Types.all, Declared, Field)
                                  = Landin.Checking.Aggregate_Field
                              then
                                 Total := Total
                                   + Landin.Checking.Layout_Field_Count
                                       (Types.all,
                                        Landin.Checking.Field_Shape_Of
                                          (Types.all, Declared, Field)
                                            .Aggregate_Body);
                              end if;
                           end loop;
                           return Total;
                        end Total_Payload_Fields;

                        Fields : IR.Field_Shape_Array
                          (1 .. Landin.Checking.Layout_Field_Count
                                  (Types.all, Declared));
                        Cases : IR.Case_Run_Array (1 .. Total_Cases) :=
                          [others => (others => 0)];
                        Payloads : IR.Field_Shape_Array
                          (1 .. Total_Payload_Fields) :=
                            [others => (others => <>)];
                        Next_Case : Natural := 1;
                        Next_Payload : Natural := 1;
                     begin
                        for Field in Fields'Range loop
                           case Landin.Checking.Field_Kind_Of
                             (Types.all, Declared, Field)
                           is
                              when Landin.Checking.Scalar_Field =>
                                 Fields (Field) :=
                                   (Kind    => IR.Scalar_Field_Shape,
                                    Element => Landin.Checking.Field_Type
                                      (Types.all, Declared, Field),
                                    Length  => 1,
                                    others  => <>);

                              when Landin.Checking.Fixed_Array_Field =>
                                 Fields (Field) :=
                                   (Kind    => IR.Array_Field_Shape,
                                    Element =>
                                      Landin.Checking.Field_Array_Element
                                        (Types.all, Declared, Field),
                                    Length  => IR.Element_Total
                                      (Landin.Checking.Field_Array_Length
                                         (Types.all, Declared, Field)),
                                    others  => <>);

                              when Landin.Checking.Aggregate_Field =>
                                 declare
                                    Shape : constant
                                      Landin.Checking.Field_Shape :=
                                        Landin.Checking.Field_Shape_Of
                                          (Types.all, Declared, Field);
                                    Child : constant Res.Declaration_Id :=
                                      Shape.Aggregate_Body;
                                    Count : constant Natural :=
                                      Landin.Checking.Layout_Field_Count
                                        (Types.all, Child);
                                 begin
                                    Fields (Field) :=
                                      (Kind           =>
                                         IR.Aggregate_Field_Shape,
                                       Element        => Ty.Bool,
                                       Length         => 1,
                                       Cases          => Count,
                                       Payloads_First => Next_Payload);

                                    for Position in 1 .. Count loop
                                       declare
                                          Part : constant Landin.Checking
                                            .Field_Shape :=
                                              Landin.Checking.Field_Shape_Of
                                                (Types.all, Child, Position);
                                       begin
                                          Payloads (Next_Payload) :=
                                            (Kind =>
                                               (if Part.Kind =
                                                  Landin.Checking.Scalar_Field
                                                then IR.Scalar_Field_Shape
                                                else IR.Array_Field_Shape),
                                             Element => Part.Element,
                                             Length  => IR.Element_Total
                                               (Part.Length),
                                             others  => <>);
                                          Next_Payload := Next_Payload + 1;
                                       end;
                                    end loop;
                                 end;

                              when Landin.Checking.Variant_Field =>
                                 declare
                                    Shape : constant
                                      Landin.Checking.Field_Shape :=
                                        Landin.Checking.Field_Shape_Of
                                          (Types.all, Declared, Field);
                                 begin
                                    Fields (Field) :=
                                      (Kind           =>
                                         IR.Variant_Field_Shape,
                                       Element        => Shape.Element,
                                       Length         => 1,
                                       Cases          => Shape.Cases,
                                       Payloads_First => Next_Case);

                                    for Which in 1 .. Shape.Cases loop
                                       declare
                                          Count : constant Natural :=
                                            Landin.Checking
                                              .Variant_Case_Field_Count
                                                (Types.all, Declared,
                                                 Field, Which);
                                       begin
                                          Cases (Next_Case) :=
                                            (First =>
                                               (if Count = 0
                                                then 0 else Next_Payload),
                                             Count => Count);
                                          Next_Case := Next_Case + 1;

                                          for Position in 1 .. Count loop
                                             declare
                                                Part : constant Landin.Checking
                                                  .Field_Shape :=
                                                    Landin.Checking
                                                      .Nth_Variant_Case_Field
                                                        (Types.all, Declared,
                                                         Field, Which,
                                                         Position);
                                             begin
                                                Payloads (Next_Payload) :=
                                                  (Kind =>
                                                     (if Part.Kind =
                                                        Landin.Checking
                                                          .Scalar_Field
                                                      then IR
                                                        .Scalar_Field_Shape
                                                      else IR
                                                        .Array_Field_Shape),
                                                   Element => Part.Element,
                                                   Length  => IR.Element_Total
                                                     (Part.Length),
                                                   others  => <>);
                                                Next_Payload :=
                                                  Next_Payload + 1;
                                             end;
                                          end loop;
                                       end;
                                    end loop;
                                 end;
                           end case;
                        end loop;

                        return IR.Emit_Aggregate_Measurement
                          (Unit.all, Filling,
                           (if Syn.Kind (Of_Tree, Node) = Syn.Size_Of
                            then IR.Measure_Size else IR.Measure_Align),
                           Fields, Result, Site,
                           Cases => Cases, Payloads => Payloads);
                     end;
                  elsif Held /= Ty.Fixed_Array then
                     return IR.Emit_Measurement
                              (Unit.all, Filling,
                               (if Syn.Kind (Of_Tree, Node) = Syn.Size_Of
                                then IR.Measure_Size else IR.Measure_Align),
                               Ty.Scalar_Name (Held), Result, Site);
                  end if;

                  declare
                     Length : constant Landin.Checking.Element_Count :=
                       Landin.Checking.Array_Length
                         (Types.all, Of_Tree, Asked);
                     Element : constant Ty.Scalar_Name :=
                       Landin.Checking.Array_Element
                         (Types.all, Of_Tree, Asked);
                  begin
                     if Syn.Kind (Of_Tree, Node) = Syn.Align_Of then
                        if Length = 0 then
                           return IR.Emit_Number
                                    (Unit.all, Filling, Result,
                                     1, False, Site);
                        end if;

                        return IR.Emit_Measurement
                                 (Unit.all, Filling, IR.Measure_Align,
                                  Element, Result, Site);
                     end if;

                     declare
                        Element_Size : constant IR.Value_Id :=
                          IR.Emit_Measurement
                            (Unit.all, Filling, IR.Measure_Size,
                             Element, Result, Site);
                        Count : constant IR.Value_Id :=
                          IR.Emit_Number
                            (Unit.all, Filling, Result,
                             Ty.Magnitude (Length), False, Site);
                     begin
                        return IR.Emit_Binary
                                 (Unit.all, Filling, IR.Multiply,
                                  Count, Element_Size, Result, Site);
                     end;
                  end;
               end;

            --  [0370]: unlike byte measurements, an array's element count is
            --  target-neutral.  D14 takes it from a named array's type; D31
            --  takes it from a literal's source run without lowering an
            --  element.  Both use the existing usize Number.
            when Syn.Len_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Operand_Of (Of_Tree, Node);
                  Length : constant Ty.Magnitude :=
                    (if Syn.Kind (Of_Tree, Asked) = Syn.Array_Literal
                     then Ty.Magnitude (Syn.Element_Count (Of_Tree, Asked))
                     else Ty.Magnitude
                            (Landin.Checking.Array_Length
                               (Types.all,
                                Res.Bound_To
                                  (Meanings.all, Of_Tree, Asked))));
               begin
                  return IR.Emit_Number
                           (Unit.all, Filling, Scalar_At (Of_Tree, Node),
                            Length, False, Site);
               end;

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

            when Syn.Element_Index =>
               --  [0570]'s element of [1740]'s module array or [1810]'s
               --  local array.  A known position stays the compact static
               --  part operation; every other `usize` is an operand the
               --  backend checks before it forms an address [1950].  D22
               --  gives a local array the same computed-index path a
               --  module array has, reaching a frame slot rather than a
               --  datum symbol.
               declare
                  From : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Nested : constant Boolean :=
                    Syn.Kind (Of_Tree, From) = Syn.Member_Selection;
                  Named : constant Syn.Node_Id :=
                    (if Nested then Syn.Target_Of (Of_Tree, From) else From);
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Named);
                  Field : constant Natural :=
                    (if Nested
                     then Landin.Checking.Field_Index
                            (Types.all, Of_Tree, From)
                     else 0);
               begin
                  if Res.Sort_Of (Meanings.all, Means)
                       = Res.Pattern_Binding
                  then
                     declare
                        Alias : Payload_Alias renames
                          Aliases (Declared (Means));
                        Index : constant IR.Value_Id :=
                          Lower_Expression
                            (Of_Tree, Syn.Index_Of (Of_Tree, Node), Scope);
                     begin
                        if not Alias.Active then
                           raise Landin.Compiler_Defect with
                             "an inactive array match binding reached"
                             & " lowering";
                        end if;
                        case Alias.Source.Kind is
                           when IR.Module_Datum =>
                              return IR.Emit_Load_Element
                                (Unit.all, Filling, Alias.Source.Datum,
                                 Index, Scalar_At (Of_Tree, Node), Site,
                                 Field => Alias.Field,
                                 Variant_Case => Alias.Which,
                                 Variant_Payload_Field =>
                                   Alias.Payload_Field);
                           when IR.Frame_Slot =>
                              return IR.Emit_Load_Slot_Element
                                (Unit.all, Filling, Alias.Source.Slot,
                                 Index, Scalar_At (Of_Tree, Node), Site,
                                 Field => Alias.Field,
                                 Variant_Case => Alias.Which,
                                 Variant_Payload_Field =>
                                   Alias.Payload_Field);
                        end case;
                     end;
                  end if;

                  if Res.Sort_Of (Meanings.all, Means)
                     = Res.Local_Binding
                  then
                     if Is_Constant_Index (Of_Tree, Node)
                       and then not Nested
                     then
                        return IR.Emit_Load_Slot_Field
                                 (Unit.all, Filling,
                                  Slot_For (Of_Tree, Named, Means),
                                  Constant_Index (Of_Tree, Node),
                                  Scalar_At (Of_Tree, Node), Site);
                     end if;

                     return IR.Emit_Load_Slot_Element
                              (Unit.all, Filling,
                               Slot_For (Of_Tree, Named, Means),
                               Lower_Expression
                                 (Of_Tree, Syn.Index_Of (Of_Tree, Node),
                                  Scope),
                               Scalar_At (Of_Tree, Node), Site,
                               Field => Field);
                  end if;

                  if Is_Constant_Index (Of_Tree, Node) and then not Nested
                  then
                     return IR.Emit_Load_Field
                              (Unit.all, Filling,
                               IR.Item_For (Unit.all, Means),
                               Constant_Index (Of_Tree, Node),
                               Scalar_At (Of_Tree, Node), Site);
                  end if;

                  return IR.Emit_Load_Element
                           (Unit.all, Filling,
                            IR.Item_For (Unit.all, Means),
                            Lower_Expression
                              (Of_Tree, Syn.Index_Of (Of_Tree, Node), Scope),
                            Scalar_At (Of_Tree, Node), Site,
                            Field => Field);
               end;

            when Syn.Member_Selection =>
               --  [0750]'s field of a struct.  The checker settled which
               --  field the name selects, so this carries the answer
               --  rather than looking a name up a second time; what it
               --  is a field *of* decides whether the base is [1740]'s
               --  module state or a cell in this frame.
               declare
                  From : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Nested : constant Boolean :=
                    Syn.Kind (Of_Tree, From) = Syn.Member_Selection;
                  Named : constant Syn.Node_Id :=
                    (if Nested
                     then Syn.Target_Of (Of_Tree, From)
                     else From);
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Named);
                  Which : constant IR.Part_Position :=
                    IR.Part_Position
                      (Landin.Checking.Field_Index
                         (Types.all, Of_Tree,
                          (if Nested then From else Node)));
                  Child : constant Natural :=
                    (if Nested
                     then Landin.Checking.Field_Index
                            (Types.all, Of_Tree, Node)
                     else 0);
               begin
                  if Res.Sort_Of (Meanings.all, Means)
                     = Res.Module_Binding
                  then
                     return IR.Emit_Load_Field
                              (Unit.all, Filling,
                               IR.Item_For (Unit.all, Means), Which,
                               Scalar_At (Of_Tree, Node), Site,
                               Nested_Field => Child);
                  end if;

                  return IR.Emit_Load_Slot_Field
                           (Unit.all, Filling,
                            Slot_For (Of_Tree, Named, Means), Which,
                            Scalar_At (Of_Tree, Node), Site,
                            Nested_Field => Child);
               end;

            when Syn.Name_Reference =>
               declare
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
               begin
                  if Res.Sort_Of (Meanings.all, Means)
                       = Res.Pattern_Binding
                  then
                     declare
                        Alias : Payload_Alias renames
                          Aliases (Declared (Means));
                     begin
                        if not Alias.Active then
                           raise Landin.Compiler_Defect with
                             "an inactive match binding reached lowering";
                        end if;
                        return IR.Emit_Variant_Field_Load
                          (Unit.all, Filling, Alias.Source,
                           Positive (Alias.Field), Positive (Alias.Which),
                           Positive (Alias.Payload_Field),
                           Scalar_At (Of_Tree, Node), Site);
                     end;
                  end if;

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
               --  [0410] fixes the order: the left, then the right.  The
               --  right can change blocks, so the earlier value crosses
               --  through a slot and is loaded in the block where the
               --  operation is emitted.  This is the same block-local
               --  operand rule a call's earlier arguments follow.
               declare
                  Left_Node : constant Syn.Node_Id :=
                    Syn.Left_Of (Of_Tree, Node);
                  Right_Node : constant Syn.Node_Id :=
                    Syn.Right_Of (Of_Tree, Node);
                  Saved_Left : constant IR.Slot_Id :=
                    IR.Add_Slot
                      (Unit.all, Filling, Scalar_At (Of_Tree, Left_Node),
                       Res.No_Declaration, Site_Of (Of_Tree, Left_Node));
                  Left : constant IR.Value_Id :=
                    Lower_Expression (Of_Tree, Left_Node, Scope);
               begin
                  IR.Emit_Store
                    (Unit.all, Filling, Saved_Left, Left,
                     Site_Of (Of_Tree, Left_Node));

                  declare
                     Right : constant IR.Value_Id :=
                       Lower_Expression (Of_Tree, Right_Node, Scope);
                     Carried_Left : constant IR.Value_Id :=
                       IR.Emit_Load (Unit.all, Filling, Saved_Left, Site);
                  begin
                     return IR.Emit_Binary
                              (Unit.all, Filling,
                               Opcode_For (Syn.Kind (Of_Tree, Node)),
                               Carried_Left, Right,
                               Scalar_At (Of_Tree, Node), Site);
                  end;
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
      --  D77: an exhaustive unfolded-variant tag match
      ------------------------------------------------------------

      procedure Lower_Match
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Scope   : Res.Scope_Id;
         Result  : IR.Slot_Id)
      is
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Subject : constant Syn.Node_Id :=
           Syn.Match_Subject (Of_Tree, Node);
         Named : constant Syn.Node_Id :=
           Syn.Target_Of (Of_Tree, Subject);
         Means : constant Res.Declaration_Id :=
           Res.Bound_To (Meanings.all, Of_Tree, Named);
         Wrote : constant Res.Declaration_Id :=
           Landin.Checking.Body_Of (Types.all, Of_Tree, Named);
         Field : constant Positive := Positive
           (Landin.Checking.Field_Index (Types.all, Of_Tree, Subject));
         Shape : constant Landin.Checking.Field_Shape :=
           Landin.Checking.Field_Shape_Of (Types.all, Wrote, Field);
         Tag_Type : constant Ty.Integer_Name :=
           Ty.Integer_Name (Shape.Element);
         Source : constant IR.Storage :=
           (if Res.Sort_Of (Meanings.all, Means) = Res.Module_Binding
            then (Kind => IR.Module_Datum,
                  Datum => IR.Item_For (Unit.all, Means))
            else (Kind => IR.Frame_Slot,
                  Slot => Slot_For (Of_Tree, Named, Means)));
         Saved_Tag : constant IR.Slot_Id :=
           IR.Add_Slot
             (Unit.all, Filling, Shape.Element, Res.No_Declaration,
              Site_Of (Of_Tree, Subject));
         Merge : constant IR.Block_Id := Fresh (Of_Tree, Node, Scope);

         procedure Bind (Arm : Syn.Node_Id);

         procedure Bind (Arm : Syn.Node_Id) is
            Which : constant Positive := Positive
              (Landin.Checking.Field_Index
                 (Types.all, Of_Tree, Syn.Match_Pattern (Of_Tree, Arm)));
         begin
            for Payload in 1 .. Syn.Match_Binding_Count (Of_Tree, Arm)
            loop
               declare
                  Binding : constant Syn.Node_Id :=
                    Syn.Nth_Match_Binding (Of_Tree, Arm, Payload);
                  Id : constant Res.Declaration_Id :=
                    Declaration_At (Syn.Source_Of (Of_Tree), Binding);
               begin
                  Aliases (Declared (Id)) :=
                    (Active        => True,
                     Source        => Source,
                     Field         => Field,
                     Which         => Which,
                     Payload_Field => Payload);
               end;
            end loop;
         end Bind;
      begin
         pragma Assert (Shape.Kind = Landin.Checking.Variant_Field);

         --  The selected storage is read exactly once.  A scalar slot is
         --  the IR's block-crossing carrier for the cascade of comparisons.
         declare
            Loaded : constant IR.Value_Id :=
              IR.Emit_Variant_Tag_Load
                (Unit.all, Filling, Source, Field, Shape.Element, Site);
         begin
            IR.Emit_Store
              (Unit.all, Filling, Saved_Tag, Loaded, Site);
         end;

         for Position in 1 .. Syn.Match_Arm_Count (Of_Tree, Node) loop
            declare
               Arm : constant Syn.Node_Id :=
                 Syn.Nth_Match_Arm (Of_Tree, Node, Position);
               Runs : constant Syn.Node_Id := Syn.Body_Of (Of_Tree, Arm);
               Inside : constant Res.Scope_Id :=
                 Res.Scope_At (Meanings.all, Of_Tree, Runs);
               Taken : constant IR.Block_Id :=
                 Fresh (Of_Tree, Runs, Inside);
            begin
               if Position < Syn.Match_Arm_Count (Of_Tree, Node) then
                  declare
                     Next : constant IR.Block_Id :=
                       Fresh (Of_Tree, Node, Scope);
                     Tag : constant IR.Value_Id :=
                       IR.Emit_Load
                         (Unit.all, Filling, Saved_Tag, Site);
                     Wanted : constant IR.Value_Id :=
                       IR.Emit_Number
                         (Unit.all, Filling, Tag_Type,
                          Ty.Magnitude
                            (Landin.Checking.Field_Index
                               (Types.all, Of_Tree,
                                Syn.Match_Pattern (Of_Tree, Arm)) - 1),
                          Negated => False,
                          Site    => Site);
                     Test : constant IR.Value_Id :=
                       IR.Emit_Binary
                         (Unit.all, Filling, IR.Equal_To,
                          Tag, Wanted, Ty.Bool, Site);
                  begin
                     IR.Emit_Branch
                       (Unit.all, Filling, Test, Taken, Next, Site);
                     IR.Leave_Block (Unit.all, Filling);
                     Current := IR.No_Block;

                     Open (Taken);
                     Bind (Arm);
                     Lower_Statements (Of_Tree, Runs, Inside, Result);
                     if Current /= IR.No_Block then
                        Close_With_Jump (Merge, Site);
                     end if;

                     Open (Next);
                  end;
               else
                  --  Exhaustiveness makes the final arm the only remaining
                  --  tag; it still gets its own lexical block.
                  Close_With_Jump (Taken, Site);
                  Open (Taken);
                  Bind (Arm);
                  Lower_Statements (Of_Tree, Runs, Inside, Result);
                  if Current /= IR.No_Block then
                     Close_With_Jump (Merge, Site);
                  end if;
               end if;
            end;
         end loop;

         Open (Merge);
      end Lower_Match;

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

               --  [0410] evaluates a destination place before its value.
               --  A computed index is the enabled place operation that can
               --  do work, so lower it once and carry that same IR value
               --  through a read-modify-write.
               function Index_For (Place : Syn.Node_Id) return IR.Value_Id;

               function Read_Place
                 (Place : Syn.Node_Id; Index : IR.Value_Id)
                  return IR.Value_Id;

               --  [1900]: a place is a name, and which of the two kinds
               --  it is decides whether a Store or a Store_Datum says it.
               procedure Write
                 (Place : Syn.Node_Id;
                  Value : IR.Value_Id;
                  Index : IR.Value_Id := IR.No_Value);

               --  One field of [0710]'s copy, read from storage on the right
               --  and written to storage on the left.  D55 also supplies a
               --  fresh destination slot that has no source-level place.
               procedure Copy_Field
                 (Wrote      : Res.Declaration_Id;
                  Source     : IR.Storage;
                  Destination : IR.Storage;
                  Field   : Positive);

               function Storage_For
                 (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Storage;

               procedure Write_Array_Value
                 (Value       : Syn.Node_Id;
                  Destination : IR.Storage;
                  Field       : Natural;
                  Variant_Case : Natural := 0;
                  Variant_Payload_Field : Natural := 0);

               procedure Write_Variant_Value
                 (Value       : Syn.Node_Id;
                  Wrote       : Res.Declaration_Id;
                  Field       : Positive;
                  Destination : IR.Storage);

               procedure Write_Struct_Literal
                 (Literal     : Syn.Node_Id;
                  Wrote       : Res.Declaration_Id;
                  Destination : IR.Storage);

               function Storage_For
                 (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return IR.Storage
               is
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
               begin
                  if Res.Sort_Of (Meanings.all, Means) = Res.Module_Binding
                  then
                     return
                       (Kind => IR.Module_Datum,
                        Datum => IR.Item_For (Unit.all, Means));
                  end if;

                  return
                    (Kind => IR.Frame_Slot,
                     Slot => Slot_For (Of_Tree, Node, Means));
               end Storage_For;

               procedure Copy_Field
                 (Wrote      : Res.Declaration_Id;
                  Source     : IR.Storage;
                  Destination : IR.Storage;
                  Field   : Positive)
               is
               begin
                  case Landin.Checking.Field_Kind_Of
                    (Types.all, Wrote, Field)
                  is
                     when Landin.Checking.Scalar_Field =>
                        declare
                           Held : constant Ty.Scalar_Name :=
                             Landin.Checking.Field_Type
                               (Types.all, Wrote, Field);
                           Taken : IR.Value_Id;
                        begin
                           case Source.Kind is
                              when IR.Module_Datum =>
                                 Taken :=
                                   IR.Emit_Load_Field
                                     (Unit.all, Filling, Source.Datum,
                                      IR.Part_Position (Field), Held, Site);
                              when IR.Frame_Slot =>
                                 Taken :=
                                   IR.Emit_Load_Slot_Field
                                     (Unit.all, Filling, Source.Slot,
                                      IR.Part_Position (Field), Held, Site);
                           end case;

                           case Destination.Kind is
                              when IR.Module_Datum =>
                                 IR.Emit_Store_Field
                                   (Unit.all, Filling, Destination.Datum,
                                    IR.Part_Position (Field), Taken, Site);
                              when IR.Frame_Slot =>
                                 IR.Emit_Store_Slot_Field
                                   (Unit.all, Filling, Destination.Slot,
                                    IR.Part_Position (Field), Taken, Site);
                           end case;
                        end;

                     when Landin.Checking.Fixed_Array_Field =>
                        IR.Emit_Array_Copy
                          (Unit.all, Filling,
                           Source      => Source,
                           Destination => Destination,
                           Site        => Site,
                           Source_Field => Field,
                           Destination_Field => Field);

                     when Landin.Checking.Aggregate_Field =>
                        raise Landin.Compiler_Defect with
                          "nested aggregate copy reached lowering";

                     when Landin.Checking.Variant_Field =>
                        IR.Emit_Variant_Copy
                          (Unit.all, Filling,
                           Source      => Source,
                           Destination => Destination,
                           Field       => Field,
                           Site        => Site);
                  end case;
               end Copy_Field;

               procedure Write_Array_Value
                 (Value       : Syn.Node_Id;
                  Destination : IR.Storage;
                  Field       : Natural;
                  Variant_Case : Natural := 0;
                  Variant_Payload_Field : Natural := 0)
               is
                  procedure Store_Element
                    (Position : Positive; Element : IR.Value_Id);

                  procedure Store_Element
                    (Position : Positive; Element : IR.Value_Id)
                  is
                     Part : constant IR.Part_Position :=
                       IR.Part_Position (Position);
                  begin
                     if Field = 0 then
                        case Destination.Kind is
                           when IR.Module_Datum =>
                              IR.Emit_Store_Field
                                (Unit.all, Filling, Destination.Datum, Part,
                                 Element, Site);
                           when IR.Frame_Slot =>
                              IR.Emit_Store_Slot_Field
                                (Unit.all, Filling, Destination.Slot, Part,
                                 Element, Site);
                        end case;
                     else
                        declare
                           Index : constant IR.Value_Id :=
                             IR.Emit_Number
                               (Unit.all, Filling, Ty.Usize,
                                Ty.Magnitude (Position - 1), False, Site);
                        begin
                           case Destination.Kind is
                              when IR.Module_Datum =>
                                 IR.Emit_Store_Element
                                   (Unit.all, Filling, Destination.Datum,
                                    Index, Element, Site, Field => Field,
                                    Variant_Case => Variant_Case,
                                    Variant_Payload_Field =>
                                      Variant_Payload_Field);
                              when IR.Frame_Slot =>
                                 IR.Emit_Store_Slot_Element
                                   (Unit.all, Filling, Destination.Slot,
                                    Index, Element, Site, Field => Field,
                                    Variant_Case => Variant_Case,
                                    Variant_Payload_Field =>
                                      Variant_Payload_Field);
                           end case;
                        end;
                     end if;
                  end Store_Element;
               begin
                  --  D49--D53/D65: every contextual fixed-array destination
                  --  uses the same field-qualified operation family.  Field
                  --  zero is complete array storage; a positive field is the
                  --  array member of an aggregate datum or slot.
                  pragma Assert
                    ((Variant_Case = 0
                      and then Variant_Payload_Field = 0)
                     or else
                       (Field > 0
                        and then Variant_Case > 0
                        and then Variant_Payload_Field > 0));
                  pragma Assert
                    (Field = 0
                     or else Syn.Kind (Of_Tree, Value)
                               in Syn.Array_Literal
                                  | Syn.Array_Repetition
                                  | Syn.Mixed_Array_Repetition
                                  | Syn.Zeroed_Literal
                                  | Syn.Name_Reference
                                  | Syn.Member_Selection);

                  if Syn.Kind (Of_Tree, Value) = Syn.Array_Literal then
                     --  D29/D52 forms each contextual element directly in
                     --  destination storage in source order.
                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Value)
                     loop
                        Store_Element
                          (Position,
                           Lower_Expression
                             (Of_Tree,
                              Syn.Nth_Element
                                (Of_Tree, Value, Position),
                              Scope));
                     end loop;
                  elsif Syn.Kind (Of_Tree, Value)
                          = Syn.Mixed_Array_Repetition
                  then
                     --  D37/D53 writes each prefix position, then evaluates
                     --  one suffix value for the compact fill.
                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Value)
                     loop
                        Store_Element
                          (Position,
                           Lower_Expression
                             (Of_Tree,
                              Syn.Nth_Element
                                (Of_Tree, Value, Position),
                              Scope));
                     end loop;

                     IR.Emit_Array_Fill
                       (Unit.all, Filling, Destination,
                        IR.Part_Position
                          (Syn.Element_Count (Of_Tree, Value) + 1),
                        Lower_Expression
                          (Of_Tree,
                           Syn.Repeated_Element (Of_Tree, Value), Scope),
                        Site, Field => Field,
                        Variant_Case => Variant_Case,
                        Variant_Payload_Field => Variant_Payload_Field);
                  elsif Syn.Kind (Of_Tree, Value) = Syn.Array_Repetition
                  then
                     IR.Emit_Array_Fill
                       (Unit.all, Filling, Destination, 1,
                        Lower_Expression
                          (Of_Tree,
                           Syn.Repeated_Element (Of_Tree, Value), Scope),
                        Site, Field => Field,
                        Variant_Case => Variant_Case,
                        Variant_Payload_Field => Variant_Payload_Field);
                  elsif Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal then
                     if Variant_Payload_Field = 0 then
                        IR.Emit_Array_Clear
                          (Unit.all, Filling, Destination, Site,
                           Field => Field);
                     end if;
                  else
                     --  D20/D50: a whole array source is storage, optionally
                     --  qualified by its containing aggregate field.
                     declare
                        Source_Nested : constant Boolean :=
                          Syn.Kind (Of_Tree, Value) = Syn.Member_Selection;
                        Source_Named : constant Syn.Node_Id :=
                          (if Source_Nested
                           then Syn.Target_Of (Of_Tree, Value)
                           else Value);
                        Source_Field : constant Natural :=
                          (if Source_Nested
                           then Landin.Checking.Field_Index
                             (Types.all, Of_Tree, Value)
                           else 0);
                     begin
                        IR.Emit_Array_Copy
                          (Unit.all, Filling,
                           Source => Storage_For (Of_Tree, Source_Named),
                           Destination => Destination,
                           Site => Site,
                           Source_Field => Source_Field,
                           Destination_Field => Field,
                           Destination_Variant_Case => Variant_Case,
                           Destination_Variant_Payload_Field =>
                             Variant_Payload_Field);
                     end;
                  end if;
               end Write_Array_Value;

               procedure Write_Variant_Value
                 (Value       : Syn.Node_Id;
                  Wrote       : Res.Declaration_Id;
                  Field       : Positive;
                  Destination : IR.Storage)
               is
                  Which : constant Positive := Positive
                    (Landin.Checking.Field_Index
                       (Types.all, Of_Tree, Value));
               begin
                  --  Selecting first clears the complete padded part, so
                  --  omitted scalar leaves, fixed-array zero payloads and
                  --  every inactive byte have [0540]'s zero image before
                  --  labelled scalar expressions are committed.
                  IR.Emit_Variant_Select
                    (Unit.all, Filling, Destination, Field, Which, Site);

                  if Syn.Kind (Of_Tree, Value) /= Syn.Struct_Literal then
                     return;
                  end if;

                  for Position in
                    1 .. Syn.Field_Value_Count (Of_Tree, Value)
                  loop
                     declare
                        Label : constant Syn.Node_Id :=
                          Syn.Nth_Field_Value (Of_Tree, Value, Position);
                        Payload_Field : constant Positive := Positive
                          (Landin.Checking.Field_Index
                             (Types.all, Of_Tree, Label));
                        Shape : constant Landin.Checking.Field_Shape :=
                          Landin.Checking.Nth_Variant_Case_Field
                            (Types.all, Wrote, Field, Which,
                             Payload_Field);
                     begin
                        case Shape.Kind is
                           when Landin.Checking.Scalar_Field =>
                              IR.Emit_Variant_Field_Store
                                (Unit.all, Filling, Destination,
                                 Field, Which, Payload_Field,
                                 Lower_Expression
                                   (Of_Tree,
                                    Syn.Value_Of (Of_Tree, Label), Scope),
                                 Site);

                           when Landin.Checking.Fixed_Array_Field =>
                              --  D84 writes the same contextual array forms
                              --  as an ordinary field.  A zero payload is a
                              --  no-op because selecting the case cleared the
                              --  complete padded part before any label ran.
                              Write_Array_Value
                                (Syn.Value_Of (Of_Tree, Label), Destination,
                                 Field, Which, Payload_Field);

                           when Landin.Checking.Aggregate_Field =>
                              raise Landin.Compiler_Defect with
                                "a nested aggregate payload reached"
                                & " lowering";

                           when Landin.Checking.Variant_Field =>
                              raise Landin.Compiler_Defect with
                                "a nested variant payload reached lowering";
                        end case;
                     end;
                  end loop;
               end Write_Variant_Value;

               procedure Write_Struct_Literal
                 (Literal     : Syn.Node_Id;
                  Wrote       : Res.Declaration_Id;
                  Destination : IR.Storage)
               is
                  Count : constant Natural :=
                    Landin.Checking.Layout_Field_Count
                      (Types.all, Wrote);
                  type Seen_Array is array (Positive range <>) of Boolean;
                  Seen : Seen_Array (1 .. Count) := [others => False];

                  procedure Store_Scalar
                    (Field : Positive; Value : IR.Value_Id);

                  procedure Store_Scalar
                    (Field : Positive; Value : IR.Value_Id) is
                  begin
                     case Destination.Kind is
                        when IR.Module_Datum =>
                           IR.Emit_Store_Field
                             (Unit.all, Filling, Destination.Datum,
                              IR.Part_Position (Field), Value, Site);
                        when IR.Frame_Slot =>
                           IR.Emit_Store_Slot_Field
                             (Unit.all, Filling, Destination.Slot,
                              IR.Part_Position (Field), Value, Site);
                     end case;
                  end Store_Scalar;
               begin
                  --  [0410]/D29: named fields are evaluated and committed in
                  --  source order, irrespective of declaration/layout order.
                  for Position in
                    1 .. Syn.Field_Value_Count (Of_Tree, Literal)
                  loop
                     declare
                        Field_Node : constant Syn.Node_Id :=
                          Syn.Nth_Field_Value
                            (Of_Tree, Literal, Position);
                        Field : constant Natural :=
                          Landin.Checking.Field_Index
                            (Types.all, Of_Tree, Field_Node);
                        Value : constant Syn.Node_Id :=
                          Syn.Value_Of (Of_Tree, Field_Node);
                     begin
                        pragma Assert (Field > 0);
                        Seen (Field) := True;
                        case Landin.Checking.Field_Kind_Of
                          (Types.all, Wrote, Field)
                        is
                           when Landin.Checking.Scalar_Field =>
                              Store_Scalar
                                (Field,
                                 Lower_Expression
                                   (Of_Tree, Value, Scope));
                           when Landin.Checking.Fixed_Array_Field =>
                              --  D65: the label is the same contextual array
                              --  destination D49--D53 lower on assignment.
                              Write_Array_Value
                                (Value, Destination, Field);

                           when Landin.Checking.Aggregate_Field =>
                              raise Landin.Compiler_Defect with
                                "a nested aggregate literal reached"
                                & " lowering";

                           when Landin.Checking.Variant_Field =>
                              Write_Variant_Value
                                (Value, Wrote, Field, Destination);
                        end case;
                     end;
                  end loop;

                  --  D64's deliberately narrow fill is all-bits zero.  It is
                  --  written after every labelled value, in declaration
                  --  order, without forming one heterogeneously typed value.
                  if Syn.Struct_Fill (Of_Tree, Literal) /= Syn.No_Node then
                     for Field in Seen'Range loop
                        if not Seen (Field) then
                           case Landin.Checking.Field_Kind_Of
                             (Types.all, Wrote, Field)
                           is
                              when Landin.Checking.Scalar_Field =>
                                 declare
                                    Held : constant Ty.Scalar_Name :=
                                      Landin.Checking.Field_Type
                                        (Types.all, Wrote, Field);
                                    Zero : IR.Value_Id;
                                 begin
                                    if Held = Ty.Bool then
                                       Zero := IR.Emit_Truth
                                         (Unit.all, Filling, False, Site);
                                    else
                                       Zero := IR.Emit_Number
                                         (Unit.all, Filling, Held, 0, False,
                                          Site);
                                    end if;
                                    Store_Scalar (Field, Zero);
                                 end;

                              when Landin.Checking.Fixed_Array_Field =>
                                 IR.Emit_Array_Clear
                                   (Unit.all, Filling, Destination, Site,
                                    Field => Field);

                              when Landin.Checking.Aggregate_Field =>
                                 raise Landin.Compiler_Defect with
                                   "a nested aggregate fill reached"
                                   & " lowering";

                              when Landin.Checking.Variant_Field =>
                                 --  D75's zero image selects the first case.
                                 IR.Emit_Variant_Select
                                   (Unit.all, Filling, Destination,
                                    Field, 1, Site);
                           end case;
                        end if;
                     end loop;
                  end if;
               end Write_Struct_Literal;

               function Index_For (Place : Syn.Node_Id) return IR.Value_Id is
               begin
                  if Syn.Kind (Of_Tree, Place) /= Syn.Element_Index
                    or else
                      (Is_Constant_Index (Of_Tree, Place)
                       and then Syn.Kind
                                  (Of_Tree, Syn.Target_Of (Of_Tree, Place))
                                /= Syn.Member_Selection
                       and then Res.Sort_Of
                         (Meanings.all,
                          Res.Bound_To
                            (Meanings.all, Of_Tree,
                             Syn.Target_Of (Of_Tree, Place)))
                           /= Res.Pattern_Binding)
                  then
                     return IR.No_Value;
                  end if;

                  return Lower_Expression
                           (Of_Tree, Syn.Index_Of (Of_Tree, Place), Scope);
               end Index_For;

               function Read_Place
                 (Place : Syn.Node_Id; Index : IR.Value_Id)
                  return IR.Value_Id
               is
                  From : Syn.Node_Id;
                  Named : Syn.Node_Id;
                  Means : Res.Declaration_Id;
                  Field : Natural;
               begin
                  if Index = IR.No_Value then
                     return Lower_Expression (Of_Tree, Place, Scope);
                  end if;

                  From := Syn.Target_Of (Of_Tree, Place);
                  Named :=
                    (if Syn.Kind (Of_Tree, From) = Syn.Member_Selection
                     then Syn.Target_Of (Of_Tree, From)
                     else From);
                  Means := Res.Bound_To (Meanings.all, Of_Tree, Named);
                  Field :=
                    (if Syn.Kind (Of_Tree, From) = Syn.Member_Selection
                     then Landin.Checking.Field_Index
                            (Types.all, Of_Tree, From)
                     else 0);
                  if Res.Sort_Of (Meanings.all, Means)
                       = Res.Pattern_Binding
                  then
                     declare
                        Alias : Payload_Alias renames
                          Aliases (Declared (Means));
                     begin
                        if not Alias.Active then
                           raise Landin.Compiler_Defect with
                             "an inactive array match binding reached"
                             & " lowering";
                        end if;
                        case Alias.Source.Kind is
                           when IR.Module_Datum =>
                              return IR.Emit_Load_Element
                                (Unit.all, Filling, Alias.Source.Datum,
                                 Index, Scalar_At (Of_Tree, Place), Site,
                                 Field => Alias.Field,
                                 Variant_Case => Alias.Which,
                                 Variant_Payload_Field =>
                                   Alias.Payload_Field);
                           when IR.Frame_Slot =>
                              return IR.Emit_Load_Slot_Element
                                (Unit.all, Filling, Alias.Source.Slot,
                                 Index, Scalar_At (Of_Tree, Place), Site,
                                 Field => Alias.Field,
                                 Variant_Case => Alias.Which,
                                 Variant_Payload_Field =>
                                   Alias.Payload_Field);
                        end case;
                     end;
                  end if;
                  if Res.Sort_Of (Meanings.all, Means) = Res.Local_Binding
                  then
                     return IR.Emit_Load_Slot_Element
                              (Unit.all, Filling,
                               Slot_For (Of_Tree, Named, Means),
                               Index, Scalar_At (Of_Tree, Place), Site,
                               Field => Field);
                  end if;

                  return IR.Emit_Load_Element
                           (Unit.all, Filling, IR.Item_For (Unit.all, Means),
                            Index, Scalar_At (Of_Tree, Place), Site,
                            Field => Field);
               end Read_Place;

               procedure Write
                 (Place : Syn.Node_Id;
                  Value : IR.Value_Id;
                  Index : IR.Value_Id := IR.No_Value)
               is
                  --  [1810]'s place is [1820]'s selection, so a field is
                  --  written where the binding holding it is named.
                  Selected : constant Syn.Node_Id :=
                    (if Syn.Kind (Of_Tree, Place) = Syn.Element_Index
                     then Syn.Target_Of (Of_Tree, Place)
                     else Place);
                  Named_Once : constant Syn.Node_Id :=
                    (if Syn.Kind (Of_Tree, Selected) = Syn.Member_Selection
                     then Syn.Target_Of (Of_Tree, Selected)
                     elsif Syn.Kind (Of_Tree, Place) = Syn.Member_Selection
                     then Syn.Target_Of (Of_Tree, Place)
                     else Selected);
                  Named : constant Syn.Node_Id :=
                    (if Syn.Kind (Of_Tree, Named_Once)
                          = Syn.Member_Selection
                     then Syn.Target_Of (Of_Tree, Named_Once)
                     else Named_Once);
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Named);
               begin
                  if Res.Sort_Of (Meanings.all, Means)
                       = Res.Pattern_Binding
                  then
                     declare
                        Alias : Payload_Alias renames
                          Aliases (Declared (Means));
                     begin
                        if not Alias.Active then
                           raise Landin.Compiler_Defect with
                             "an inactive match binding reached lowering";
                        end if;
                        if Syn.Kind (Of_Tree, Place) = Syn.Element_Index then
                           pragma Assert (Index /= IR.No_Value);
                           case Alias.Source.Kind is
                              when IR.Module_Datum =>
                                 IR.Emit_Store_Element
                                   (Unit.all, Filling, Alias.Source.Datum,
                                    Index, Value, Site,
                                    Field => Alias.Field,
                                    Variant_Case => Alias.Which,
                                    Variant_Payload_Field =>
                                      Alias.Payload_Field);
                              when IR.Frame_Slot =>
                                 IR.Emit_Store_Slot_Element
                                   (Unit.all, Filling, Alias.Source.Slot,
                                    Index, Value, Site,
                                    Field => Alias.Field,
                                    Variant_Case => Alias.Which,
                                    Variant_Payload_Field =>
                                      Alias.Payload_Field);
                           end case;
                        else
                           IR.Emit_Variant_Field_Store
                             (Unit.all, Filling, Alias.Source,
                              Positive (Alias.Field), Positive (Alias.Which),
                              Positive (Alias.Payload_Field), Value, Site);
                        end if;
                        return;
                     end;
                  end if;

                  if Syn.Kind (Of_Tree, Place) = Syn.Element_Index then
                     declare
                        Field : constant Natural :=
                          (if Syn.Kind (Of_Tree, Selected)
                                = Syn.Member_Selection
                           then Landin.Checking.Field_Index
                                  (Types.all, Of_Tree, Selected)
                           else 0);
                     begin
                        if Res.Sort_Of (Meanings.all, Means)
                           = Res.Local_Binding
                        then
                           if Index = IR.No_Value then
                              IR.Emit_Store_Slot_Field
                                (Unit.all, Filling,
                                 Slot_For (Of_Tree, Named, Means),
                                 Constant_Index (Of_Tree, Place),
                                 Value, Site);
                           else
                              IR.Emit_Store_Slot_Element
                                (Unit.all, Filling,
                                 Slot_For (Of_Tree, Named, Means),
                                 Index, Value, Site, Field => Field);
                           end if;
                        elsif Index = IR.No_Value then
                           IR.Emit_Store_Field
                             (Unit.all, Filling,
                              IR.Item_For (Unit.all, Means),
                              Constant_Index (Of_Tree, Place), Value, Site);
                        else
                           IR.Emit_Store_Element
                             (Unit.all, Filling,
                              IR.Item_For (Unit.all, Means),
                              Index, Value, Site, Field => Field);
                        end if;
                     end;
                     return;
                  end if;

                  if Syn.Kind (Of_Tree, Place) = Syn.Member_Selection then
                     declare
                        From : constant Syn.Node_Id :=
                          Syn.Target_Of (Of_Tree, Place);
                        Nested : constant Boolean :=
                          Syn.Kind (Of_Tree, From) = Syn.Member_Selection;
                        Which : constant IR.Part_Position :=
                          IR.Part_Position
                            (Landin.Checking.Field_Index
                               (Types.all, Of_Tree,
                                (if Nested then From else Place)));
                        Child : constant Natural :=
                          (if Nested
                           then Landin.Checking.Field_Index
                                  (Types.all, Of_Tree, Place)
                           else 0);
                     begin
                        if Res.Sort_Of (Meanings.all, Means)
                           = Res.Module_Binding
                        then
                           IR.Emit_Store_Field
                             (Unit.all, Filling,
                              IR.Item_For (Unit.all, Means), Which,
                              Value, Site, Nested_Field => Child);
                        else
                           IR.Emit_Store_Slot_Field
                             (Unit.all, Filling,
                              Slot_For (Of_Tree, Named, Means), Which,
                              Value, Site, Nested_Field => Child);
                        end if;
                     end;

                     return;
                  end if;

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
                        if Value = Syn.No_Node then
                           null;
                        elsif Landin.Checking.Type_Of (Types.all, Id)
                                = Ty.Fixed_Array
                        then
                           if Syn.Kind (Of_Tree, Value)
                                = Syn.Array_Literal
                           then
                              --  D23/D25: a literal has exactly the finite
                              --  element run the source wrote.  Lower and
                              --  store each one immediately, preserving
                              --  [0410]'s left-to-right evaluation in the
                              --  existing compact array slot.
                              for Position in
                                1 .. Syn.Element_Count (Of_Tree, Value)
                              loop
                                 IR.Emit_Store_Slot_Field
                                   (Unit.all, Filling, Where,
                                    IR.Part_Position (Position),
                                    Lower_Expression
                                      (Of_Tree,
                                       Syn.Nth_Element
                                         (Of_Tree, Value, Position),
                                       Scope),
                                    Site);
                              end loop;
                           elsif Syn.Kind (Of_Tree, Value)
                                   = Syn.Mixed_Array_Repetition
                           then
                              --  D36 stores the prefix as it is evaluated,
                              --  then evaluates one suffix pattern and fills
                              --  from the first part after that prefix.
                              for Position in
                                1 .. Syn.Element_Count (Of_Tree, Value)
                              loop
                                 IR.Emit_Store_Slot_Field
                                   (Unit.all, Filling, Where,
                                    IR.Part_Position (Position),
                                    Lower_Expression
                                      (Of_Tree,
                                       Syn.Nth_Element
                                         (Of_Tree, Value, Position),
                                       Scope),
                                    Site);
                              end loop;

                              IR.Emit_Array_Fill
                                (Unit.all, Filling,
                                 Destination =>
                                   IR.Storage'
                                     (Kind => IR.Frame_Slot, Slot => Where),
                                 First       =>
                                   IR.Part_Position
                                     (Syn.Element_Count (Of_Tree, Value) + 1),
                                 Value       =>
                                   Lower_Expression
                                     (Of_Tree,
                                      Syn.Repeated_Element (Of_Tree, Value),
                                      Scope),
                                 Site        => Site);
                           elsif Syn.Kind (Of_Tree, Value)
                                   = Syn.Array_Repetition
                           then
                              IR.Emit_Array_Fill
                                (Unit.all, Filling,
                                 Destination =>
                                   IR.Storage'
                                     (Kind => IR.Frame_Slot, Slot => Where),
                                 First       => 1,
                                 Value       =>
                                   Lower_Expression
                                     (Of_Tree,
                                      Syn.Repeated_Element (Of_Tree, Value),
                                      Scope),
                                 Site        => Site);
                           elsif Syn.Kind (Of_Tree, Value)
                                   = Syn.Zeroed_Literal
                           then
                              --  D28: clear the complete compact slot at
                              --  runtime with one extent-independent
                              --  operation.
                              IR.Emit_Array_Clear
                                (Unit.all, Filling,
                                 Destination =>
                                   IR.Storage'
                                     (Kind => IR.Frame_Slot, Slot => Where),
                                 Site        => Site);
                           else
                              --  D21: the initializer copies a whole array
                              --  from storage into this fresh local slot.
                              --  D51 reuses D50's source-field identity when
                              --  that storage is a containing struct; no
                              --  opcode or target offset is introduced.
                              declare
                                 Source_Nested : constant Boolean :=
                                   Syn.Kind (Of_Tree, Value)
                                     = Syn.Member_Selection;
                                 Source_Named : constant Syn.Node_Id :=
                                   (if Source_Nested
                                    then Syn.Target_Of (Of_Tree, Value)
                                    else Value);
                                 Source_Field : constant Natural :=
                                   (if Source_Nested
                                    then Landin.Checking.Field_Index
                                      (Types.all, Of_Tree, Value)
                                    else 0);
                              begin
                                 IR.Emit_Array_Copy
                                   (Unit.all, Filling,
                                    Source =>
                                      Storage_For (Of_Tree, Source_Named),
                                    Destination =>
                                      IR.Storage'
                                        (Kind => IR.Frame_Slot,
                                         Slot => Where),
                                    Site => Site,
                                    Source_Field => Source_Field);
                              end;
                           end if;
                        elsif Landin.Checking.Type_Of (Types.all, Id)
                                = Ty.Aggregate
                        then
                           if Syn.Kind (Of_Tree, Value)
                                = Syn.Struct_Literal
                           then
                              Write_Struct_Literal
                                (Value,
                                 Landin.Checking.Body_Of (Types.all, Id),
                                 (Kind => IR.Frame_Slot, Slot => Where));
                           elsif Syn.Kind (Of_Tree, Value)
                                = Syn.Zeroed_Literal
                           then
                              --  D57: one whole-storage clear writes the
                              --  complete padded image of the fresh aggregate
                              --  slot; field zero identifies the whole cell.
                              IR.Emit_Array_Clear
                                (Unit.all, Filling,
                                 Destination =>
                                   IR.Storage'
                                     (Kind => IR.Frame_Slot, Slot => Where),
                                 Site => Site);
                           else
                              --  D55: the destination slot is fresh and the
                              --  direct source is existing storage.  Reuse
                              --  D54's declaration-ordered scalar/array field
                              --  copy without forming an aggregate value.
                              declare
                                 Wrote : constant Res.Declaration_Id :=
                                   Landin.Checking.Body_Of (Types.all, Id);
                                 Source : constant IR.Storage :=
                                   Storage_For (Of_Tree, Value);
                                 Destination : constant IR.Storage :=
                                   (Kind => IR.Frame_Slot, Slot => Where);
                              begin
                                 for Field in
                                   1 .. Landin.Checking.Layout_Field_Count
                                          (Types.all, Wrote)
                                 loop
                                    Copy_Field
                                      (Wrote, Source, Destination, Field);
                                 end loop;
                              end;
                           end if;
                        else
                           IR.Emit_Store
                             (Unit.all, Filling, Where,
                              Lower_Expression (Of_Tree, Value, Scope),
                              Site);
                        end if;
                     end;

                  when Syn.Assignment =>
                     --  D76's direct part assignment is contextual and its
                     --  target is Not_Typed rather than a general aggregate
                     --  value.  Lower it before the ordinary whole-struct
                     --  branch asks the place for an aggregate body.
                     if Syn.Kind
                          (Of_Tree, Syn.Target_Of (Of_Tree, Stmt))
                          = Syn.Member_Selection
                       and then Landin.Checking.Type_Of
                         (Types.all, Of_Tree,
                          Syn.Target_Of (Of_Tree, Stmt)) = Ty.Not_Typed
                     then
                        declare
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           Named : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Place);
                           Wrote : constant Res.Declaration_Id :=
                             Landin.Checking.Body_Of
                               (Types.all, Of_Tree, Named);
                           Field : constant Positive := Positive
                             (Landin.Checking.Field_Index
                                (Types.all, Of_Tree, Place));
                        begin
                           pragma Assert
                             (Landin.Checking.Field_Kind_Of
                                (Types.all, Wrote, Field)
                                = Landin.Checking.Variant_Field);
                           Write_Variant_Value
                             (Syn.Value_Of (Of_Tree, Stmt), Wrote, Field,
                              Storage_For (Of_Tree, Named));
                        end;

                     --  [0710]'s copy visits the same fields in [0750]'s
                     --  order: a scalar is one field read and write, and
                     --  D54 copies an array field with D50's compact
                     --  operation.  No whole-struct opcode says more.
                     elsif Landin.Checking.Type_Of
                          (Types.all, Of_Tree,
                           Syn.Target_Of (Of_Tree, Stmt)) = Ty.Aggregate
                     then
                        declare
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           From : constant Syn.Node_Id :=
                             Syn.Value_Of (Of_Tree, Stmt);
                           Destination : constant IR.Storage :=
                             Storage_For (Of_Tree, Place);
                        begin
                           if Syn.Kind (Of_Tree, From) = Syn.Struct_Literal
                           then
                              Write_Struct_Literal
                                (From,
                                 Landin.Checking.Body_Of
                                   (Types.all, Of_Tree, Place),
                                 Destination);
                           elsif Syn.Kind (Of_Tree, From) = Syn.Zeroed_Literal
                           then
                              --  D58 reuses D57's field-zero whole aggregate
                              --  clear for either datum or slot storage.  Test
                              --  the syntax before asking Storage_For to bind
                              --  a source that deliberately does not exist.
                              IR.Emit_Array_Clear
                                (Unit.all, Filling, Destination, Site);
                           else
                              --  [0710]'s copy visits the same fields in
                              --  [0750]'s order: a scalar is one field read
                              --  and write, and D54 copies an array field with
                              --  D50's compact operation.
                              declare
                                 Wrote : constant Res.Declaration_Id :=
                                   Landin.Checking.Body_Of
                                     (Types.all, Of_Tree, Place);
                                 Source : constant IR.Storage :=
                                   Storage_For (Of_Tree, From);
                              begin
                                 for Field in
                                   1 .. Landin.Checking.Layout_Field_Count
                                          (Types.all, Wrote)
                                 loop
                                    Copy_Field
                                      (Wrote, Source, Destination, Field);
                                 end loop;
                              end;
                           end if;
                        end;
                     elsif Landin.Checking.Type_Of
                             (Types.all, Of_Tree,
                              Syn.Target_Of (Of_Tree, Stmt)) = Ty.Fixed_Array
                     then
                        declare
                           Value : constant Syn.Node_Id :=
                             Syn.Value_Of (Of_Tree, Stmt);
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           Nested : constant Boolean :=
                             Syn.Kind (Of_Tree, Place)
                               = Syn.Member_Selection;
                           Named : constant Syn.Node_Id :=
                             (if Nested
                              then Syn.Target_Of (Of_Tree, Place)
                              else Place);
                           Field : constant Natural :=
                             (if Nested
                              then Landin.Checking.Field_Index
                                (Types.all, Of_Tree, Place)
                              else 0);
                           Destination : constant IR.Storage :=
                             Storage_For (Of_Tree, Named);
                        begin
                           --  D49--D53 and D65 share one field-qualified
                           --  lowering rule for every contextual array value.
                           Write_Array_Value (Value, Destination, Field);
                        end;
                     else
                        declare
                           Place : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree, Stmt);
                           Index : constant IR.Value_Id := Index_For (Place);
                           Saved_Index : IR.Slot_Id := IR.No_Slot;
                        begin
                           --  The right-hand side can cross blocks through a
                           --  short circuit.  Save the already-evaluated
                           --  destination index before it runs, then reload it
                           --  in the block where the store is emitted.
                           if Index /= IR.No_Value then
                              Saved_Index :=
                                IR.Add_Slot
                                  (Unit.all, Filling, Ty.Usize,
                                   Res.No_Declaration, Site);
                              IR.Emit_Store
                                (Unit.all, Filling, Saved_Index, Index, Site);
                           end if;

                           declare
                              Value : constant IR.Value_Id :=
                                Lower_Expression
                                  (Of_Tree, Syn.Value_Of (Of_Tree, Stmt),
                                   Scope);
                              Carried_Index : constant IR.Value_Id :=
                                (if Saved_Index = IR.No_Slot
                                 then IR.No_Value
                                 else IR.Emit_Load
                                        (Unit.all, Filling, Saved_Index,
                                         Site));
                           begin
                              Write (Place, Value, Carried_Index);
                           end;
                        end;
                     end if;

                  when Syn.Increment | Syn.Decrement =>
                     --  [1900]: `inc` says what `x += 1` says, which is a
                     --  load, a one, a trapping add and a store.
                     declare
                        Place : constant Syn.Node_Id :=
                          Syn.Target_Of (Of_Tree, Stmt);
                        Held : constant Ty.Scalar_Name :=
                          Scalar_At (Of_Tree, Place);
                        Index : constant IR.Value_Id := Index_For (Place);
                        Was : constant IR.Value_Id :=
                          Read_Place (Place, Index);
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
                              Site),
                           Index);
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

                  when Syn.Match_Statement =>
                     Lower_Match (Of_Tree, Stmt, Scope, Result);

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

      ------------------------------------------------------------
      --  [1940]: a module value
      ------------------------------------------------------------

      --  A datum's block describes its value.  [1460] says nothing runs
      --  before the entry point, so this is not code and R1.80 reads it
      --  rather than executing it.
      procedure Lower_Datum (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

      procedure Lower_Datum (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Src : constant Landin.Source.Source_Id := Syn.Source_Of (Of_Tree);
         Site : constant Landin.Provenance.Origin :=
           Site_Of (Of_Tree, Node);
         Id : constant Res.Declaration_Id := Declaration_At (Src, Node);
         Held : constant Ty.Type_Kind :=
           Landin.Checking.Type_Of (Types.all, Id);
         Value : constant Syn.Node_Id := Syn.Value_Of (Of_Tree, Node);
         Answer : IR.Value_Id;
      begin
         if Held not in Ty.Scalar_Name
           and then Held not in Ty.Aggregate | Ty.Fixed_Array
         then
            raise Landin.Compiler_Defect with
              "a module binding reached the lowering with no storable type";
         end if;

         Filling := IR.Item_For (Unit.all, Id);
         Slots := No_Slots;

         --  Aggregate state has no runtime-producing value.  D10 zeroes a
         --  struct, while R2.20 has proved that every direct-name module array
         --  image chain terminates at a D10-zeroed array.  Each declaration
         --  still owns a distinct datum whose storage is described by the
         --  fields or shape the item was given, so its block carries no value.
         if Held in Ty.Aggregate | Ty.Fixed_Array then
            Open (Fresh (Of_Tree, Node, Res.Program_Scope));
            IR.Emit_Leave (Unit.all, Filling, IR.No_Value, Site);
            IR.Leave_Block (Unit.all, Filling);
            Current := IR.No_Block;
            Filling := IR.No_Item;
            return;
         end if;

         --  [1840]: a module value is read in the module scope, and
         --  [1800]'s expression body is the only other thing that opens
         --  none.  So the block carries the scope the resolver read it in.
         Open (Fresh (Of_Tree, Node, Res.Program_Scope));

         if Value = Syn.No_Node
           or else Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal
         then
            --  D10: a binding with no value holds zero, false for a bool.
            --  D39's contextual scalar `zeroed` is exactly that existing
            --  scalar IR, not a separately evaluated expression.
            if Held = Ty.Bool then
               Answer :=
                 IR.Emit_Truth (Unit.all, Filling, False, Site);
            else
               Answer :=
                 IR.Emit_Number
                   (Unit.all, Filling, Held, 0, False, Site);
            end if;
         else
            Answer := Lower_Expression (Of_Tree, Value, Res.Program_Scope);
         end if;

         IR.Emit_Leave (Unit.all, Filling, Answer, Site);
         IR.Leave_Block (Unit.all, Filling);
         Current := IR.No_Block;
         Filling := IR.No_Item;
      end Lower_Datum;

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
                        declare
                           Held : constant Ty.Type_Kind :=
                             Landin.Checking.Type_Of (Types.all, Id);
                        begin
                           Made :=
                             IR.Add_Item
                               (Unit.all, IR.Datum, Id, Held,
                                Site_Of (Of_Tree.all, Node));

                           --  [0520]'s shape: one element and a count,
                           --  because an array is its element repeated
                           --  and a run of them would be as long as the
                           --  count, which reaches four billion.
                           if Held = Ty.Fixed_Array then
                              IR.Set_Array
                                (Unit.all, Made,
                                 Landin.Checking.Array_Element
                                   (Types.all, Id),
                                 IR.Element_Total
                                   (Landin.Checking.Array_Length
                                      (Types.all, Id)));
                           end if;

                           --  [0750]'s fields, in the order they were
                           --  written.  The compact scalar or fixed-array
                           --  shapes and not the offsets: a backend has a
                           --  description and works out the same placement
                           --  the checker did.
                           if Held = Ty.Aggregate then
                              for Field in
                                1 .. Landin.Checking.Layout_Field_Count
                                       (Types.all, Id)
                              loop
                                 Add_Stored_Field
                                   (Id, Field, Datum => Made);
                              end loop;
                           end if;
                        end;

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
                  case Syn.Kind (Of_Tree.all, Node) is
                     when Syn.Function_Declaration =>
                        Lower_Routine (Of_Tree.all, Node);

                     when Syn.Binding =>
                        Lower_Datum (Of_Tree.all, Node);

                     when others =>
                        null;
                  end case;
               end;
            end loop;
         end;
      end loop;

      --  Pass three: D24/D34/D66 initial-image resolution.  Array datums keep
      --  their per-position or compact repetition folds; an aggregate literal
      --  carries one fold per declaration-order field.  A direct storage name
      --  follows D21/D60/D61's chain while preserving the source image.  An
      --  absent or explicit zero image stays reserved in `.bss`; a written
      --  image reaches `.data`.  This pass follows Lower_Datum because a
      --  source may be written below its use [1740].
      Resolve_Module_Images :
      declare
         Declarations : constant Natural :=
           Res.Declaration_Count (Meanings.all);
         subtype Numbered is
           Res.Declaration_Id range 1 .. Res.Declaration_Id
                                          (Positive'Max (1, Declarations));

         type Image_State is (Unseen, Visiting, Resolved);

         Where : array (Numbered) of Image_State := [others => Unseen];
         Made  : array (Numbered) of Boolean := [others => False];

         --  Every [1820] operator [1940] admits over literals, so a
         --  bool comparison, a bitwise expression, a shift or a wrapping
         --  arithmetic operator produces the same image bytes here that
         --  the backend's own module-value fold would have produced for
         --  a scalar module binding: one target-aware folder for both.
         --  Constructs the checker excludes from D24 (a call, a member
         --  selection, an element index and a nested array literal) are
         --  refused before this pass reads them and reach here as a
         --  compiler defect, not as [1940] silently narrowed.
         type Pattern is mod 2 ** 64;
         function Mask
           (Value : Pattern;
            Bits  : Landin.Targets.Bit_Width) return Pattern
           is (if Bits >= 64 then Value
               else Value and (2 ** Natural (Bits) - 1));
         function Is_Negative
           (Value : Pattern;
            Bits  : Landin.Targets.Bit_Width) return Boolean
           is ((Value and 2 ** (Natural (Bits) - 1)) /= 0);
         function To_Pattern
           (Value : Ty.Folded;
            Bits  : Landin.Targets.Bit_Width) return Pattern
           is (if Value < 0
               then Mask (0 - Pattern (-Value), Bits)
               else Mask (Pattern (Value), Bits));
         function As_Number
           (Value  : Pattern;
            Bits   : Landin.Targets.Bit_Width;
            Signed : Boolean) return Ty.Folded
           is (if Signed and then Is_Negative (Value, Bits)
               then -Ty.Folded (Mask (0 - Value, Bits))
               else Ty.Folded (Value));

         --  How wide this expression folds.  Bool has no arithmetic width
         --  and folds at the byte the backend gives it -- the same rule
         --  the backend's own folder keeps.
         function Fold_Width
           (Kind : Ty.Scalar_Name) return Landin.Targets.Bit_Width
           is (if Kind in Ty.Integer_Name
               then Ty.Width (Ty.Integer_Name (Kind), Facts)
               else 8);

         function Is_Signed_Type (Kind : Ty.Scalar_Name) return Boolean
           is (Kind in Ty.Integer_Name
               and then Ty.Is_Signed (Ty.Integer_Name (Kind)));

         procedure Fold_Constant
           (Of_Tree : Syn.Tree;
            Node    : Syn.Node_Id;
            Value   : out Ty.Folded;
            Known   : out Boolean);

         procedure Fold_Scalar_Datum
           (Id    : Res.Declaration_Id;
            Value : out Ty.Folded;
            Known : out Boolean);

         --  A per-datum guard against the fold following a [1940] cycle
         --  the checker's own fold guard did not report.  Deliberately a
         --  distinct set from Where above, because Fold_Scalar_Datum can
         --  reach a module binding that also owns an array image and the
         --  two questions travel through the same table.
         Folding : array (Numbered) of Boolean := [others => False];

         procedure Fold_Scalar_Datum
           (Id    : Res.Declaration_Id;
            Value : out Ty.Folded;
            Known : out Boolean)
         is
            Their_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Id));
            Theirs : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Id);
            Their_Value : constant Syn.Node_Id :=
              Syn.Value_Of (Their_Tree.all, Theirs);
         begin
            Value := 0;
            Known := False;

            if Folding (Id) then
               return;
            end if;

            if Their_Value = Syn.No_Node then
               --  D10 gives an omitted-initializer binding zero and False
               --  for a bool.  Either way, the folded value is zero.
               Value := 0;
               Known := True;
               return;
            end if;

            Folding (Id) := True;
            Fold_Constant (Their_Tree.all, Their_Value, Value, Known);
            Folding (Id) := False;
         end Fold_Scalar_Datum;

         procedure Fold_Constant
           (Of_Tree : Syn.Tree;
            Node    : Syn.Node_Id;
            Value   : out Ty.Folded;
            Known   : out Boolean)
         is
            procedure Combine
              (Left, Right : Ty.Folded;
               Of_Kind     : Syn.Node_Kind;
               Answer      : out Ty.Folded;
               Fits        : out Boolean);

            procedure Combine
              (Left, Right : Ty.Folded;
               Of_Kind     : Syn.Node_Kind;
               Answer      : out Ty.Folded;
               Fits        : out Boolean) is
            begin
               Answer := 0;
               Fits   := True;

               case Of_Kind is
                  when Syn.Add | Syn.Wrapping_Add =>
                     Fits := (if Right > 0
                              then Left <= Ty.Folded'Last - Right
                              else Left >= Ty.Folded'First - Right);

                  when Syn.Subtract | Syn.Wrapping_Subtract =>
                     Fits := (if Right > 0
                              then Left >= Ty.Folded'First + Right
                              else Left <= Ty.Folded'Last + Right);

                  when Syn.Multiply | Syn.Wrapping_Multiply =>
                     Fits := Left = 0
                             or else abs Right
                                     <= Ty.Folded'Last / abs Left;

                  when Syn.Divide | Syn.Remainder =>
                     Fits := Right /= 0;

                  when others =>
                     Fits := False;
               end case;

               if not Fits then
                  return;
               end if;

               case Of_Kind is
                  when Syn.Add | Syn.Wrapping_Add =>
                     Answer := Left + Right;
                  when Syn.Subtract | Syn.Wrapping_Subtract =>
                     Answer := Left - Right;
                  when Syn.Multiply | Syn.Wrapping_Multiply =>
                     Answer := Left * Right;
                  when Syn.Divide =>
                     Answer := Left / Right;
                  when Syn.Remainder =>
                     Answer := Left rem Right;
                  when others =>
                     Fits := False;
               end case;
            end Combine;
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
                       Landin.Stages.Source
                         (Context, Syn.Source_Of (Of_Tree));
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

               when Syn.True_Literal =>
                  Value := 1;
                  Known := True;

               when Syn.False_Literal =>
                  Value := 0;
                  Known := True;

               when Syn.Zeroed_Literal =>
                  --  D66 gives a labelled scalar `zeroed` its field type;
                  --  its target-neutral fold is the same zero pattern D42
                  --  uses at runtime.
                  Value := 0;
                  Known := True;

               when Syn.Negation =>
                  declare
                     Under : Ty.Folded;
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                        Under, Known);
                     if Known then
                        Value := -Under;
                     end if;
                  end;

               when Syn.Name_Reference =>
                  if Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                     = Res.Bound
                  then
                     declare
                        Means : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, Node);
                     begin
                        if Res.Sort_Of (Meanings.all, Means)
                           = Res.Module_Binding
                          and then Landin.Checking.Type_Of
                                     (Types.all, Means)
                                   in Ty.Scalar_Name
                        then
                           Fold_Scalar_Datum (Means, Value, Known);
                        end if;
                     end;
                  end if;

               when Syn.Add | Syn.Subtract | Syn.Multiply | Syn.Divide
                  | Syn.Remainder =>
                  declare
                     Left, Right : Ty.Folded;
                     Left_Known, Right_Known, Fits : Boolean;
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Left_Of (Of_Tree, Node),
                        Left, Left_Known);
                     Fold_Constant
                       (Of_Tree, Syn.Right_Of (Of_Tree, Node),
                        Right, Right_Known);
                     if Left_Known and then Right_Known then
                        Combine
                          (Left, Right, Syn.Kind (Of_Tree, Node),
                           Value, Fits);
                        Known := Fits;
                     end if;
                  end;

               --  [0300]'s wrapping arithmetic, [0330]'s bitwise set and
               --  [0320]'s shifts all depend on the operand type's width.
               --  Checking has already settled the same target-aware fold;
               --  this second walk records its verified answer in the image.
               when Syn.Wrapping_Add | Syn.Wrapping_Subtract
                  | Syn.Wrapping_Multiply
                  | Syn.Bitwise_And | Syn.Bitwise_Xor | Syn.Bitwise_Or
                  | Syn.Shift_Left | Syn.Shift_Right =>
                  declare
                     Op         : constant Syn.Node_Kind :=
                       Syn.Kind (Of_Tree, Node);
                     Left_Node  : constant Syn.Node_Id :=
                       Syn.Left_Of (Of_Tree, Node);
                     Right_Node : constant Syn.Node_Id :=
                       Syn.Right_Of (Of_Tree, Node);
                     Left       : Ty.Folded := 0;
                     Right      : Ty.Folded := 0;
                     Left_Known, Right_Known : Boolean := False;
                     Kind       : constant Ty.Type_Kind :=
                       Landin.Checking.Type_Of
                         (Types.all, Of_Tree, Node);
                  begin
                     Fold_Constant (Of_Tree, Left_Node, Left, Left_Known);
                     Fold_Constant
                       (Of_Tree, Right_Node, Right, Right_Known);

                     if Left_Known and then Right_Known
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
                              when Syn.Wrapping_Add =>
                                 Answer := Mask (LP + RP, Bits);
                              when Syn.Wrapping_Subtract =>
                                 Answer := Mask (LP - RP, Bits);
                              when Syn.Wrapping_Multiply =>
                                 Answer := Mask (LP * RP, Bits);
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
                                           (LP * 2 ** Natural (Right),
                                            Bits));
                              when Syn.Shift_Right =>
                                 --  [0320]: signed `>>` preserves the sign
                                 --  and unsigned fills with zeros.  Mirror
                                 --  the backend's rule so the image is what
                                 --  a datum's loaded bytes would compute.
                                 Answer :=
                                   (if Exhausted then 0
                                    elsif Signed and then Left < 0
                                    then Mask
                                           (not
                                             (Mask (not LP, Bits)
                                              / 2 ** Natural (Right)),
                                            Bits)
                                    else Mask
                                           (LP / 2 ** Natural (Right),
                                            Bits));
                              when others =>
                                 raise Landin.Compiler_Defect with
                                   "unreachable width-op case";
                           end case;
                           Value := As_Number (Answer, Bits, Signed);
                           Known := True;
                        end;
                     end if;
                  end;

               when Syn.Complement =>
                  declare
                     Under : Ty.Folded := 0;
                     Under_Known : Boolean := False;
                     Kind : constant Ty.Type_Kind :=
                       Landin.Checking.Type_Of
                         (Types.all, Of_Tree, Node);
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                        Under, Under_Known);
                     if Under_Known and then Kind in Ty.Scalar_Name then
                        declare
                           Bits : constant Landin.Targets.Bit_Width :=
                             Fold_Width (Ty.Scalar_Name (Kind));
                           Signed : constant Boolean :=
                             Is_Signed_Type (Ty.Scalar_Name (Kind));
                        begin
                           Value :=
                             As_Number
                               (Mask
                                  (not To_Pattern (Under, Bits), Bits),
                                Bits, Signed);
                           Known := True;
                        end;
                     end if;
                  end;

               when Syn.Logical_Not =>
                  declare
                     Under : Ty.Folded := 0;
                     Under_Known : Boolean := False;
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                        Under, Under_Known);
                     if Under_Known then
                        Value := 1 - Under;
                        Known := True;
                     end if;
                  end;

               when Syn.Logical_And =>
                  --  [0410]: `and` short-circuits.  A false left settles
                  --  the answer without evaluating the right, which is
                  --  the same rule the checker's own module value fold
                  --  keeps for the same reason -- the right may not fold.
                  declare
                     Left : Ty.Folded := 0;
                     Left_Known : Boolean := False;
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Left_Of (Of_Tree, Node),
                        Left, Left_Known);
                     if Left_Known and then Left = 0 then
                        Value := 0;
                        Known := True;
                     elsif Left_Known then
                        declare
                           Right : Ty.Folded := 0;
                           Right_Known : Boolean := False;
                        begin
                           Fold_Constant
                             (Of_Tree, Syn.Right_Of (Of_Tree, Node),
                              Right, Right_Known);
                           if Right_Known then
                              Value := Right;
                              Known := True;
                           end if;
                        end;
                     end if;
                  end;

               when Syn.Logical_Or =>
                  declare
                     Left : Ty.Folded := 0;
                     Left_Known : Boolean := False;
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Left_Of (Of_Tree, Node),
                        Left, Left_Known);
                     if Left_Known and then Left = 1 then
                        Value := 1;
                        Known := True;
                     elsif Left_Known then
                        declare
                           Right : Ty.Folded := 0;
                           Right_Known : Boolean := False;
                        begin
                           Fold_Constant
                             (Of_Tree, Syn.Right_Of (Of_Tree, Node),
                              Right, Right_Known);
                           if Right_Known then
                              Value := Right;
                              Known := True;
                           end if;
                        end;
                     end if;
                  end;

               when Syn.Equal_To | Syn.Not_Equal_To
                  | Syn.Less_Than | Syn.Less_Or_Equal
                  | Syn.Greater_Than | Syn.Greater_Or_Equal =>
                  declare
                     Op : constant Syn.Node_Kind :=
                       Syn.Kind (Of_Tree, Node);
                     Left, Right : Ty.Folded := 0;
                     Left_Known, Right_Known : Boolean := False;
                  begin
                     Fold_Constant
                       (Of_Tree, Syn.Left_Of (Of_Tree, Node),
                        Left, Left_Known);
                     Fold_Constant
                       (Of_Tree, Syn.Right_Of (Of_Tree, Node),
                        Right, Right_Known);
                     if Left_Known and then Right_Known then
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
                  --  [0370]: a measurement of an enabled type folds to the
                  --  target's own byte count; the whole point of it being
                  --  a `usize` is that a target answers.  D44's aggregate
                  --  answer is the checked target layout here because this
                  --  walk is forming a static datum image, not ordinary IR.
                  declare
                     Asked : constant Syn.Node_Id :=
                       Syn.Measured_Type (Of_Tree, Node);
                     Held : constant Ty.Type_Kind :=
                       Landin.Checking.Type_Of
                         (Types.all, Of_Tree, Asked);
                  begin
                     if Held in Ty.Scalar_Name then
                        declare
                           Size : constant Landin.Targets.Scalar_Size :=
                             Ty.Storage_Size
                               (Ty.Scalar_Name (Held), Facts);
                        begin
                           if Syn.Kind (Of_Tree, Node) = Syn.Size_Of then
                              Value :=
                                Ty.Folded
                                  (Landin.Targets.Bytes (Size));
                           else
                              Value :=
                                Ty.Folded
                                  (Landin.Targets.Alignment_Of
                                     (Facts, Size));
                           end if;
                           Known := True;
                        end;
                     elsif Held = Ty.Fixed_Array then
                        declare
                           Length : constant Landin.Checking.Element_Count
                             :=
                               Landin.Checking.Array_Length
                                 (Types.all, Of_Tree, Asked);
                           Element : constant Ty.Scalar_Name :=
                             Landin.Checking.Array_Element
                               (Types.all, Of_Tree, Asked);
                           Size : constant Landin.Targets.Scalar_Size :=
                             Ty.Storage_Size (Element, Facts);
                        begin
                           if Syn.Kind (Of_Tree, Node) = Syn.Align_Of then
                              Value :=
                                (if Length = 0 then 1
                                 else Ty.Folded
                                        (Landin.Targets.Alignment_Of
                                           (Facts, Size)));
                           else
                              Value :=
                                Ty.Folded
                                  (Landin.Targets.Byte_Count (Length)
                                   * Landin.Targets.Byte_Count
                                       (Landin.Targets.Bytes (Size)));
                           end if;
                           Known := True;
                        end;
                     elsif Held = Ty.Aggregate then
                        declare
                           Declared : constant Res.Declaration_Id :=
                             Landin.Checking.Body_Of
                               (Types.all, Of_Tree, Asked);
                        begin
                           Value :=
                             Ty.Folded
                               (if Syn.Kind (Of_Tree, Node) = Syn.Size_Of
                                then Landin.Checking.Layout_Size
                                       (Types.all, Declared)
                                else Landin.Checking.Layout_Alignment
                                       (Types.all, Declared));
                           Known := True;
                        end;
                     end if;
                  end;

               when Syn.Len_Of =>
                  --  [0370]'s length lives on the type, not on storage.
                  declare
                     Asked : constant Syn.Node_Id :=
                       Syn.Operand_Of (Of_Tree, Node);
                  begin
                     if Syn.Kind (Of_Tree, Asked) = Syn.Array_Literal then
                        Value :=
                          Ty.Folded (Syn.Element_Count (Of_Tree, Asked));
                        Known := True;
                     elsif Syn.Kind (Of_Tree, Asked) = Syn.Name_Reference
                       and then Res.Verdict_Of
                                  (Meanings.all, Of_Tree, Asked)
                                = Res.Bound
                     then
                        declare
                           Named : constant Res.Declaration_Id :=
                             Res.Bound_To
                               (Meanings.all, Of_Tree, Asked);
                        begin
                           if Landin.Checking.Type_Of
                                (Types.all, Named) = Ty.Fixed_Array
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
                  --  A construct outside D24's boundary.  The checker
                  --  refused everything else that could reach here, so
                  --  meeting one is a compiler defect rather than a
                  --  diagnosis.
                  raise Landin.Compiler_Defect with
                    "a module array literal element the lowering cannot"
                    & " fold reached image resolution";
            end case;
         end Fold_Constant;

         procedure Set_Image_From_Literal
           (Id      : Res.Declaration_Id;
            Of_Tree : Syn.Tree;
            Literal : Syn.Node_Id);

         procedure Set_Image_From_Literal
           (Id      : Res.Declaration_Id;
            Of_Tree : Syn.Tree;
            Literal : Syn.Node_Id)
         is
            Count : constant Natural :=
              Syn.Element_Count (Of_Tree, Literal);
         begin
            if Count = 0 then
               return;
            end if;

            declare
               Values : Ty.Folded_Array (1 .. Count) := [others => 0];
               Held   : Ty.Folded;
               Known  : Boolean;
            begin
               for Position in 1 .. Count loop
                  Fold_Constant
                    (Of_Tree,
                     Syn.Nth_Element (Of_Tree, Literal, Position),
                     Held, Known);
                  if not Known then
                     raise Landin.Compiler_Defect with
                       "a module array literal element the checker"
                       & " accepted did not fold at lowering";
                  end if;
                  Values (Position) := Held;
               end loop;

               IR.Set_Array_Image
                 (Unit.all, IR.Item_For (Unit.all, Id), Values);
               Made (Id) := True;
            end;
         end Set_Image_From_Literal;

         procedure Set_Image_From_Repetition
           (Id         : Res.Declaration_Id;
            Of_Tree    : Syn.Tree;
            Repetition : Syn.Node_Id);

         procedure Set_Image_From_Repetition
           (Id         : Res.Declaration_Id;
            Of_Tree    : Syn.Tree;
            Repetition : Syn.Node_Id)
         is
            Held  : Ty.Folded;
            Known : Boolean;
         begin
            Fold_Constant
              (Of_Tree, Syn.Repeated_Element (Of_Tree, Repetition),
               Held, Known);
            if not Known then
               raise Landin.Compiler_Defect with
                 "a module array repetition element the checker accepted"
                 & " did not fold at lowering";
            end if;

            --  D34's zero pattern is loader-zeroed storage, represented by
            --  the same absent image as D10 and `zeroed`.  Every nonzero
            --  extent is one scalar plus the compact D17 shape.
            if Held /= 0 then
               IR.Set_Repeated_Array_Image
                 (Unit.all, IR.Item_For (Unit.all, Id), Held);
               Made (Id) := True;
            end if;
         end Set_Image_From_Repetition;

         procedure Set_Image_From_Mixed_Repetition
           (Id         : Res.Declaration_Id;
            Of_Tree    : Syn.Tree;
            Repetition : Syn.Node_Id);

         procedure Set_Image_From_Mixed_Repetition
           (Id         : Res.Declaration_Id;
            Of_Tree    : Syn.Tree;
            Repetition : Syn.Node_Id)
         is
            Count : constant Natural :=
              Syn.Element_Count (Of_Tree, Repetition);
            Values : Ty.Folded_Array (1 .. Count) := [others => 0];
            Held  : Ty.Folded;
            Known : Boolean;
         begin
            for Position in Values'Range loop
               Fold_Constant
                 (Of_Tree,
                  Syn.Nth_Element (Of_Tree, Repetition, Position),
                  Held, Known);
               if not Known then
                  raise Landin.Compiler_Defect with
                    "a module mixed repetition prefix the checker accepted"
                    & " did not fold at lowering";
               end if;
               Values (Position) := Held;
            end loop;

            Fold_Constant
              (Of_Tree, Syn.Repeated_Element (Of_Tree, Repetition),
               Held, Known);
            if not Known then
               raise Landin.Compiler_Defect with
                 "a module mixed repetition suffix the checker accepted"
                 & " did not fold at lowering";
            end if;

            --  D38 always records the hybrid, including a zero suffix.  Its
            --  finite prefix makes the datum an explicit `.data` image.
            IR.Set_Hybrid_Array_Image
              (Unit.all, IR.Item_For (Unit.all, Id), Values, Held);
            Made (Id) := True;
         end Set_Image_From_Mixed_Repetition;

         --  D69's struct-literal field may name an array datum declared
         --  later, so its image must be resolved before the aggregate image
         --  gathers that field's compact descriptor.
         procedure Resolve_Image (Id : Res.Declaration_Id);

         procedure Copy_Field_Descriptor
           (Source_Item  : IR.Item_Id;
            Source_Field : Positive;
            Cursor       : in out Natural;
            Image        : out IR.Aggregate_Field_Image;
            Elements     : in out Ty.Folded_Array);

         function Array_Image_Element_Count
           (Source_Item : IR.Item_Id) return Natural;

         procedure Copy_Array_Descriptor
           (Source_Item : IR.Item_Id;
            Cursor      : in out Natural;
            Image       : out IR.Aggregate_Field_Image;
            Elements    : in out Ty.Folded_Array);

         function Array_Image_Element_Count
           (Source_Item : IR.Item_Id) return Natural
         is
         begin
            return
              (if IR.Is_Repeated_Image (Unit.all, Source_Item)
               then Natural
                 (IR.Image_Prefix_Length (Unit.all, Source_Item))
               else Natural (IR.Image_Length (Unit.all, Source_Item)));
         end Array_Image_Element_Count;

         procedure Copy_Array_Descriptor
           (Source_Item : IR.Item_Id;
            Cursor      : in out Natural;
            Image       : out IR.Aggregate_Field_Image;
            Elements    : in out Ty.Folded_Array)
         is
         begin
            Image := (others => <>);
            Image.Offset := Cursor;

            if IR.Is_Repeated_Image (Unit.all, Source_Item) then
               Image.Count := Natural
                 (IR.Image_Prefix_Length (Unit.all, Source_Item));
               Image.Form :=
                 (if Image.Count = 0 then IR.Repeated else IR.Hybrid);
               Image.Value :=
                 IR.Repeated_Image_Value (Unit.all, Source_Item);
            else
               Image.Count := Natural
                 (IR.Image_Length (Unit.all, Source_Item));
               Image.Form := IR.Finite;
            end if;

            for Position in 1 .. Image.Count loop
               Elements (Cursor + Position) :=
                 IR.Nth_Image
                   (Unit.all, Source_Item, IR.Part_Position (Position));
            end loop;
            Cursor := Cursor + Image.Count;
         end Copy_Array_Descriptor;

         procedure Copy_Field_Descriptor
           (Source_Item  : IR.Item_Id;
            Source_Field : Positive;
            Cursor       : in out Natural;
            Image        : out IR.Aggregate_Field_Image;
            Elements     : in out Ty.Folded_Array)
         is
         begin
            Image :=
              IR.Field_Image_Of (Unit.all, Source_Item, Source_Field);
            Image.Offset := Cursor;

            if Image.Form in IR.Finite | IR.Hybrid then
               for Position in 1 .. Image.Count loop
                  Elements (Cursor + Position) :=
                    IR.Nth_Field_Element
                      (Unit.all, Source_Item, Source_Field,
                       IR.Part_Position (Position));
               end loop;
            elsif Image.Count /= 0 then
               raise Landin.Compiler_Defect with
                 "an absent or repeated aggregate field image carried"
                 & " finite elements";
            end if;

            Cursor := Cursor + Image.Count;
         end Copy_Field_Descriptor;

         procedure Set_Image_From_Struct_Literal
           (Id      : Res.Declaration_Id;
            Of_Tree : Syn.Tree;
            Literal : Syn.Node_Id);

         procedure Set_Image_From_Struct_Literal
           (Id      : Res.Declaration_Id;
            Of_Tree : Syn.Tree;
            Literal : Syn.Node_Id)
         is
            Item : constant IR.Item_Id := IR.Item_For (Unit.all, Id);
            Count : constant Natural := IR.Field_Count (Unit.all, Item);
            type Node_Array is array (Positive range <>) of Syn.Node_Id;
            Nodes : Node_Array (1 .. Count) := [others => Syn.No_Node];
            Element_Count : Natural := 0;
            Payload_Count : Natural := 0;
         begin
            for Position in
              1 .. Syn.Field_Value_Count (Of_Tree, Literal)
            loop
               declare
                  Field : constant Syn.Node_Id :=
                    Syn.Nth_Field_Value (Of_Tree, Literal, Position);
                  Which : constant Positive :=
                    Landin.Checking.Field_Index
                      (Types.all, Of_Tree, Field);
               begin
                  Nodes (Which) := Field;
                  if IR.Nth_Field_Shape
                       (Unit.all, Item, Which).Kind
                       = IR.Variant_Field_Shape
                  then
                     declare
                        Value : constant Syn.Node_Id :=
                          Syn.Value_Of (Of_Tree, Field);
                        Selected : constant Positive :=
                          Positive
                            (Landin.Checking.Field_Index
                               (Types.all, Of_Tree, Value));
                     begin
                        Payload_Count := Payload_Count
                          + IR.Variant_Case_Field_Count
                              (Unit.all,
                               IR.Nth_Field_Shape
                                 (Unit.all, Item, Which),
                               Selected);

                        --  D82's finite and hybrid payload images append
                        --  their prefix folds to the same item-owned image
                        --  run as D67's top-level array fields.  Count them
                        --  before opening that single run below.
                        if Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal then
                           for Payload_Position in
                             1 .. Syn.Field_Value_Count (Of_Tree, Value)
                           loop
                              declare
                                 Label : constant Syn.Node_Id :=
                                   Syn.Nth_Field_Value
                                     (Of_Tree, Value, Payload_Position);
                                 Payload : constant Positive := Positive
                                   (Landin.Checking.Field_Index
                                      (Types.all, Of_Tree, Label));
                                 Leaf : constant IR.Field_Shape :=
                                   IR.Nth_Variant_Case_Field
                                     (Unit.all,
                                      IR.Nth_Field_Shape
                                        (Unit.all, Item, Which),
                                      Selected, Payload);
                                 Given : constant Syn.Node_Id :=
                                   Syn.Value_Of (Of_Tree, Label);
                              begin
                                 if Leaf.Kind = IR.Array_Field_Shape
                                   and then Syn.Kind (Of_Tree, Given)
                                     in Syn.Array_Literal
                                        | Syn.Mixed_Array_Repetition
                                 then
                                    Element_Count := Element_Count
                                      + Syn.Element_Count
                                          (Of_Tree, Given);
                                 elsif Leaf.Kind = IR.Array_Field_Shape
                                   and then Syn.Kind (Of_Tree, Given)
                                     = Syn.Name_Reference
                                 then
                                    declare
                                       Source_Id : constant
                                         Res.Declaration_Id :=
                                           Res.Bound_To
                                             (Meanings.all, Of_Tree, Given);
                                    begin
                                       Resolve_Image (Source_Id);
                                       if Made (Source_Id) then
                                          Element_Count := Element_Count
                                            + Array_Image_Element_Count
                                                (IR.Item_For
                                                   (Unit.all, Source_Id));
                                       end if;
                                    end;
                                 elsif Leaf.Kind = IR.Array_Field_Shape
                                   and then Syn.Kind (Of_Tree, Given)
                                     = Syn.Member_Selection
                                 then
                                    declare
                                       From : constant Syn.Node_Id :=
                                         Syn.Target_Of (Of_Tree, Given);
                                       Source_Id : constant
                                         Res.Declaration_Id :=
                                           Res.Bound_To
                                             (Meanings.all, Of_Tree, From);
                                    begin
                                       Resolve_Image (Source_Id);
                                       if Made (Source_Id) then
                                          Element_Count := Element_Count
                                            + IR.Field_Image_Of
                                                (Unit.all,
                                                 IR.Item_For
                                                   (Unit.all, Source_Id),
                                                 Positive
                                                   (Landin.Checking
                                                      .Field_Index
                                                      (Types.all, Of_Tree,
                                                       Given))).Count;
                                       end if;
                                    end;
                                 end if;
                              end;
                           end loop;
                        end if;
                     end;
                  elsif Syn.Kind
                       (Of_Tree, Syn.Value_Of (Of_Tree, Field))
                       in Syn.Array_Literal | Syn.Mixed_Array_Repetition
                  then
                     Element_Count := Element_Count
                       + Syn.Element_Count
                           (Of_Tree, Syn.Value_Of (Of_Tree, Field));
                  elsif Syn.Kind
                    (Of_Tree, Syn.Value_Of (Of_Tree, Field))
                      = Syn.Name_Reference
                    and then IR.Nth_Field_Shape
                      (Unit.all, Item, Which).Kind
                        = IR.Array_Field_Shape
                  then
                     declare
                        Value : constant Syn.Node_Id :=
                          Syn.Value_Of (Of_Tree, Field);
                        Source_Id : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, Value);
                     begin
                        Resolve_Image (Source_Id);
                        if Made (Source_Id) then
                           declare
                              Source_Item : constant IR.Item_Id :=
                                IR.Item_For (Unit.all, Source_Id);
                           begin
                              Element_Count := Element_Count
                                + (if IR.Is_Repeated_Image
                                       (Unit.all, Source_Item)
                                   then Natural
                                     (IR.Image_Prefix_Length
                                        (Unit.all, Source_Item))
                                   else Natural
                                     (IR.Image_Length
                                        (Unit.all, Source_Item)));
                           end;
                        end if;
                     end;
                  elsif Syn.Kind
                    (Of_Tree, Syn.Value_Of (Of_Tree, Field))
                      = Syn.Member_Selection
                    and then IR.Nth_Field_Shape
                      (Unit.all, Item, Which).Kind
                        = IR.Array_Field_Shape
                  then
                     declare
                        Value : constant Syn.Node_Id :=
                          Syn.Value_Of (Of_Tree, Field);
                        From : constant Syn.Node_Id :=
                          Syn.Target_Of (Of_Tree, Value);
                        Source_Id : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, From);
                     begin
                        Resolve_Image (Source_Id);
                        if Made (Source_Id) then
                           declare
                              Source_Item : constant IR.Item_Id :=
                                IR.Item_For (Unit.all, Source_Id);
                              Source_Field : constant Positive :=
                                Positive
                                  (Landin.Checking.Field_Index
                                     (Types.all, Of_Tree, Value));
                           begin
                              Element_Count := Element_Count
                                + IR.Field_Image_Of
                                    (Unit.all, Source_Item,
                                     Source_Field).Count;
                           end;
                        end if;
                     end;
                  end if;
               end;
            end loop;

            declare
               Values : Ty.Folded_Array (1 .. Count) := [others => 0];
               Images : IR.Aggregate_Field_Image_Array (1 .. Count) :=
                 [others => (others => <>)];
               Payloads : IR.Aggregate_Field_Image_Array
                 (1 .. Payload_Count) := [others => (others => <>)];
               Elements : Ty.Folded_Array (1 .. Element_Count) :=
                 [others => 0];
               Cursor : Natural := 0;
               Payload_Cursor : Natural := 0;
            begin
               for Which in 1 .. Count loop
                  Images (Which).Offset := Cursor;

                  if Nodes (Which) /= Syn.No_Node then
                     declare
                        Value : constant Syn.Node_Id :=
                          Syn.Value_Of (Of_Tree, Nodes (Which));
                        Shape : constant IR.Field_Shape :=
                          IR.Nth_Field_Shape (Unit.all, Item, Which);
                     begin
                        if Shape.Kind = IR.Scalar_Field_Shape then
                           declare
                              Held  : Ty.Folded;
                              Known : Boolean;
                           begin
                              Fold_Constant
                                (Of_Tree, Value, Held, Known);
                              if not Known then
                                 raise Landin.Compiler_Defect with
                                   "a module struct literal field the"
                                   & " checker accepted did not fold at"
                                   & " lowering";
                              end if;
                              Values (Which) := Held;
                           end;
                        elsif Shape.Kind = IR.Variant_Field_Shape then
                           declare
                              Selected : constant Positive :=
                                Positive
                                  (Landin.Checking.Field_Index
                                     (Types.all, Of_Tree, Value));
                              Payload_Count : constant Natural :=
                                IR.Variant_Case_Field_Count
                                  (Unit.all, Shape, Selected);
                              Payload_Nodes : Node_Array
                                (1 .. Payload_Count) :=
                                  [others => Syn.No_Node];
                           begin
                              Images (Which) :=
                                (Form   => IR.Selected,
                                 Offset => Payload_Cursor,
                                 Count  => Payload_Count,
                                 Value  => Ty.Folded (Selected));

                              if Syn.Kind (Of_Tree, Value)
                                   = Syn.Struct_Literal
                              then
                                 for Position in
                                   1 .. Syn.Field_Value_Count
                                          (Of_Tree, Value)
                                 loop
                                    declare
                                       Label : constant Syn.Node_Id :=
                                         Syn.Nth_Field_Value
                                           (Of_Tree, Value, Position);
                                       Payload : constant Positive :=
                                         Positive
                                           (Landin.Checking.Field_Index
                                              (Types.all, Of_Tree, Label));
                                    begin
                                       Payload_Nodes (Payload) := Label;
                                    end;
                                 end loop;
                              end if;

                              for Payload in 1 .. Payload_Count loop
                                 declare
                                    Image : IR.Aggregate_Field_Image
                                      renames Payloads
                                        (Payload_Cursor + Payload);
                                    Leaf : constant IR.Field_Shape :=
                                      IR.Nth_Variant_Case_Field
                                        (Unit.all, Shape, Selected, Payload);
                                 begin
                                    Image.Offset := Cursor;
                                    if Leaf.Kind =
                                         IR.Scalar_Field_Shape
                                      and then Payload_Nodes (Payload)
                                        /= Syn.No_Node
                                    then
                                       declare
                                          Held : Ty.Folded;
                                          Known : Boolean;
                                       begin
                                          Fold_Constant
                                            (Of_Tree,
                                             Syn.Value_Of
                                               (Of_Tree,
                                                Payload_Nodes (Payload)),
                                             Held, Known);
                                          if not Known then
                                             raise Landin.Compiler_Defect
                                               with "a module variant"
                                               & " payload the checker"
                                               & " accepted did not fold";
                                          end if;
                                          Image.Value := Held;
                                       end;
                                    elsif Leaf.Kind = IR.Array_Field_Shape
                                      and then Payload_Nodes (Payload)
                                        /= Syn.No_Node
                                    then
                                       declare
                                          Given : constant Syn.Node_Id :=
                                            Syn.Value_Of
                                              (Of_Tree,
                                               Payload_Nodes (Payload));
                                       begin
                                          if Syn.Kind (Of_Tree, Given)
                                            in Syn.Array_Literal
                                               | Syn.Mixed_Array_Repetition
                                          then
                                             Image.Form :=
                                               (if Syn.Kind (Of_Tree, Given)
                                                    = Syn.Array_Literal
                                                then IR.Finite
                                                else IR.Hybrid);
                                             Image.Count :=
                                               Syn.Element_Count
                                                 (Of_Tree, Given);
                                             for Position in
                                               1 .. Image.Count
                                             loop
                                                declare
                                                   Held : Ty.Folded;
                                                   Known : Boolean;
                                                begin
                                                   Fold_Constant
                                                     (Of_Tree,
                                                      Syn.Nth_Element
                                                        (Of_Tree, Given,
                                                         Position),
                                                      Held, Known);
                                                   if not Known then
                                                      raise
                                                        Landin.Compiler_Defect
                                                        with "a module"
                                                        & " variant array"
                                                        & " payload element"
                                                        & " did not fold";
                                                   end if;
                                                   Elements
                                                     (Cursor + Position) :=
                                                       Held;
                                                end;
                                             end loop;
                                             Cursor := Cursor + Image.Count;

                                             if Image.Form = IR.Hybrid then
                                                declare
                                                   Held : Ty.Folded;
                                                   Known : Boolean;
                                                begin
                                                   Fold_Constant
                                                     (Of_Tree,
                                                      Syn.Repeated_Element
                                                        (Of_Tree, Given),
                                                      Held, Known);
                                                   if not Known then
                                                      raise
                                                        Landin.Compiler_Defect
                                                        with "a module"
                                                        & " variant hybrid"
                                                        & " payload suffix"
                                                        & " did not fold";
                                                   end if;
                                                   Image.Value := Held;
                                                end;
                                             end if;
                                          elsif Syn.Kind (Of_Tree, Given)
                                                  = Syn.Array_Repetition
                                          then
                                             declare
                                                Held : Ty.Folded;
                                                Known : Boolean;
                                             begin
                                                Fold_Constant
                                                  (Of_Tree,
                                                   Syn.Repeated_Element
                                                     (Of_Tree, Given),
                                                   Held, Known);
                                                if not Known then
                                                   raise
                                                     Landin.Compiler_Defect
                                                     with "a module variant"
                                                     & " array payload"
                                                     & " pattern did not"
                                                     & " fold";
                                                end if;

                                                --  D34 parity: a full zero
                                                --  pattern is the absent
                                                --  payload image.  D38 keeps
                                                --  a zero hybrid suffix
                                                --  written above.
                                                if Held /= 0 then
                                                   Image.Form := IR.Repeated;
                                                   Image.Value := Held;
                                                end if;
                                             end;
                                          elsif Syn.Kind (Of_Tree, Given)
                                                  = Syn.Name_Reference
                                          then
                                             declare
                                                Source_Id : constant
                                                  Res.Declaration_Id :=
                                                    Res.Bound_To
                                                      (Meanings.all,
                                                       Of_Tree, Given);
                                             begin
                                                Resolve_Image (Source_Id);
                                                if Made (Source_Id) then
                                                   Copy_Array_Descriptor
                                                     (IR.Item_For
                                                        (Unit.all,
                                                         Source_Id),
                                                      Cursor, Image,
                                                      Elements);
                                                end if;
                                             end;
                                          elsif Syn.Kind (Of_Tree, Given)
                                                  = Syn.Member_Selection
                                          then
                                             declare
                                                From : constant Syn.Node_Id :=
                                                  Syn.Target_Of
                                                    (Of_Tree, Given);
                                                Source_Id : constant
                                                  Res.Declaration_Id :=
                                                    Res.Bound_To
                                                      (Meanings.all,
                                                       Of_Tree, From);
                                             begin
                                                Resolve_Image (Source_Id);
                                                if Made (Source_Id) then
                                                   Copy_Field_Descriptor
                                                     (IR.Item_For
                                                        (Unit.all,
                                                         Source_Id),
                                                      Positive
                                                        (Landin.Checking
                                                           .Field_Index
                                                           (Types.all,
                                                            Of_Tree,
                                                            Given)),
                                                      Cursor, Image,
                                                      Elements);
                                                end if;
                                             end;
                                          elsif Syn.Kind (Of_Tree, Given)
                                                  /= Syn.Zeroed_Literal
                                          then
                                             raise Landin.Compiler_Defect
                                               with "a module variant array"
                                               & " payload outside D83"
                                               & " reached lowering";
                                          end if;
                                       end;
                                    elsif Leaf.Kind =
                                      IR.Variant_Field_Shape
                                    then
                                       raise Landin.Compiler_Defect with
                                         "a nested variant payload reached"
                                         & " module image lowering";
                                    end if;
                                 end;
                              end loop;
                              Payload_Cursor := Payload_Cursor
                                + Payload_Count;
                           end;
                        elsif Syn.Kind (Of_Tree, Value)
                                in Syn.Array_Literal
                                   | Syn.Mixed_Array_Repetition
                        then
                           Images (Which).Form :=
                             (if Syn.Kind (Of_Tree, Value)
                                   = Syn.Array_Literal
                              then IR.Finite
                              else IR.Hybrid);
                           Images (Which).Count :=
                             Syn.Element_Count (Of_Tree, Value);
                           for Position in
                             1 .. Syn.Element_Count (Of_Tree, Value)
                           loop
                              declare
                                 Held  : Ty.Folded;
                                 Known : Boolean;
                              begin
                                 Fold_Constant
                                   (Of_Tree,
                                    Syn.Nth_Element
                                      (Of_Tree, Value, Position),
                                    Held, Known);
                                 if not Known then
                                    raise Landin.Compiler_Defect with
                                      "a module struct array-field element"
                                      & " the checker accepted did not"
                                      & " fold at lowering";
                                 end if;
                                 Elements (Cursor + Position) := Held;
                              end;
                           end loop;
                           Cursor := Cursor + Images (Which).Count;
                           if Images (Which).Form = IR.Hybrid then
                              declare
                                 Held  : Ty.Folded;
                                 Known : Boolean;
                              begin
                                 Fold_Constant
                                   (Of_Tree,
                                    Syn.Repeated_Element (Of_Tree, Value),
                                    Held, Known);
                                 if not Known then
                                    raise Landin.Compiler_Defect with
                                      "a module struct hybrid suffix the"
                                      & " checker accepted did not fold at"
                                      & " lowering";
                                 end if;
                                 Images (Which).Value := Held;
                              end;
                           end if;
                        elsif Syn.Kind (Of_Tree, Value)
                                = Syn.Array_Repetition
                        then
                           declare
                              Held  : Ty.Folded;
                              Known : Boolean;
                           begin
                              Fold_Constant
                                (Of_Tree,
                                 Syn.Repeated_Element (Of_Tree, Value),
                                 Held, Known);
                              if not Known then
                                 raise Landin.Compiler_Defect with
                                   "a module struct repetition pattern the"
                                   & " checker accepted did not fold at"
                                   & " lowering";
                              end if;

                              --  D34's full zero pattern is the absent
                              --  field image.  A mixed zero suffix remains
                              --  present above because its prefix is written.
                              if Held /= 0 then
                                 Images (Which).Form := IR.Repeated;
                                 Images (Which).Value := Held;
                              end if;
                           end;
                        elsif Syn.Kind (Of_Tree, Value)
                                = Syn.Name_Reference
                        then
                           declare
                              Source_Id : constant Res.Declaration_Id :=
                                Res.Bound_To
                                  (Meanings.all, Of_Tree, Value);
                           begin
                              Resolve_Image (Source_Id);
                              if Made (Source_Id) then
                                 Copy_Array_Descriptor
                                   (IR.Item_For (Unit.all, Source_Id),
                                    Cursor, Images (Which), Elements);
                              end if;
                           end;
                        elsif Syn.Kind (Of_Tree, Value)
                                = Syn.Member_Selection
                        then
                           declare
                              From : constant Syn.Node_Id :=
                                Syn.Target_Of (Of_Tree, Value);
                              Source_Id : constant Res.Declaration_Id :=
                                Res.Bound_To
                                  (Meanings.all, Of_Tree, From);
                           begin
                              Resolve_Image (Source_Id);
                              if Made (Source_Id) then
                                 Copy_Field_Descriptor
                                   (IR.Item_For (Unit.all, Source_Id),
                                    Positive
                                      (Landin.Checking.Field_Index
                                         (Types.all, Of_Tree, Value)),
                                    Cursor, Images (Which), Elements);
                              end if;
                           end;
                        elsif Syn.Kind (Of_Tree, Value)
                                /= Syn.Zeroed_Literal
                        then
                           raise Landin.Compiler_Defect with
                             "a module struct array-field image outside"
                             & " D69/D71 reached lowering";
                        end if;
                     end;
                  end if;
               end loop;

               IR.Set_Aggregate_Image
                 (Unit.all, Item, Values, Images, Payloads, Elements);
               Made (Id) := True;
            end;
         end Set_Image_From_Struct_Literal;

         procedure Set_Image_From_Struct_Field
           (Id        : Res.Declaration_Id;
            Of_Tree   : Syn.Tree;
            Selection : Syn.Node_Id);

         procedure Set_Image_From_Struct_Field
           (Id        : Res.Declaration_Id;
            Of_Tree   : Syn.Tree;
            Selection : Syn.Node_Id)
         is
            From : constant Syn.Node_Id :=
              Syn.Target_Of (Of_Tree, Selection);
            Source_Id : constant Res.Declaration_Id :=
              Res.Bound_To (Meanings.all, Of_Tree, From);
            Field : constant Positive :=
              Positive
                (Landin.Checking.Field_Index
                   (Types.all, Of_Tree, Selection));
         begin
            --  D70 resolves the containing aggregate first.  An absent
            --  aggregate image is the complete zero image, so its field and
            --  the destination array both remain absent loader-zeroed data.
            Resolve_Image (Source_Id);
            if not Made (Source_Id) then
               return;
            end if;

            declare
               Source_Item : constant IR.Item_Id :=
                 IR.Item_For (Unit.all, Source_Id);
               Image : constant IR.Aggregate_Field_Image :=
                 IR.Field_Image_Of (Unit.all, Source_Item, Field);
               Destination : constant IR.Item_Id :=
                 IR.Item_For (Unit.all, Id);
            begin
               case Image.Form is
                  when IR.Absent =>
                     null;

                  when IR.Finite =>
                     if Image.Count = 0 then
                        return;
                     end if;

                     declare
                        Values : Ty.Folded_Array (1 .. Image.Count) :=
                          [others => 0];
                     begin
                        for Position in Values'Range loop
                           Values (Position) :=
                             IR.Nth_Field_Element
                               (Unit.all, Source_Item, Field,
                                IR.Part_Position (Position));
                        end loop;
                        IR.Set_Array_Image
                          (Unit.all, Destination, Values);
                     end;
                     Made (Id) := True;

                  when IR.Repeated =>
                     IR.Set_Repeated_Array_Image
                       (Unit.all, Destination, Image.Value);
                     Made (Id) := True;

                  when IR.Hybrid =>
                     declare
                        Prefix : Ty.Folded_Array (1 .. Image.Count) :=
                          [others => 0];
                     begin
                        for Position in Prefix'Range loop
                           Prefix (Position) :=
                             IR.Nth_Field_Element
                               (Unit.all, Source_Item, Field,
                                IR.Part_Position (Position));
                        end loop;
                        IR.Set_Hybrid_Array_Image
                          (Unit.all, Destination, Prefix, Image.Value);
                     end;
                     Made (Id) := True;

                  when IR.Selected =>
                     raise Landin.Compiler_Defect with
                       "a selected variant field was used as an array image";
               end case;
            end;
         end Set_Image_From_Struct_Field;

         procedure Copy_Image_From
           (Destination : Res.Declaration_Id;
            Source_Id   : Res.Declaration_Id);

         procedure Copy_Image_From
           (Destination : Res.Declaration_Id;
            Source_Id   : Res.Declaration_Id)
         is
            Source_Item : constant IR.Item_Id :=
              IR.Item_For (Unit.all, Source_Id);
            Length : constant IR.Element_Total :=
              IR.Image_Length (Unit.all, Source_Item);
         begin
            if IR.Result_Of (Unit.all, Source_Item) = Ty.Aggregate then
               declare
                  Fields : constant Natural :=
                    IR.Field_Count (Unit.all, Source_Item);
                  Elements_Count : constant Natural :=
                    Natural (Length - IR.Element_Total (Fields));
                  Payload_Count : constant Natural :=
                    IR.Aggregate_Field_Image_Count
                      (Unit.all, Source_Item) - Fields;
                  Values : Ty.Folded_Array (1 .. Fields) := [others => 0];
                  Images : IR.Aggregate_Field_Image_Array
                    (1 .. Fields) := [others => (others => <>)];
                  Payloads : IR.Aggregate_Field_Image_Array
                    (1 .. Payload_Count) := [others => (others => <>)];
                  Elements : Ty.Folded_Array (1 .. Elements_Count) :=
                    [others => 0];
                  Cursor : Natural := 0;
                  Payload_Cursor : Natural := 0;
               begin
                  for Field in 1 .. Fields loop
                     Values (Field) :=
                       IR.Nth_Field_Image (Unit.all, Source_Item, Field);
                     declare
                        Source_Image : constant IR.Aggregate_Field_Image :=
                          IR.Field_Image_Of
                            (Unit.all, Source_Item, Field);
                     begin
                        if Source_Image.Form = IR.Selected then
                           Images (Field) := Source_Image;
                           Images (Field).Offset := Payload_Cursor;
                           for Payload in 1 .. Source_Image.Count loop
                              declare
                                 Source_Payload : constant
                                   IR.Aggregate_Field_Image :=
                                     IR.Variant_Payload_Image_Of
                                       (Unit.all, Source_Item, Field,
                                        Payload);
                                 Target : IR.Aggregate_Field_Image renames
                                   Payloads (Payload_Cursor + Payload);
                              begin
                                 Target := Source_Payload;
                                 Target.Offset := Cursor;
                                 if Source_Payload.Form
                                      in IR.Finite | IR.Hybrid
                                 then
                                    for Position in
                                      1 .. Source_Payload.Count
                                    loop
                                       Elements (Cursor + Position) :=
                                         IR.Nth_Variant_Field_Element
                                           (Unit.all, Source_Item, Field,
                                            Payload,
                                            IR.Part_Position (Position));
                                    end loop;
                                 elsif Source_Payload.Form = IR.Selected
                                 then
                                    raise Landin.Compiler_Defect with
                                      "a nested selected variant image"
                                      & " reached aggregate image copying";
                                 elsif Source_Payload.Count /= 0 then
                                    raise Landin.Compiler_Defect with
                                      "a compact variant payload image"
                                      & " carried finite elements";
                                 end if;
                                 Cursor := Cursor + Source_Payload.Count;
                              end;
                           end loop;
                           Payload_Cursor := Payload_Cursor
                             + Source_Image.Count;
                        else
                           Copy_Field_Descriptor
                             (Source_Item, Field, Cursor, Images (Field),
                              Elements);
                        end if;
                     end;
                  end loop;
                  IR.Set_Aggregate_Image
                    (Unit.all, IR.Item_For (Unit.all, Destination), Values,
                     Images, Payloads, Elements);
                  Made (Destination) := True;
               end;
               return;
            end if;

            if IR.Is_Repeated_Image (Unit.all, Source_Item) then
               declare
                  Prefix : constant IR.Element_Total :=
                    IR.Image_Prefix_Length (Unit.all, Source_Item);
               begin
                  if Prefix = 0 then
                     IR.Set_Repeated_Array_Image
                       (Unit.all, IR.Item_For (Unit.all, Destination),
                        IR.Repeated_Image_Value (Unit.all, Source_Item));
                  else
                     declare
                        Values : Ty.Folded_Array
                          (1 .. Positive (Prefix)) := [others => 0];
                     begin
                        for Position in Values'Range loop
                           Values (Position) :=
                             IR.Nth_Image
                               (Unit.all, Source_Item,
                                IR.Part_Position (Position));
                        end loop;
                        IR.Set_Hybrid_Array_Image
                          (Unit.all, IR.Item_For (Unit.all, Destination),
                           Values,
                           IR.Repeated_Image_Value (Unit.all, Source_Item));
                     end;
                  end if;
               end;
               Made (Destination) := True;
               return;
            end if;

            if Length = 0 then
               return;
            end if;

            declare
               Values : Ty.Folded_Array
                 (1 .. Positive (Length)) := [others => 0];
            begin
               for Position in Values'Range loop
                  Values (Position) :=
                    IR.Nth_Image
                      (Unit.all, Source_Item,
                       IR.Part_Position (Position));
               end loop;

               IR.Set_Array_Image
                 (Unit.all,
                  IR.Item_For (Unit.all, Destination), Values);
               Made (Destination) := True;
            end;
         end Copy_Image_From;

         procedure Resolve_Image (Id : Res.Declaration_Id)
         is
            Their_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Id));
            Node : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Id);
            Value : constant Syn.Node_Id :=
              Syn.Value_Of (Their_Tree.all, Node);
         begin
            case Where (Id) is
               when Resolved =>
                  return;
               when Visiting =>
                  --  A cycle the checker already reported: leave the
                  --  destination without an image.  Following it would
                  --  loop; the diagnostic is the reader's answer here.
                  return;
               when Unseen =>
                  null;
            end case;

            Where (Id) := Visiting;

            if Value = Syn.No_Node then
               null;
            elsif Syn.Kind (Their_Tree.all, Value) = Syn.Zeroed_Literal then
               --  D27's explicit zero image remains absent, just like D10's
               --  omitted initializer; the backend therefore selects .bss.
               null;
            elsif Syn.Kind (Their_Tree.all, Value) = Syn.Array_Literal then
               Set_Image_From_Literal (Id, Their_Tree.all, Value);
            elsif Syn.Kind (Their_Tree.all, Value) = Syn.Struct_Literal then
               Set_Image_From_Struct_Literal (Id, Their_Tree.all, Value);
            elsif Syn.Kind (Their_Tree.all, Value) = Syn.Array_Repetition then
               Set_Image_From_Repetition (Id, Their_Tree.all, Value);
            elsif Syn.Kind (Their_Tree.all, Value)
                    = Syn.Mixed_Array_Repetition
            then
               Set_Image_From_Mixed_Repetition (Id, Their_Tree.all, Value);
            elsif Syn.Kind (Their_Tree.all, Value) = Syn.Member_Selection
            then
               Set_Image_From_Struct_Field (Id, Their_Tree.all, Value);
            elsif Syn.Kind (Their_Tree.all, Value) = Syn.Name_Reference
              and then Res.Verdict_Of
                         (Meanings.all, Their_Tree.all, Value) = Res.Bound
            then
               declare
                  Source_Id : constant Res.Declaration_Id :=
                    Res.Bound_To
                      (Meanings.all, Their_Tree.all, Value);
               begin
                  if Res.Sort_Of (Meanings.all, Source_Id)
                       = Res.Module_Binding
                    and then Landin.Checking.Type_Of
                               (Types.all, Source_Id)
                               = Landin.Checking.Type_Of (Types.all, Id)
                    and then
                      (Landin.Checking.Type_Of (Types.all, Id)
                         = Ty.Fixed_Array
                       or else
                         (Landin.Checking.Type_Of (Types.all, Id)
                            = Ty.Aggregate
                          and then Landin.Checking.Body_Of
                            (Types.all, Source_Id)
                            = Landin.Checking.Body_Of (Types.all, Id)))
                  then
                     Resolve_Image (Source_Id);
                     if Made (Source_Id) then
                        Copy_Image_From (Id, Source_Id);
                     end if;
                  end if;
               end;
            end if;

            Where (Id) := Resolved;
         end Resolve_Image;
      begin
         if Declarations > 0 then
            for Id in Res.Declaration_Id'(1) ..
                      Res.Declaration_Id (Declarations)
            loop
               if Res.Sort_Of (Meanings.all, Id) = Res.Module_Binding
                 and then Landin.Checking.Type_Of (Types.all, Id)
                          in Ty.Fixed_Array | Ty.Aggregate
               then
                  Resolve_Image (Id);
               end if;
            end loop;
         end if;
      end Resolve_Module_Images;

      --  Every Unit this stage builds, in every build mode.  A failure
      --  is a Landin.Compiler_Defect and never a diagnostic: the
      --  frontend refused every ill-formed program and this stage
      --  refused to run on a refused one, so nothing a program can say
      --  reaches here.  Facts flow in so D24's per-position image values
      --  are held to fitting their element type at this compilation's
      --  target rather than at the host running the compiler.
      Landin.IR.Verifier.Verify (Unit.all, Facts);

      Outcome := Continue;
   end Run;

end Landin.Stages.Lowering;
