package body Landin.IR is

   ------------------------------------------------------------------
   --  Runs
   --
   --  Every per-item table is one run in one vector, so a reference is
   --  one addition.  These four helpers are the only place a run's
   --  arithmetic is written.
   ------------------------------------------------------------------

   function Element (Of_Unit : Unit; Item : Item_Id) return Item_Record
     is (Of_Unit.Items (Positive (Item)));

   function Slot_At
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id) return Positive
     is (Element (Of_Unit, Item).Slots.First + Positive (Slot));

   function Block_At
     (Of_Unit : Unit; Item : Item_Id; Block : Block_Id) return Positive
     is (Element (Of_Unit, Item).Blocks.First + Positive (Block));

   function Value_At
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Positive
     is (Element (Of_Unit, Item).Values.First + Positive (Value));

   ------------------------------------------------------------------
   --  Building
   ------------------------------------------------------------------

   function Is_Prepared (Of_Unit : Unit) return Boolean
     is (Of_Unit.Ready);

   function Declaration_Limit (Of_Unit : Unit) return Natural
     is (Natural (Of_Unit.Standing.Length));

   function Item_Count (Of_Unit : Unit) return Natural
     is (Natural (Of_Unit.Items.Length));

   procedure Prepare
     (Into : in out Unit; Meanings : Landin.Resolution.Table) is
   begin
      --  One entry per declaration, so Item_For is an index rather than a
      --  scan, and No_Item means "no item stands for this declaration".
      for Unused in
        1 .. Landin.Resolution.Declaration_Count (Meanings)
      loop
         Into.Standing.Append (No_Item);
      end loop;

      Into.Ready := True;
   end Prepare;

   function Add_Item
     (Into     : in out Unit;
      Kind     : Item_Kind;
      Declares : Declaration_Id;
      Result   : Landin.Types.Type_Kind;
      Site     : Landin.Provenance.Origin) return Item_Id
   is
      Made : Item_Record;
   begin
      Made.Kind := Kind;
      Made.Declaration := Declares;
      Made.Result := Result;
      Made.Site := Site;
      --  A run's base is taken on its first append and not here.  [1740]
      --  makes a module a set, so `f` may call `g` written below it, and
      --  Emit_Call's `Holds (Into, Callee)` therefore forces a lowering to
      --  create every item before it fills any.  Taking the base here gave
      --  all of them the same one, and item two's slots then read back as
      --  item one's -- silently in a release build, where Add_Slot's
      --  postcondition is not there to catch it.
      Made.Slots      := Run'(First => 0, Count => 0);
      Made.Parameters := Run'(First => 0, Count => 0);
      Made.Blocks     := Run'(First => 0, Count => 0);
      Made.Values     := Run'(First => 0, Count => 0);

      Into.Items.Append (Made);

      if Declares /= No_Declaration then
         Into.Standing (Positive (Declares)) :=
           Item_Id (Into.Items.Last_Index);
      end if;

      return Item_Id (Into.Items.Last_Index);
   end Add_Item;

   function Kind_Of (Of_Unit : Unit; Id : Item_Id) return Item_Kind
     is (Element (Of_Unit, Id).Kind);

   function Declares (Of_Unit : Unit; Id : Item_Id) return Declaration_Id
     is (Element (Of_Unit, Id).Declaration);

   function Result_Of (Of_Unit : Unit; Id : Item_Id)
     return Landin.Types.Type_Kind
     is (Element (Of_Unit, Id).Result);

   function Origin_Of (Of_Unit : Unit; Id : Item_Id)
     return Landin.Provenance.Origin
     is (Element (Of_Unit, Id).Site);

   function Item_For (Of_Unit : Unit; Declared : Declaration_Id)
     return Item_Id
     is (Of_Unit.Standing (Positive (Declared)));

   ------------------------------------------------------------------
   --  Slots
   ------------------------------------------------------------------

   function Slot_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     is (Element (Of_Unit, Item).Slots.Count);

   --  Opens a run on its first append, and refuses one that is no longer
   --  at the end of its vector.  A Run is a base and a count, so an item's
   --  entities have to be contiguous; filling item one after starting item
   --  two would silently interleave two runs and leave both wrong.  The
   --  rule is the body's and holds in every mode, which is what
   --  Landin.Targets learnt when a release build accepted an alignment of
   --  twelve that only a precondition had refused.
   procedure Open_Run (Into : in out Run; Length : Natural);

   procedure Open_Run (Into : in out Run; Length : Natural) is
   begin
      if Into.Count = 0 then
         Into.First := Length;
      elsif Into.First + Into.Count /= Length then
         raise Landin.Compiler_Defect with
           "an item's run is no longer at the end of its vector, so two"
           & " items were filled at once";
      end if;
   end Open_Run;

   function Add_Slot
     (Into     : in out Unit;
      Item     : Item_Id;
      Of_Type  : Landin.Types.Scalar_Name;
      Declares : Declaration_Id;
      Site     : Landin.Provenance.Origin) return Slot_Id
   is
      Held : Item_Record := Element (Into, Item);
   begin
      Open_Run (Held.Slots, Natural (Into.Slots.Length));
      Into.Slots.Append
        (Slot_Record'(Of_Type     => Of_Type,
                      Declaration => Declares,
                      Site        => Site));
      Held.Slots.Count := Held.Slots.Count + 1;
      Into.Items (Positive (Item)) := Held;
      return Slot_Id (Held.Slots.Count);
   end Add_Slot;

   function Add_Parameter
     (Into     : in out Unit;
      Item     : Item_Id;
      Of_Type  : Landin.Types.Scalar_Name;
      Declares : Declaration_Id;
      Site     : Landin.Provenance.Origin) return Slot_Id
   is
      Made : constant Slot_Id :=
        Add_Slot (Into, Item, Of_Type, Declares, Site);
      Held : Item_Record := Element (Into, Item);
   begin
      --  A parameter is a slot the caller filled, and the run below is
      --  the order [1920] names the parameters in.
      Open_Run (Held.Parameters, Natural (Into.Parameters.Length));
      Into.Parameters.Append (Made);
      Held.Parameters.Count := Held.Parameters.Count + 1;
      Into.Items (Positive (Item)) := Held;
      return Made;
   end Add_Parameter;

   function Parameter_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     is (Element (Of_Unit, Item).Parameters.Count);

   function Nth_Parameter
     (Of_Unit : Unit; Item : Item_Id; Index : Positive) return Slot_Id
     is (Of_Unit.Parameters
           (Element (Of_Unit, Item).Parameters.First + Index));

   procedure Set_Result_Slot
     (Into : in out Unit; Item : Item_Id; Slot : Slot_Id)
   is
      Held : Item_Record := Element (Into, Item);
   begin
      Held.Returns_To := Slot;
      Into.Items (Positive (Item)) := Held;
   end Set_Result_Slot;

   function Result_Slot (Of_Unit : Unit; Item : Item_Id) return Slot_Id
     is (Element (Of_Unit, Item).Returns_To);

   function Type_Of (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id)
     return Landin.Types.Scalar_Name
     is (Of_Unit.Slots (Slot_At (Of_Unit, Item, Slot)).Of_Type);

   function Declares
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id)
     return Declaration_Id
     is (Of_Unit.Slots (Slot_At (Of_Unit, Item, Slot)).Declaration);

   function Origin_Of
     (Of_Unit : Unit; Item : Item_Id; Slot : Slot_Id)
     return Landin.Provenance.Origin
     is (Of_Unit.Slots (Slot_At (Of_Unit, Item, Slot)).Site);

   ------------------------------------------------------------------
   --  Blocks
   ------------------------------------------------------------------

   function Block_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     is (Element (Of_Unit, Item).Blocks.Count);

   function Add_Block
     (Into  : in out Unit;
      Item  : Item_Id;
      Scope : Scope_Id;
      Site  : Landin.Provenance.Origin) return Block_Id
   is
      Held : Item_Record := Element (Into, Item);
   begin
      --  First_Value is Enter's and not this one's.  Landin.IR's header
      --  says blocks are created out of fill order -- "an `if`'s
      --  else-entry is created before the then-arm's inner blocks and
      --  filled after them" -- so a base taken at creation belongs to
      --  whichever block was filled first, and every later block reports
      --  that one's instructions.
      Open_Run (Held.Blocks, Natural (Into.Blocks.Length));
      Into.Blocks.Append
        (Block_Record'(Scope       => Scope,
                       Site        => Site,
                       First_Value => 0,
                       Values      => 0));
      Held.Blocks.Count := Held.Blocks.Count + 1;
      Into.Items (Positive (Item)) := Held;
      return Block_Id (Held.Blocks.Count);
   end Add_Block;

   procedure Enter
     (Into : in out Unit; Item : Item_Id; Block : Block_Id)
   is
      Held  : Item_Record := Element (Into, Item);
      Where : constant Positive := Block_At (Into, Item, Block);
      Ready : Block_Record := Into.Blocks (Where);
   begin
      --  The block is empty here -- Enter's precondition says so -- so
      --  there is no run to move, and this is the first moment at which
      --  where its instructions will land is known.
      Ready.First_Value := Natural (Into.Code.Length);
      Into.Blocks (Where) := Ready;

      Held.Open := Block;
      Into.Items (Positive (Item)) := Held;
   end Enter;

   procedure Leave_Block (Into : in out Unit; Item : Item_Id) is
      Held : Item_Record := Element (Into, Item);
   begin
      Held.Open := No_Block;
      Into.Items (Positive (Item)) := Held;
   end Leave_Block;

   function Open_Block (Of_Unit : Unit; Item : Item_Id) return Block_Id
     is (Element (Of_Unit, Item).Open);

   function Scope_Of
     (Of_Unit : Unit; Item : Item_Id; Block : Block_Id) return Scope_Id
     is (Of_Unit.Blocks (Block_At (Of_Unit, Item, Block)).Scope);

   function Origin_Of
     (Of_Unit : Unit; Item : Item_Id; Block : Block_Id)
     return Landin.Provenance.Origin
     is (Of_Unit.Blocks (Block_At (Of_Unit, Item, Block)).Site);

   function Length
     (Of_Unit : Unit; Item : Item_Id; Block : Block_Id) return Natural
     is (Of_Unit.Blocks (Block_At (Of_Unit, Item, Block)).Values);

   function Nth_Value
     (Of_Unit : Unit;
      Item    : Item_Id;
      Block   : Block_Id;
      Index   : Positive) return Value_Id
     is (Value_Id
           (Of_Unit.Blocks
              (Block_At (Of_Unit, Item, Block)).First_Value
            - Element (Of_Unit, Item).Values.First
            + Index));

   ------------------------------------------------------------------
   --  Instructions
   ------------------------------------------------------------------

   function Value_Count (Of_Unit : Unit; Item : Item_Id) return Natural
     is (Element (Of_Unit, Item).Values.Count);

   function Held (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Instruction
     is (Of_Unit.Code (Value_At (Of_Unit, Item, Value)));

   function Op_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Opcode
     is (Held (Of_Unit, Item, Value).Op);

   function Result_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Types.Type_Kind
     is (Held (Of_Unit, Item, Value).Result);

   function Origin_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Provenance.Origin
     is (Held (Of_Unit, Item, Value).Site);

   function Block_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Block_Id
     is (Held (Of_Unit, Item, Value).In_Block);

   function Operand_Count
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Natural
     is (Held (Of_Unit, Item, Value).Args);

   function Nth_Operand
     (Of_Unit : Unit;
      Item    : Item_Id;
      Value   : Value_Id;
      Index   : Positive) return Value_Id
     is (Of_Unit.Operands
           (Held (Of_Unit, Item, Value).First_Arg + Index));

   function Slot_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Slot_Id
     is (Held (Of_Unit, Item, Value).Slot);

   function Datum_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Item_Id
     is (Held (Of_Unit, Item, Value).Named);

   function Callee_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Item_Id
     is (Held (Of_Unit, Item, Value).Named);

   function Target_Of (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Block_Id
     is (Held (Of_Unit, Item, Value).Target);

   function Alternative_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Block_Id
     is (Held (Of_Unit, Item, Value).Alternative);

   function Number_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id)
     return Landin.Types.Magnitude
     is (Held (Of_Unit, Item, Value).Number);

   function Is_Negated
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Boolean
     is (Held (Of_Unit, Item, Value).Negated);

   function Truth_Of
     (Of_Unit : Unit; Item : Item_Id; Value : Value_Id) return Boolean
     is (Held (Of_Unit, Item, Value).Truth);

   ------------------------------------------------------------------
   --  Emitting
   --
   --  Every Emit goes through Append, which is the only place an
   --  instruction is put in the table and the only place a block's count
   --  and an item's count move together.
   ------------------------------------------------------------------

   function Append
     (Into : in out Unit; Item : Item_Id; What : Instruction)
     return Value_Id;

   function Append
     (Into : in out Unit; Item : Item_Id; What : Instruction)
     return Value_Id
   is
      Held  : Item_Record := Element (Into, Item);
      Where : constant Positive :=
        Block_At (Into, Item, Held.Open);
      Block : Block_Record := Into.Blocks (Where);
      Made  : Instruction := What;
   begin
      Made.In_Block := Held.Open;
      Open_Run (Held.Values, Natural (Into.Code.Length));
      Into.Code.Append (Made);

      Held.Values.Count := Held.Values.Count + 1;
      Block.Values := Block.Values + 1;

      Into.Items (Positive (Item)) := Held;
      Into.Blocks (Where) := Block;

      return Value_Id (Held.Values.Count);
   end Append;

   function Emit_Number
     (Into    : in out Unit;
      Item    : Item_Id;
      Of_Type : Landin.Types.Integer_Name;
      Value   : Landin.Types.Magnitude;
      Negated : Boolean;
      Site    : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op      => Number,
                         Result  => Of_Type,
                         Site    => Site,
                         Number  => Value,
                         Negated => Negated,
                         others  => <>)));

   function Emit_Truth
     (Into  : in out Unit;
      Item  : Item_Id;
      Value : Boolean;
      Site  : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op     => Truth,
                         Result => Landin.Types.Bool,
                         Site   => Site,
                         Truth  => Value,
                         others => <>)));

   function Emit_Load
     (Into : in out Unit;
      Item : Item_Id;
      Slot : Slot_Id;
      Site : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op     => Load,
                         Result => Type_Of (Into, Item, Slot),
                         Site   => Site,
                         Slot   => Slot,
                         others => <>)));

   procedure Emit_Store
     (Into  : in out Unit;
      Item  : Item_Id;
      Slot  : Slot_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin)
   is
      Made : Instruction :=
        Instruction'(Op     => Store,
                     Site   => Site,
                     Slot   => Slot,
                     others => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Value);
      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Store;

   function Emit_Load_Datum
     (Into  : in out Unit;
      Item  : Item_Id;
      Datum : Item_Id;
      Site  : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op     => Load_Datum,
                         Result => Result_Of (Into, Datum),
                         Site   => Site,
                         Named  => Datum,
                         others => <>)));

   procedure Emit_Store_Datum
     (Into  : in out Unit;
      Item  : Item_Id;
      Datum : Item_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin)
   is
      Made : Instruction :=
        Instruction'(Op     => Store_Datum,
                     Site   => Site,
                     Named  => Datum,
                     others => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Value);
      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Store_Datum;

   function Emit_Unary
     (Into    : in out Unit;
      Item    : Item_Id;
      Op      : Unary_Kind;
      Operand : Value_Id;
      Result  : Landin.Types.Scalar_Name;
      Site    : Landin.Provenance.Origin) return Value_Id
   is
      Made : Instruction :=
        Instruction'(Op     => Op,
                     Result => Result,
                     Site   => Site,
                     others => <>);
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Operand);
      return Append (Into, Item, Made);
   end Emit_Unary;

   function Emit_Binary
     (Into   : in out Unit;
      Item   : Item_Id;
      Op     : Binary_Kind;
      Left   : Value_Id;
      Right  : Value_Id;
      Result : Landin.Types.Scalar_Name;
      Site   : Landin.Provenance.Origin) return Value_Id
   is
      Made : Instruction :=
        Instruction'(Op     => Op,
                     Result => Result,
                     Site   => Site,
                     others => <>);
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 2;
      Into.Operands.Append (Left);
      Into.Operands.Append (Right);
      return Append (Into, Item, Made);
   end Emit_Binary;

   function Emit_Call
     (Into   : in out Unit;
      Item   : Item_Id;
      Callee : Item_Id;
      Result : Landin.Types.Type_Kind;
      Site   : Landin.Provenance.Origin) return Value_Id
     is (Append
           (Into, Item,
            Instruction'(Op        => Call,
                         Result    => Result,
                         Site      => Site,
                         Named     => Callee,
                         First_Arg => Natural (Into.Operands.Length),
                         Args      => 0,
                         others    => <>)));

   procedure Add_Argument
     (Into  : in out Unit;
      Item  : Item_Id;
      Call  : Value_Id;
      Value : Value_Id)
   is
      Where : constant Positive := Value_At (Into, Item, Call);
      What  : Instruction := Into.Code (Where);
   begin
      --  The call is the last instruction, so its operand run is the top
      --  of the operand vector and appending extends it in place.
      Into.Operands.Append (Value);
      What.Args := What.Args + 1;
      Into.Code (Where) := What;
   end Add_Argument;

   procedure Emit_Jump
     (Into   : in out Unit;
      Item   : Item_Id;
      Target : Block_Id;
      Site   : Landin.Provenance.Origin)
   is
      Where : constant Value_Id :=
        Append (Into, Item,
                Instruction'(Op     => Jump,
                             Site   => Site,
                             Target => Target,
                             others => <>));
   begin
      pragma Assert (Where /= No_Value);
   end Emit_Jump;

   procedure Emit_Branch
     (Into        : in out Unit;
      Item        : Item_Id;
      Condition   : Value_Id;
      Target      : Block_Id;
      Alternative : Block_Id;
      Site        : Landin.Provenance.Origin)
   is
      Made : Instruction :=
        Instruction'(Op          => Branch,
                     Site        => Site,
                     Target      => Target,
                     Alternative => Alternative,
                     others      => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);
      Made.Args := 1;
      Into.Operands.Append (Condition);
      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Branch;

   procedure Emit_Leave
     (Into  : in out Unit;
      Item  : Item_Id;
      Value : Value_Id;
      Site  : Landin.Provenance.Origin)
   is
      Made : Instruction :=
        Instruction'(Op     => Leave,
                     Site   => Site,
                     others => <>);
      Where : Value_Id;
   begin
      Made.First_Arg := Natural (Into.Operands.Length);

      if Value /= No_Value then
         Made.Args := 1;
         Into.Operands.Append (Value);
      end if;

      Where := Append (Into, Item, Made);
      pragma Assert (Where /= No_Value);
   end Emit_Leave;

end Landin.IR;
