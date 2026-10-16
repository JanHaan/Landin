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

   --  The value numbering table of a routine: a power of two at least
   --  twice its values, so that probing always finds a free entry.
   function Table_Size (Count : Natural) return Positive;

   function Table_Size (Count : Natural) return Positive is
      Size : Positive := 2;
   begin
      while Size < 2 * Count loop
         Size := 2 * Size;
      end loop;
      return Size;
   end Table_Size;

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
         Held : constant Item_Record := Into.Items.Element (Positive (Item));
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
         Loaded_Owner : constant Flags.Owner :=
           Flags.Create (Held.Slots.Count);
         Loaded : Flags.Elements renames Loaded_Owner.Data.all;
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
         First_Load_Owner : constant Values.Owner :=
           Values.Create (Held.Slots.Count);
         First_Load : Values.Elements renames First_Load_Owner.Data.all;
         Class_Owner : constant Values.Owner :=
           Values.Create (Held.Values.Count);
         Class : Values.Elements renames Class_Owner.Data.all;
         Last_Write_Owner : constant Values.Owner :=
           Values.Create (Held.Slots.Count);
         Last_Write : Values.Elements renames Last_Write_Owner.Data.all;
         Exposed_Owner : constant Flags.Owner :=
           Flags.Create (Held.Slots.Count);
         Exposed : Flags.Elements renames Exposed_Owner.Data.all;
         Table_Owner : constant Values.Owner :=
           Values.Create (Table_Size (Held.Values.Count));
         Table : Values.Elements renames Table_Owner.Data.all;
         Filled_Owner : constant Indices.Owner :=
           Indices.Create (Held.Values.Count);
         Filled : Indices.Elements renames Filled_Owner.Data.all;
         Filled_Count : Natural := 0;
         Pending_Count : Natural := 0;
         Remembered_Count : Natural := 0;
         Last_Block : Block_Id := No_Block;

         procedure Forget_Pending;
         procedure Forget_Stores;
         procedure Remember
           (Slot : Slot_Id; Value : Value_Id; Is_Load : Boolean := False);

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
               First_Load (Remembered (Index)) := No_Value;
            end loop;
            Remembered_Count := 0;
         end Forget_Stores;

         --  A store makes its operand the slot's value.  A load that had
         --  nothing to forward is only the first of its class: a later
         --  load of the slot is numbered the same, but keeps its own value
         --  so that no value lives longer than the code asked for.
         procedure Remember
           (Slot : Slot_Id; Value : Value_Id; Is_Load : Boolean := False) is
         begin
            if Stored (Positive (Slot)) = No_Value
              and then First_Load (Positive (Slot)) = No_Value
            then
               Remembered_Count := Remembered_Count + 1;
               Remembered (Remembered_Count) := Positive (Slot);
            end if;
            if Is_Load then
               First_Load (Positive (Slot)) := Value;
            else
               Stored (Positive (Slot)) := Value;
               First_Load (Positive (Slot)) := No_Value;
            end if;
         end Remember;

         function Code_At (Value : Value_Id) return Instruction
           is (Into.Code.Element (Held.Values.First + Positive (Value)));

         procedure Pin (Place : Storage);
         procedure Pin (Place : Storage) is
         begin
            case Place.Kind is
               when Frame_Slot =>
                  if Place.Slot /= No_Slot then
                     Eligible (Positive (Place.Slot)) := False;
                  end if;
               when Runtime_Address =>
                  if Place.Address /= No_Slot then
                     Eligible (Positive (Place.Address)) := False;
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
            Left := Into.Operands.Element (Code.First_Arg + 1);
            if Code.Args = 2 then
               Right := Into.Operands.Element (Code.First_Arg + 2);
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

         function Operand
           (Code : Instruction; Position : Positive) return Value_Id
           is (Into.Operands.Element (Code.First_Arg + Position));

         function Zero (Value : Value_Id) return Boolean
           is (Integer_Constant (Value) and then Numeric (Value) = 0);

         function One (Value : Value_Id) return Boolean
           is (Integer_Constant (Value) and then Numeric (Value) = 1);

         --  Integer identities.  None holds for a float: x + 0.0 is not x
         --  when x is -0.0, and x == x is false for a NaN.  An identity
         --  that drops a checked operation drops a check that cannot fail.
         procedure Apply_Identity
           (Code : in out Instruction; Same_As : out Value_Id);

         procedure Apply_Identity
           (Code : in out Instruction; Same_As : out Value_Id)
         is
            Left, Right : Value_Id;
         begin
            Same_As := No_Value;
            if not Plain (Code) or else Code.Args /= 2 then
               return;
            end if;
            Left := Operand (Code, 1);
            Right := Operand (Code, 2);
            if Code.Op in Comparison_Kind then
               if Class (Positive (Left)) = Class (Positive (Right))
                 and then Code_At (Left).Result
                   not in Landin.Types.Float_Name
               then
                  Code := (Op => Truth, Result => Code.Result,
                           Site => Code.Site, In_Block => Code.In_Block,
                           Truth => Code.Op in Equal_To | Less_Or_Equal
                             | Greater_Or_Equal,
                           others => <>);
               end if;
               return;
            elsif Code.Result not in Landin.Types.Integer_Name then
               return;
            end if;
            case Code.Op is
               when Add | Wrapping_Add | Bitwise_Xor =>
                  Same_As := (if Zero (Right) then Left
                              elsif Zero (Left) then Right else No_Value);
               when Bitwise_Or =>
                  Same_As :=
                    (if Zero (Right)
                       or else Class (Positive (Left))
                         = Class (Positive (Right))
                     then Left elsif Zero (Left) then Right else No_Value);
               when Subtract | Wrapping_Subtract | Shift_Left | Shift_Right =>
                  Same_As := (if Zero (Right) then Left else No_Value);
               when Multiply | Wrapping_Multiply =>
                  Same_As := (if One (Right) then Left
                              elsif One (Left) then Right else No_Value);
               when Divide =>
                  Same_As := (if One (Right) then Left else No_Value);
               when Bitwise_And =>
                  Same_As :=
                    (if Class (Positive (Left)) = Class (Positive (Right))
                     then Left else No_Value);
               when others => null;
            end case;
            if Same_As /= No_Value
              and then (Code_At (Same_As).Result /= Code.Result
                        or else not Plain (Code_At (Same_As)))
            then
               Same_As := No_Value;
            end if;
         end Apply_Identity;

         --  A storage reached through an address slot is the same place
         --  only while that slot keeps its address, which only a direct
         --  write changes when nothing else can reach the slot.
         function Stable (Place : Storage) return Boolean
           is (Place.Kind /= Runtime_Address
               or else not Exposed (Positive (Place.Address)));

         function Unchanged (Place : Storage; Since : Value_Id) return Boolean
           is (Place.Kind /= Runtime_Address
               or else Last_Write (Positive (Place.Address)) < Since);

         --  The pure computations, checked ones among them, that value
         --  numbering may share.  Memory reads are not among them; loads
         --  of an eligible slot only lend their operands a class.  An
         --  address is shared only for a whole place or one indexed
         --  element of it, whose bounds are its static shape's.
         function Numbered (Code : Instruction) return Boolean
           is (Code.Op in Unary_Kind | Binary_Kind | Conversion | Range_Check
                 | Storage_Address | Place_Address | Pointer_Address
               and then Code.Variadic_Types.Count = 0
               and then Code.Assembly_Run.Count = 0
               and then Code.Source_Nested.Count = 0
               and then Code.Below_Element.Count = 0
               and then Code.Nested.Count = 0
               and then Code.Element_Field = 0
               and then Code.Variant_Case = 0
               and then Stable (Code.Source)
               and then Stable (Code.Destination));

         --  Everything an operation computes from, apart from where it is
         --  written and which values it reads: those are compared through
         --  their classes.  The unchecked flag stays in: an operation whose
         --  check was removed by [1120] proves nothing for a checked one.
         function Normal (Code : Instruction) return Instruction
           is (Code with delta Site => Landin.Provenance.No_Origin,
                 In_Block => No_Block, First_Arg => 0,
                 Variadic_Types => (others => <>),
                 Assembly_Run => (others => <>),
                 Source_Nested => (others => <>),
                 Below_Element => (others => <>),
                 Nested => (others => <>));

         function Same (Earlier : Value_Id; Code : Instruction)
           return Boolean;

         function Same (Earlier : Value_Id; Code : Instruction)
           return Boolean
         is
            Prior : constant Instruction := Code_At (Earlier);
         begin
            if Normal (Prior) /= Normal (Code)
              or else not Unchanged (Prior.Source, Earlier)
              or else not Unchanged (Prior.Destination, Earlier)
            then
               return False;
            end if;
            for A in 1 .. Code.Args loop
               if Class (Positive (Operand (Prior, A)))
                 /= Class (Positive (Operand (Code, A)))
               then
                  return False;
               end if;
            end loop;
            return True;
         end Same;

         function Hash (Code : Instruction) return Bits;

         function Hash (Code : Instruction) return Bits is
            --  Every field that tells two operations apart is mixed in,
            --  so that distinct operations rarely share a chain and the
            --  table stays linear in a block of near-identical checks.
            Result : Bits := Bits (Opcode'Pos (Code.Op)) * 16#9E37_79B9#
              + Bits (Landin.Types.Type_Kind'Pos (Code.Result))
              + Bits (Code.Number) + Bits (Code.Pointee)
              + Pattern (Code.Lower_Bound) * 7
              + Pattern (Code.Upper_Bound) * 13
              + Bits (Boolean'Pos (Code.Unchecked));
         begin
            for A in 1 .. Code.Args loop
               Result := Result * 31
                 + Bits (Class (Positive (Operand (Code, A))));
            end loop;
            if Code.Destination.Kind = Frame_Slot then
               Result := Result * 31 + Bits (Code.Destination.Slot);
            elsif Code.Destination.Kind = Runtime_Address then
               Result := Result * 31 + Bits (Code.Destination.Address);
            end if;
            return Result;
         end Hash;

         --  [1960]: an operation that would have failed stopped the
         --  program where it stood, so a later identical one in the same
         --  block cannot fail and has the earlier one's value.  That is a
         --  proof, not an unchecked assumption: the replaced operation is
         --  gone, and no flag says its check was waived.
         function Earlier_Same (V : Positive; Code : Instruction)
           return Value_Id;

         function Earlier_Same (V : Positive; Code : Instruction)
           return Value_Id
         is
            Mask : constant Bits := Bits (Table'Length - 1);
            Index : Bits := Hash (Code) and Mask;
         begin
            while Table (Natural (Index) + 1) /= No_Value loop
               if Same (Table (Natural (Index) + 1), Code) then
                  return Table (Natural (Index) + 1);
               end if;
               Index := (Index + 1) and Mask;
            end loop;
            Table (Natural (Index) + 1) := Value_Id (V);
            Filled_Count := Filled_Count + 1;
            Filled (Filled_Count) := Natural (Index) + 1;
            return No_Value;
         end Earlier_Same;

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
               Slot : constant Slot_Record := Into.Slots.Element
                 (Held.Slots.First + S);
            begin
               --  A forwarded load is the stored value itself: a float
               --  keeps its exact bits, NaN payload and signed zero, and a
               --  pointer its pointee, which the verifier already held to
               --  agree with the slot's when the value was stored.
               Eligible (S) :=
                 not Slot.Aggregate and then not Slot.Array_Shape
                 and then not Slot.Addressed
                 and then Slot.Signature = No_Signature
                 and then Slot.Atom_Set = No_Atom_Set;
            end;
         end loop;
         for V in Alias'Range loop
            Alias (V) := Value_Id (V);
            declare
               Code : constant Instruction := Code_At (Value_Id (V));
            begin
               Pin (Code.Source);
               Pin (Code.Destination);
               if Code.Source.Kind = Frame_Slot
                 and then Code.Source.Slot /= No_Slot
               then
                  Exposed (Positive (Code.Source.Slot)) := True;
               end if;
               if Code.Destination.Kind = Frame_Slot
                 and then Code.Destination.Slot /= No_Slot
               then
                  Exposed (Positive (Code.Destination.Slot)) := True;
               end if;
               if Code.Op = Range_Check and then Code.Pointee /= No_Pointee
               then
                  --  A raw-pointer check proves its carrier using the
                  --  preceding integer-to-usize conversion, not just its
                  --  bits. Keep that structural witness intact.
                  Required_Proof (Positive
                    (Into.Operands.Element (Code.First_Arg + 1))) := True;
               end if;
               if Code.Slot /= No_Slot and then Code.Op not in Load | Store
               then
                  Eligible (Positive (Code.Slot)) := False;
               end if;
               --  [1630]: a block writes its output slots itself, so no
               --  store before it may stand in for a load after it.
               for A in 1 .. Code.Assembly_Run.Count loop
                  declare
                     Output : constant Slot_Id :=
                       Into.Assembly_Operands.Element
                         (Code.Assembly_Run.First + A).Output;
                  begin
                     if Output /= No_Slot then
                        Eligible (Positive (Output)) := False;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         --  An eligible slot is a scalar whose address nothing takes:
         --  every instruction that names it any other way than as a load
         --  or store target, as a source or destination storage, or as an
         --  assembly output made it ineligible above.  So only its own
         --  loads and stores reach it, and a call, an indirect or element
         --  store or a memory event can neither read nor write it.  An
         --  assembly block remains a barrier for every slot: its text is
         --  opaque, and [1630] keeps it ordered against all memory.
         --
         --  A plain local store has no observer before the next store to
         --  that slot in this block.  A load of it, the block boundary or
         --  an assembly block ends the proof, and so does a call: while
         --  the callee runs, a debugger shows this frame's variables.  Its
         --  value preparation remains subject to the backward demand
         --  pass, which keeps any calls or traps.
         for V in Alias'Range loop
            declare
               Code : constant Instruction := Code_At (Value_Id (V));
            begin
               if Code.In_Block /= Last_Block then
                  Forget_Pending;
                  Last_Block := Code.In_Block;
               end if;
               if Code.Op = Store and then Eligible (Positive (Code.Slot))
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
               elsif Code.Op = Load and then Eligible (Positive (Code.Slot))
               then
                  Pending (Positive (Code.Slot)) := No_Value;
               elsif Effects.Of_Code (Code.Op).Calls then
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
                  for Index in 1 .. Filled_Count loop
                     Table (Filled (Index)) := No_Value;
                  end loop;
                  Filled_Count := 0;
                  Last_Block := Code.In_Block;
               end if;
               Class (V) := Value_Id (V);
               for A in 1 .. Code.Args loop
                  Into.Operands.Replace_Element
                    (Code.First_Arg + A, Alias (Positive
                       (Into.Operands.Element (Code.First_Arg + A))));
               end loop;
               if Code.Op = Load and then Eligible (Positive (Code.Slot))
                 and then Stored (Positive (Code.Slot)) /= No_Value
               then
                  Alias (V) := Stored (Positive (Code.Slot));
                  Keep (Held.Values.First + V) := False;
               elsif Code.Op = Load and then Eligible (Positive (Code.Slot))
                 and then First_Load (Positive (Code.Slot)) /= No_Value
               then
                  Class (V) := Class
                    (Positive (First_Load (Positive (Code.Slot))));
               else
                  if not Required_Proof (V) then
                     Fold (Code);
                     declare
                        Same_As : Value_Id;
                     begin
                        Apply_Identity (Code, Same_As);
                        if Same_As = No_Value and then Numbered (Code) then
                           Same_As := Earlier_Same (V, Code);
                        end if;
                        if Same_As /= No_Value then
                           Alias (V) := Same_As;
                           Keep (Held.Values.First + V) := False;
                        end if;
                     end;
                  end if;
                  if Code.Op = Branch then
                     declare
                        Condition : constant Instruction := Code_At
                          (Into.Operands.Element (Code.First_Arg + 1));
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
               --  For the same reason the slot's value survives every
               --  instruction but its own stores and an assembly block.  A
               --  load that found nothing to forward lends its class to
               --  any later load of the slot in this block until then.
               if Code.Op = Store and then Eligible (Positive (Code.Slot))
               then
                  Remember
                    (Code.Slot, Into.Operands.Element (Code.First_Arg + 1));
               elsif Code.Op = Load and then Eligible (Positive (Code.Slot))
                 and then First_Load (Positive (Code.Slot)) = No_Value
                 and then Alias (V) = Value_Id (V)
               then
                  Remember (Code.Slot, Value_Id (V), Is_Load => True);
               elsif Code.Op = Assembly then
                  Forget_Stores;
               end if;
               if Effects.Of_Code (Code.Op).Writes
                 and then Code.Slot /= No_Slot
               then
                  Last_Write (Positive (Code.Slot)) := Value_Id (V);
               end if;
               for A in 1 .. Code.Assembly_Run.Count loop
                  declare
                     Output : constant Slot_Id :=
                       Into.Assembly_Operands.Element
                         (Code.Assembly_Run.First + A).Output;
                  begin
                     if Output /= No_Slot then
                        Last_Write (Positive (Output)) := Value_Id (V);
                     end if;
                  end;
               end loop;
            end;
         end loop;
         --  An eligible slot is read only by its loads.  Once forwarding
         --  has replaced the last of them, a compiler temporary's stores
         --  have no observer: lowering's carried left operand is the
         --  common case.  A declared slot keeps its stores, because they
         --  are its variable's home for the debugger.
         for V in Alias'Range loop
            if Keep (Held.Values.First + V)
              and then Code_At (Value_Id (V)).Op = Load
            then
               Loaded (Positive (Code_At (Value_Id (V)).Slot)) := True;
            end if;
         end loop;
         for V in Alias'Range loop
            declare
               Code : constant Instruction := Code_At (Value_Id (V));
            begin
               if Code.Op = Store and then Eligible (Positive (Code.Slot))
                 and then not Loaded (Positive (Code.Slot))
                 and then Code.Slot /= Result_Slot (Into, Item)
                 and then Into.Slots.Element
                   (Held.Slots.First + Positive (Code.Slot)).Declaration
                   = No_Declaration
               then
                  Keep (Held.Values.First + V) := False;
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
                        Needed (Positive (Into.Operands.Element
                          (Code.First_Arg + A))) := True;
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
