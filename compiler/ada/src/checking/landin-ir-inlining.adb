with Ada.Containers.Vectors;
with Landin.IR.Effects;
with Landin.IR.Verifier;
with Landin.Machine;
with Landin.Targets.Capabilities;

package body Landin.IR.Inlining is
   use type Landin.Machine.Convention;
   use type Landin.Machine.Placement;
   use type Landin.Optimization.Objective;
   use type Landin.Types.Magnitude;
   use type Landin.Targets.Capabilities.Backend_Kind;

   package Natural_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Natural);
   package Boolean_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Boolean);

   --  What a routine is as a body to copy, measured once.
   type Callee_Facts is record
      Eligible : Boolean := False;
      Weight : Natural := 0;
      Leaves, Fails : Natural := 0;
      --  The block of the routine's one `return`, when it has one.
      Exit_Block : Block_Id := No_Block;
   end record;
   package Callee_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Callee_Facts);

   --  How a call is replaced: not at all, by a copy whose returns rejoin
   --  the caller's block, or by a copy whose returns and failures take the
   --  two ways of the failure test that followed the call.
   type Expansion is (Kept, Plain, Failing);
   package Expansion_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Expansion);

   type Candidate is record
      Value : Value_Id := No_Value;
      Depth, Weight : Natural := 0;
      Kind : Expansion := Kept;
   end record;
   package Candidate_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Candidate);

   --  Calls inside loops first, then the cheapest, then in program order.
   function Before (Left, Right : Candidate) return Boolean is
     (Left.Depth > Right.Depth
      or else (Left.Depth = Right.Depth
               and then (Left.Weight < Right.Weight
                         or else (Left.Weight = Right.Weight
                                  and then Left.Value < Right.Value))));
   package Candidate_Order is new Candidate_Vectors.Generic_Sorting (Before);

   type Value_Array is array (Positive range <>) of Value_Id;

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
      Callees : Callee_Vectors.Vector;
      Plans : Expansion_Vectors.Vector;
      Changed : Boolean_Vectors.Vector;
      Exposed : Boolean_Vectors.Vector;
      Any : Boolean := False;

      function Held (Item : Item_Id) return Item_Record is
        (Into.Items.Element (Positive (Item)));

      function Global (Item : Item_Id; Value : Value_Id) return Positive is
        (Held (Item).Values.First + Positive (Value));

      function Code_At (Item : Item_Id; Value : Value_Id) return Instruction
        is (Into.Code.Element (Global (Item, Value)));

      function Slot_Record_Of
        (Item : Item_Id; Slot : Slot_Id) return Slot_Record
        is (Into.Slots.Element (Held (Item).Slots.First + Positive (Slot)));

      function Operand (Code : Instruction; Index : Positive) return Value_Id
        is (Into.Operands.Element (Code.First_Arg + Index));

      procedure Expose (Item : Item_Id);
      procedure Expose (Item : Item_Id) is
      begin
         Exposed (Positive (Item)) := True;
      end Expose;

      --  Whether lowering's by-value aggregate transport is what reached
      --  this parameter: an address of storage, a carrier kept in an
      --  address slot, or D97's zero.
      function Is_Carrier (Item : Item_Id; Code : Instruction) return Boolean
        is ((Code.Op = Storage_Address and then Code.Args = 0
             and then Code.Destination.Kind /= Runtime_Address)
            or else (Code.Op = Number and then Code.Number = 0
                     and then Code.Result = Landin.Types.Usize)
            or else (Code.Op = Load
                     and then Slot_Record_Of (Item, Code.Slot).Addressed));

      --  What may be stored into an address slot (the verifier's rule).
      function Is_Address_Value
        (Item : Item_Id; Code : Instruction) return Boolean
        is (Code.Op in Place_Address | Storage_Address | Pointer_Address
                     | Slice_Address
            or else (Code.Op = Load
                     and then Slot_Record_Of (Item, Code.Slot).Addressed));

      --  An aggregate or array result, which the call hands the routine
      --  storage for as its first argument and the routine copies into on
      --  its way out.
      function Stores_Result (Callee : Item_Id) return Boolean is
        (Held (Callee).Result in Landin.Types.Aggregate
                               | Landin.Types.Fixed_Array);

      function Is_Constant (Code : Instruction) return Boolean is
        (Code.Op in Number | Truth | Atom);

      --  A value that may wait in a slot across a copied body, or be made
      --  again after it: a scalar whose consumers do not ask what produced
      --  it.  Addresses and evidence projections stay beside their users.
      function Crosses (Item : Item_Id; Code : Instruction) return Boolean is
        (Is_Constant (Code)
         or else
           (Code.Result in Landin.Types.Scalar_Name
            and then
              (Code.Op in Load_Datum | Load_Field | Load_Element
                        | Load_Indirect | Load_Variant_Tag
                        | Load_Variant_Field | Conversion | Range_Check
                        | Measurement_Kind | Unary_Kind
                        | Binary_Kind | Failure_Test | Call | Indirect_Call
               or else (Code.Op = Load
                        and then not Slot_Record_Of
                          (Item, Code.Slot).Addressed))));

      --  An address slot that reaches Shape, as lowering makes one.
      function Address_Slot
        (Shape : Field_Shape; Site : Landin.Provenance.Origin)
         return Slot_Record
        is ((Of_Type => Landin.Types.Usize, Element => Shape,
             Addressed => True, Site => Site, others => <>));

      --  The neutral shape of a routine's aggregate slot, as In_Place
      --  gives one to its home.
      function Aggregate_Shape
        (Item : Item_Id; Slot : Slot_Id) return Field_Shape;
      function Aggregate_Shape
        (Item : Item_Id; Slot : Slot_Id) return Field_Shape
      is
         Was : constant Slot_Record := Slot_Record_Of (Item, Slot);
         Parts : Field_Shape_Array (1 .. Was.Fields.Count);
      begin
         for F in Parts'Range loop
            Parts (F) := Into.Slot_Fields.Element (Was.Fields.First + F);
         end loop;
         return
           (Kind           => Aggregate_Field_Shape,
            Element        => Landin.Types.Bool,
            Length         => 1,
            Cases          => Parts'Length,
            Payloads_First => Add_Shape_Run (Into, Parts),
            Nominal        => Was.Nominal,
            others         => <>);
      end Aggregate_Shape;

      --  Whether a routine only reads a by-value parameter: no store,
      --  clear, fill or selection writes it and no `addr` is taken of it.
      --  Its storage address may still go to a call or under a slice.
      function Read_Only (Callee : Item_Id; Slot : Slot_Id) return Boolean;
      function Read_Only (Callee : Item_Id; Slot : Slot_Id) return Boolean is
         Body_Of : constant Item_Record := Held (Callee);
      begin
         for V in 1 .. Body_Of.Values.Count loop
            declare
               Code : constant Instruction :=
                 Into.Code.Element (Body_Of.Values.First + V);
               Names : constant Boolean :=
                 Code.Destination.Kind = Frame_Slot
                 and then Code.Destination.Slot = Slot;
            begin
               if (Code.Op = Place_Address and then Names)
                 or else (Code.Op in Store | Store_Field | Store_Element
                          and then Code.Slot = Slot)
                 or else (Code.Op in Copy_Array | Copy_Variant | Clear_Array
                                   | Fill_Array | Select_Variant
                                   | Store_Variant_Field
                          and then Names)
               then
                  return False;
               end if;
            end;
         end loop;
         return True;
      end Read_Only;

      --  The caller's slots something could write while a copy runs.  A
      --  frame slot is written from outside its own instructions only
      --  through an address of it, and an address that only reaches calls,
      --  directly or through address slots whose loads only reach calls,
      --  in positions whose parameters do not escape, is gone when each of
      --  those calls returns: [1730]'s origins keep a routine from keeping
      --  an address it was not given to keep.  An `addr` kept in a
      --  variable, a slice over the slot or any other use of its address
      --  lets a copy, or a call the copy makes, write it.  A call that is
      --  itself copied is checked for its own arguments separately.
      function Escaping (Caller : Item_Id) return Boolean_Vectors.Vector;
      function Escaping (Caller : Item_Id) return Boolean_Vectors.Vector is
         Own : constant Item_Record := Held (Caller);
         Count : constant Ada.Containers.Count_Type :=
           Ada.Containers.Count_Type (Own.Values.Count);
         --  A value used other than as a call's argument or as what an
         --  address slot is given.
         Spread : Boolean_Vectors.Vector :=
           Boolean_Vectors.To_Vector (False, Count);
         Leaks : Boolean_Vectors.Vector := Boolean_Vectors.To_Vector
           (False, Ada.Containers.Count_Type (Own.Slots.Count));
         Result : Boolean_Vectors.Vector := Boolean_Vectors.To_Vector
           (False, Ada.Containers.Count_Type (Own.Slots.Count));

         function Code (V : Positive) return Instruction is
           (Into.Code.Element (Own.Values.First + V));
      begin
         for V in 1 .. Own.Values.Count loop
            declare
               User : constant Instruction := Code (V);
            begin
               if User.Op in Call | Indirect_Call then
                  declare
                     Hidden : constant Natural :=
                       (if Signature_Result_Count (Into, User.Signature) > 1
                          or else
                            (Signature_Result_Count (Into, User.Signature) = 1
                             and then Signature_Result
                               (Into, User.Signature).Kind
                                 in Landin.Types.Aggregate
                                  | Landin.Types.Fixed_Array)
                        then 1 else 0);
                     --  An indirect call's first operand is its callee.
                     Skip : constant Natural :=
                       (if User.Op = Indirect_Call then 1 else 0);
                  begin
                     for A in 1 + Skip .. User.Args loop
                        if A - Skip > Hidden
                          and then
                            (A - Skip - Hidden
                               > Signature_Parameter_Count
                                   (Into, User.Signature)
                             or else Nth_Signature_Parameter
                               (Into, User.Signature,
                                A - Skip - Hidden).Escaping)
                        then
                           Spread.Replace_Element
                             (Positive (Operand (User, A)), True);
                        end if;
                     end loop;
                     if Skip = 1 then
                        Spread.Replace_Element
                          (Positive (Operand (User, 1)), True);
                     end if;
                  end;
               elsif not (User.Op = Store
                          and then Slot_Record_Of
                            (Caller, User.Slot).Addressed)
               then
                  for A in 1 .. User.Args loop
                     Spread.Replace_Element
                       (Positive (Operand (User, A)), True);
                  end loop;
               end if;
            end;
         end loop;
         for V in 1 .. Own.Values.Count loop
            if Code (V).Op = Load and then Spread.Element (V)
              and then Slot_Record_Of (Caller, Code (V).Slot).Addressed
            then
               Leaks.Replace_Element (Positive (Code (V).Slot), True);
            end if;
         end loop;
         for V in 1 .. Own.Values.Count loop
            declare
               User : constant Instruction := Code (V);
            begin
               if User.Op = Store
                 and then Slot_Record_Of (Caller, User.Slot).Addressed
                 and then Leaks.Element (Positive (User.Slot))
               then
                  Spread.Replace_Element (Positive (Operand (User, 1)), True);
               end if;
            end;
         end loop;
         for V in 1 .. Own.Values.Count loop
            declare
               Made : constant Instruction := Code (V);
            begin
               if Made.Op in Place_Address | Storage_Address
                 and then Made.Destination.Kind = Frame_Slot
                 and then (Made.Op = Place_Address or else Spread.Element (V))
               then
                  Result.Replace_Element
                    (Positive (Made.Destination.Slot), True);
               end if;
            end;
         end loop;
         return Result;
      end Escaping;

      --  For each of the caller's address slots, the frame slot whose
      --  address it is given, zero for none and Many for more than one or
      --  an address of unknown origin.
      Many : constant Natural := Natural'Last;

      function Holders (Caller : Item_Id) return Natural_Vectors.Vector;
      function Holders (Caller : Item_Id) return Natural_Vectors.Vector is
         Own : constant Item_Record := Held (Caller);
         Result : Natural_Vectors.Vector := Natural_Vectors.To_Vector
           (0, Ada.Containers.Count_Type (Own.Slots.Count));
      begin
         for V in 1 .. Own.Values.Count loop
            declare
               User : constant Instruction :=
                 Into.Code.Element (Own.Values.First + V);
            begin
               if User.Op = Store
                 and then Slot_Record_Of (Caller, User.Slot).Addressed
               then
                  declare
                     Given : constant Instruction :=
                       Code_At (Caller, Operand (User, 1));
                     Named : constant Natural :=
                       (if Given.Op in Place_Address | Storage_Address
                          and then Given.Destination.Kind = Frame_Slot
                        then Natural (Given.Destination.Slot) else Many);
                     Was : constant Natural :=
                       Result.Element (Positive (User.Slot));
                  begin
                     Result.Replace_Element
                       (Positive (User.Slot),
                        (if Was = 0 or else Was = Named then Named
                         else Many));
                  end;
               end if;
            end;
         end loop;
         return Result;
      end Holders;

      procedure Measure (Callee : Item_Id);
      procedure Measure (Callee : Item_Id) is
         Body_Of : constant Item_Record := Held (Callee);
         Signature : constant Signature_Id := Body_Of.Signature;
         Found : Callee_Facts;
      begin
         if Body_Of.Kind /= Routine or else Body_Of.External
           or else Body_Of.Blocks.Count = 0
           or else Body_Of.Inlines.Count /= 0
           or else Exposed (Positive (Callee))
           or else not Holds (Into, Signature)
           or else Signature_Uses_C_ABI (Into, Signature)
           or else Signature_Machine (Into, Signature)
             /= Landin.Machine.Ordinary
           or else Signature_Is_Variadic (Into, Signature)
           or else Signature_Never_Returns (Into, Signature)
           or else Signature_Has_Erased_Self (Into, Signature)
           or else not (Body_Of.Result in Landin.Types.Scalar_Name
                        or else Body_Of.Result in Landin.Types.No_Value
                                               | Landin.Types.Aggregate
                                               | Landin.Types.Fixed_Array)
           or else Body_Of.Placement /= Landin.Machine.Placement'(others => <>)
         then
            return;
         end if;
         for Index in 1 .. Signature_Parameter_Count (Into, Signature) loop
            if Nth_Signature_Parameter (Into, Signature, Index).Convention
              = Sink_Value
            then
               return;
            end if;
         end loop;
         for S in 1 .. Body_Of.Slots.Count loop
            if Into.Slots.Element (Body_Of.Slots.First + S).Home /= No_Slot
            then
               return;
            end if;
         end loop;
         --  A whole aggregate is copied between two addresses, and an
         --  address names a nominal shape; D128's anonymous results have
         --  none, and their routines stay calls.
         for S in 1 .. Body_Of.Slots.Count loop
            declare
               Slot : constant Slot_Record :=
                 Into.Slots.Element (Body_Of.Slots.First + S);
            begin
               if Slot.Aggregate and then Slot.Nominal = No_Nominal_Type
                 and then (Slot_Id (S) = Body_Of.Returns_To
                           or else (for some P in 1 .. Body_Of.Parameters.Count
                                      => Into.Parameters.Element
                                           (Body_Of.Parameters.First + P)
                                         = Slot_Id (S)))
               then
                  return;
               end if;
            end;
         end loop;
         for V in 1 .. Body_Of.Values.Count loop
            declare
               Code : constant Instruction :=
                 Into.Code.Element (Body_Of.Values.First + V);
            begin
               if Code.Op = Assembly then
                  return;
               end if;
               Found.Weight := Found.Weight + Effects.Weight (Code.Op);
               if Found.Weight > Body_Bound then
                  return;
               end if;
               if Code.Op = Leave then
                  Found.Leaves := Found.Leaves + 1;
                  Found.Exit_Block := Code.In_Block;
               elsif Code.Op = Fail then
                  Found.Fails := Found.Fails + 1;
               end if;
            end;
         end loop;
         Found.Eligible := Found.Leaves > 0;
         Callees.Replace_Element (Positive (Callee), Found);
      end Measure;

      --  Choose the calls of one caller to copy.
      procedure Plan (Caller : Item_Id);
      procedure Plan (Caller : Item_Id) is
         Own : constant Item_Record := Held (Caller);
         Count : constant Ada.Containers.Count_Type :=
           Ada.Containers.Count_Type (Own.Values.Count);
         Last_Use : Natural_Vectors.Vector :=
           Natural_Vectors.To_Vector (0, Count);
         Uses : Natural_Vectors.Vector := Natural_Vectors.To_Vector (0, Count);
         Slot_Uses : Natural_Vectors.Vector := Natural_Vectors.To_Vector
           (0, Ada.Containers.Count_Type (Own.Slots.Count));
         Entries : Natural_Vectors.Vector := Natural_Vectors.To_Vector
           (0, Ada.Containers.Count_Type (Own.Blocks.Count));
         Found : Candidate_Vectors.Vector;
         Weight : Natural := 0;

         procedure Note_Slot (Slot : Slot_Id);
         procedure Note_Slot (Slot : Slot_Id) is
         begin
            if Slot /= No_Slot then
               Slot_Uses.Replace_Element
                 (Positive (Slot), Slot_Uses.Element (Positive (Slot)) + 1);
            end if;
         end Note_Slot;

         procedure Note_Storage (Place : Storage);
         procedure Note_Storage (Place : Storage) is
         begin
            case Place.Kind is
               when Frame_Slot => Note_Slot (Place.Slot);
               when Runtime_Address => Note_Slot (Place.Address);
               when Module_Datum => null;
            end case;
         end Note_Storage;

         --  Lowering's failure test after a call that can fail, and nothing
         --  else reading the call's status: the call's value only stored,
         --  the status loaded once for the test and otherwise only in the
         --  failing block, which nothing else enters.  The call stores its
         --  value on both ways, a failure's being the result it never set,
         --  where a copy stores one only on success; so the slot it goes to
         --  must be a temporary read once, on the succeeding way: in its
         --  block or in one only it leads to, through jumps.
         function Failure_Test_Follows
           (Block : Block_Record; Position : Positive; Call : Value_Id;
            Code : Instruction) return Boolean;
         function Failure_Test_Follows
           (Block : Block_Record; Position : Positive; Call : Value_Id;
            Code : Instruction) return Boolean
         is
            At_Value : Natural := Position + 1;
            Status : constant Slot_Id := Code.Slot;
            Stored : Boolean := False;

            function Nth (P : Positive) return Instruction is
              (Into.Code.Element (Block.First_Value + P));
            function Id (P : Positive) return Value_Id is
              (Value_Id (Block.First_Value + P - Own.Values.First));
         begin
            if Status = No_Slot then
               return False;
            end if;
            if At_Value <= Block.Values and then Nth (At_Value).Op = Store
              and then Nth (At_Value).Args = 1
              and then Operand (Nth (At_Value), 1) = Call
            then
               Stored := True;
               At_Value := At_Value + 1;
            end if;
            if Uses.Element (Positive (Call)) /= (if Stored then 1 else 0)
              or else At_Value + 2 /= Block.Values
              or else Nth (At_Value).Op /= Load
              or else Nth (At_Value).Slot /= Status
              or else Nth (At_Value + 1).Op /= Failure_Test
              or else Operand (Nth (At_Value + 1), 1) /= Id (At_Value)
              or else Nth (At_Value + 2).Op /= Branch
              or else Operand (Nth (At_Value + 2), 1) /= Id (At_Value + 1)
            then
               return False;
            end if;
            declare
               Failed : constant Block_Id := Nth (At_Value + 2).Target;
               Failing : constant Block_Record := Into.Blocks.Element
                 (Own.Blocks.First + Positive (Failed));
               Loads : Natural := 0;
            begin
               if Entries.Element (Positive (Failed)) /= 1
                 or else Nth (At_Value + 2).Alternative = Failed
               then
                  return False;
               end if;
               for P in 1 .. Failing.Values loop
                  declare
                     Inside : constant Instruction :=
                       Into.Code.Element (Failing.First_Value + P);
                  begin
                     if Inside.Op = Load and then Inside.Slot = Status then
                        Loads := Loads + 1;
                     end if;
                  end;
               end loop;
               if Stored then
                  declare
                     Kept : constant Slot_Id := Nth (Position + 1).Slot;
                     Next : Block_Id := Nth (At_Value + 2).Alternative;
                     Read_There : Boolean := False;
                  begin
                     if Slot_Uses.Element (Positive (Kept)) /= 2
                       or else Slot_Record_Of (Caller, Kept).Declaration
                                 /= No_Declaration
                     then
                        return False;
                     end if;
                     for Hop in 1 .. 8 loop
                        exit when Entries.Element (Positive (Next)) /= 1;
                        declare
                           Succeeding : constant Block_Record :=
                             Into.Blocks.Element
                               (Own.Blocks.First + Positive (Next));
                           Last : constant Instruction := Into.Code.Element
                             (Succeeding.First_Value + Succeeding.Values);
                        begin
                           for P in 1 .. Succeeding.Values loop
                              declare
                                 Inside : constant Instruction :=
                                   Into.Code.Element
                                     (Succeeding.First_Value + P);
                              begin
                                 Read_There := Read_There
                                   or else (Inside.Op = Load
                                            and then Inside.Slot = Kept);
                              end;
                           end loop;
                           exit when Read_There or else Last.Op /= Jump;
                           Next := Last.Target;
                        end;
                     end loop;
                     if not Read_There then
                        return False;
                     end if;
                  end;
               end if;
               return Slot_Uses.Element (Positive (Status)) = 2 + Loads;
            end;
         end Failure_Test_Follows;
      begin
         for V in 1 .. Own.Values.Count loop
            declare
               Code : constant Instruction :=
                 Into.Code.Element (Own.Values.First + V);
            begin
               Weight := Weight + Effects.Weight (Code.Op);
               for A in 1 .. Code.Args loop
                  declare
                     Used : constant Positive := Positive (Operand (Code, A));
                  begin
                     Uses.Replace_Element (Used, Uses.Element (Used) + 1);
                  end;
               end loop;
               Note_Slot (Code.Slot);
               Note_Storage (Code.Source);
               Note_Storage (Code.Destination);
               for A in 1 .. Code.Assembly_Run.Count loop
                  Note_Slot (Into.Assembly_Operands.Element
                    (Code.Assembly_Run.First + A).Output);
               end loop;
               if Code.Op in Jump | Branch then
                  Entries.Replace_Element
                    (Positive (Code.Target),
                     Entries.Element (Positive (Code.Target)) + 1);
                  if Code.Op = Branch then
                     Entries.Replace_Element
                       (Positive (Code.Alternative),
                        Entries.Element (Positive (Code.Alternative)) + 1);
                  end if;
               end if;
            end;
         end loop;
         for B in 1 .. Own.Blocks.Count loop
            declare
               Block : constant Block_Record :=
                 Into.Blocks.Element (Own.Blocks.First + B);
               --  The furthest use of a value that cannot cross a copy,
               --  among the values above the current position.
               Stranded : Natural := 0;
            begin
               for P in 1 .. Block.Values loop
                  declare
                     Code : constant Instruction :=
                       Into.Code.Element (Block.First_Value + P);
                  begin
                     for A in 1 .. Code.Args loop
                        Last_Use.Replace_Element
                          (Positive (Operand (Code, A)), P);
                     end loop;
                  end;
               end loop;
               for P in 1 .. Block.Values loop
                  declare
                     V : constant Value_Id :=
                       Value_Id (Block.First_Value + P - Own.Values.First);
                     Code : constant Instruction :=
                       Into.Code.Element (Block.First_Value + P);
                     Callee : constant Item_Id := Code.Named;
                     Kind : Expansion := Kept;
                  begin
                     if Code.Op = Call and then Callee /= Caller
                       and then Callees.Element (Positive (Callee)).Eligible
                       and then Code.Args = Held (Callee).Parameters.Count
                     then
                        Kind := Plain;
                        for A in 1 .. Code.Args loop
                           declare
                              Parameter : constant Slot_Record :=
                                Slot_Record_Of
                                  (Callee,
                                   Into.Parameters.Element
                                     (Held (Callee).Parameters.First + A));
                              Given : constant Instruction :=
                                Code_At (Caller, Operand (Code, A));
                           begin
                              if A = 1 and then Stores_Result (Callee) then
                                 --  The caller's storage for the result.
                                 if not (Is_Carrier (Caller, Given)
                                         and then Given.Op /= Number)
                                 then
                                    Kind := Kept;
                                 end if;
                              elsif Parameter.Addressed then
                                 if not Is_Address_Value (Caller, Given) then
                                    Kind := Kept;
                                 end if;
                              elsif (Parameter.Aggregate
                                     or else Parameter.Array_Shape)
                                and then not Is_Carrier (Caller, Given)
                              then
                                 Kind := Kept;
                              end if;
                           end;
                        end loop;
                        if Kind /= Kept then
                           if Signature_Errors
                               (Into, Held (Callee).Signature) /= No_Atom_Set
                           then
                              Kind :=
                                (if Callees.Element (Positive (Callee)).Fails
                                      > 0
                                   and then Failure_Test_Follows
                                     (Block, P, V, Code)
                                 then Failing else Kept);
                           elsif Stranded > P then
                              Kind := Kept;
                           end if;
                        end if;
                        if Kind /= Kept then
                           Found.Append
                             (Candidate'(Value => V, Depth => Code.Call_Depth,
                               Weight =>
                                 Callees.Element (Positive (Callee)).Weight,
                               Kind => Kind));
                        end if;
                     end if;
                     if not Crosses (Caller, Code) then
                        Stranded := Natural'Max
                          (Stranded, Last_Use.Element (Positive (V)));
                     end if;
                  end;
               end loop;
            end;
         end loop;
         if Found.Is_Empty then
            return;
         end if;
         Candidate_Order.Sort (Found);
         declare
            Budget : Natural := Natural'Max (Growth_Floor, Weight);
         begin
            for Chosen of Found loop
               if Chosen.Weight <= Budget then
                  Budget := Budget - Chosen.Weight;
                  Plans.Replace_Element
                    (Global (Caller, Chosen.Value), Chosen.Kind);
                  Changed.Replace_Element (Positive (Caller), True);
                  Any := True;
               end if;
            end loop;
         end;
      end Plan;

      New_Items : Item_Vectors.Vector;
      New_Slots : Slot_Vectors.Vector;
      New_Blocks : Block_Vectors.Vector;
      New_Code : Code_Vectors.Vector;
      New_Args : Value_Ref_Vectors.Vector;
      New_Aliases : Source_Alias_Vectors.Vector;
      New_Sites : Inline_Site_Vectors.Vector;

      --  An item nothing is copied into keeps every identity.
      procedure Keep_Item (Item : Item_Id);
      procedure Keep_Item (Item : Item_Id) is
         Old : constant Item_Record := Held (Item);
         Now : Item_Record := Old;
      begin
         Now.Slots.First := Natural (New_Slots.Length);
         for S in 1 .. Old.Slots.Count loop
            New_Slots.Append (Into.Slots.Element (Old.Slots.First + S));
         end loop;
         Now.Aliases.First := Natural (New_Aliases.Length);
         for A in 1 .. Old.Aliases.Count loop
            New_Aliases.Append (Into.Aliases.Element (Old.Aliases.First + A));
         end loop;
         Now.Inlines.First := Natural (New_Sites.Length);
         for S in 1 .. Old.Inlines.Count loop
            New_Sites.Append
              (Into.Inline_Sites.Element (Old.Inlines.First + S));
         end loop;
         Now.Values.First := Natural (New_Code.Length);
         Now.Blocks.First := Natural (New_Blocks.Length);
         for B in 1 .. Old.Blocks.Count loop
            declare
               Block : Block_Record :=
                 Into.Blocks.Element (Old.Blocks.First + B);
            begin
               Block.First_Value :=
                 Block.First_Value - Old.Values.First + Now.Values.First;
               New_Blocks.Append (Block);
            end;
         end loop;
         for V in 1 .. Old.Values.Count loop
            declare
               Code : Instruction := Into.Code.Element (Old.Values.First + V);
            begin
               for A in 1 .. Code.Args loop
                  New_Args.Append (Operand (Code, A));
               end loop;
               Code.First_Arg := Natural (New_Args.Length) - Code.Args;
               New_Code.Append (Code);
            end;
         end loop;
         New_Items.Append (Now);
      end Keep_Item;

      --  The item with its chosen calls replaced.  Blocks are numbered in
      --  the order they are written, which is the order a backend lays them
      --  out: each copy right after the block that enters it, the routine's
      --  one return last, and the rest of the caller's block right after.
      procedure Expand_Item (Caller : Item_Id);
      procedure Expand_Item (Caller : Item_Id) is
         Old : constant Item_Record := Held (Caller);
         Now : Item_Record := Old;
         Values : constant Ada.Containers.Count_Type :=
           Ada.Containers.Count_Type (Old.Values.Count);
         --  Per original value of the caller: its value in the block being
         --  written, valid in segment Seen; the slot it waits in across a
         --  copy; whether it is a constant made again instead.
         Map : Value_Ref_Vectors.Vector :=
           Value_Ref_Vectors.To_Vector (No_Value, Values);
         Seen : Natural_Vectors.Vector :=
           Natural_Vectors.To_Vector (0, Values);
         Waits : Slot_Ref_Vectors.Vector :=
           Slot_Ref_Vectors.To_Vector (No_Slot, Values);
         Remade : Boolean_Vectors.Vector :=
           Boolean_Vectors.To_Vector (False, Values);
         Last_Use : Natural_Vectors.Vector :=
           Natural_Vectors.To_Vector (0, Values);
         First_Of : Natural_Vectors.Vector := Natural_Vectors.To_Vector
           (0, Ada.Containers.Count_Type (Old.Blocks.Count));
         Open_Values : Value_Ref_Vectors.Vector;
         --  A caller value no instruction will use: a by-value address only
         --  a copied call took, whose copy names the storage instead.
         Dropped : Boolean_Vectors.Vector :=
           Boolean_Vectors.To_Vector (False, Values);
         Uses : Natural_Vectors.Vector :=
           Natural_Vectors.To_Vector (0, Values);
         Escapes : constant Boolean_Vectors.Vector := Escaping (Caller);
         Holding : constant Natural_Vectors.Vector := Holders (Caller);

         function Holds_Place_Of (Address, Slot : Slot_Id) return Boolean is
           (Holding.Element (Positive (Address)) in Natural (Slot) | Many);

         --  Whether a call is handed Slot's address in any argument but the
         --  one at Except other than a by-value carrier: then its copy could
         --  write the slot, through that argument, while it reads it.
         function Also_Given
           (Code : Instruction; Slot : Slot_Id; Except : Positive)
            return Boolean is
           (for some A in 1 .. Code.Args =>
              A /= Except and then
              (declare
                 Given : constant Instruction :=
                   Code_At (Caller, Operand (Code, A));
               begin
                 (Given.Op = Place_Address
                  and then Given.Destination.Kind = Frame_Slot
                  and then Given.Destination.Slot = Slot)
                 or else (Given.Op = Load
                          and then Slot_Record_Of
                            (Caller, Given.Slot).Addressed
                          and then Holds_Place_Of (Given.Slot, Slot))));

         --  A by-value aggregate the routine only reads, given by the
         --  address of a caller slot nothing can write while the copy runs,
         --  is read there, as Landin.IR.In_Place would have the routine read
         --  it: the copy's reads see the bytes the routine's own copy would
         --  have held.  This is that slot for the call's A'th argument, or
         --  No_Slot.  The slot is an address slot when the call was handed
         --  the address lowering kept in it, an address of part of one slot
         --  nothing can write, and nothing stored to it before the call.
         function Read_There (Call : Value_Id; A : Positive)
            return Slot_Id;
         function Read_There (Call : Value_Id; A : Positive)
            return Slot_Id
         is
            Code : constant Instruction := Code_At (Caller, Call);
            Parameter : constant Slot_Id := Into.Parameters.Element
              (Held (Code.Named).Parameters.First + A);
            Shaped : constant Slot_Record :=
              Slot_Record_Of (Code.Named, Parameter);
            Given : constant Value_Id := Operand (Code, A);
            Producer : constant Instruction := Code_At (Caller, Given);
         begin
            if not (Shaped.Aggregate or else Shaped.Array_Shape)
              or else Shaped.Addressed
              or else (A = 1 and then Stores_Result (Code.Named))
              or else not Read_Only (Code.Named, Parameter)
            then
               return No_Slot;
            elsif Producer.Op = Storage_Address
              and then Producer.Destination.Kind = Frame_Slot
              and then Producer.Element_Field = 0
              and then Producer.Nested.Count = 0
              and then not Escapes.Element
                (Positive (Producer.Destination.Slot))
              and then not Also_Given (Code, Producer.Destination.Slot, A)
            then
               return Producer.Destination.Slot;
            elsif Producer.Op = Load
              and then Slot_Record_Of (Caller, Producer.Slot).Addressed
              and then Producer.In_Block = Code.In_Block
              and then Holding.Element (Positive (Producer.Slot)) not in 0
                                                                      | Many
              and then not Escapes.Element
                (Holding.Element (Positive (Producer.Slot)))
              and then not Also_Given
                (Code, Slot_Id (Holding.Element (Positive (Producer.Slot))),
                 A)
              and then
                (for all V in Given + 1 .. Call - 1 =>
                   not (Code_At (Caller, V).Op = Store
                        and then Code_At (Caller, V).Slot = Producer.Slot))
            then
               return Producer.Slot;
            end if;
            return No_Slot;
         end Read_There;

         --  Whether the copy of a call names its A'th argument's storage
         --  itself, so that the address the call was handed has no other
         --  use: an argument read in place, an array copied from where it
         --  is, an array result copied to where it goes.  Such an address
         --  is not formed; Landin.IR.In_Place would read one as a use.
         function Names_Storage (Call : Value_Id; A : Positive)
            return Boolean;
         function Names_Storage (Call : Value_Id; A : Positive)
            return Boolean
         is
            Code : constant Instruction := Code_At (Caller, Call);
            Producer : constant Instruction :=
              Code_At (Caller, Operand (Code, A));
            Shaped : constant Slot_Record :=
              Slot_Record_Of
                (Code.Named,
                 Into.Parameters.Element
                   (Held (Code.Named).Parameters.First + A));
         begin
            if Producer.Op = Load then
               return Read_There (Call, A) /= No_Slot;
            elsif Producer.Op /= Storage_Address or else Producer.Args /= 0
              or else Producer.Destination.Kind = Runtime_Address
            then
               return False;
            elsif A = 1 and then Stores_Result (Code.Named) then
               return not Slot_Record_Of
                 (Code.Named, Held (Code.Named).Returns_To).Aggregate;
            else
               return Read_There (Call, A) /= No_Slot
                 or else (Shaped.Array_Shape and then not Shaped.Addressed);
            end if;
         end Names_Storage;
         Segment : Natural := 0;
         Current : Block_Id := No_Block;
         Next_Block : Natural := 0;
         Block_Total : Natural := 0;
         Site_Count : Natural := Old.Inlines.Count;

         function New_Id (Block : Block_Id) return Block_Id is
           (Block_Id (First_Of.Element (Positive (Block))));

         function Slot_Count_Now return Natural is
           (Natural (New_Slots.Length) - Now.Slots.First);

         procedure Open
           (Block : Block_Id; Scope : Scope_Id;
            Site : Landin.Provenance.Origin; Inlined : Natural);
         procedure Open
           (Block : Block_Id; Scope : Scope_Id;
            Site : Landin.Provenance.Origin; Inlined : Natural) is
         begin
            if Natural (Block) /= Next_Block + 1 then
               raise Landin.Compiler_Defect with "inlined blocks out of order";
            end if;
            Next_Block := Natural (Block);
            Current := Block;
            Segment := Segment + 1;
            New_Blocks.Replace_Element
              (Now.Blocks.First + Positive (Block),
               (Scope => Scope, Site => Site,
                First_Value => Natural (New_Code.Length), Values => 0,
                Inlined => Inlined));
         end Open;

         function Put
           (Code : Instruction; Operands : Value_Array) return Value_Id;
         function Put
           (Code : Instruction; Operands : Value_Array) return Value_Id
         is
            Made : Instruction := Code;
            At_Block : constant Positive :=
              Now.Blocks.First + Positive (Current);
            Block : Block_Record := New_Blocks.Element (At_Block);
         begin
            Made.In_Block := Current;
            Made.First_Arg := Natural (New_Args.Length);
            Made.Args := Operands'Length;
            for Operand_Value of Operands loop
               New_Args.Append (Operand_Value);
            end loop;
            New_Code.Append (Made);
            Block.Values := Block.Values + 1;
            New_Blocks.Replace_Element (At_Block, Block);
            return Value_Id (Natural (New_Code.Length) - Now.Values.First);
         end Put;

         procedure Put (Code : Instruction; Operands : Value_Array);
         procedure Put (Code : Instruction; Operands : Value_Array) is
            Ignored : constant Value_Id := Put (Code, Operands);
         begin
            pragma Unreferenced (Ignored);
         end Put;

         function New_Slot (Made : Slot_Record) return Slot_Id;
         function New_Slot (Made : Slot_Record) return Slot_Id is
         begin
            New_Slots.Append (Made);
            return Slot_Id (Slot_Count_Now);
         end New_Slot;

         function Load_Of
           (Slot : Slot_Id; Site : Landin.Provenance.Origin)
            return Value_Id;
         function Load_Of
           (Slot : Slot_Id; Site : Landin.Provenance.Origin)
            return Value_Id
         is
            Record_Of : constant Slot_Record :=
              New_Slots.Element (Now.Slots.First + Positive (Slot));
         begin
            return Put
              ((Op => Load, Result => Record_Of.Of_Type, Site => Site,
                Slot => Slot, Pointee => Record_Of.Pointee,
                Signature => Record_Of.Signature,
                Atom_Set => Record_Of.Atom_Set, others => <>),
               []);
         end Load_Of;

         procedure Store_Of
           (Slot : Slot_Id; Value : Value_Id;
            Site : Landin.Provenance.Origin);
         procedure Store_Of
           (Slot : Slot_Id; Value : Value_Id;
            Site : Landin.Provenance.Origin) is
         begin
            Put ((Op => Store, Site => Site, Slot => Slot, others => <>),
                 [Value]);
         end Store_Of;

         procedure Jump_To
           (Target : Block_Id; Site : Landin.Provenance.Origin);
         procedure Jump_To
           (Target : Block_Id; Site : Landin.Provenance.Origin) is
         begin
            Put ((Op => Jump, Site => Site, Target => Target, others => <>),
                 []);
         end Jump_To;

         --  A caller value where the block being written can use it.
         function Resolve
           (Value : Value_Id; Site : Landin.Provenance.Origin)
            return Value_Id;
         function Resolve
           (Value : Value_Id; Site : Landin.Provenance.Origin)
            return Value_Id
         is
            Index : constant Positive := Positive (Value);
            Made : Value_Id;
         begin
            if Seen.Element (Index) = Segment then
               return Map.Element (Index);
            elsif Remade.Element (Index) then
               declare
                  Again : Instruction := Code_At (Caller, Value);
               begin
                  Again.Site := Site;
                  Made := Put (Again, []);
               end;
            elsif Waits.Element (Index) /= No_Slot then
               Made := Load_Of (Waits.Element (Index), Site);
            else
               raise Landin.Compiler_Defect with
                 "an inlined call stranded a value";
            end if;
            Map.Replace_Element (Index, Made);
            Seen.Replace_Element (Index, Segment);
            return Made;
         end Resolve;

         function Resolved
           (Code : Instruction; Site : Landin.Provenance.Origin)
            return Value_Array;
         function Resolved
           (Code : Instruction; Site : Landin.Provenance.Origin)
            return Value_Array
         is
            Result : Value_Array (1 .. Code.Args);
         begin
            for A in Result'Range loop
               Result (A) := Resolve (Operand (Code, A), Site);
            end loop;
            return Result;
         end Resolved;

         --  The values above a copy that are used below it wait in a slot,
         --  or are made again when they are constants.
         procedure Carry_Across (Position : Positive);
         procedure Carry_Across (Position : Positive) is
         begin
            for Value of Open_Values loop
               declare
                  Index : constant Positive := Positive (Value);
               begin
                  if Last_Use.Element (Index) > Position
                    and then Seen.Element (Index) = Segment
                    and then Waits.Element (Index) = No_Slot
                    and then not Remade.Element (Index)
                  then
                     declare
                        Code : constant Instruction := Code_At (Caller, Value);
                     begin
                        if Is_Constant (Code) then
                           Remade.Replace_Element (Index, True);
                        else
                           Waits.Replace_Element
                             (Index,
                              New_Slot
                                ((Of_Type => Landin.Types.Scalar_Name
                                    (Code.Result),
                                  Signature => Signature_Of
                                    (Into, Caller, Value),
                                  Atom_Set => Atom_Set_Of
                                    (Into, Caller, Value),
                                  Pointee => Pointee_Of
                                    (Into, Caller, Value),
                                  Site => Code.Site,
                                  others => <>)));
                           Store_Of
                             (Waits.Element (Index), Map.Element (Index),
                              Code.Site);
                        end if;
                     end;
                  end if;
               end;
            end loop;
            Open_Values.Clear;
         end Carry_Across;

         --  The number of blocks a routine's copy takes, and where its
         --  block lands among them: its one return last, when the rest of
         --  the caller's block follows it.
         function Position_In
           (Callee : Item_Id; Block : Block_Id; Exit_Last : Boolean)
            return Positive;
         function Position_In
           (Callee : Item_Id; Block : Block_Id; Exit_Last : Boolean)
            return Positive
         is
            Last : constant Block_Id :=
              Callees.Element (Positive (Callee)).Exit_Block;
         begin
            if not Exit_Last or else Block < Last then
               return Positive (Block);
            elsif Block = Last then
               return Held (Callee).Blocks.Count;
            else
               return Positive (Block) - 1;
            end if;
         end Position_In;

         function Exits_Last (Callee : Item_Id; Kind : Expansion)
            return Boolean is
           (Kind = Plain
            and then Callees.Element (Positive (Callee)).Leaves = 1
            and then Callees.Element (Positive (Callee)).Exit_Block
                       /= First_Block);

         --  Replace the call at Position of the caller's block Block.
         procedure Expand
           (Block : Block_Record; Position : Positive; Call : Value_Id;
            Kind : Expansion);
         procedure Expand
           (Block : Block_Record; Position : Positive; Call : Value_Id;
            Kind : Expansion)
         is
            Code : constant Instruction := Code_At (Caller, Call);
            Callee : constant Item_Id := Code.Named;
            Body_Of : constant Item_Record := Held (Callee);
            Exit_Last : constant Boolean := Exits_Last (Callee, Kind);
            Base : constant Natural := Slot_Count_Now;
            First_Copy : constant Natural := Next_Block;
            Result : constant Slot_Id := Body_Of.Returns_To;
            Copied : Value_Ref_Vectors.Vector :=
              Value_Ref_Vectors.To_Vector
                (No_Value, Ada.Containers.Count_Type (Body_Of.Values.Count));
            --  For each parameter, the caller's constant that it is.
            Known : Value_Ref_Vectors.Vector :=
              Value_Ref_Vectors.To_Vector
                (No_Value, Ada.Containers.Count_Type (Body_Of.Slots.Count));
            --  For each by-value parameter the copy reads where the caller
            --  keeps it, that storage's slot.
            In_Place : Slot_Ref_Vectors.Vector :=
              Slot_Ref_Vectors.To_Vector
                (No_Slot, Ada.Containers.Count_Type (Body_Of.Slots.Count));
            Status : constant Slot_Id := Code.Slot;
            Success, Failure : Block_Id := No_Block;
            Kept_Result : Slot_Id := No_Slot;
            Continuation : Block_Id := No_Block;
            --  Where each return copies a stored result, from and to.
            Result_From, Result_Into : Storage;
            Result_Field : Natural := 0;
            Result_Nested : Landin.IR.Run;

            function Copy_Of (Slot : Slot_Id) return Slot_Id is
              (if Slot = No_Slot then No_Slot
               elsif In_Place.Element (Positive (Slot)) /= No_Slot
               then In_Place.Element (Positive (Slot))
               else Slot_Id (Base + Natural (Slot)));

            --  A parameter read through the caller's carrier is reached
            --  through that address slot, as Landin.IR.In_Place reaches one.
            function Through (Slot : Slot_Id) return Boolean is
              (In_Place.Element (Positive (Slot)) /= No_Slot
               and then Slot_Record_Of
                 (Caller, In_Place.Element (Positive (Slot))).Addressed);

            function Copy_Of (Place : Storage) return Storage is
              (case Place.Kind is
                  when Module_Datum => Place,
                  when Frame_Slot =>
                    (if Place.Slot /= No_Slot and then Through (Place.Slot)
                     then (Kind => Runtime_Address,
                           Address => Copy_Of (Place.Slot))
                     else (Kind => Frame_Slot, Slot => Copy_Of (Place.Slot))),
                  when Runtime_Address =>
                    (Kind => Runtime_Address,
                     Address => Copy_Of (Place.Address)));

            function Block_Of_Copy (Block_In : Block_Id) return Block_Id is
              (Block_Id (First_Copy + Position_In
                 (Callee, Block_In, Exit_Last)));

            --  The routine's way out copies its result slot into the
            --  storage the call named; the copy does the same at each of
            --  its returns.  A whole aggregate is copied between two
            --  addresses, as lowering copies one.
            procedure Prepare_Result
              (Given : Value_Id; Producer : Instruction);
            procedure Prepare_Result
              (Given : Value_Id; Producer : Instruction)
            is
               Aggregate : constant Boolean :=
                 Slot_Record_Of (Callee, Result).Aggregate;
               Shape : constant Field_Shape :=
                 (if Producer.Op = Load
                  then Slot_Record_Of (Caller, Producer.Slot).Element
                  elsif Aggregate then Aggregate_Shape (Callee, Result)
                  else (others => <>));
            begin
               Result_From := (Kind => Frame_Slot, Slot => Copy_Of (Result));
               if Producer.Op = Storage_Address and then not Aggregate then
                  Result_Into := Producer.Destination;
                  Result_Field := Producer.Element_Field;
                  Result_Nested := Producer.Nested;
               else
                  declare
                     Carrier : constant Slot_Id :=
                       New_Slot (Address_Slot (Shape, Code.Site));
                  begin
                     Store_Of
                       (Carrier, Resolve (Given, Code.Site), Code.Site);
                     Result_Into :=
                       (Kind => Runtime_Address, Address => Carrier);
                  end;
               end if;
               if Aggregate then
                  declare
                     Home : constant Slot_Id :=
                       New_Slot (Address_Slot (Shape, Code.Site));
                  begin
                     Store_Of
                       (Home,
                        Put ((Op => Storage_Address,
                              Result => Landin.Types.Usize,
                              Site => Code.Site,
                              Destination => Result_From,
                              others => <>), []),
                        Code.Site);
                     Result_From :=
                       (Kind => Runtime_Address, Address => Home);
                  end;
               end if;
            end Prepare_Result;
         begin
            Site_Count := Site_Count + 1;
            New_Sites.Append
              (Inline_Site'(Callee => Callee, Call => Code.Site,
                            Scope => Block.Scope));
            --  A by-value aggregate the routine only reads, given by the
            --  address of a caller slot nothing can write while the copy
            --  runs, is read there, as Landin.IR.In_Place would have the
            --  routine read it: the copy's reads see the same bytes the
            --  routine's own copy would have held.
            for A in 1 .. Code.Args loop
               if Read_There (Call, A) /= No_Slot then
                  In_Place.Replace_Element
                    (Positive (Into.Parameters.Element
                       (Body_Of.Parameters.First + A)),
                     Read_There (Call, A));
               end if;
            end loop;
            for S in 1 .. Body_Of.Slots.Count loop
               declare
                  Made : Slot_Record :=
                    Into.Slots.Element (Body_Of.Slots.First + S);
               begin
                  Made.Concrete_Evidence := No_Evidence;
                  Made.Home := No_Slot;
                  Made.Inlined := Site_Count;
                  Made.Origin := Slot_Id (S);
                  if In_Place.Element (S) /= No_Slot then
                     --  Unused; the alias below names the parameter.
                     Made.Declaration := No_Declaration;
                  end if;
                  New_Slots.Append (Made);
               end;
            end loop;
            for A in 1 .. Body_Of.Aliases.Count loop
               declare
                  Made : Stored_Source_Alias :=
                    Into.Aliases.Element (Body_Of.Aliases.First + A);
               begin
                  Made.Info.Place := Copy_Of (Made.Info.Place);
                  Made.Inlined := Site_Count;
                  Made.Origin := A;
                  New_Aliases.Append (Made);
               end;
            end loop;
            --  A carrier's storage is not known to be initialized where the
            --  debugger stops, so a parameter read through one has no alias.
            for S in 1 .. Body_Of.Slots.Count loop
               if In_Place.Element (S) /= No_Slot
                 and then not Through (Slot_Id (S))
               then
                  declare
                     Shaped : constant Slot_Record :=
                       Into.Slots.Element (Body_Of.Slots.First + S);
                  begin
                     New_Aliases.Append
                       (Stored_Source_Alias'
                          (Info => (Binding => Shaped.Declaration,
                                    Site => Shaped.Site,
                                    Place => (Kind => Frame_Slot,
                                              Slot => In_Place.Element (S)),
                                    Field => 0,
                                    Initialized_On_Entry => False),
                           Path => (0, 0),
                           Inlined => Site_Count,
                           Origin => 0,
                           Parameter => Slot_Id (S)));
                  end;
               end if;
            end loop;

            --  Each argument into its parameter, as the routine's entry
            --  would have had it.
            for A in 1 .. Code.Args loop
               declare
                  Parameter : constant Slot_Id := Into.Parameters.Element
                    (Body_Of.Parameters.First + A);
                  Shaped : constant Slot_Record :=
                    Slot_Record_Of (Callee, Parameter);
                  Given : constant Value_Id := Operand (Code, A);
                  Producer : constant Instruction := Code_At (Caller, Given);
               begin
                  if In_Place.Element (Positive (Parameter)) /= No_Slot then
                     null;
                  elsif (Shaped.Aggregate or else Shaped.Array_Shape)
                    and then not Shaped.Addressed
                  then
                     if Producer.Op = Number then
                        --  D97's zero carrier: the routine clears its own.
                        Put ((Op => Clear_Array, Site => Code.Site,
                              Destination =>
                                (Kind => Frame_Slot,
                                 Slot => Copy_Of (Parameter)),
                              others => <>), []);
                     elsif Shaped.Array_Shape
                       and then Producer.Op = Storage_Address
                     then
                        Put ((Op => Copy_Array, Site => Code.Site,
                              Source => Producer.Destination,
                              Source_Field => Producer.Element_Field,
                              Source_Nested => Producer.Nested,
                              Destination =>
                                (Kind => Frame_Slot,
                                 Slot => Copy_Of (Parameter)),
                              others => <>), []);
                     else
                        --  The carrier as the call would have received it,
                        --  copied from as the routine's entry copies.  A
                        --  whole aggregate is copied between two addresses,
                        --  as lowering copies one.
                        declare
                           Shape : constant Field_Shape :=
                             (if Producer.Op = Load
                              then Slot_Record_Of
                                (Caller, Producer.Slot).Element
                              elsif Shaped.Aggregate
                              then Aggregate_Shape (Callee, Parameter)
                              else (others => <>));
                           Carrier : constant Slot_Id :=
                             (if Producer.Op = Load or else Shaped.Aggregate
                              then New_Slot (Address_Slot (Shape, Code.Site))
                              else No_Slot);
                           Into_Parameter : Storage :=
                             (Kind => Frame_Slot,
                              Slot => Copy_Of (Parameter));
                           From : Storage := Producer.Destination;
                        begin
                           if Carrier /= No_Slot then
                              Store_Of
                                (Carrier, Resolve (Given, Code.Site),
                                 Code.Site);
                              From :=
                                (Kind => Runtime_Address, Address => Carrier);
                           end if;
                           if Shaped.Aggregate then
                              declare
                                 Home : constant Slot_Id := New_Slot
                                   (Address_Slot (Shape, Code.Site));
                              begin
                                 Store_Of
                                   (Home,
                                    Put ((Op => Storage_Address,
                                          Result => Landin.Types.Usize,
                                          Site => Code.Site,
                                          Destination => Into_Parameter,
                                          others => <>), []),
                                    Code.Site);
                                 Into_Parameter :=
                                   (Kind => Runtime_Address, Address => Home);
                              end;
                           end if;
                           Put ((Op => Copy_Array, Site => Code.Site,
                                 Source => From,
                                 Source_Field =>
                                   (if Carrier = No_Slot
                                    then Producer.Element_Field else 0),
                                 Source_Nested =>
                                   (if Carrier = No_Slot then Producer.Nested
                                    else Landin.IR.Run'(0, 0)),
                                 Destination => Into_Parameter,
                                 others => <>), []);
                        end;
                     end if;
                  elsif A = 1 and then Stores_Result (Callee) then
                     --  The result's storage, which only the way out uses.
                     Prepare_Result (Given, Producer);
                  else
                     Store_Of
                       (Copy_Of (Parameter), Resolve (Given, Code.Site),
                        Code.Site);
                     if Is_Constant (Producer) and then not Shaped.Addressed
                     then
                        Known.Replace_Element (Positive (Parameter), Given);
                     end if;
                  end if;
               end;
            end loop;

            if Kind = Plain then
               Carry_Across (Position);
               Continuation :=
                 Block_Id (First_Copy + Body_Of.Blocks.Count + 1);
               if Last_Use.Element (Positive (Call)) > Position then
                  Kept_Result := Copy_Of (Result);
               end if;
            else
               declare
                  Last : constant Instruction := Into.Code.Element
                    (Block.First_Value + Block.Values);
                  Stores : constant Instruction := Into.Code.Element
                    (Block.First_Value + Position + 1);
               begin
                  Failure := New_Id (Last.Target);
                  Success := New_Id (Last.Alternative);
                  if Stores.Op = Store then
                     Kept_Result := Stores.Slot;
                  end if;
               end;
            end if;
            Jump_To (Block_Id (First_Copy + 1), Code.Site);

            for Order in 1 .. Body_Of.Blocks.Count loop
               declare
                  From : Block_Id := No_Block;
               begin
                  for B in 1 .. Body_Of.Blocks.Count loop
                     if Position_In (Callee, Block_Id (B), Exit_Last) = Order
                     then
                        From := Block_Id (B);
                     end if;
                  end loop;
                  declare
                     Copied_Block : constant Block_Record :=
                       Into.Blocks.Element
                         (Body_Of.Blocks.First + Positive (From));
                  begin
                     Open (Block_Id (First_Copy + Order), Copied_Block.Scope,
                           Copied_Block.Site, Site_Count);
                     for P in 1 .. Copied_Block.Values loop
                        declare
                           Original : constant Instruction :=
                             Into.Code.Element (Copied_Block.First_Value + P);
                           Inside : constant Value_Id := Value_Id
                             (Copied_Block.First_Value + P
                              - Body_Of.Values.First);
                           Operands : Value_Array (1 .. Original.Args);
                           Made : Instruction := Original;
                        begin
                           for A in Operands'Range loop
                              Operands (A) := Copied.Element
                                (Positive (Operand (Original, A)));
                           end loop;
                           Made.Slot := Copy_Of (Original.Slot);
                           Made.Source := Copy_Of (Original.Source);
                           Made.Destination := Copy_Of (Original.Destination);
                           case Original.Op is
                              when Load =>
                                 if Known.Element (Positive (Original.Slot))
                                   /= No_Value
                                 then
                                    --  A parameter the caller knows: its
                                    --  constant, made where it is read.
                                    Made := Code_At
                                      (Caller, Known.Element
                                         (Positive (Original.Slot)));
                                    Made.Site := Original.Site;
                                 end if;
                                 Copied.Replace_Element
                                   (Positive (Inside), Put (Made, Operands));
                              when Jump =>
                                 Made.Target :=
                                   Block_Of_Copy (Original.Target);
                                 Put (Made, Operands);
                              when Branch =>
                                 Made.Target :=
                                   Block_Of_Copy (Original.Target);
                                 Made.Alternative :=
                                   Block_Of_Copy (Original.Alternative);
                                 Put (Made, Operands);
                              when Leave =>
                                 if Original.Args = 1
                                   and then Kept_Result /= No_Slot
                                   and then
                                     (Kind = Failing
                                      or else not
                                        (Code_At
                                           (Callee, Operand (Original, 1)).Op
                                           = Load
                                         and then Code_At
                                           (Callee, Operand (Original, 1)).Slot
                                           = Result))
                                 then
                                    Store_Of
                                      (Kept_Result, Operands (1),
                                       Original.Site);
                                 end if;
                                 if Stores_Result (Callee) then
                                    Put ((Op => Copy_Array,
                                          Site => Original.Site,
                                          Source => Result_From,
                                          Destination => Result_Into,
                                          Element_Field => Result_Field,
                                          Nested => Result_Nested,
                                          others => <>), []);
                                 end if;
                                 Jump_To
                                   ((if Kind = Plain then Continuation
                                     else Success), Original.Site);
                              when Fail =>
                                 Store_Of
                                   (Status, Operands (1), Original.Site);
                                 Jump_To (Failure, Original.Site);
                              when others =>
                                 Copied.Replace_Element
                                   (Positive (Inside), Put (Made, Operands));
                           end case;
                        end;
                     end loop;
                  end;
               end;
            end loop;

            if Kind = Plain then
               Open (Continuation, Block.Scope, Block.Site, 0);
               if Kept_Result /= No_Slot then
                  Waits.Replace_Element (Positive (Call), Kept_Result);
               end if;
            end if;
         end Expand;
      begin
         --  Number every block before writing any: a branch may name one
         --  that is written later.
         for B in 1 .. Old.Blocks.Count loop
            declare
               Block : constant Block_Record :=
                 Into.Blocks.Element (Old.Blocks.First + B);
            begin
               First_Of.Replace_Element (B, Block_Total + 1);
               Block_Total := Block_Total + 1;
               for P in 1 .. Block.Values loop
                  declare
                     Code : constant Instruction :=
                       Into.Code.Element (Block.First_Value + P);
                  begin
                     for A in 1 .. Code.Args loop
                        Last_Use.Replace_Element
                          (Positive (Operand (Code, A)), P);
                        Uses.Replace_Element
                          (Positive (Operand (Code, A)),
                           Uses.Element (Positive (Operand (Code, A))) + 1);
                     end loop;
                     case Plans.Element (Block.First_Value + P) is
                        when Kept => null;
                        when Plain =>
                           Block_Total := Block_Total
                             + Held (Code.Named).Blocks.Count + 1;
                        when Failing =>
                           Block_Total := Block_Total
                             + Held (Code.Named).Blocks.Count;
                     end case;
                  end;
               end loop;
            end;
         end loop;

         for V in 1 .. Old.Values.Count loop
            declare
               Code : constant Instruction :=
                 Into.Code.Element (Old.Values.First + V);
            begin
               if Plans.Element (Old.Values.First + V) /= Kept then
                  for A in 1 .. Code.Args loop
                     if Uses.Element (Positive (Operand (Code, A))) = 1
                       and then Names_Storage (Value_Id (V), A)
                     then
                        Dropped.Replace_Element
                          (Positive (Operand (Code, A)), True);
                     end if;
                  end loop;
               end if;
            end;
         end loop;

         Now.Slots.First := Natural (New_Slots.Length);
         for S in 1 .. Old.Slots.Count loop
            New_Slots.Append (Into.Slots.Element (Old.Slots.First + S));
         end loop;
         Now.Aliases.First := Natural (New_Aliases.Length);
         for A in 1 .. Old.Aliases.Count loop
            New_Aliases.Append (Into.Aliases.Element (Old.Aliases.First + A));
         end loop;
         Now.Inlines.First := Natural (New_Sites.Length);
         for S in 1 .. Old.Inlines.Count loop
            New_Sites.Append
              (Into.Inline_Sites.Element (Old.Inlines.First + S));
         end loop;
         Now.Values.First := Natural (New_Code.Length);
         Now.Blocks.First := Natural (New_Blocks.Length);
         New_Blocks.Append
           ((others => <>), Ada.Containers.Count_Type (Block_Total));

         for B in 1 .. Old.Blocks.Count loop
            declare
               Block : constant Block_Record :=
                 Into.Blocks.Element (Old.Blocks.First + B);
            begin
               Open_Values.Clear;
               Open (New_Id (Block_Id (B)), Block.Scope, Block.Site,
                     Block.Inlined);
               for P in 1 .. Block.Values loop
                  declare
                     V : constant Value_Id :=
                       Value_Id (Block.First_Value + P - Old.Values.First);
                     Code : constant Instruction :=
                       Into.Code.Element (Block.First_Value + P);
                     Kind : constant Expansion :=
                       Plans.Element (Block.First_Value + P);
                  begin
                     if Kind /= Kept then
                        Expand (Block, P, V, Kind);
                        exit when Kind = Failing;
                     elsif Dropped.Element (Positive (V)) then
                        null;
                     else
                        declare
                           Made : Instruction := Code;
                           Defined : Value_Id;
                        begin
                           if Code.Op in Jump | Branch then
                              Made.Target := New_Id (Code.Target);
                              if Code.Op = Branch then
                                 Made.Alternative :=
                                   New_Id (Code.Alternative);
                              end if;
                           end if;
                           Defined := Put (Made, Resolved (Code, Code.Site));
                           Map.Replace_Element (Positive (V), Defined);
                           Seen.Replace_Element (Positive (V), Segment);
                           if Last_Use.Element (Positive (V)) > P then
                              Open_Values.Append (V);
                           end if;
                        end;
                     end if;
                  end;
               end loop;
            end;
         end loop;

         if Next_Block /= Block_Total then
            raise Landin.Compiler_Defect with "inlined blocks miscounted";
         end if;
         Now.Slots.Count := Slot_Count_Now;
         Now.Aliases.Count := Natural (New_Aliases.Length) - Now.Aliases.First;
         Now.Inlines.Count := Natural (New_Sites.Length) - Now.Inlines.First;
         Now.Blocks.Count := Block_Total;
         Now.Values.Count := Natural (New_Code.Length) - Now.Values.First;
         New_Items.Append (Now);
      end Expand_Item;
   begin
      if Objective /= Landin.Optimization.Speed
        or else Landin.Targets.Capabilities.Backend_For (Facts)
          = Landin.Targets.Capabilities.Cortex_M0_ELF
        or else Items = 0
      then
         return;
      end if;
      Callees := Callee_Vectors.To_Vector
        ((others => <>), Ada.Containers.Count_Type (Items));
      Changed := Boolean_Vectors.To_Vector
        (False, Ada.Containers.Count_Type (Items));
      Exposed := Boolean_Vectors.To_Vector
        (False, Ada.Containers.Count_Type (Items));
      Plans := Expansion_Vectors.To_Vector (Kept, Into.Code.Length);
      Visit_Address_Exposures (Into, Expose'Access);
      for I in 1 .. Items loop
         Measure (Item_Id (I));
      end loop;
      for I in 1 .. Items loop
         if Held (Item_Id (I)).Kind = Routine
           and then not Held (Item_Id (I)).External
           and then Held (Item_Id (I)).Blocks.Count > 0
         then
            Plan (Item_Id (I));
         end if;
      end loop;
      if not Any then
         return;
      end if;
      New_Slots.Reserve_Capacity (Into.Slots.Length);
      New_Blocks.Reserve_Capacity (Into.Blocks.Length);
      New_Code.Reserve_Capacity (Into.Code.Length);
      New_Args.Reserve_Capacity (Into.Operands.Length);
      for I in 1 .. Items loop
         if Changed.Element (I) then
            Expand_Item (Item_Id (I));
         else
            Keep_Item (Item_Id (I));
         end if;
      end loop;
      Into.Items.Move (New_Items);
      Into.Slots.Move (New_Slots);
      Into.Blocks.Move (New_Blocks);
      Into.Code.Move (New_Code);
      Into.Operands.Move (New_Args);
      Into.Aliases.Move (New_Aliases);
      Into.Inline_Sites.Move (New_Sites);
      Verifier.Verify (Into, Facts);
   end Run_On_Verified;
end Landin.IR.Inlining;
