with Interfaces;
with Landin.IR.Effects;
with Landin.IR.Rewriting;
with Landin.IR.Verifier;

package body Landin.IR.Simplification is
   use type Interfaces.Unsigned_64;
   use type Landin.Optimization.Objective;
   subtype Bits is Interfaces.Unsigned_64;
   subtype Integer_Value is Landin.Types.Folded;

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
      Objective : Landin.Optimization.Objective)
   is
      Keep : Rewriting.Keep_Array (1 .. Natural (Into.Code.Length)) :=
        [others => True];

      procedure Simplify (Item : Item_Id);

      procedure Simplify (Item : Item_Id) is
         Held : constant Item_Record := Into.Items (Positive (Item));
         Alias : array (1 .. Held.Values.Count) of Value_Id;
         Needed : array (1 .. Held.Values.Count) of Boolean :=
           [others => False];
         Required_Proof : array (1 .. Held.Values.Count) of Boolean :=
           [others => False];
         Eligible : array (1 .. Held.Slots.Count) of Boolean;
         Stored : array (1 .. Held.Slots.Count) of Value_Id :=
           [others => No_Value];
         Last_Block : Block_Id := No_Block;

         function Code_At (Value : Value_Id) return Instruction
           is (Into.Code (Held.Values.First + Positive (Value)));

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
              and then Plain (Code);
         end Removable;
      begin
         for S in Eligible'Range loop
            declare
               Slot : constant Slot_Record := Into.Slots
                 (Held.Slots.First + S);
            begin
               Eligible (S) := not Slot.Aggregate and then not Slot.Array_Shape
                 and then not Slot.Addressed and then Slot.Pointee = No_Pointee
                 and then Slot.Signature = No_Signature
                 and then Slot.Atom_Set = No_Atom_Set
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
               end if;
            end;
         end loop;
         for V in Alias'Range loop
            declare
               Code : Instruction := Code_At (Value_Id (V));
            begin
               if Code.In_Block /= Last_Block then
                  Stored := [others => No_Value];
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
                  Stored (Positive (Code.Slot)) :=
                    Into.Operands (Code.First_Arg + 1);
               elsif Effects.Of_Code (Code.Op).Writes then
                  Stored := [others => No_Value];
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
      Verifier.Verify (Into, Facts);
      if Objective = Landin.Optimization.None then
         return;
      end if;
      for I in 1 .. Item_Count (Into) loop
         if Kind_Of (Into, Item_Id (I)) = Routine
           and then not Is_External (Into, Item_Id (I))
         then
            Simplify (Item_Id (I));
         end if;
      end loop;
      Rewriting.Compact (Into, Keep);
      Verifier.Verify (Into, Facts);
   end Run;
end Landin.IR.Simplification;
