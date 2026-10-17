with Ada.Containers.Vectors;
with Landin.IR.Control_Flow;
with Landin.IR.Effects;
with Landin.IR.Liveness;
with Landin.IR.Rewriting;
with Landin.IR.Shape_Measurement;
with Landin.IR.Verifier;
with Landin.Machine;

package body Landin.IR.In_Place is
   use type Landin.Optimization.Objective;
   use type Landin.Machine.Convention;
   use type Ada.Containers.Count_Type;

   package Flag_Vectors is new Ada.Containers.Vectors (Positive, Boolean);
   package Count_Vectors is new Ada.Containers.Vectors (Positive, Natural);

   function Code_Of
     (Into : Unit; Held : Item_Record; Value : Value_Id) return Instruction
     is (Into.Code.Element (Held.Values.First + Positive (Value)));

   function Slot_Of
     (Into : Unit; Held : Item_Record; Slot : Slot_Id) return Slot_Record
     is (Into.Slots.Element (Held.Slots.First + Positive (Slot)));

   function Operand
     (Into : Unit; Code : Instruction; Index : Positive) return Value_Id
     is (Into.Operands.Element (Code.First_Arg + Index));

   --  D106: an aggregate or multiple result arrives through a hidden first
   --  argument, after an indirect call's own address.  The verifier counts
   --  the same way.
   function Hidden_Count
     (Into : Unit; Signature : Signature_Id) return Natural
     is (if Signature_Result_Count (Into, Signature) > 1
           or else
             (Signature_Result_Count (Into, Signature) = 1
              and then Nth_Signature_Result (Into, Signature, 1).Kind
                         in Landin.Types.Aggregate
                          | Landin.Types.Fixed_Array)
         then 1 else 0);

   --  The address slots of one routine that only ever hold an address in
   --  its own frame: every store to one is the address of a frame slot,
   --  as lowering keeps a computed element or a destination it writes
   --  through.  A parameter's slot holds its caller's address instead.
   function Frame_Addresses
     (Into : Unit; Held : Item_Record) return Flag_Vectors.Vector;

   function Frame_Addresses
     (Into : Unit; Held : Item_Record) return Flag_Vectors.Vector
   is
      Count : constant Ada.Containers.Count_Type :=
        Ada.Containers.Count_Type (Held.Slots.Count);
      Stored : Flag_Vectors.Vector := Flag_Vectors.To_Vector (False, Count);
      Other : Flag_Vectors.Vector := Flag_Vectors.To_Vector (False, Count);
   begin
      for P in 1 .. Held.Parameters.Count loop
         Other (Positive (Into.Parameters.Element
           (Held.Parameters.First + P))) := True;
      end loop;
      for V in 1 .. Held.Values.Count loop
         declare
            Code : constant Instruction := Code_Of (Into, Held, Value_Id (V));
         begin
            if Code.Op = Store then
               declare
                  Value : constant Instruction :=
                    Code_Of (Into, Held, Operand (Into, Code, 1));
               begin
                  if Value.Op in Storage_Address | Place_Address
                    and then Value.Destination.Kind = Frame_Slot
                  then
                     Stored (Positive (Code.Slot)) := True;
                  else
                     Other (Positive (Code.Slot)) := True;
                  end if;
               end;
            elsif Code.Op = Assembly then
               for Which in 1 .. Code.Assembly_Run.Count loop
                  declare
                     Output : constant Slot_Id :=
                       Into.Assembly_Operands.Element
                         (Code.Assembly_Run.First + Which).Output;
                  begin
                     if Output /= No_Slot then
                        Other (Positive (Output)) := True;
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;
      for S in 1 .. Held.Slots.Count loop
         Stored (S) := Stored (S) and then not Other (S)
           and then Into.Slots.Element (Held.Slots.First + S).Addressed;
      end loop;
      return Stored;
   end Frame_Addresses;

   --  Whether one instruction may write memory outside the frame of the
   --  routine that runs it, leaving aside what a direct callee's own body
   --  does, which is the summary's question.  Anything that writes and is
   --  not plainly in this frame answers yes; Framed is Frame_Addresses.
   function Writes_Outside
     (Into : Unit; Held : Item_Record; Framed : Flag_Vectors.Vector;
      Code : Instruction) return Boolean;

   function Writes_Outside
     (Into : Unit; Held : Item_Record; Framed : Flag_Vectors.Vector;
      Code : Instruction) return Boolean
   is
      function In_Frame (Place : Storage) return Boolean
        is (case Place.Kind is
               when Frame_Slot => True,
               when Runtime_Address => Framed (Positive (Place.Address)),
               when Module_Datum => False);
   begin
      if not Effects.Of_Code (Code.Op).Writes then
         return False;
      end if;
      case Code.Op is
         when Store =>
            return False;
         when Store_Field | Store_Element =>
            --  An address slot reaches through itself, a shaped slot is
            --  storage in the frame, and no slot is a module datum.
            return Code.Slot = No_Slot
              or else (Into.Slots.Element
                         (Held.Slots.First + Positive (Code.Slot)).Addressed
                       and then not Framed (Positive (Code.Slot)));
         when Copy_Array | Copy_Variant | Clear_Array | Fill_Array
            | Select_Variant | Store_Variant_Field =>
            return not In_Frame (Code.Destination);
         when Call =>
            --  Its failure status is a slot of this frame; its result is
            --  written where its hidden destination says.
            if Hidden_Count (Into, Code.Signature) = 1 then
               declare
                  Destination : constant Instruction :=
                    Code_Of (Into, Held, Operand (Into, Code, 1));
               begin
                  return not
                    ((Destination.Op = Storage_Address
                      and then In_Frame (Destination.Destination))
                     or else (Destination.Op = Load
                              and then Framed
                                (Positive (Destination.Slot))));
               end;
            end if;
            return False;
         when others =>
            return True;
      end case;
   end Writes_Outside;

   --  Whether operand Index of a call is a by-value aggregate
   --  source argument: not an indirect callee's address, not a
   --  hidden result destination and not an inout place.
   function By_Value
     (Into : Unit; Code : Instruction; Index : Positive) return Boolean;
   function By_Value
     (Into : Unit; Code : Instruction; Index : Positive) return Boolean
   is
      Offset : constant Natural :=
        (if Code.Op not in Call | Indirect_Call then 0
         else (if Code.Op = Indirect_Call then 1 else 0)
           + Hidden_Count (Into, Code.Signature));
   begin
      if Code.Op not in Call | Indirect_Call
        or else Index <= Offset
        or else Index - Offset
                  > Signature_Parameter_Count
                      (Into, Code.Signature)
      then
         return False;
      end if;
      declare
         Part : constant Signature_Part :=
           Nth_Signature_Parameter
             (Into, Code.Signature, Index - Offset);
      begin
         return Part.Convention /= Inout_Place
           and then Part.Kind
             in Landin.Types.Aggregate | Landin.Types.Fixed_Array;
      end;
   end By_Value;

   --  Every slot one instruction names, with whether it names it as the
   --  target of a plain Load or Store.
   generic
      with procedure Name (Slot : Slot_Id; Plain : Boolean);
   procedure Each_Slot (Into : Unit; Code : Instruction);

   procedure Each_Slot (Into : Unit; Code : Instruction) is
      procedure Name (Place : Storage);
      procedure Name (Place : Storage) is
      begin
         case Place.Kind is
            when Frame_Slot => Name (Place.Slot, False);
            when Runtime_Address => Name (Place.Address, False);
            when Module_Datum => null;
         end case;
      end Name;
   begin
      case Code.Op is
         when Load | Store =>
            Name (Code.Slot, True);
         when Load_Field | Store_Field | Load_Element | Store_Element
            | Call | Indirect_Call =>
            Name (Code.Slot, False);
         when Copy_Array | Copy_Variant =>
            Name (Code.Source);
            Name (Code.Destination);
         when Load_Variant_Tag | Load_Variant_Field =>
            Name (Code.Source);
         when Storage_Address | Place_Address | Clear_Array
            | Fill_Array | Select_Variant | Store_Variant_Field =>
            Name (Code.Destination);
         when Assembly =>
            for Which in 1 .. Code.Assembly_Run.Count loop
               Name (Into.Assembly_Operands.Element
                 (Code.Assembly_Run.First + Which).Output, False);
            end loop;
         when others =>
            null;
      end case;
   end Each_Slot;

   --  Lowering passes a slice or `any` argument through a fresh temporary
   --  copied from its storage.  When nothing between that copy and the
   --  call can write memory, the storage still holds the copied bytes when
   --  the callee receives its address, exactly as D94 passes a named
   --  aggregate: the call is given the storage itself and the copy goes.
   --  A temporary qualifies when the copy and its one address are all that
   --  name it, and that address is one by-value argument of a call later in
   --  the same block.
   procedure Forward
     (Into : in out Unit;
      Item : Item_Id;
      Keep : in out Rewriting.Keep_Vectors.Vector;
      Changed : in out Boolean);

   procedure Forward
     (Into : in out Unit;
      Item : Item_Id;
      Keep : in out Rewriting.Keep_Vectors.Vector;
      Changed : in out Boolean)
   is
      Held : constant Item_Record := Into.Items.Element (Positive (Item));
      Slots : constant Ada.Containers.Count_Type :=
        Ada.Containers.Count_Type (Held.Slots.Count);
      Values : constant Ada.Containers.Count_Type :=
        Ada.Containers.Count_Type (Held.Values.Count);
      --  How often each slot is named, and each value used.
      Named : Count_Vectors.Vector := Count_Vectors.To_Vector (0, Slots);
      Used : Count_Vectors.Vector := Count_Vectors.To_Vector (0, Values);
      --  The copy into each temporary still open in this block, and the
      --  address of that temporary once it is taken.
      Copy_Of : Count_Vectors.Vector := Count_Vectors.To_Vector (0, Slots);
      Address_Of : Count_Vectors.Vector :=
        Count_Vectors.To_Vector (0, Values);
      --  Where that address was taken: the value itself, or the address
      --  a load of a saved carrier stands for.
      Taken_At : Count_Vectors.Vector :=
        Count_Vectors.To_Vector (0, Values);
      --  A saved carrier: the address one store put in an address slot
      --  that one load reads back, as lowering keeps an argument across
      --  later ones.
      Saved : Count_Vectors.Vector := Count_Vectors.To_Vector (0, Slots);
      Open : Count_Vectors.Vector;

      procedure Name (Slot : Slot_Id; Plain : Boolean);
      procedure Name (Slot : Slot_Id; Plain : Boolean) is
         pragma Unreferenced (Plain);
      begin
         if Slot /= No_Slot then
            Named (Positive (Slot)) := Named (Positive (Slot)) + 1;
         end if;
      end Name;

      procedure Name_All is new Each_Slot (Name);

      procedure Close;
      procedure Close is
      begin
         for Slot of Open loop
            Copy_Of (Slot) := 0;
         end loop;
         Open.Clear;
      end Close;

      --  A copy into a temporary this rewrite may remove.
      function Opens (Code : Instruction) return Boolean
        is (Code.Op = Copy_Array
            and then Code.Destination.Kind = Frame_Slot
            and then Code.Destination.Slot /= No_Slot
            and then Code.Element_Field = 0
            and then Code.Nested.Count = 0
            and then Code.Variant_Case = 0
            and then Code.Variant_Payload_Field = 0
            and then Named (Positive (Code.Destination.Slot)) = 2
            and then not Is_Address (Into, Item, Code.Destination.Slot)
            and then Declares (Into, Item, Code.Destination.Slot)
                       = No_Declaration);
   begin
      for P in 1 .. Held.Parameters.Count loop
         Named (Positive (Into.Parameters.Element
           (Held.Parameters.First + P))) := 3;
      end loop;
      if Held.Returns_To /= No_Slot then
         Named (Positive (Held.Returns_To)) := 3;
      end if;
      for A in 1 .. Held.Aliases.Count loop
         declare
            Place : constant Storage :=
              Into.Aliases.Element (Held.Aliases.First + A).Info.Place;
         begin
            Name ((case Place.Kind is
                     when Frame_Slot => Place.Slot,
                     when Runtime_Address => Place.Address,
                     when Module_Datum => No_Slot), False);
         end;
      end loop;
      for V in 1 .. Held.Values.Count loop
         declare
            Code : constant Instruction := Code_Of (Into, Held, Value_Id (V));
         begin
            for Index in 1 .. Code.Args loop
               declare
                  Operand_Value : constant Positive :=
                    Positive (Operand (Into, Code, Index));
               begin
                  Used (Operand_Value) := Used (Operand_Value) + 1;
               end;
            end loop;
            Name_All (Into, Code);
         end;
      end loop;

      for B in 1 .. Held.Blocks.Count loop
         Close;
         for Position in 1 .. Length (Into, Item, Block_Id (B)) loop
            declare
               Value : constant Value_Id :=
                 Nth_Value (Into, Item, Block_Id (B), Position);
               Code : constant Instruction := Code_Of (Into, Held, Value);
            begin
               --  An address taken of an open temporary, and the call that
               --  receives it by value.
               if Code.Op = Storage_Address
                 and then Code.Destination.Kind = Frame_Slot
                 and then Code.Destination.Slot /= No_Slot
                 and then Copy_Of (Positive (Code.Destination.Slot)) /= 0
                 and then Code.Element_Field = 0
                 and then Code.Nested.Count = 0
                 and then not Code.Indexed_Address
                 and then Used (Positive (Value)) = 1
               then
                  Address_Of (Positive (Value)) :=
                    Natural (Code.Destination.Slot);
                  Taken_At (Positive (Value)) := Natural (Value);
               elsif Code.Op = Store
                 and then Address_Of (Positive (Operand (Into, Code, 1))) /= 0
                 and then Named (Positive (Code.Slot)) = 2
                 and then Is_Address (Into, Item, Code.Slot)
                 and then Declares (Into, Item, Code.Slot) = No_Declaration
               then
                  Saved (Positive (Code.Slot)) :=
                    Natural (Operand (Into, Code, 1));
               elsif Code.Op = Load
                 and then Saved (Positive (Code.Slot)) /= 0
                 and then Used (Positive (Value)) = 1
               then
                  Address_Of (Positive (Value)) :=
                    Address_Of (Saved (Positive (Code.Slot)));
                  Taken_At (Positive (Value)) :=
                    Taken_At (Saved (Positive (Code.Slot)));
               end if;
               if Code.Op in Call | Indirect_Call then
                  for Index in 1 .. Code.Args loop
                     declare
                        Argument : constant Value_Id :=
                          Operand (Into, Code, Index);
                        Slot : constant Natural :=
                          Address_Of (Positive (Argument));
                     begin
                        if Slot /= 0
                          and then Copy_Of (Slot) /= 0
                          and then By_Value (Into, Code, Index)
                        then
                           declare
                              Copy_At : constant Positive :=
                                Held.Values.First + Copy_Of (Slot);
                              Copy : constant Instruction :=
                                Into.Code.Element (Copy_At);
                              Address_At : constant Positive :=
                                Held.Values.First
                                + Taken_At (Positive (Argument));
                              Address : Instruction :=
                                Into.Code.Element (Address_At);
                           begin
                              Address.Destination := Copy.Source;
                              Address.Element_Field := Copy.Source_Field;
                              Address.Nested := Copy.Source_Nested;
                              Into.Code.Replace_Element (Address_At, Address);
                              Keep (Copy_At) := False;
                              Copy_Of (Slot) := 0;
                              Changed := True;
                           end;
                        end if;
                     end;
                  end loop;
               end if;

               --  Anything else that writes may change a copied source.
               --  A copy into another such temporary writes only that, and
               --  a scalar store only its own slot, which matters only to
               --  a source reached through it.
               if Opens (Code) then
                  Copy_Of (Positive (Code.Destination.Slot)) :=
                    Natural (Value);
                  Open.Append (Positive (Code.Destination.Slot));
               elsif Code.Op = Store then
                  declare
                     Reached : Boolean := False;
                  begin
                     for Slot of Open loop
                        if Copy_Of (Slot) /= 0 then
                           declare
                              Source : constant Storage := Into.Code.Element
                                (Held.Values.First + Copy_Of (Slot)).Source;
                           begin
                              Reached := Reached
                                or else (Source.Kind = Runtime_Address
                                         and then Source.Address
                                                    = Code.Slot);
                           end;
                        end if;
                     end loop;
                     if Reached then
                        Close;
                     end if;
                  end;
               elsif Effects.Of_Code (Code.Op).Writes then
                  Close;
               end if;
            end;
         end loop;
      end loop;
   end Forward;

   procedure Run
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective) is
   begin
      Verifier.Verify (Into, Facts);
      Run_On_Verified (Into, Facts, Objective);
   end Run;

   procedure Run_On_Verified
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective)
   is
      Items : constant Natural := Item_Count (Into);

      --  Whether a call to the routine may write memory outside its
      --  caller's frame: the least answer closed under direct calls.
      Outside : Flag_Vectors.Vector :=
        Flag_Vectors.To_Vector (False, Ada.Containers.Count_Type (Items));

      --  Whether Forward gave any call its argument's own storage.
      Forwarded : Boolean := False;

      --  The parameters read in place, one entry per pair, in item order.
      Chosen_Items : Count_Vectors.Vector;
      Chosen_Slots : Count_Vectors.Vector;

      function Has_Body (Item : Item_Id) return Boolean
        is (Kind_Of (Into, Item) = Routine
            and then not Is_External (Into, Item));

      procedure Summarize;
      procedure Choose (Item : Item_Id);
      procedure Rewrite (Item : Item_Id; First, Last : Positive);
      procedure Rehome;

      procedure Summarize is
         Callees : Count_Vectors.Vector;
         Callers : Count_Vectors.Vector;
         First : Count_Vectors.Vector :=
           Count_Vectors.To_Vector
             (0, Ada.Containers.Count_Type (Items + 1));
         Edges : Count_Vectors.Vector;
         Work : Count_Vectors.Vector;
      begin
         for I in 1 .. Items loop
            declare
               Item : constant Item_Id := Item_Id (I);
            begin
               if Kind_Of (Into, Item) = Routine
                 and then not Has_Body (Item)
               then
                  Outside (I) := True;
               elsif Has_Body (Item) then
                  declare
                     Held : constant Item_Record := Into.Items.Element (I);
                     Framed : constant Flag_Vectors.Vector :=
                       Frame_Addresses (Into, Held);
                  begin
                     for V in 1 .. Held.Values.Count loop
                        declare
                           Code : constant Instruction :=
                             Code_Of (Into, Held, Value_Id (V));
                        begin
                           if Writes_Outside (Into, Held, Framed, Code) then
                              Outside (I) := True;
                           end if;
                           if Code.Op = Call then
                              if Has_Body (Code.Named) then
                                 Callees.Append (Positive (Code.Named));
                                 Callers.Append (I);
                              else
                                 Outside (I) := True;
                              end if;
                           end if;
                        end;
                     end loop;
                  end;
               end if;
            end;
         end loop;

         --  The callers of each routine, grouped by callee.
         for Callee of Callees loop
            First (Callee + 1) := First (Callee + 1) + 1;
         end loop;
         for I in 2 .. Items + 1 loop
            First (I) := First (I) + First (I - 1);
         end loop;
         Edges.Set_Length (Callees.Length);
         declare
            Next : Count_Vectors.Vector := First;
         begin
            for E in 1 .. Natural (Callees.Length) loop
               Next (Callees (E)) := Next (Callees (E)) + 1;
               Edges (Next (Callees (E))) := Callers (E);
            end loop;
         end;

         for I in 1 .. Items loop
            if Outside (I) then
               Work.Append (I);
            end if;
         end loop;
         while not Work.Is_Empty loop
            declare
               Callee : constant Positive := Work.Last_Element;
            begin
               Work.Delete_Last;
               for E in First (Callee) + 1 .. First (Callee + 1) loop
                  if not Outside (Edges (E)) then
                     Outside (Edges (E)) := True;
                     Work.Append (Edges (E));
                  end if;
               end loop;
            end;
         end loop;
      end Summarize;

      --  Whether a shaped parameter is wider than two words.  Copying a
      --  narrower one is two loads and two stores at entry, which a loop
      --  reading it through a carrier the routine keeps in memory repays
      --  with a dependent load on every iteration: a slice searched in a
      --  short hot loop measured slower read in place.  So a narrow
      --  parameter is read in place only outside loops, where the copy is
      --  the larger cost; a wider one saves a copy loop or a string move.
      function Wider_Than_Two_Words
        (Item : Item_Id; Slot : Slot_Id) return Boolean;

      function Wider_Than_Two_Words
        (Item : Item_Id; Slot : Slot_Id) return Boolean
      is
         use type Landin.Targets.Byte_Count;
         Word : constant Landin.Targets.Byte_Count :=
           Landin.Targets.Byte_Count
             (Landin.Targets.Pointer_Width (Facts)) / 8;
         Size : Landin.Targets.Byte_Count;
      begin
         if Is_Array (Into, Item, Slot) then
            Size := Shape_Measurement.Extent
              (Into, Whole_Slot_Array_Shape (Into, Item, Slot), Facts,
               Landin.Targets.Byte_Count'Last).Size;
         else
            declare
               Fields : Field_Shape_Array
                 (1 .. Slot_Field_Count (Into, Item, Slot));
            begin
               for Index in Fields'Range loop
                  Fields (Index) :=
                    Nth_Slot_Field_Shape (Into, Item, Slot, Index);
               end loop;
               Size := Shape_Measurement.Fields_Layout
                 (Into, Fields, Layout_Of (Into, Item, Slot), Facts,
                  Landin.Targets.Byte_Count'Last).Size;
            end;
         end if;
         return Size > 2 * Word;
      end Wider_Than_Two_Words;

      procedure Choose (Item : Item_Id) is
         Held : constant Item_Record := Into.Items.Element (Positive (Item));
         Signature : constant Signature_Id := Held.Signature;
         Candidate : Flag_Vectors.Vector :=
           Flag_Vectors.To_Vector
             (False, Ada.Containers.Count_Type (Held.Slots.Count));
         Narrow : Flag_Vectors.Vector :=
           Flag_Vectors.To_Vector
             (False, Ada.Containers.Count_Type (Held.Slots.Count));
         Any : Boolean := False;
         Any_Narrow : Boolean := False;
      begin
         if Signature /= No_Signature
           and then (Signature_Uses_C_ABI (Into, Signature)
                     or else Signature_Machine (Into, Signature)
                       /= Landin.Machine.Ordinary)
         then
            return;
         end if;

         --  A D94/D95 parameter has a shaped slot of its own.  A pointer
         --  union's code cell is read with a reserved zero only from a
         --  frame slot, so one stays where it is.
         for P in 1 .. Held.Parameters.Count loop
            declare
               Slot : constant Slot_Id :=
                 Into.Parameters.Element (Held.Parameters.First + P);
               Kept : constant Slot_Record := Slot_Of (Into, Held, Slot);
            begin
               if not Kept.Addressed
                 and then
                   ((Kept.Aggregate
                     and then Kept.Fields.Count > 0
                     and then not
                       (Holds (Into, Kept.Nominal)
                        and then Is_Pointer_Union (Into, Kept.Nominal)))
                    or else Kept.Array_Shape)
               then
                  Candidate (Positive (Slot)) := True;
                  Narrow (Positive (Slot)) :=
                    not Wider_Than_Two_Words (Item, Slot);
                  Any_Narrow := Any_Narrow or else Narrow (Positive (Slot));
                  Any := True;
               end if;
            end;
         end loop;
         if not Any then
            return;
         end if;

         declare
            Blocks : constant Natural := Held.Blocks.Count;
            Graph : constant Control_Flow.Graph :=
              Control_Flow.Make (Into, Item);
            --  The first position in each block that may write outside
            --  this frame, or zero.
            First_Hazard : Count_Vectors.Vector :=
              Count_Vectors.To_Vector
                (0, Ada.Containers.Count_Type (Blocks));
            --  Whether such a write may already have happened when the
            --  block starts: the block follows one with a hazard.
            Tainted : Flag_Vectors.Vector :=
              Flag_Vectors.To_Vector
                (False, Ada.Containers.Count_Type (Blocks));
            Work : Count_Vectors.Vector;
            Framed : constant Flag_Vectors.Vector :=
              Frame_Addresses (Into, Held);
            Depths : constant Liveness.Count_Vectors.Vector :=
              (if Any_Narrow then Liveness.Loop_Depths (Graph)
               else Liveness.Count_Vectors.Empty_Vector);
            --  The parameter slot a Storage_Address value addresses.
            Carried : Count_Vectors.Vector :=
              Count_Vectors.To_Vector
                (0, Ada.Containers.Count_Type (Held.Values.Count));
            Lost : Flag_Vectors.Vector :=
              Flag_Vectors.To_Vector
                (False, Ada.Containers.Count_Type (Held.Slots.Count));
            --  A saved carrier: an address slot lowering keeps an argument
            --  in across later ones, holding only the address of the
            --  parameter it names.  Mixed when anything else is stored
            --  there or the slot is named some other way.
            Through : Count_Vectors.Vector :=
              Count_Vectors.To_Vector
                (0, Ada.Containers.Count_Type (Held.Slots.Count));
            Mixed : Flag_Vectors.Vector :=
              Flag_Vectors.To_Vector
                (False, Ada.Containers.Count_Type (Held.Slots.Count));

            procedure Name (Slot : Slot_Id; Plain : Boolean);
            procedure Name (Slot : Slot_Id; Plain : Boolean) is
            begin
               if Slot /= No_Slot and then not Plain then
                  Mixed (Positive (Slot)) := True;
               end if;
            end Name;

            procedure Name_All is new Each_Slot (Name);

            --  The address slot an instruction reads through, when reading
            --  is all it does there: D339's copies read a parameter their
            --  caller passed on through the carrier lowering kept it in.
            --  Only at speed, where those copies are, so that size keeps
            --  the choices it made.
            function Read_Through (Code : Instruction) return Slot_Id
              is (if Objective /= Landin.Optimization.Speed then No_Slot
                  else (case Code.Op is
                     when Load_Field | Load_Element =>
                       (if Code.Slot /= No_Slot
                          and then Is_Address (Into, Item, Code.Slot)
                        then Code.Slot else No_Slot),
                     when Load_Variant_Tag | Load_Variant_Field =>
                       (if Code.Source.Kind = Runtime_Address
                        then Code.Source.Address else No_Slot),
                     when Copy_Array | Copy_Variant =>
                       (if Code.Source.Kind = Runtime_Address
                          and then not (Code.Destination.Kind
                                          = Runtime_Address
                                        and then Code.Destination.Address
                                                   = Code.Source.Address)
                        then Code.Source.Address else No_Slot),
                     when Storage_Address =>
                       (if Code.Destination.Kind = Runtime_Address
                          and then not Code.Indexed_Address
                        then Code.Destination.Address else No_Slot),
                     when others => No_Slot));

            --  Name an instruction's slots, but not the carrier it only
            --  reads through: that reach is a read of what it carries.
            procedure Name_Except_Reads (Code : Instruction);
            procedure Name_Except_Reads (Code : Instruction) is
               Reached : constant Slot_Id := Read_Through (Code);
               Was : constant Boolean :=
                 (Reached /= No_Slot and then Mixed (Positive (Reached)));
            begin
               Name_All (Into, Code);
               if Reached /= No_Slot then
                  Mixed (Positive (Reached)) := Was;
               end if;
            end Name_Except_Reads;

            procedure Taint (Block : Block_Id);
            procedure Taint (Block : Block_Id) is
            begin
               if Block /= No_Block and then not Tainted (Positive (Block))
               then
                  Tainted (Positive (Block)) := True;
                  Work.Append (Positive (Block));
               end if;
            end Taint;

            function Watched (Slot : Slot_Id) return Boolean
              is (Slot /= No_Slot and then Candidate (Positive (Slot)));

            function Watched (Place : Storage) return Boolean
              is (Place.Kind = Frame_Slot and then Watched (Place.Slot));

            --  A read of Slot at Position of Block: lost when a write
            --  outside the frame may come first.
            procedure Read
              (Slot : Slot_Id; Block : Positive; Position : Positive);
            procedure Read
              (Slot : Slot_Id; Block : Positive; Position : Positive) is
            begin
               if Tainted (Block)
                 or else First_Hazard (Block) in 1 .. Position - 1
                 or else (Narrow (Positive (Slot))
                          and then Depths (Block) > 0)
               then
                  Lost (Positive (Slot)) := True;
               end if;
            end Read;

         begin
            for B in 1 .. Blocks loop
               for Position in 1 .. Length (Into, Item, Block_Id (B)) loop
                  declare
                     Code : constant Instruction := Code_Of
                       (Into, Held,
                        Nth_Value (Into, Item, Block_Id (B), Position));
                  begin
                     if First_Hazard (B) = 0
                       and then
                         (Writes_Outside (Into, Held, Framed, Code)
                          or else (Code.Op = Call
                                   and then Outside (Positive (Code.Named))))
                     then
                        First_Hazard (B) := Position;
                     end if;
                  end;
               end loop;
               if First_Hazard (B) /= 0 then
                  for Index in 1 .. 2 loop
                     Taint (Control_Flow.Successor
                       (Graph, Block_Id (B), Index));
                  end loop;
               end if;
            end loop;
            while not Work.Is_Empty loop
               declare
                  Block : constant Block_Id := Block_Id (Work.Last_Element);
               begin
                  Work.Delete_Last;
                  for Index in 1 .. 2 loop
                     Taint (Control_Flow.Successor (Graph, Block, Index));
                  end loop;
               end;
            end loop;

            --  Which values are a parameter's address, and which address
            --  slots carry nothing else.
            for V in 1 .. Held.Values.Count loop
               declare
                  Code : constant Instruction :=
                    Code_Of (Into, Held, Value_Id (V));
               begin
                  if Code.Op = Storage_Address
                    and then Watched (Code.Destination)
                    and then not Code.Indexed_Address
                  then
                     Carried (V) := Natural (Code.Destination.Slot);
                  end if;
                  Name_Except_Reads (Code);
               end;
            end loop;
            for P in 1 .. Held.Parameters.Count loop
               Mixed (Positive (Into.Parameters.Element
                 (Held.Parameters.First + P))) := True;
            end loop;
            for A in 1 .. Held.Aliases.Count loop
               declare
                  Place : constant Storage :=
                    Into.Aliases.Element (Held.Aliases.First + A).Info.Place;
               begin
                  if Place.Kind = Runtime_Address then
                     Mixed (Positive (Place.Address)) := True;
                  end if;
               end;
            end loop;
            for V in 1 .. Held.Values.Count loop
               declare
                  Code : constant Instruction :=
                    Code_Of (Into, Held, Value_Id (V));
               begin
                  if Code.Op = Store then
                     declare
                        Slot : constant Positive := Positive (Code.Slot);
                        Stored : constant Natural := Carried
                          (Positive (Operand (Into, Code, 1)));
                     begin
                        if Stored = 0
                          or else not Is_Address (Into, Item, Code.Slot)
                          or else Declares (Into, Item, Code.Slot)
                                    /= No_Declaration
                          or else Through (Slot) not in 0 | Stored
                        then
                           Mixed (Slot) := True;
                        end if;
                        if Stored /= 0 then
                           if Through (Slot) not in 0 | Stored then
                              Lost (Through (Slot)) := True;
                           end if;
                           Through (Slot) := Stored;
                        end if;
                     end;
                  end if;
               end;
            end loop;
            for Slot in 1 .. Held.Slots.Count loop
               if Mixed (Slot) and then Through (Slot) /= 0 then
                  Lost (Through (Slot)) := True;
                  Through (Slot) := 0;
               end if;
            end loop;

            for B in 1 .. Blocks loop
               for Position in 1 .. Length (Into, Item, Block_Id (B)) loop
                  declare
                     Value : constant Value_Id :=
                       Nth_Value (Into, Item, Block_Id (B), Position);
                     Code : constant Instruction :=
                       Code_Of (Into, Held, Value);
                  begin
                     --  A load of a saved carrier is the address again, and
                     --  so is an address formed through one.
                     if Code.Op = Load
                       and then Through (Positive (Code.Slot)) /= 0
                     then
                        Carried (Positive (Value)) :=
                          Through (Positive (Code.Slot));
                     elsif Code.Op = Storage_Address
                       and then Read_Through (Code) /= No_Slot
                       and then Through (Positive (Read_Through (Code))) /= 0
                     then
                        Carried (Positive (Value)) :=
                          Through (Positive (Read_Through (Code)));
                     end if;

                     --  A read through a saved carrier reads the parameter.
                     if Code.Op /= Storage_Address
                       and then Read_Through (Code) /= No_Slot
                       and then Through (Positive (Read_Through (Code))) /= 0
                     then
                        Read
                          (Slot_Id (Through (Positive (Read_Through (Code)))),
                           B, Position);
                     end if;

                     --  A parameter's address read by the call it is
                     --  passed to, kept in a saved carrier, or put
                     --  anywhere else.
                     for Index in 1 .. Code.Args loop
                        declare
                           Slot : constant Natural := Carried
                             (Positive (Operand (Into, Code, Index)));
                        begin
                           if Slot /= 0
                             and then Code.Op = Store
                             and then Through (Positive (Code.Slot)) = Slot
                           then
                              null;
                           elsif Slot /= 0 then
                              if By_Value (Into, Code, Index) then
                                 Read (Slot_Id (Slot), B, Position);
                              else
                                 Lost (Slot) := True;
                              end if;
                           end if;
                        end;
                     end loop;

                     case Code.Op is
                        when Load_Field | Load_Element =>
                           if Watched (Code.Slot) then
                              Read (Code.Slot, B, Position);
                           end if;
                        when Load_Variant_Tag | Load_Variant_Field =>
                           if Watched (Code.Source) then
                              Read (Code.Source.Slot, B, Position);
                           end if;
                        when Copy_Array | Copy_Variant =>
                           if Watched (Code.Source) then
                              Read (Code.Source.Slot, B, Position);
                           end if;
                           if Watched (Code.Destination) then
                              Lost (Positive (Code.Destination.Slot)) :=
                                True;
                           end if;
                        when Storage_Address =>
                           if Watched (Code.Destination)
                             and then Code.Indexed_Address
                           then
                              Lost (Positive (Code.Destination.Slot)) :=
                                True;
                           end if;
                        when Place_Address | Clear_Array | Fill_Array
                           | Select_Variant | Store_Variant_Field =>
                           if Watched (Code.Destination) then
                              Lost (Positive (Code.Destination.Slot)) :=
                                True;
                           end if;
                        when Load | Store | Store_Field | Store_Element =>
                           if Watched (Code.Slot) then
                              Lost (Positive (Code.Slot)) := True;
                           end if;
                        when others =>
                           null;
                     end case;
                  end;
               end loop;
            end loop;

            for Slot in 1 .. Held.Slots.Count loop
               if Candidate (Slot) and then not Lost (Slot) then
                  Chosen_Items.Append (Positive (Item));
                  Chosen_Slots.Append (Slot);
               end if;
            end loop;
         end;
      end Choose;

      --  Every reach of the chosen parameters goes through their address.
      --  A field or element operation names its slot whichever it is, and
      --  an address slot is what makes it a runtime address.
      procedure Rewrite (Item : Item_Id; First, Last : Positive) is
         Held : constant Item_Record := Into.Items.Element (Positive (Item));
         Marked : Flag_Vectors.Vector :=
           Flag_Vectors.To_Vector
             (False, Ada.Containers.Count_Type (Held.Slots.Count));

         function Chosen (Place : Storage) return Boolean
           is (Place.Kind = Frame_Slot
               and then Place.Slot /= No_Slot
               and then Marked (Positive (Place.Slot)));

         function Moved (Place : Storage) return Storage
           is (if Chosen (Place)
               then (Kind => Runtime_Address, Address => Place.Slot)
               else Place);
      begin
         for C in First .. Last loop
            Marked (Chosen_Slots (C)) := True;
         end loop;
         for V in 1 .. Held.Values.Count loop
            declare
               At_Code : constant Positive := Held.Values.First + V;
               Code : Instruction := Into.Code.Element (At_Code);
            begin
               if Code.Op in Copy_Array | Copy_Variant | Load_Variant_Tag
                            | Load_Variant_Field
                 and then Chosen (Code.Source)
               then
                  Code.Source := Moved (Code.Source);
                  Into.Code.Replace_Element (At_Code, Code);
               elsif Code.Op = Storage_Address
                 and then Chosen (Code.Destination)
               then
                  Code.Destination := Moved (Code.Destination);
                  Into.Code.Replace_Element (At_Code, Code);
               end if;
            end;
         end loop;
         for A in 1 .. Held.Aliases.Count loop
            declare
               Kept : Stored_Source_Alias :=
                 Into.Aliases.Element (Held.Aliases.First + A);
            begin
               if Chosen (Kept.Info.Place) then
                  Kept.Info.Place := Moved (Kept.Info.Place);
                  Into.Aliases.Replace_Element (Held.Aliases.First + A, Kept);
               end if;
            end;
         end loop;
      end Rewrite;

      --  Each chosen parameter keeps its identity, declaration and
      --  position, and becomes an address slot; its old shaped record,
      --  without a declaration, becomes a new last slot of its item.  An
      --  item's slots are one run, so the vector is laid out again.
      procedure Rehome is
         Slots : Slot_Vectors.Vector;
         Next : Positive := 1;
      begin
         Slots.Reserve_Capacity (Into.Slots.Length + Chosen_Slots.Length);
         for I in 1 .. Items loop
            declare
               Held : Item_Record := Into.Items.Element (I);
               Old : constant Landin.IR.Run := Held.Slots;
               Count : Natural := Old.Count;
            begin
               Held.Slots.First := Natural (Slots.Length);
               for S in 1 .. Old.Count loop
                  Slots.Append (Into.Slots.Element (Old.First + S));
               end loop;
               while Next <= Natural (Chosen_Items.Length)
                 and then Chosen_Items (Next) = I
               loop
                  declare
                     Slot : constant Positive := Chosen_Slots (Next);
                     Was : constant Slot_Record :=
                       Into.Slots.Element (Old.First + Slot);
                     Home : Slot_Record := Was;
                     Shape : Field_Shape;
                  begin
                     if Was.Aggregate then
                        declare
                           Parts : Field_Shape_Array (1 .. Was.Fields.Count);
                        begin
                           for F in Parts'Range loop
                              Parts (F) :=
                                Into.Slot_Fields.Element
                                  (Was.Fields.First + F);
                           end loop;
                           Shape :=
                             (Kind           => Aggregate_Field_Shape,
                              Element        => Landin.Types.Bool,
                              Length         => 1,
                              Cases          => Parts'Length,
                              Payloads_First => Add_Shape_Run (Into, Parts),
                              Nominal        => Was.Nominal,
                              others         => <>);
                        end;
                     else
                        Shape :=
                          (Kind           => Array_Field_Shape,
                           Element        => Was.Element.Element,
                           Length         => Was.Length,
                           Cases          =>
                             (if Was.Element_Run = 0 then 0 else 1),
                           Payloads_First => Was.Element_Run,
                           Nominal        => Was.Element.Nominal,
                           Slice_Element  => Was.Slice_Element,
                           others         => <>);
                     end if;
                     Count := Count + 1;
                     Home.Declaration := No_Declaration;
                     Slots.Append (Home);
                     Slots.Replace_Element
                       (Held.Slots.First + Slot,
                        Slot_Record'(Of_Type     => Landin.Types.Usize,
                                     Element     => Shape,
                                     Addressed   => True,
                                     Declaration => Was.Declaration,
                                     Site        => Was.Site,
                                     Home        => Slot_Id (Count),
                                     others      => <>));
                  end;
                  Next := Next + 1;
               end loop;
               Held.Slots.Count := Count;
               Into.Items.Replace_Element (I, Held);
            end;
         end loop;
         Into.Slots.Move (Slots);
      end Rehome;
   begin
      if Objective = Landin.Optimization.None then
         return;
      end if;
      declare
         Keep : Rewriting.Keep_Vectors.Vector :=
           Rewriting.Keep_Vectors.To_Vector (True, Into.Code.Length);
      begin
         for I in 1 .. Items loop
            if Has_Body (Item_Id (I)) then
               Forward (Into, Item_Id (I), Keep, Forwarded);
            end if;
         end loop;
         if Forwarded then
            Rewriting.Compact (Into, Keep);
         end if;
      end;
      Summarize;
      for I in 1 .. Items loop
         if Has_Body (Item_Id (I)) then
            Choose (Item_Id (I));
         end if;
      end loop;
      if Chosen_Items.Is_Empty then
         if Forwarded then
            Verifier.Verify (Into, Facts);
         end if;
         return;
      end if;
      declare
         First : Positive := 1;
      begin
         while First <= Natural (Chosen_Items.Length) loop
            declare
               Last : Positive := First;
            begin
               while Last < Natural (Chosen_Items.Length)
                 and then Chosen_Items (Last + 1) = Chosen_Items (First)
               loop
                  Last := Last + 1;
               end loop;
               Rewrite (Item_Id (Chosen_Items (First)), First, Last);
               First := Last + 1;
            end;
         end loop;
      end;
      Rehome;
      Verifier.Verify (Into, Facts);
   end Run_On_Verified;
end Landin.IR.In_Place;
