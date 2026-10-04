with Ada.Finalization;
with Ada.Unchecked_Deallocation;
with System.Storage_Elements;
with Interfaces;
with Landin.IR.Effects;
with Landin.IR.Rewriting;
with Landin.IR.Verifier;

package body Landin.IR.Simplification is
   use type Interfaces.Unsigned_64;
   use type System.Storage_Elements.Storage_Count;
   use type Landin.Optimization.Objective;
   subtype Bits is Interfaces.Unsigned_64;
   subtype Integer_Value is Landin.Types.Folded;

   function Checked_Scratch_Bytes
     (Count : Natural; Width : System.Storage_Elements.Storage_Count)
      return System.Storage_Elements.Storage_Count;

   function Checked_Scratch_Bytes
     (Count : Natural; Width : System.Storage_Elements.Storage_Count)
      return System.Storage_Elements.Storage_Count
   is
      use System.Storage_Elements;
   begin
      if Width /= 0 and then Storage_Count (Count)
        > Storage_Count'Last / Width
      then
         raise Storage_Error with
           "simplifier scratch size is not representable";
      end if;
      return Storage_Count (Count) * Width;
   end Checked_Scratch_Bytes;

   generic
      type Element is private;
      Initial : Element;
   package Scratch_Arrays is
      type Elements is array (Positive range <>) of Element;
      type Elements_Access is access Elements;
      type Owner is new Ada.Finalization.Limited_Controlled with record
         Data : Elements_Access := null;
      end record;
      overriding procedure Finalize (Value : in out Owner);
      function Create (Count : Natural) return Owner;
   end Scratch_Arrays;

   package body Scratch_Arrays is
      procedure Free is new Ada.Unchecked_Deallocation
        (Object => Elements, Name => Elements_Access);

      overriding procedure Finalize (Value : in out Owner) is
      begin
         Free (Value.Data);
      end Finalize;

      function Create (Count : Natural) return Owner is
         Bytes : constant System.Storage_Elements.Storage_Count :=
           Checked_Scratch_Bytes
             (Count, Element'Object_Size / System.Storage_Unit);
      begin
         pragma Unreferenced (Bytes);
         return Result : Owner do
            --  Initialize in owned heap storage, without an input-sized
            --  aggregate or return temporary on the compiler's stack.
            Result.Data := new Elements (1 .. Count);
            for Held of Result.Data.all loop
               Held := Initial;
            end loop;
         end return;
      end Create;
   end Scratch_Arrays;

   package Flags is new Scratch_Arrays (Boolean, False);
   package Values is new Scratch_Arrays (Value_Id, No_Value);
   package Indices is new Scratch_Arrays (Positive, 1);

   function Pattern (Value : Integer_Value) return Bits
     is (if Value < 0 then 0 - Bits (-Value) else Bits (Value));

   function Mask (Width : Positive) return Bits
     is (if Width = 64 then Bits'Last else 2 ** Width - 1);

   function Signed_Value
     (Value : Bits; Width : Positive; Signed : Boolean) return Integer_Value;

   function Signed_Value
     (Value : Bits; Width : Positive; Signed : Boolean) return Integer_Value
   is
      Kept : constant Bits := Value and Mask (Width);
   begin
      if Signed and then (Kept and 2 ** (Width - 1)) /= 0 then
         return -Integer_Value (((not Kept) and Mask (Width)) + 1);
      else
         return Integer_Value (Kept);
      end if;
   end Signed_Value;

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
      procedure Simplify
        (Item : Item_Id; Keep : in out Rewriting.Keep_Vectors.Vector);

      procedure Simplify
        (Item : Item_Id; Keep : in out Rewriting.Keep_Vectors.Vector) is
         Held : constant Item_Record := Into.Items (Positive (Item));
         Alias_Owner : constant Values.Owner :=
           Values.Create (Held.Values.Count);
         Alias : Values.Elements renames Alias_Owner.Data.all;
         Needed_Owner : constant Flags.Owner :=
           Flags.Create (Held.Values.Count);
         Needed : Flags.Elements renames Needed_Owner.Data.all;
         Required_Proof_Owner : constant Flags.Owner :=
           Flags.Create (Held.Values.Count);
         Required_Proof : Flags.Elements renames Required_Proof_Owner.Data.all;
         Eligible_Owner : constant Flags.Owner :=
           Flags.Create (Held.Slots.Count);
         Eligible : Flags.Elements renames Eligible_Owner.Data.all;
         Local_Store_Owner : constant Flags.Owner :=
           Flags.Create (Held.Slots.Count);
         Local_Store : Flags.Elements renames Local_Store_Owner.Data.all;
         Pending_Owner : constant Values.Owner :=
           Values.Create (Held.Slots.Count);
         Pending : Values.Elements renames Pending_Owner.Data.all;
         Pending_Tracked_Owner : constant Flags.Owner :=
           Flags.Create (Held.Slots.Count);
         Pending_Tracked : Flags.Elements renames
           Pending_Tracked_Owner.Data.all;
         Pending_Slots_Owner : constant Indices.Owner :=
           Indices.Create (Held.Slots.Count);
         Pending_Slots : Indices.Elements renames Pending_Slots_Owner.Data.all;
         Stored_Owner : constant Values.Owner :=
           Values.Create (Held.Slots.Count);
         Stored : Values.Elements renames Stored_Owner.Data.all;
         Remembered_Owner : constant Indices.Owner :=
           Indices.Create (Held.Slots.Count);
         Remembered : Indices.Elements renames Remembered_Owner.Data.all;
         Pending_Count : Natural := 0;
         Remembered_Count : Natural := 0;
         Last_Block : Block_Id := No_Block;

         procedure Forget_Pending;
         procedure Forget_Stores;

         procedure Forget_Pending is
         begin
            for Index in 1 .. Pending_Count loop
               Pending (Pending_Slots (Index)) := No_Value;
               Pending_Tracked (Pending_Slots (Index)) := False;
            end loop;
            Pending_Count := 0;
         end Forget_Pending;

         procedure Forget_Stores is
         begin
            for Index in 1 .. Remembered_Count loop
               Stored (Remembered (Index)) := No_Value;
            end loop;
            Remembered_Count := 0;
         end Forget_Stores;

         function Code_At (Value : Value_Id) return Instruction
           is (Into.Code (Held.Values.First + Positive (Value)));

         procedure Pin (Place : Storage);
         procedure Pin (Place : Storage) is
         begin
            case Place.Kind is
               when Frame_Slot =>
                  if Place.Slot /= No_Slot then
                     Eligible (Positive (Place.Slot)) := False;
                     Local_Store (Positive (Place.Slot)) := False;
                  end if;
               when Runtime_Address =>
                  if Place.Address /= No_Slot then
                     Eligible (Positive (Place.Address)) := False;
                     Local_Store (Positive (Place.Address)) := False;
                  end if;
               when Module_Datum => null;
            end case;
         end Pin;

         function Plain (Code : Instruction) return Boolean
           is (Code.Pointee = No_Pointee
               and then Code.Signature = No_Signature
               and then Code.Atom_Set = No_Atom_Set);

         function Integer_Constant (Value : Value_Id) return Boolean
           is (Code_At (Value).Op = Number
               and then Code_At (Value).Result in Landin.Types.Integer_Name
               and then Plain (Code_At (Value)));

         function Numeric (Value : Value_Id) return Integer_Value
           is (if Code_At (Value).Negated
               then -Integer_Value (Code_At (Value).Number)
               else Integer_Value (Code_At (Value).Number));

         procedure Fold (Code : in out Instruction);
         procedure Fold (Code : in out Instruction) is
            Left, Right : Value_Id := No_Value;
            A, B, Result : Integer_Value := 0;
            Known : Boolean := False;
            Boolean_Result : Boolean := False;
            Is_Boolean : Boolean := False;
            Width : Positive := 1;
            Kind : Landin.Types.Integer_Name := Landin.Types.U8;

            procedure Compare;
            procedure Compare is
            begin
               Is_Boolean := True;
               Known := True;
               Boolean_Result :=
                 (case Code.Op is
                     when Equal_To => A = B,
                     when Not_Equal_To => A /= B,
                     when Less_Than => A < B,
                     when Less_Or_Equal => A <= B,
                     when Greater_Than => A > B,
                     when Greater_Or_Equal => A >= B,
                     when others => False);
            end Compare;
         begin
            if not Plain (Code) or else Code.Args = 0 then
               return;
            end if;
            Left := Into.Operands (Code.First_Arg + 1);
            if Code.Args = 2 then
               Right := Into.Operands (Code.First_Arg + 2);
            end if;
            if Code.Op = Logical_Not and then Code_At (Left).Op = Truth then
               Known := True;
               Is_Boolean := True;
               Boolean_Result := not Code_At (Left).Truth;
            elsif Code.Op in Equal_To | Not_Equal_To
              and then Right /= No_Value
              and then Code_At (Left).Op = Truth
              and then Code_At (Right).Op = Truth
            then
               A := Boolean'Pos (Code_At (Left).Truth);
               B := Boolean'Pos (Code_At (Right).Truth);
               Compare;
            elsif Integer_Constant (Left)
              and then (Code.Op in Unary_Kind | Binary_Kind
                        | Conversion | Range_Check)
              and then (Code.Args = 1 or else Integer_Constant (Right))
            then
               A := Numeric (Left);
               if Right /= No_Value then
                  B := Numeric (Right);
               end if;
               Kind := Landin.Types.Integer_Name (Code_At (Left).Result);
               Width := Positive (Landin.Types.Width (Kind, Facts));
               if Code.Op in Comparison_Kind then
                  Compare;
               elsif Code.Result in Landin.Types.Integer_Name then
                  Kind := Landin.Types.Integer_Name (Code.Result);
                  Width := Positive (Landin.Types.Width (Kind, Facts));
                  case Code.Op is
                     when Add | Subtract =>
                        if Code.Op = Subtract then
                           B := -B;
                        end if;
                        if Code.Unchecked then
                           Result := Signed_Value
                             (Pattern (A) + Pattern (B), Width,
                              Landin.Types.Is_Signed (Kind));
                           Known := True;
                        elsif (B >= 0 and then A <= Integer_Value'Last - B)
                          or else (B < 0
                            and then A >= Integer_Value'First - B)
                        then
                           Result := A + B;
                           Known := True;
                        end if;
                     when Multiply =>
                        if Code.Unchecked then
                           Result := Signed_Value
                             (Pattern (A) * Pattern (B), Width,
                              Landin.Types.Is_Signed (Kind));
                           Known := True;
                        elsif B = 0 or else
                          abs A <= Integer_Value'Last / abs B
                        then
                           Result := A * B;
                           Known := True;
                        end if;
                     when Negation =>
                        Result := -A;
                        if Code.Unchecked then
                           Result := Signed_Value
                             (Pattern (Result), Width,
                              Landin.Types.Is_Signed (Kind));
                        end if;
                        Known := True;
                     when Divide | Remainder =>
                        if B /= 0 then
                           Result := (if Code.Op = Divide then A / B
                                      else A rem B);
                           Known := True;
                        end if;
                     when Wrapping_Add | Wrapping_Subtract
                        | Wrapping_Multiply | Bitwise_And | Bitwise_Xor
                        | Bitwise_Or | Complement =>
                        declare
                           X : constant Bits := Pattern (A);
                           Y : constant Bits := Pattern (B);
                           Z : constant Bits :=
                             (case Code.Op is
                                 when Wrapping_Add => X + Y,
                                 when Wrapping_Subtract => X - Y,
                                 when Wrapping_Multiply => X * Y,
                                 when Bitwise_And => X and Y,
                                 when Bitwise_Xor => X xor Y,
                                 when Bitwise_Or => X or Y,
                                 when Complement => not X,
                                 when others => 0);
                        begin
                           Result := Signed_Value
                             (Z, Width, Landin.Types.Is_Signed (Kind));
                           Known := True;
                        end;
                     when Shift_Left | Shift_Right =>
                        if B >= 0 then
                           if B >= Integer_Value (Width) then
                              Result := 0;
                           elsif Code.Op = Shift_Left then
                              Result := Signed_Value
                                (Interfaces.Shift_Left
                                   (Pattern (A), Natural (B)), Width,
                                 Landin.Types.Is_Signed (Kind));
                           else
                              declare
                                 X : Bits := Interfaces.Shift_Right
                                   (Pattern (A), Natural (B));
                              begin
                                 if A < 0 and then B > 0 then
                                    X := X or not Interfaces.Shift_Right
                                      (Bits'Last, Natural (B));
                                 end if;
                                 Result := Signed_Value
                                   (X, Width, Landin.Types.Is_Signed (Kind));
                              end;
                           end if;
                           Known := True;
                        end if;
                     when Conversion =>
                        Result := A;
                        if Code.Unchecked then
                           Result := Signed_Value
                             (Pattern (A), Width,
                              Landin.Types.Is_Signed (Kind));
                        end if;
                        Known := True;
                     when Range_Check =>
                        Result := A;
                        Known := A >= Code.Lower_Bound
                          and then A <= Code.Upper_Bound;
                     when others => null;
                  end case;
                  Known := Known and then Landin.Types.Holds
                    (Result, Kind, Facts);
               end if;
            end if;
            if Known then
               --  Replacement keeps the operation's source site, not the
               --  literal's site. Removed checks were proved, never assumed.
               Code := (Op => (if Is_Boolean then Truth else Number),
                        Result => Code.Result, Site => Code.Site,
                        In_Block => Code.In_Block,
                        Number => Landin.Types.Magnitude (abs Result),
                        Negated => Result < 0, Truth => Boolean_Result,
                        others => <>);
            end if;
         end Fold;

         function Removable (Code : Instruction) return Boolean;

         function Removable (Code : Instruction) return Boolean is
            Effect : constant Effects.Effect_Set := Effects.Of_Code (Code.Op);
         begin
            if Code.Op = Load then
               return Eligible (Positive (Code.Slot));
            end if;
            return not Effect.Reads and then not Effect.Writes
              and then not Effect.Calls and then not Effect.Traps
              and then not Effect.Control and then not Effect.Adjacency
              --  A verified function address is a pure value even though
              --  it carries a signature. Demand still keeps every live use.
              and then (Plain (Code) or else Code.Op = Function_Address);
         end Removable;
      begin
         for S in Eligible'Range loop
            declare
               Slot : constant Slot_Record := Into.Slots
                 (Held.Slots.First + S);
            begin
               Local_Store (S) :=
                 not Slot.Aggregate and then not Slot.Array_Shape
                 and then not Slot.Addressed and then Slot.Pointee = No_Pointee
                 and then Slot.Signature = No_Signature
                 and then Slot.Atom_Set = No_Atom_Set;
               Eligible (S) := Local_Store (S)
                 and then Slot.Of_Type not in Landin.Types.Float_Name;
            end;
         end loop;
         for V in Alias'Range loop
            Alias (V) := Value_Id (V);
            declare
               Code : constant Instruction := Code_At (Value_Id (V));
            begin
               Pin (Code.Source);
               Pin (Code.Destination);
               if Code.Op = Range_Check and then Code.Pointee /= No_Pointee
               then
                  --  A raw-pointer check proves its carrier using the
                  --  preceding integer-to-usize conversion, not just its
                  --  bits. Keep that structural witness intact.
                  Required_Proof
                    (Positive (Into.Operands (Code.First_Arg + 1))) := True;
               end if;
               if Code.Slot /= No_Slot and then Code.Op not in Load | Store
               then
                  Eligible (Positive (Code.Slot)) := False;
                  Local_Store (Positive (Code.Slot)) := False;
               end if;
               --  [1630]: a block writes its output slots itself, so no
               --  store before it may stand in for a load after it.
               for A in 1 .. Code.Assembly_Run.Count loop
                  declare
                     Output : constant Slot_Id := Into.Assembly_Operands
                       (Code.Assembly_Run.First + A).Output;
                  begin
                     if Output /= No_Slot then
                        Eligible (Positive (Output)) := False;
                        Local_Store (Positive (Output)) := False;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         --  A plain local store has no observer before the next write to
         --  that slot in this block.  A load, block boundary or other write
         --  ends the proof.  Its value preparation remains subject to the
         --  backward demand pass, which keeps any calls or traps.
         for V in Alias'Range loop
            declare
               Code : constant Instruction := Code_At (Value_Id (V));
            begin
               if Code.In_Block /= Last_Block then
                  Forget_Pending;
                  Last_Block := Code.In_Block;
               end if;
               if Code.Op = Store and then Local_Store (Positive (Code.Slot))
               then
                  if Pending (Positive (Code.Slot)) /= No_Value then
                     Keep (Held.Values.First
                           + Positive (Pending (Positive (Code.Slot)))) :=
                       False;
                  elsif not Pending_Tracked (Positive (Code.Slot)) then
                     Pending_Count := Pending_Count + 1;
                     Pending_Slots (Pending_Count) := Positive (Code.Slot);
                     Pending_Tracked (Positive (Code.Slot)) := True;
                  end if;
                  Pending (Positive (Code.Slot)) := Value_Id (V);
               elsif Code.Op = Load
                 and then Local_Store (Positive (Code.Slot))
               then
                  Pending (Positive (Code.Slot)) := No_Value;
               elsif Effects.Of_Code (Code.Op).Writes then
                  Forget_Pending;
               end if;
            end;
         end loop;
         Last_Block := No_Block;
         for V in Alias'Range loop
            declare
               Code : Instruction := Code_At (Value_Id (V));
            begin
               if Code.In_Block /= Last_Block then
                  Forget_Stores;
                  Last_Block := Code.In_Block;
               end if;
               for A in 1 .. Code.Args loop
                  Into.Operands.Replace_Element
                    (Code.First_Arg + A, Alias (Positive
                       (Into.Operands (Code.First_Arg + A))));
               end loop;
               if Code.Op = Load and then Eligible (Positive (Code.Slot))
                 and then Stored (Positive (Code.Slot)) /= No_Value
               then
                  Alias (V) := Stored (Positive (Code.Slot));
                  Keep (Held.Values.First + V) := False;
               else
                  if not Required_Proof (V) then
                     Fold (Code);
                  end if;
                  if Code.Op = Branch then
                     declare
                        Condition : constant Instruction := Code_At
                          (Into.Operands (Code.First_Arg + 1));
                     begin
                        if Condition.Op = Truth then
                           Code.Target := (if Condition.Truth then Code.Target
                                           else Code.Alternative);
                           Code.Op := Jump;
                           Code.Args := 0;
                           Code.Alternative := No_Block;
                        end if;
                     end;
                  end if;
                  Into.Code.Replace_Element (Held.Values.First + V, Code);
               end if;
               if Code.Op = Store and then Eligible (Positive (Code.Slot))
               then
                  if Stored (Positive (Code.Slot)) = No_Value then
                     Remembered_Count := Remembered_Count + 1;
                     Remembered (Remembered_Count) := Positive (Code.Slot);
                  end if;
                  Stored (Positive (Code.Slot)) :=
                    Into.Operands (Code.First_Arg + 1);
               elsif Effects.Of_Code (Code.Op).Writes then
                  Forget_Stores;
               end if;
            end;
         end loop;
         --  Backward demand marks transitive operands once. Observable
         --  instructions are roots even when their result is discarded.
         for V in reverse Alias'Range loop
            if Keep (Held.Values.First + V) then
               declare
                  Code : constant Instruction := Code_At (Value_Id (V));
               begin
                  if Needed (V) or else not Removable (Code) then
                     for A in 1 .. Code.Args loop
                        Needed (Positive
                          (Into.Operands (Code.First_Arg + A))) := True;
                     end loop;
                  else
                     Keep (Held.Values.First + V) := False;
                  end if;
               end;
            end if;
         end loop;
      end Simplify;
   begin
      if Objective = Landin.Optimization.None then
         return;
      end if;
      declare
         Keep : Rewriting.Keep_Vectors.Vector :=
           Rewriting.Keep_Vectors.To_Vector
             (True, Into.Code.Length);
      begin
         for I in 1 .. Item_Count (Into) loop
            if Kind_Of (Into, Item_Id (I)) = Routine
              and then not Is_External (Into, Item_Id (I))
            then
               Simplify (Item_Id (I), Keep);
            end if;
         end loop;
         Rewriting.Compact (Into, Keep);
      end;
      Verifier.Verify (Into, Facts);
   end Run_On_Verified;
end Landin.IR.Simplification;
