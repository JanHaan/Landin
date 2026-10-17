with Ada.Containers.Vectors;
with Landin.IR.Control_Flow;
with Landin.IR.Verifier;

package body Landin.IR.Scalar_Replacement is
   use type Landin.Machine.Convention;
   use type Landin.Optimization.Objective;
   use type Ada.Containers.Count_Type;

   --  A slice is two parts.  Four keeps a small record of scalars and
   --  stops a long fixed array from becoming one slot per element.
   Most_Parts : constant := 4;
   subtype Part_Index is Positive range 1 .. Most_Parts;
   type Part_Flags is array (Part_Index) of Boolean;
   type Part_Slots is array (Part_Index) of Slot_Id;

   --  Whole leaves a slot alone.  Entry_Copy reads a parameter's parts
   --  from scalar copies taken on entry; Split moves every part.
   type Form is (Whole, Entry_Copy, Split);

   type Slot_Plan is record
      --  Every part is a scalar whose load carries no check: no packing,
      --  no atom code and no erased receiver.
      Shaped : Boolean := False;
      --  Shaped, and no part is a pointer or a function value either, so
      --  a part's slot needs no metadata a whole copy or clear could fail
      --  to supply on some path.
      Plain : Boolean := False;
      Parts : Natural := 0;
      Parameter : Boolean := False;
      Barred : Boolean := False;
      Written : Boolean := False;
      Accessed : Boolean := False;
      Read : Part_Flags := [others => False];
      Use_As : Form := Whole;
      Pieces : Part_Slots := [others => No_Slot];
   end record;

   package Plan_Vectors is new Ada.Containers.Vectors (Positive, Slot_Plan);
   package Value_Maps is new Ada.Containers.Vectors (Positive, Value_Id);
   package Flag_Vectors is new Ada.Containers.Vectors (Positive, Boolean);
   package Index_Vectors is new Ada.Containers.Vectors (Positive, Natural);

   --  Which blocks of Item lie on a cycle: those in a strongly connected
   --  component of two or more blocks, or with an edge to themselves.
   --  Tarjan's algorithm with an explicit stack, linear in blocks.
   function Cyclic (Of_Unit : Unit; Item : Item_Id) return Flag_Vectors.Vector;
   function Cyclic (Of_Unit : Unit; Item : Item_Id) return Flag_Vectors.Vector
   is
      Count : constant Natural := Block_Count (Of_Unit, Item);
      Graph : constant Control_Flow.Graph := Control_Flow.Make (Of_Unit, Item);
      Order, Low, Pending, Next : Index_Vectors.Vector;
      On_Stack, Result : Flag_Vectors.Vector;
      --  Pending holds the open components; Frames the depth-first path,
      --  each with the next successor it has to try.
      Frames : Index_Vectors.Vector;
      Counter : Natural := 0;

      procedure Visit (Block : Positive);
      procedure Visit (Block : Positive) is
      begin
         Counter := Counter + 1;
         Order (Block) := Counter;
         Low (Block) := Counter;
         Pending.Append (Block);
         On_Stack (Block) := True;
         Frames.Append (Block);
         Next (Block) := 1;
      end Visit;
   begin
      Order.Append (0, Ada.Containers.Count_Type (Count));
      Low.Append (0, Ada.Containers.Count_Type (Count));
      Next.Append (0, Ada.Containers.Count_Type (Count));
      On_Stack.Append (False, Ada.Containers.Count_Type (Count));
      Result.Append (False, Ada.Containers.Count_Type (Count));
      for Root in 1 .. Count loop
         if Order (Root) = 0 then
            Visit (Root);
            while not Frames.Is_Empty loop
               declare
                  Block : constant Positive := Frames.Last_Element;
               begin
                  if Next (Block) <= 2 then
                     declare
                        Target : constant Block_Id := Control_Flow.Successor
                          (Graph, Block_Id (Block), Next (Block));
                     begin
                        Next (Block) := Next (Block) + 1;
                        if Target = Block_Id (Block) then
                           Result (Block) := True;
                        elsif Target = No_Block then
                           null;
                        elsif Order (Positive (Target)) = 0 then
                           Visit (Positive (Target));
                        elsif On_Stack (Positive (Target)) then
                           Low (Block) := Natural'Min
                             (Low (Block), Order (Positive (Target)));
                        end if;
                     end;
                  else
                     Frames.Delete_Last;
                     if not Frames.Is_Empty then
                        Low (Frames.Last_Element) := Natural'Min
                          (Low (Frames.Last_Element), Low (Block));
                     end if;
                     if Low (Block) = Order (Block) then
                        declare
                           Member : Positive;
                           Several : constant Boolean :=
                             Pending.Last_Element /= Block;
                        begin
                           loop
                              Member := Pending.Last_Element;
                              Pending.Delete_Last;
                              On_Stack (Member) := False;
                              if Several then
                                 Result (Member) := True;
                              end if;
                              exit when Member = Block;
                           end loop;
                        end;
                     end if;
                  end if;
               end;
            end loop;
         end if;
      end loop;
      return Result;
   end Cyclic;

   procedure Run
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective) is
   begin
      Verifier.Verify (Into, Facts);
      Replace (Into, Objective);
      Verifier.Verify (Into, Facts);
   end Run;

   procedure Replace
     (Into : in out Unit;
      Objective : Landin.Optimization.Objective)
   is
      --  One plan per slot of the unit, at the slot's place in Into.Slots.
      Plans : Plan_Vectors.Vector;
      Changed : Boolean := False;
      --  How many pieces every item gains, together.
      Added_Total : Natural := 0;

      function Part_Shape
        (Slot : Slot_Record; Part : Positive) return Field_Shape
        is (if Slot.Array_Shape then Slot.Element
            else Into.Slot_Fields.Element (Slot.Fields.First + Part));

      function Part_Type
        (Slot : Slot_Record; Part : Positive) return Landin.Types.Scalar_Name
        is (Part_Shape (Slot, Part).Element);

      procedure Shape (Slot : Slot_Record; Plan : in out Slot_Plan);
      procedure Shape (Slot : Slot_Record; Plan : in out Slot_Plan) is
      begin
         if Slot.Addressed or else Slot.Signature /= No_Signature
           or else Slot.Atom_Set /= No_Atom_Set
           or else Slot.Pointee /= No_Pointee
           or else Slot.Concrete_Evidence /= No_Evidence
         then
            return;
         elsif Slot.Array_Shape then
            if Slot.Length < 1 or else Slot.Length > Most_Parts then
               return;
            end if;
            Plan.Parts := Natural (Slot.Length);
         elsif Slot.Aggregate then
            --  A pointer union's code field admits a reserved zero only
            --  as a load of that field from frame storage.
            if Slot.Fields.Count < 1 or else Slot.Fields.Count > Most_Parts
              or else (Slot.Nominal /= No_Nominal_Type
                       and then Is_Pointer_Union (Into, Slot.Nominal))
            then
               return;
            end if;
            Plan.Parts := Slot.Fields.Count;
         else
            return;
         end if;
         Plan.Shaped := True;
         Plan.Plain := True;
         for Part in 1 .. Plan.Parts loop
            declare
               Held : constant Field_Shape := Part_Shape (Slot, Part);
            begin
               if Held.Kind /= Scalar_Field_Shape
                 or else Held.Packing.Bits /= 0
                 or else Held.Atoms /= No_Atom_Set
                 or else (Held.Signature /= No_Signature
                          and then Signature_Has_Erased_Self
                            (Into, Held.Signature))
               then
                  Plan.Shaped := False;
               end if;
               if Held.Signature /= No_Signature
                 or else Held.Pointee /= No_Pointee
               then
                  Plan.Plain := False;
               end if;
            end;
         end loop;
         Plan.Plain := Plan.Plain and then Plan.Shaped;
      end Shape;

      --  Classify every slot of Item and choose what becomes of it.
      procedure Plan_Item (Item : Item_Id);
      procedure Plan_Item (Item : Item_Id) is
         Held : constant Item_Record := Into.Items.Element (Positive (Item));
         Base : constant Natural := Held.Slots.First;
         Added : Natural := 0;

         function Plan_Of (Slot : Slot_Id) return Positive
           is (Base + Positive (Slot));

         procedure Bar (Slot : Slot_Id);
         procedure Bar (Slot : Slot_Id) is
         begin
            if Slot /= No_Slot then
               Plans.Reference (Plan_Of (Slot)).Barred := True;
            end if;
         end Bar;

         --  A whole copy between two frame slots is rewritten part by
         --  part, which needs the same scalar parts on both sides and a
         --  destination that a part store may write.
         function Whole_Copy (Code : Instruction) return Boolean;
         function Whole_Copy (Code : Instruction) return Boolean is
         begin
            if Code.Op /= Copy_Array
              or else Code.Source.Kind /= Frame_Slot
              or else Code.Destination.Kind /= Frame_Slot
              or else Code.Source.Slot = No_Slot
              or else Code.Destination.Slot = No_Slot
              or else Code.Source_Field /= 0
              or else Code.Source_Nested.Count /= 0
              or else Code.Element_Field /= 0
              or else Code.Nested.Count /= 0
              or else Code.Variant_Case /= 0
              or else Code.Variant_Payload_Field /= 0
            then
               return False;
            end if;
            declare
               From : constant Slot_Plan :=
                 Plans.Element (Plan_Of (Code.Source.Slot));
               To : constant Slot_Plan :=
                 Plans.Element (Plan_Of (Code.Destination.Slot));
               From_Slot : constant Slot_Record :=
                 Into.Slots.Element (Plan_Of (Code.Source.Slot));
               To_Slot : constant Slot_Record :=
                 Into.Slots.Element (Plan_Of (Code.Destination.Slot));
            begin
               if not From.Shaped or else not To.Shaped
                 or else To.Parameter or else From.Parts /= To.Parts
               then
                  return False;
               end if;
               for Part in 1 .. From.Parts loop
                  if Part_Type (From_Slot, Part) /= Part_Type (To_Slot, Part)
                  then
                     return False;
                  end if;
               end loop;
               return True;
            end;
         end Whole_Copy;

         procedure Note_Place
           (Place : Storage; Code : Instruction; Is_Destination : Boolean);
         procedure Note_Place
           (Place : Storage; Code : Instruction; Is_Destination : Boolean)
         is
         begin
            if Place.Kind /= Frame_Slot or else Place.Slot = No_Slot then
               return;
            elsif Whole_Copy (Code) then
               if Is_Destination then
                  Plans.Reference (Plan_Of (Place.Slot)).Written := True;
               end if;
            elsif Is_Destination and then Code.Op = Clear_Array
              and then Code.Element_Field = 0 and then Code.Nested.Count = 0
            then
               Plans.Reference (Plan_Of (Place.Slot)).Written := True;
            else
               Bar (Place.Slot);
            end if;
         end Note_Place;

         Convention : constant Landin.Machine.Convention :=
           Signature_Machine (Into, Held.Signature);
         --  Lowering reads both parts of a slice where it needs one; a
         --  part only an unused load reads needs no copy on entry.
         Used : Flag_Vectors.Vector;
         --  A parameter's part is worth a copy on entry only where a loop
         --  reads it, and only at speed: there a register can hold it.
         Looping : constant Flag_Vectors.Vector :=
           (if Objective = Landin.Optimization.Speed
            then Cyclic (Into, Item) else Flag_Vectors.Empty_Vector);
      begin
         Used.Append (False, Ada.Containers.Count_Type (Held.Values.Count));
         for V in 1 .. Held.Values.Count loop
            declare
               Code : constant Instruction :=
                 Into.Code.Element (Held.Values.First + V);
            begin
               for A in 1 .. Code.Args loop
                  Used (Positive
                    (Into.Operands.Element (Code.First_Arg + A))) := True;
               end loop;
            end;
         end loop;
         for S in 1 .. Held.Slots.Count loop
            Shape (Into.Slots.Element (Base + S), Plans.Reference (Base + S));
         end loop;
         for P in 1 .. Held.Parameters.Count loop
            Plans.Reference
              (Plan_Of (Into.Parameters.Element (Held.Parameters.First + P)))
              .Parameter := True;
         end loop;
         Bar (Held.Returns_To);
         --  A source alias is described through its storage.
         for A in 1 .. Held.Aliases.Count loop
            declare
               Place : constant Storage :=
                 Into.Aliases.Element (Held.Aliases.First + A).Info.Place;
            begin
               if Place.Kind = Frame_Slot then
                  Bar (Place.Slot);
               end if;
            end;
         end loop;
         for V in 1 .. Held.Values.Count loop
            declare
               Code : constant Instruction :=
                 Into.Code.Element (Held.Values.First + V);
            begin
               if Code.Slot /= No_Slot then
                  if Code.Op in Load_Field | Store_Field
                    and then Code.Nested.Count = 0
                  then
                     declare
                        Plan : Slot_Plan renames
                          Plans.Reference (Plan_Of (Code.Slot));
                     begin
                        Plan.Accessed := True;
                        if Code.Op = Store_Field then
                           Plan.Written := True;
                        elsif Plan.Shaped and then Used (V)
                          and then Positive (Code.Part) <= Plan.Parts
                          and then not Looping.Is_Empty
                          and then Looping (Positive (Code.In_Block))
                        then
                           Plan.Read (Positive (Code.Part)) := True;
                        end if;
                     end;
                  else
                     Bar (Code.Slot);
                  end if;
               end if;
               Note_Place (Code.Source, Code, Is_Destination => False);
               Note_Place (Code.Destination, Code, Is_Destination => True);
               for A in 1 .. Code.Assembly_Run.Count loop
                  Bar (Into.Assembly_Operands
                         (Code.Assembly_Run.First + A).Output);
               end loop;
            end;
         end loop;
         for S in 1 .. Held.Slots.Count loop
            declare
               Plan : Slot_Plan renames Plans.Reference (Base + S);
               Slot : constant Slot_Record := Into.Slots.Element (Base + S);
            begin
               if not Plan.Shaped or else Plan.Barred
                 or else Convention /= Landin.Machine.Ordinary
               then
                  null;
               elsif Plan.Parameter then
                  if not Plan.Written then
                     for Part in 1 .. Plan.Parts loop
                        if Plan.Read (Part) then
                           Plan.Use_As := Entry_Copy;
                           Added := Added + 1;
                           Plan.Pieces (Part) :=
                             Slot_Id (Held.Slots.Count + Added);
                        end if;
                     end loop;
                  end if;
               elsif Plan.Plain and then Plan.Accessed
                 and then (Objective = Landin.Optimization.Speed
                           or else Slot.Declaration = No_Declaration)
               then
                  Plan.Use_As := Split;
                  for Part in 1 .. Plan.Parts loop
                     Added := Added + 1;
                     Plan.Pieces (Part) :=
                       Slot_Id (Held.Slots.Count + Added);
                  end loop;
               end if;
            end;
         end loop;
         Changed := Changed or else Added > 0;
         Added_Total := Added_Total + Added;
      end Plan_Item;

      --  Copy every item into fresh slot, code, operand and assembly runs,
      --  appending the pieces to each item's slots and rewriting the uses
      --  of the slots they replace.
      procedure Rebuild;
      procedure Rebuild is
         Slots : Slot_Vectors.Vector;
         Code : Code_Vectors.Vector;
         Args : Value_Ref_Vectors.Vector;
         Assembled : Assembly_Operand_Vectors.Vector;
      begin
         --  Room for what the pieces usually add; a vector still grows
         --  past it when a unit has many whole copies.
         Slots.Reserve_Capacity
           (Into.Slots.Length + Ada.Containers.Count_Type (Added_Total));
         Code.Reserve_Capacity
           (Into.Code.Length + 2 * Ada.Containers.Count_Type (Added_Total));
         Args.Reserve_Capacity (Into.Operands.Length);
         Assembled.Reserve_Capacity (Into.Assembly_Operands.Length);
         for I in 1 .. Item_Count (Into) loop
            declare
               Old : constant Item_Record := Into.Items.Element (I);
               Held : Item_Record := Old;
               Map : Value_Maps.Vector;
               Entry_Value : constant Natural :=
                 (if Old.Kind = Routine and then Old.Blocks.Count > 0
                    and then Into.Blocks
                      (Old.Blocks.First + Positive (First_Block)).Values > 0
                  then Into.Blocks
                      (Old.Blocks.First + Positive (First_Block)).First_Value
                    - Old.Values.First + 1
                  else 0);

               function Plan_Of (Slot : Slot_Id) return Slot_Plan
                 is (Plans.Element (Old.Slots.First + Positive (Slot)));

               function Slot_Of (Slot : Slot_Id) return Slot_Record
                 is (Into.Slots.Element (Old.Slots.First + Positive (Slot)));

               --  Append one instruction to this item's run in its block.
               function Append
                 (Made : Instruction; Operands : Value_Ref_Vectors.Vector)
                  return Value_Id;
               function Append
                 (Made : Instruction; Operands : Value_Ref_Vectors.Vector)
                  return Value_Id
               is
                  Now : Instruction := Made;
                  At_Block : constant Positive :=
                    Old.Blocks.First + Positive (Made.In_Block);
               begin
                  Now.First_Arg := Natural (Args.Length);
                  Now.Args := Natural (Operands.Length);
                  for Operand of Operands loop
                     Args.Append (Operand);
                  end loop;
                  Now.Assembly_Run :=
                    (First => Natural (Assembled.Length),
                     Count => Made.Assembly_Run.Count);
                  for A in 1 .. Made.Assembly_Run.Count loop
                     Assembled.Append
                       (Into.Assembly_Operands.Element
                          (Made.Assembly_Run.First + A));
                  end loop;
                  if Into.Blocks (At_Block).Values = 0 then
                     Into.Blocks (At_Block).First_Value :=
                       Natural (Code.Length);
                  end if;
                  Into.Blocks (At_Block).Values :=
                    Into.Blocks (At_Block).Values + 1;
                  Code.Append (Now);
                  Held.Values.Count := Held.Values.Count + 1;
                  return Value_Id (Held.Values.Count);
               end Append;

               function No_Operands return Value_Ref_Vectors.Vector
                 is (Value_Ref_Vectors.Empty_Vector);

               function One (Value : Value_Id) return Value_Ref_Vectors.Vector
                 is (Value_Ref_Vectors.To_Vector (Value, 1));

               procedure Put
                 (Slot : Slot_Id; Value : Value_Id; Like : Instruction);
               procedure Put
                 (Slot : Slot_Id; Value : Value_Id; Like : Instruction)
               is
                  Made : constant Value_Id := Append
                    (Instruction'(Op => Store, Site => Like.Site,
                                  In_Block => Like.In_Block, Slot => Slot,
                                  others => <>), One (Value));
               begin
                  pragma Assert (Made /= No_Value);
               end Put;

               --  One part of Slot as a value: its piece where it has one,
               --  else a field load from the whole slot.
               function Read_Part
                 (Slot : Slot_Id; Part : Positive; Like : Instruction)
                  return Value_Id;
               function Read_Part
                 (Slot : Slot_Id; Part : Positive; Like : Instruction)
                  return Value_Id
               is
                  Plan : constant Slot_Plan := Plan_Of (Slot);
                  Shape : constant Field_Shape :=
                    Part_Shape (Slot_Of (Slot), Part);
               begin
                  if Plan.Pieces (Part) /= No_Slot then
                     return Append
                       (Instruction'(Op => Load, Result => Shape.Element,
                                     Site => Like.Site,
                                     In_Block => Like.In_Block,
                                     Slot => Plan.Pieces (Part),
                                     Signature => Shape.Signature,
                                     Pointee => Shape.Pointee,
                                     others => <>), No_Operands);
                  end if;
                  return Append
                    (Instruction'(Op => Load_Field, Result => Shape.Element,
                                  Site => Like.Site,
                                  In_Block => Like.In_Block, Slot => Slot,
                                  Part => Part_Position (Part),
                                  Signature => Shape.Signature,
                                  others => <>), No_Operands);
               end Read_Part;

               procedure Write_Part
                 (Slot : Slot_Id; Part : Positive; Value : Value_Id;
                  Like : Instruction);
               procedure Write_Part
                 (Slot : Slot_Id; Part : Positive; Value : Value_Id;
                  Like : Instruction)
               is
                  Plan : constant Slot_Plan := Plan_Of (Slot);
                  Made : Value_Id;
               begin
                  if Plan.Use_As = Split then
                     Put (Plan.Pieces (Part), Value, Like);
                  else
                     Made := Append
                       (Instruction'(Op => Store_Field, Site => Like.Site,
                                     In_Block => Like.In_Block, Slot => Slot,
                                     Part => Part_Position (Part),
                                     others => <>), One (Value));
                     pragma Assert (Made /= No_Value);
                  end if;
               end Write_Part;

               --  Whether Was is a use this pass rewrites rather than copies.
               function Rewritten (Was : Instruction) return Boolean is
                 (case Was.Op is
                     when Load_Field | Store_Field =>
                        Was.Slot /= No_Slot and then Was.Nested.Count = 0
                        and then Natural (Was.Part) <= Plan_Of (Was.Slot).Parts
                        and then Plan_Of (Was.Slot).Pieces
                          (Positive (Was.Part)) /= No_Slot,
                     when Copy_Array =>
                        Was.Source.Kind = Frame_Slot
                        and then Was.Destination.Kind = Frame_Slot
                        and then (Plan_Of (Was.Source.Slot).Use_As = Split
                          or else Plan_Of (Was.Destination.Slot).Use_As
                            = Split),
                     when Clear_Array =>
                        Was.Destination.Kind = Frame_Slot
                        and then Plan_Of (Was.Destination.Slot).Use_As
                          = Split,
                     when others => False);
            begin
               Held.Slots := (First => Natural (Slots.Length), Count => 0);
               for S in 1 .. Old.Slots.Count loop
                  declare
                     Slot : Slot_Record :=
                       Into.Slots.Element (Old.Slots.First + S);
                  begin
                     if Plans.Element (Old.Slots.First + S).Use_As = Split then
                        Slot.First_Piece :=
                          Plans.Element (Old.Slots.First + S).Pieces (1);
                     end if;
                     Slots.Append (Slot);
                  end;
               end loop;
               --  Pieces follow in slot order, which is the order Plan_Item
               --  numbered them in.
               for S in 1 .. Old.Slots.Count loop
                  declare
                     Plan : constant Slot_Plan :=
                       Plans.Element (Old.Slots.First + S);
                     Slot : constant Slot_Record :=
                       Into.Slots.Element (Old.Slots.First + S);
                  begin
                     for Part in 1 .. Plan.Parts loop
                        if Plan.Pieces (Part) /= No_Slot then
                           declare
                              Shape : constant Field_Shape :=
                                Part_Shape (Slot, Part);
                           begin
                              --  A piece of an inlined copy's slot belongs
                              --  to the same copy.
                              Slots.Append
                                (Slot_Record'(Of_Type => Shape.Element,
                                              Signature => Shape.Signature,
                                              Pointee => Shape.Pointee,
                                              Site => Slot.Site,
                                              Inlined => Slot.Inlined,
                                              others => <>));
                              if Slot_Id (Natural (Slots.Length)
                                            - Held.Slots.First)
                                /= Plan.Pieces (Part)
                              then
                                 raise Landin.Compiler_Defect with
                                   "scalar replacement misnumbered a piece";
                              end if;
                           end;
                        end if;
                     end loop;
                  end;
               end loop;
               Held.Slots.Count := Natural (Slots.Length) - Held.Slots.First;

               Held.Values := (First => Natural (Code.Length), Count => 0);
               for B in 1 .. Old.Blocks.Count loop
                  Into.Blocks (Old.Blocks.First + B).First_Value := 0;
                  Into.Blocks (Old.Blocks.First + B).Values := 0;
               end loop;
               Map.Append (No_Value, Ada.Containers.Count_Type
                 (Old.Values.Count));
               for V in 1 .. Old.Values.Count loop
                  declare
                     Was : constant Instruction :=
                       Into.Code.Element (Old.Values.First + V);
                     Now : Instruction := Was;
                     Operands : Value_Ref_Vectors.Vector;
                  begin
                     if V = Entry_Value then
                        --  A parameter's parts, copied once before the
                        --  first block's first instruction.
                        for S in 1 .. Old.Slots.Count loop
                           declare
                              Plan : constant Slot_Plan :=
                                Plans.Element (Old.Slots.First + S);
                           begin
                              if Plan.Use_As = Entry_Copy then
                                 for Part in 1 .. Plan.Parts loop
                                    if Plan.Pieces (Part) /= No_Slot then
                                       declare
                                          Shape : constant Field_Shape :=
                                            Part_Shape
                                              (Slot_Of (Slot_Id (S)), Part);
                                       begin
                                          Put
                                            (Plan.Pieces (Part),
                                             Append
                                               (Instruction'
                                                  (Op => Load_Field,
                                                   Result => Shape.Element,
                                                   Site => Was.Site,
                                                   In_Block => First_Block,
                                                   Slot => Slot_Id (S),
                                                   Part => Part_Position
                                                     (Part),
                                                   Signature =>
                                                     Shape.Signature,
                                                   others => <>),
                                                No_Operands),
                                             Was);
                                       end;
                                    end if;
                                 end loop;
                              end if;
                           end;
                        end loop;
                     end if;
                     for A in 1 .. Was.Args loop
                        declare
                           Before : constant Value_Id :=
                             Into.Operands.Element (Was.First_Arg + A);
                        begin
                           if Map (Positive (Before)) = No_Value then
                              raise Landin.Compiler_Defect with
                                "scalar replacement lost an operand";
                           end if;
                           Operands.Append (Map (Positive (Before)));
                        end;
                     end loop;
                     if not Rewritten (Was) then
                        Map (V) := Append (Now, Operands);
                     elsif Was.Op = Load_Field then
                        declare
                           Piece : constant Slot_Id :=
                             Plan_Of (Was.Slot).Pieces (Positive (Was.Part));
                           Slot : constant Slot_Record := Slots
                             (Held.Slots.First + Positive (Piece));
                        begin
                           Now.Op := Load;
                           Now.Slot := Piece;
                           Now.Part := 1;
                           Now.Signature := Slot.Signature;
                           Now.Pointee := Slot.Pointee;
                           Map (V) := Append (Now, Operands);
                        end;
                     elsif Was.Op = Store_Field then
                        Now.Op := Store;
                        Now.Slot := Plan_Of (Was.Slot).Pieces
                          (Positive (Was.Part));
                        Now.Part := 1;
                        Map (V) := Append (Now, Operands);
                     elsif Was.Op = Copy_Array then
                        for Part in 1 .. Plan_Of (Was.Source.Slot).Parts loop
                           Write_Part
                             (Was.Destination.Slot, Part,
                              Read_Part (Was.Source.Slot, Part, Was), Was);
                        end loop;
                     else
                        --  Clear_Array: zero of each part's own type.
                        for Part in 1 .. Plan_Of (Was.Destination.Slot).Parts
                        loop
                           declare
                              Of_Type : constant Landin.Types.Scalar_Name :=
                                Part_Type (Slot_Of (Was.Destination.Slot),
                                           Part);
                           begin
                              Put
                                (Plan_Of (Was.Destination.Slot).Pieces (Part),
                                 Append
                                   ((if Of_Type = Landin.Types.Bool
                                     then Instruction'
                                       (Op => Truth, Result => Of_Type,
                                        Site => Was.Site,
                                        In_Block => Was.In_Block,
                                        Truth => False, others => <>)
                                     else Instruction'
                                       (Op => Number, Result => Of_Type,
                                        Site => Was.Site,
                                        In_Block => Was.In_Block,
                                        Number => 0, others => <>)),
                                    No_Operands),
                                 Was);
                           end;
                        end loop;
                     end if;
                  end;
               end loop;
               Into.Items.Replace_Element (I, Held);
            end;
         end loop;
         Into.Slots.Move (Slots);
         Into.Code.Move (Code);
         Into.Operands.Move (Args);
         Into.Assembly_Operands.Move (Assembled);
      end Rebuild;
   begin
      if Objective = Landin.Optimization.None then
         return;
      end if;
      Plans.Append ((others => <>), Into.Slots.Length);
      for I in 1 .. Item_Count (Into) loop
         if Kind_Of (Into, Item_Id (I)) = Routine
           and then not Is_External (Into, Item_Id (I))
         then
            Plan_Item (Item_Id (I));
         end if;
      end loop;
      if Changed then
         Rebuild;
      end if;
   end Replace;
end Landin.IR.Scalar_Replacement;
