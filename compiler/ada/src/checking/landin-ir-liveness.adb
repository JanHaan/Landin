with Landin.Types;

package body Landin.IR.Liveness is

   function Zeroes (Count : Natural) return Count_Vectors.Vector
     is (Count_Vectors.To_Vector (0, Ada.Containers.Count_Type (Count)));

   --  A depth-first walk meets a loop's back edges as edges into a block
   --  it has not yet left.  When it leaves that header, every block
   --  numbered since the header opened is below it, and the loop's body is
   --  each of those that reaches a back edge without passing the header.
   --  Each body adds one level to its blocks.
   function Loop_Depths
     (Of_Graph : Control_Flow.Graph) return Count_Vectors.Vector
   is
      Block_Total : constant Natural := Of_Graph.Count;
      Depth : Count_Vectors.Vector := Zeroes (Block_Total);
      --  Each block's depth-first number, how many of its successors the
      --  walk has tried, the walk's path, the header a block last joined
      --  and the blocks whose predecessors are still to be joined.
      Order : Count_Vectors.Vector := Zeroes (Block_Total);
      Tried : Count_Vectors.Vector := Zeroes (Block_Total);
      Walk : Count_Vectors.Vector := Zeroes (Block_Total);
      Stamp : Count_Vectors.Vector := Zeroes (Block_Total);
      Pending : Count_Vectors.Vector := Zeroes (Block_Total);
      Height, Clock, Waiting : Natural := 0;

      procedure Join (Header, Block : Positive);

      procedure Join (Header, Block : Positive) is
      begin
         if Order (Block) >= Order (Header)
           and then Stamp (Block) /= Header
         then
            Stamp (Block) := Header;
            Depth (Block) := Depth (Block) + 1;
            Waiting := Waiting + 1;
            Pending (Waiting) := Block;
         end if;
      end Join;
   begin
      if Block_Total = 0 then
         return Depth;
      end if;
      Height := 1;
      Clock := 1;
      Walk (1) := 1;
      Order (1) := 1;
      while Height > 0 loop
         declare
            Block : constant Positive := Walk (Height);
            Edge : Natural;
         begin
            if Tried (Block) < 2 then
               Tried (Block) := Tried (Block) + 1;
               declare
                  Target : constant Block_Id := Control_Flow.Successor
                    (Of_Graph, Block_Id (Block), Tried (Block));
               begin
                  if Target /= No_Block
                    and then Order (Positive (Target)) = 0
                  then
                     Clock := Clock + 1;
                     Order (Positive (Target)) := Clock;
                     Height := Height + 1;
                     Walk (Height) := Positive (Target);
                  end if;
               end;
            else
               --  An edge from below closes a loop at Block.  Its body is
               --  found backward and joins Block once.
               Height := Height - 1;
               Edge := Control_Flow.First_Predecessor
                 (Of_Graph, Block_Id (Block));
               while Edge /= 0 loop
                  if Order (Positive (Control_Flow.Predecessor
                    (Of_Graph, Edge))) >= Order (Block)
                  then
                     Join (Block, Block);
                  end if;
                  Edge := Control_Flow.Next_Predecessor (Of_Graph, Edge);
               end loop;
               while Waiting > 0 loop
                  Edge := Control_Flow.First_Predecessor
                    (Of_Graph, Block_Id (Pending (Waiting)));
                  Waiting := Waiting - 1;
                  while Edge /= 0 loop
                     Join (Block, Positive
                       (Control_Flow.Predecessor (Of_Graph, Edge)));
                     Edge := Control_Flow.Next_Predecessor (Of_Graph, Edge);
                  end loop;
               end loop;
            end if;
         end;
      end loop;
      return Depth;
   end Loop_Depths;

   --  Liveness is found backward from each block whose first reference to
   --  a slot reads it, through predecessors that do not mention the slot,
   --  stopping at one that does: such a block either writes the slot
   --  before reading it or is itself where the search began.  The
   --  interval is the hull of the slot's references and of the start of
   --  every block it is live into and the end of every block it is live
   --  out of.
   function Slot_Intervals
     (Of_Unit : Unit; Item : Item_Id; Of_Graph : Control_Flow.Graph)
      return Interval_Vectors.Vector
   is
      Slot_Total : constant Natural := Slot_Count (Of_Unit, Item);
      Block_Total : constant Natural := Block_Count (Of_Unit, Item);
      Value_Total : constant Natural := Value_Count (Of_Unit, Item);
      Result : Interval_Vectors.Vector := Interval_Vectors.To_Vector
        ((others => <>), Ada.Containers.Count_Type (Slot_Total));
      --  Each block's first and last position.
      Opens, Closes : Count_Vectors.Vector := Zeroes (Block_Total);
      --  For each slot the blocks that mention it, as a list of records
      --  through Next: which block, and whether its first mention reads.
      Head, Seen_In : Count_Vectors.Vector := Zeroes (Slot_Total);
      Mentioned_In, Next : Count_Vectors.Vector;
      Reads_First : Count_Vectors.Vector;
      --  Per block, the slot whose search last found a mention in it or
      --  found it live on entry; and the blocks waiting to be searched.
      Mentions, Entered : Count_Vectors.Vector := Zeroes (Block_Total);
      Waiting : Count_Vectors.Vector := Zeroes (Block_Total);
      Budget : Natural := 32 * (Value_Total + Block_Total + 1);
      Tick : Natural := 0;
      First_Value : constant Natural :=
        Of_Unit.Items.Element (Positive (Item)).Values.First;

      procedure Note
        (Slot : Slot_Id; Block : Positive; Position : Natural;
         Reads : Boolean);

      procedure Note
        (Slot : Slot_Id; Block : Positive; Position : Natural;
         Reads : Boolean)
      is
      begin
         if Slot = No_Slot then
            return;
         end if;
         declare
            Index : constant Positive := Positive (Slot);
            Span : Interval renames Result (Index);
         begin
            if Is_Empty (Span) then
               Span := (Position, Position);
            else
               Span.First := Natural'Min (Span.First, Position);
               Span.Last := Natural'Max (Span.Last, Position);
            end if;
            if Seen_In (Index) /= Block then
               Seen_In (Index) := Block;
               Mentioned_In.Append (Block);
               Reads_First.Append (Boolean'Pos (Reads));
               Next.Append (Head (Index));
               Head (Index) := Natural (Mentioned_In.Length);
            end if;
         end;
      end Note;

      procedure Note_Storage
        (Place : Storage; Block : Positive; Position : Natural);

      procedure Note_Storage
        (Place : Storage; Block : Positive; Position : Natural) is
      begin
         case Place.Kind is
            when Frame_Slot =>
               Note (Place.Slot, Block, Position, True);
            when Runtime_Address =>
               Note (Place.Address, Block, Position, True);
            when Module_Datum => null;
         end case;
      end Note_Storage;

      Aggregate_Result : constant Boolean :=
        Result_Of (Of_Unit, Item) not in Landin.Types.Scalar_Name
        and then Result_Of (Of_Unit, Item) /= Landin.Types.No_Value;
   begin
      if Block_Total = 0 then
         return Result;
      end if;
      for Index in 1 .. Parameter_Count (Of_Unit, Item) loop
         Note (Nth_Parameter (Of_Unit, Item, Index), 1, 0, False);
      end loop;
      for B in 1 .. Block_Total loop
         Opens (B) := Tick + 1;
         for Position in 1 .. Length (Of_Unit, Item, Block_Id (B)) loop
            declare
               Value : constant Value_Id :=
                 Nth_Value (Of_Unit, Item, Block_Id (B), Position);
               --  Read once: the walk asks each instruction for a field or
               --  two, and copying it out again for each was most of what
               --  the walk cost.
               Code : constant Instruction :=
                 Of_Unit.Code.Element (First_Value + Positive (Value));
            begin
               Tick := Tick + 1;
               case Code.Op is
                  when Load =>
                     Note (Code.Slot, B, Tick, True);
                  when Store =>
                     Note (Code.Slot, B, Tick, False);
                  when Load_Field | Store_Field
                     | Load_Element | Store_Element =>
                     --  No_Slot, when it reaches no slot, notes nothing.
                     Note (Code.Slot, B, Tick, True);
                  when Copy_Array | Copy_Variant =>
                     Note_Storage (Code.Source, B, Tick);
                     Note_Storage (Code.Destination, B, Tick);
                  when Load_Variant_Tag | Load_Variant_Field =>
                     Note_Storage (Code.Source, B, Tick);
                  when Storage_Address | Place_Address
                     | Clear_Array | Fill_Array
                     | Select_Variant | Store_Variant_Field =>
                     Note_Storage (Code.Destination, B, Tick);
                  when Call | Indirect_Call =>
                     --  Its failure slot.
                     Note (Code.Slot, B, Tick, True);
                  when Assembly =>
                     for Which in 1 .. Assembly_Operand_Count
                       (Of_Unit, Item, Value)
                     loop
                        Note (Nth_Assembly_Operand
                                (Of_Unit, Item, Value, Which).Output,
                              B, Tick, False);
                     end loop;
                  when Leave =>
                     Note (Result_Slot (Of_Unit, Item), B, Tick, True);
                     if Aggregate_Result
                       and then Parameter_Count (Of_Unit, Item) > 0
                     then
                        Note (Nth_Parameter (Of_Unit, Item, 1),
                              B, Tick, True);
                     end if;
                  when others => null;
               end case;
            end;
         end loop;
         Closes (B) := Tick;
      end loop;
      for Index in 1 .. Slot_Total loop
         declare
            Span : Interval renames Result (Index);
            Queued : Natural := 0;
            Record_At : Natural := Head (Index);
         begin
            if Is_Empty (Span) then
               goto Next_Slot;
            end if;
            while Record_At /= 0 loop
               Mentions (Mentioned_In (Record_At)) := Index;
               Record_At := Next (Record_At);
            end loop;
            Record_At := Head (Index);
            while Record_At /= 0 loop
               if Reads_First (Record_At) = 1 then
                  Entered (Mentioned_In (Record_At)) := Index;
                  Queued := Queued + 1;
                  Waiting (Queued) := Mentioned_In (Record_At);
               end if;
               Record_At := Next (Record_At);
            end loop;
            while Queued > 0 loop
               declare
                  Block : constant Positive := Waiting (Queued);
                  Edge : Natural := Control_Flow.First_Predecessor
                    (Of_Graph, Block_Id (Block));
               begin
                  Queued := Queued - 1;
                  --  Live into the entry block is live at the entry.
                  Span.First := Natural'Min
                    (Span.First, (if Block = 1 then 0 else Opens (Block)));
                  while Edge /= 0 loop
                     if Budget = 0 then
                        Span := (0, Value_Total);
                        Queued := 0;
                        exit;
                     end if;
                     Budget := Budget - 1;
                     declare
                        From : constant Positive := Positive
                          (Control_Flow.Predecessor (Of_Graph, Edge));
                     begin
                        Span.First := Natural'Min (Span.First, Closes (From));
                        Span.Last := Natural'Max (Span.Last, Closes (From));
                        if Mentions (From) /= Index
                          and then Entered (From) /= Index
                        then
                           Entered (From) := Index;
                           Queued := Queued + 1;
                           Waiting (Queued) := From;
                        end if;
                     end;
                     Edge := Control_Flow.Next_Predecessor (Of_Graph, Edge);
                  end loop;
               end;
            end loop;
         end;
         <<Next_Slot>>
      end loop;
      return Result;
   end Slot_Intervals;

end Landin.IR.Liveness;
