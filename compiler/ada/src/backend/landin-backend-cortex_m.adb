with Landin.Backend.Firmware;
with Landin.Machine;
with Landin.Layouts;
with Landin.Packed;
with Landin.Memory;
with Landin.Targets.Packed;
with Ada.Strings.Fixed;
with Landin.Backend.Arm32_ABI;
with Landin.Backend.Work_Arrays;
with Landin.Types;

package body Landin.Backend.Cortex_M is

   use type Landin.Machine.Convention;

   package Unbounded renames Ada.Strings.Unbounded;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Scalar_Size;
   use type Landin.IR.Atom_Set_Id;
   use type Landin.IR.Declaration_Id;
   use type Landin.IR.Item_Kind;
   use type Landin.IR.Item_Id;
   use type Landin.IR.Opcode;
   use type Landin.IR.Signature_Id;
   use type Landin.IR.Slot_Id;
   use type Landin.IR.Element_Total;
   use type Landin.IR.Field_Image_Form;
   use type Landin.IR.Field_Shape_Kind;
   use type Landin.Types.Folded;
   use type Landin.Types.Type_Kind;

   use type Landin.Targets.Target_Facts;
   use type Landin.Layouts.Policy;
   use type Landin.Targets.C_ABI_Kind;

   LF : constant Character := Character'Val (10);

   --  `Image` leads with a blank for a non-negative number and assembly
   --  is bytes, so the blank is a byte.  Landin.IR.Dump's trim, for the
   --  same reason.
   function Trimmed (Value : String) return String
     is (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

   --  A source atom identity is neutral.  Cortex gives atoms dense,
   --  nonzero u32 codes in declaration-identity order; zero stays available
   --  for the successful half of R2.30's failing-call carrier.
   function Atom_Code
     (Of_Unit : Landin.IR.Unit;
      Identity : Landin.IR.Declaration_Id) return Positive;

   function Atom_Code
     (Of_Unit : Landin.IR.Unit;
      Identity : Landin.IR.Declaration_Id) return Positive
   is
      Result : Natural := 0;

      function Is_Atom
        (Candidate : Landin.IR.Declaration_Id) return Boolean;

      function Is_Atom
        (Candidate : Landin.IR.Declaration_Id) return Boolean
      is
      begin
         for Set_Index in 1 .. Landin.IR.Atom_Set_Count (Of_Unit) loop
            declare
               Set_Id : constant Landin.IR.Atom_Set_Id :=
                 Landin.IR.Atom_Set_Id (Set_Index);
            begin
               for Index in 1 .. Landin.IR.Atom_Count (Of_Unit, Set_Id) loop
                  if Landin.IR.Nth_Atom (Of_Unit, Set_Id, Index)
                    = Candidate
                  then
                     return True;
                  end if;
               end loop;
            end;
         end loop;
         return False;
      end Is_Atom;
   begin
      for Candidate in Landin.IR.Declaration_Id'(1) .. Identity loop
         if Is_Atom (Candidate) then
            Result := Result + 1;
         end if;
      end loop;
      if Result = 0 then
         raise Landin.Compiler_Defect with
           "an atom instruction names no atom-set member";
      end if;
      return Positive (Result);
   end Atom_Code;

   subtype Held_Size is Landin.Targets.Scalar_Size
     range Landin.Targets.Byte_1 .. Landin.Targets.Byte_8;

   --  A datum's value, held as the bit pattern the target will store.  A
   --  module value is folded rather than run [1940], and `Landin.IR`'s own
   --  header says why the folding lands here: the checker declines the
   --  bitwise and shift levels because [0320]'s zero-fill needs a width,
   --  and a width needs a target.  This is that width's side of the seam.
   --
   --  The widest enabled type is 64 bits, so one modular type covers every
   --  fold and narrower ones are masked back to their own width after each
   --  operation.  This asks the host nothing: the modulus is written out,
   --  exactly as `Landin.Types.Folded`'s bound is.
   type Pattern is mod 2 ** 64;

   function Mask
     (Value : Pattern; Bits : Landin.Targets.Bit_Width) return Pattern
     is (if Bits >= 64 then Value
         else Value and (2 ** Natural (Bits) - 1));

   --  Whether a pattern's top bit is set at that width, which for a signed
   --  type is what makes it negative.
   function Is_Negative
     (Value : Pattern; Bits : Landin.Targets.Bit_Width) return Boolean
     is ((Value and 2 ** (Natural (Bits) - 1)) /= 0);

   --  A number read as the pattern the target stores, and back again.  A
   --  fold works in numbers, because a module value has no moment in which
   --  to trap [1460] and so the whole expression is worked out before any
   --  type is asked to hold it; these two are for the operators that are
   --  about a width rather than about a number -- the wrapping forms, the
   --  bitwise set and the shifts.
   function To_Pattern
     (Value : Landin.Types.Folded;
      Bits  : Landin.Targets.Bit_Width) return Pattern
     is (if Value < 0
         then Mask (0 - Pattern (-Value), Bits)
         else Mask (Pattern (Value), Bits));

   function As_Number
     (Value  : Pattern;
      Bits   : Landin.Targets.Bit_Width;
      Signed : Boolean) return Landin.Types.Folded
     is (if Signed and then Is_Negative (Value, Bits)
         then -Landin.Types.Folded (Mask (0 - Value, Bits))
         else Landin.Types.Folded (Value));

   --  How wide a fold works at.  `Landin.Types.Width` answers for the
   --  enabled integers only, and a bool is [1870]'s zero or one in the byte
   --  `Landin.Backend` gives it, so it folds at that byte's width.
   function Fold_Width
     (Kind : Landin.Types.Scalar_Name;
      Facts : Landin.Targets.Target_Facts) return Landin.Targets.Bit_Width
     is (if Kind in Landin.Types.Integer_Name
         then Landin.Types.Width (Landin.Types.Integer_Name (Kind), Facts)
         else 8);

   --  All source places stay pinned. Verified scalar temporaries are block
   --  local: an operand's last read precedes reuse, including across calls.
   --  Scratch registers belong to selection; eight-byte spill homes hold any
   --  admitted scalar without a second calling convention or host-sized math.
   function Allocated_Frame
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Frame;

   function Allocated_Frame
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count) return Frame
   is
      package IR renames Landin.IR;
      package L renames Landin.Targets.Layouts;
      package Masks is new Work_Arrays (Boolean, Home_Mask, True);
      package Numbers is new Work_Arrays (Natural, Spill_Assignments, 0);
      package Extents is new Work_Arrays
        (L.Field_Extent, L.Field_Extent_Array, (8, 8));
      Slots : Masks.Buffer (IR.Slot_Count (Of_Unit, Item));
      Values : Numbers.Buffer (IR.Value_Count (Of_Unit, Item));
      Last : Numbers.Buffer (IR.Value_Count (Of_Unit, Item));
      Free_After : Numbers.Buffer (IR.Value_Count (Of_Unit, Item));
      Spills : Extents.Buffer (IR.Value_Count (Of_Unit, Item));
      Count : Natural := 0;
   begin
      for Block in 1 .. IR.Block_Count (Of_Unit, Item) loop
         for Home in 1 .. Count loop
            Free_After.Data (Home) := 0;
         end loop;
         for Position in 1 .. IR.Length
           (Of_Unit, Item, IR.Block_Id (Block))
         loop
            declare
               Value : constant IR.Value_Id := IR.Nth_Value
                 (Of_Unit, Item, IR.Block_Id (Block), Position);
            begin
               Last.Data (Positive (Value)) := Position;
               for Index in 1 .. IR.Operand_Count (Of_Unit, Item, Value) loop
                  Last.Data (Positive (IR.Nth_Operand
                    (Of_Unit, Item, Value, Index))) := Position;
               end loop;
            end;
         end loop;
         for Position in 1 .. IR.Length
           (Of_Unit, Item, IR.Block_Id (Block))
         loop
            declare
               Value : constant IR.Value_Id := IR.Nth_Value
                 (Of_Unit, Item, IR.Block_Id (Block), Position);
               Home : Positive := 1;
            begin
               if IR.Result_Of (Of_Unit, Item, Value)
                 in Landin.Types.Scalar_Name
               then
                  while Home <= Count
                    and then Free_After.Data (Home) >= Position
                  loop
                     Home := Home + 1;
                  end loop;
                  Count := Natural'Max (Count, Home);
                  Values.Data (Positive (Value)) := Home;
                  Free_After.Data (Home) := Last.Data (Positive (Value));
               end if;
            end;
         end loop;
      end loop;
      return Laid_Out
        (Of_Unit, Item, Facts, Slots.Data.all, Values.Data.all,
         Spills.Data (1 .. Count), L.Field_Extent_Array'(1 .. 0 => <>),
         Maximum);
   end Allocated_Frame;

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Boolean
   is
      pragma Unreferenced (Options);
      Layout : Frame;
      Limit : constant Landin.Targets.Byte_Count := 16#FFFF_FFC0#;
   begin
      if Facts /= Landin.Targets.Cortex_M then
         return False;
      end if;
      if Landin.IR.Is_External (Of_Unit, Item) then
         return True;
      end if;
      Layout := Allocated_Frame (Of_Unit, Item, Facts, Limit);
      --  Include caller staging and the largest transient selector scratch.
      --  Physical RAM belongs to the selected image, not this address bound.
      for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
         for Position in 1 .. Landin.IR.Length
           (Of_Unit, Item, Landin.IR.Block_Id (Block))
         loop
            declare
               Value : constant Landin.IR.Value_Id := Landin.IR.Nth_Value
                 (Of_Unit, Item, Landin.IR.Block_Id (Block), Position);
            begin
               if Landin.IR.Op_Of (Of_Unit, Item, Value)
                 in Landin.IR.Call | Landin.IR.Indirect_Call
               then
                  declare
                     Call : constant Arm32_ABI.Plan := Arm32_ABI.Call_Plan
                       (Of_Unit, Item, Value, Facts, Limit - Extent (Layout));
                     pragma Unreferenced (Call);
                  begin
                     null;
                  end;
               end if;
            end;
         end loop;
      end loop;
      return Extent (Layout) <= Limit;
   exception
      when Stack_Limit_Exceeded => return False;
   end Frame_Is_Addressable;

   procedure Emit
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Options  : Landin.Optimization.Options;
      Assembly : out Unbounded.Unbounded_String;
      Report   : in out Landin.Build_Reports.Report;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item;
      Debug : access constant Landin.Debugging.Information := null;
      Firmware_Entry : Landin.IR.Item_Id := Landin.IR.No_Item)
   is
      Out_Text : Unbounded.Unbounded_String;
      Serial : Natural := 0;
      Instruction_Count : Natural := 0;
      pragma Unreferenced (Options, Debug);

      function Fresh return String;
      procedure Put (Line : String);
      procedure Emit (Instruction : String);
      procedure Immediate (Register : String; Value : Pattern);
      procedure Address (Register, Name : String; Imported : Boolean := False);
      procedure Add_Offset
        (Register : String; Offset : Landin.Targets.Byte_Count);
      procedure Frame_Address
        (Offset : Landin.Targets.Byte_Count; Register : String := "r6");
      procedure Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String);
      procedure Reserve (Bytes : Landin.Targets.Byte_Count);
      procedure Release (Bytes : Landin.Targets.Byte_Count);
      procedure Copy_Bytes (Bytes : Landin.Targets.Byte_Count);
      procedure Zero_Bytes (Bytes : Landin.Targets.Byte_Count);
      function High (Register : String) return String;



      procedure Put (Line : String) is
      begin
         Unbounded.Append (Out_Text, Line & LF);
      end Put;

      procedure Emit (Instruction : String) is
      begin
         if Instruction'Length > 0
           and then Instruction (Instruction'First) /= '.'
         then
            Instruction_Count := Instruction_Count + 1;
         end if;
         Put (Character'Val (9) & Instruction);
      end Emit;

      function High (Register : String) return String is
        (case Register (Register'Last) is
            when '0' => "r1", when '2' => "r3", when '4' => "r5",
            when others => raise Compiler_Defect with "invalid word pair");

      --  Every literal is adjacent to its load and skipped in execution.
      --  No pool-distance assumption depends on cleanup expansion or layout.
      procedure Address (Register, Name : String; Imported : Boolean := False)
      is
         pragma Unreferenced (Imported);
         Id : constant String := Fresh;
      begin
         Emit ("ldr " & Register & ", " & Id);
         Emit ("b " & Id & "_end");
         Emit (".balign 4");
         Put (Id & ":");
         Emit (".word " & Name);
         Put (Id & "_end:");
      end Address;

      procedure Immediate (Register : String; Value : Pattern) is
      begin
         if Value > 16#FFFF_FFFF# then
            raise Compiler_Defect with "word constant exceeds ARMv6-M";
         elsif Value <= 255 then
            Emit ("movs " & Register & ", #" & Trimmed (Value'Image));
         else
            for Shift in 1 .. 31 loop
               if Value mod 2 ** Shift = 0
                 and then Value / 2 ** Shift <= 255
               then
                  Emit ("movs " & Register & ", #"
                    & Trimmed (Pattern'Image (Value / 2 ** Shift)));
                  Emit ("lsls " & Register & ", " & Register & ", #"
                    & Trimmed (Integer'Image (Shift)));
                  return;
               end if;
            end loop;
            Address (Register, Trimmed (Value'Image));
         end if;
      end Immediate;

      procedure Add_Offset
        (Register : String; Offset : Landin.Targets.Byte_Count) is
      begin
         if Offset in 1 .. 255 then
            Emit ("adds " & Register & ", #" & Trimmed (Offset'Image));
         elsif Offset > 0 then
            Immediate ("r7", Pattern (Offset));
            Emit ("adds " & Register & ", " & Register & ", r7");
         end if;
      end Add_Offset;

      procedure Frame_Address
        (Offset : Landin.Targets.Byte_Count; Register : String := "r6") is
      begin
         Emit ("mov " & Register & ", r11");
         if Offset <= 255 then
            Emit ("subs " & Register & ", #" & Trimmed (Offset'Image));
         else
            Immediate ("r7", Pattern (Offset));
            Emit ("subs " & Register & ", " & Register & ", r7");
         end if;
      end Frame_Address;

      procedure Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String) is
         Op : constant String := (if Store then "str" else "ldr");
      begin
         Emit (Op & (case Size is
           when Landin.Targets.Byte_1 => "b",
           when Landin.Targets.Byte_2 => "h", when others => "")
           & " " & Register & ", [" & Base & "]");
         if Size = Landin.Targets.Byte_8 then
            Emit (Op & " " & High (Register) & ", [" & Base & ", #4]");
         end if;
      end Memory;

      procedure Reserve (Bytes : Landin.Targets.Byte_Count) is
      begin
         if Bytes in 1 .. 508 and then Bytes mod 4 = 0 then
            Emit ("sub sp, #" & Trimmed (Bytes'Image));
         elsif Bytes > 0 then
            Immediate ("r7", Pattern (Bytes));
            Emit ("mov r6, sp");
            Emit ("subs r6, r6, r7");
            Emit ("mov sp, r6");
         end if;
      end Reserve;

      procedure Release (Bytes : Landin.Targets.Byte_Count) is
      begin
         if Bytes in 1 .. 508 and then Bytes mod 4 = 0 then
            Emit ("add sp, #" & Trimmed (Bytes'Image));
         elsif Bytes > 0 then
            Immediate ("r7", Pattern (Bytes));
            Emit ("add sp, r7");
         end if;
      end Release;

      --  Ordinary copies only: never use this loop for a volatile transaction.
      --  r0 destination, r2 source. Call arguments live in stack homes first.
      procedure Copy_Bytes (Bytes : Landin.Targets.Byte_Count) is
         Id : constant String := Fresh;
      begin
         if Bytes = 0 then
            return;
         end if;
         Immediate ("r4", Pattern (Bytes));
         Put (Id & ":");
         Emit ("ldrb r5, [r2]");
         Emit ("strb r5, [r0]");
         Emit ("adds r2, #1");
         Emit ("adds r0, #1");
         Emit ("subs r4, #1");
         Emit ("bne " & Id);
      end Copy_Bytes;

      procedure Zero_Bytes (Bytes : Landin.Targets.Byte_Count) is
         Id : constant String := Fresh;
      begin
         if Bytes = 0 then
            return;
         end if;
         Immediate ("r4", Pattern (Bytes));
         Emit ("movs r5, #0");
         Put (Id & ":");
         Emit ("strb r5, [r0]");
         Emit ("adds r0, #1");
         Emit ("subs r4, #1");
         Emit ("bne " & Id);
      end Zero_Bytes;
      --  Allocate one namespace before emitting anything.  Forced linker
      --  identities are reserved first, including imports whose source names
      --  differ.  Ordinary routines, anonymous items and data then keep their
      --  readable names when free, or receive a deterministic unused mangle.
      --  A candidate must avoid both forced names and other source names:
      --  even `landin_1_foo` can be an explicit C name or an ordinary datum.
      function Symbol (Item : Landin.IR.Item_Id) return String;
      function Evidence_Symbol (Id : Landin.IR.Evidence_Id) return String;
      function Is_Public_Item (Item : Landin.IR.Item_Id) return Boolean;

      Allocated_Symbols : array
        (1 .. Positive'Max (1, Landin.IR.Item_Count (Of_Unit))) of
          Unbounded.Unbounded_String;

      function Is_C_Item (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
            and then Landin.IR.Signature_Uses_C_ABI
              (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item)));

      function Is_Forced (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Link_Symbol (Of_Unit, Item)
              /= Landin.Source.Names.No_Name
            or else Item = Hosted_Entry
            or else Landin.IR.Is_External (Of_Unit, Item));

      --  Pick a disjoint prefix for generated local labels. External source
      --  identities retain their ELF spelling at the rendering seam.
      function Unused_Local_Prefix return String;

      function Unused_Local_Prefix return String is
         Candidate : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String ("L");
         Collides : Boolean;
      begin
         loop
            Collides := False;
            for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
               declare
                  Id : constant Landin.IR.Item_Id :=
                    Landin.IR.Item_Id (Position);
                  Declared : constant Landin.IR.Declaration_Id :=
                    Landin.IR.Declares (Of_Unit, Id);
                  Explicit_Link : constant Landin.Source.Names.Name_Id :=
                    Landin.IR.Link_Symbol (Of_Unit, Id);
                  Link : constant Landin.Source.Names.Name_Id :=
                    (if Explicit_Link /= Landin.Source.Names.No_Name
                     then Explicit_Link
                     elsif Declared /= Landin.IR.No_Declaration
                     then Landin.Resolution.Name_Of (Meanings, Declared)
                     else Landin.Source.Names.No_Name);
               begin
                  if Link /= Landin.Source.Names.No_Name then
                     declare
                        Spelling : constant String :=
                          Landin.Source.Names.Spelling (Names, Link);
                        Prefix : constant String :=
                          Unbounded.To_String (Candidate);
                     begin
                        if Spelling'Length >= Prefix'Length
                          and then Spelling
                            (Spelling'First
                             .. Spelling'First + Prefix'Length - 1) = Prefix
                        then
                           Collides := True;
                           exit;
                        end if;
                     end;
                  end if;
               end;
            end loop;
            exit when not Collides;
            Unbounded.Append (Candidate, "_");
         end loop;
         return Unbounded.To_String (Candidate);
      end Unused_Local_Prefix;

      Local_Prefix : constant String := Unused_Local_Prefix;

      function Fresh return String is
      begin
         Serial := Serial + 1;
         return Local_Prefix & "cm_step_" & Trimmed (Serial'Image);
      end Fresh;

      --  Linker identity, not assembly syntax.  This is also available before
      --  allocation, when discovery decides which runtime names to reserve.
      function Source_Symbol (Item : Landin.IR.Item_Id) return String;

      function Source_Symbol (Item : Landin.IR.Item_Id) return String is
         Declared : constant Landin.IR.Declaration_Id :=
           Landin.IR.Declares (Of_Unit, Item);
      begin
         if Landin.IR.Link_Symbol (Of_Unit, Item)
           /= Landin.Source.Names.No_Name
         then
            return Landin.Source.Names.Spelling
              (Names, Landin.IR.Link_Symbol (Of_Unit, Item));
         elsif Declared = Landin.IR.No_Declaration then
            return Local_Prefix & "landin_anonymous_"
              & Trimmed (Landin.IR.Item_Id'Image (Item));
         end if;
         return Landin.Source.Names.Spelling
           (Names, Landin.Resolution.Name_Of (Meanings, Declared));
      end Source_Symbol;

      procedure Allocate_Symbols;

      procedure Allocate_Symbols is
         function Available
           (Candidate : String; Item : Landin.IR.Item_Id) return Boolean;

         function Available
           (Candidate : String; Item : Landin.IR.Item_Id) return Boolean
         is
         begin
            if (Candidate'Length >= 8
                and then Candidate (Candidate'First
                  .. Candidate'First + 7) = "__aeabi_")
              or else Ada.Strings.Fixed.Index
                (Candidate, "_landin_firmware_") = Candidate'First
            then
               return False;
            end if;
            for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
               declare
                  Other : constant Landin.IR.Item_Id :=
                    Landin.IR.Item_Id (Position);
               begin
                  if Other /= Item
                    and then
                      (Unbounded.To_String (Allocated_Symbols (Position))
                         = Candidate
                       or else Source_Symbol (Other) = Candidate)
                  then
                     return False;
                  end if;
               end;
            end loop;
            return True;
         end Available;
      begin
         for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Position);
            begin
               if Is_Forced (Item) then
                  Allocated_Symbols (Position) :=
                    Unbounded.To_Unbounded_String (Source_Symbol (Item));
               end if;
            end;
         end loop;
         for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Position);
               Declared : constant Landin.IR.Declaration_Id :=
                 Landin.IR.Declares (Of_Unit, Item);
               Spelling : constant String := Source_Symbol (Item);
            begin
               if not Is_Forced (Item) then
                  if not Is_C_Item (Item) and then Available (Spelling, Item)
                  then
                     Allocated_Symbols (Position) :=
                       Unbounded.To_Unbounded_String (Spelling);
                  else
                     declare
                        Base : constant String :=
                          (if Declared = Landin.IR.No_Declaration
                           then Spelling
                           else "landin_"
                             & Trimmed
                               (Landin.IR.Declaration_Id'Image (Declared))
                             & "_" & Spelling);
                        Candidate : Unbounded.Unbounded_String :=
                          Unbounded.To_Unbounded_String (Base);
                        Attempt : Natural := 0;
                     begin
                        while not Available
                          (Unbounded.To_String (Candidate), Item)
                        loop
                           Attempt := Attempt + 1;
                           Candidate := Unbounded.To_Unbounded_String
                             (Base & "_" & Trimmed (Natural'Image (Attempt)));
                        end loop;
                        Allocated_Symbols (Position) := Candidate;
                     end;
                  end if;
               end if;
            end;
         end loop;
      end Allocate_Symbols;

      --  Render the allocated ELF symbol identity.
      --  Namespace comparisons retain the source identity.
      function Symbol (Item : Landin.IR.Item_Id) return String is
         Spelling : constant String :=
           Unbounded.To_String (Allocated_Symbols (Positive (Item)));
      begin
         if Spelling'Length = 0 then
            raise Landin.Compiler_Defect with
              "an unallocated linker symbol reached assembly rendering";
         elsif Spelling = "." or else Spelling (Spelling'First) = '$' then
            return '"' & Spelling & '"';
         end if;
         return Spelling;
      end Symbol;

      function Evidence_Symbol (Id : Landin.IR.Evidence_Id) return String
        is (Local_Prefix & "landin_evidence_"
            & Trimmed (Landin.IR.Evidence_Id'Image (Id)));

      function Is_Public_Item (Item : Landin.IR.Item_Id) return Boolean
      is
         Declared : constant Landin.IR.Declaration_Id :=
           Landin.IR.Declares (Of_Unit, Item);
      begin
         return Is_Forced (Item)
           or else (Declared /= Landin.IR.No_Declaration
             and then Landin.Resolution.Is_Public (Meanings, Declared));
      end Is_Public_Item;

      --  Labels carry the item, because a Block_Id restarts at 1 in the
      --  next item and two blocks named `.L1` would be one label.
      function Label
        (Item : Landin.IR.Item_Id; Block : Landin.IR.Block_Id)
        return String
        is (Local_Prefix & Trimmed (Landin.IR.Item_Id'Image (Item))
            & "_" & Trimmed (Landin.IR.Block_Id'Image (Block)));

      --  Where a field of [0670]'s state sits, and how much room the
      --  whole of it takes.  Worked out here from the item's own field
      --  types rather than read from a table the IR would have had to
      --  carry, because an offset needs a target: this is
      --  Landin.Targets.Placement over the same run against the same
      --  description the checker used, so the two cannot disagree.
      procedure Place_Fields
        (Item   : Landin.IR.Item_Id;
         Placed : out Landin.Targets.Placement;
         Wanted : Landin.IR.Element_Total;
         Offset : out Landin.Targets.Byte_Count);

      procedure Place_Fields
        (Item   : Landin.IR.Item_Id;
         Placed : out Landin.Targets.Placement;
         Wanted : Landin.IR.Element_Total;
         Offset : out Landin.Targets.Byte_Count) is
      begin
         Placed := Landin.Targets.Empty_Placement;
         Offset := 0;

         --  [0520]'s array is its element repeated, so where a part sits
         --  is one multiplication rather than a walk: the count reaches
         --  four billion and placing each in turn would take as long.
         if Landin.IR.Result_Of (Of_Unit, Item) = Landin.Types.Fixed_Array
         then
            declare
               --  D122 admits an aggregate element, so the stride is the
               --  element shape's own extent and not a scalar width.
               Size : Landin.Targets.Byte_Count;
               Alignment : Landin.Targets.Byte_Alignment;
            begin
               Landin.Backend.Field_Extent
                 (Of_Unit,
                  Landin.IR.Array_Element_Shape (Of_Unit, Item),
                  Facts, Size, Alignment);
               if Wanted > 0 then
                  Offset :=
                    Landin.Targets.Byte_Count (Wanted - 1) * Size;
               end if;
            end;

            return;
         end if;

         declare
            Plan : constant Landin.Targets.Layouts.Plan :=
              Datum_Layout (Of_Unit, Item, Facts);
            Ignored : Landin.Targets.Byte_Count;
         begin
            Landin.Targets.Place (Placed, Plan.Size, Plan.Alignment, Ignored);
            if Wanted > 0 then
               Offset := Plan.Offsets (Positive (Wanted));
            end if;
         end;
      end Place_Fields;

      function Field_Offset
        (Item : Landin.IR.Item_Id; Field : Landin.IR.Part_Position)
        return Landin.Targets.Byte_Count;

      function Field_Offset
        (Item : Landin.IR.Item_Id; Field : Landin.IR.Part_Position)
        return Landin.Targets.Byte_Count
      is
         Placed : Landin.Targets.Placement;
         Offset : Landin.Targets.Byte_Count;
      begin
         Place_Fields
           (Item, Placed, Landin.IR.Element_Total (Field), Offset);
         return Offset;
      end Field_Offset;

      procedure Select_Section
        (Item : Landin.IR.Item_Id; Prefix, Flags : String);
      procedure Select_Section
        (Item : Landin.IR.Item_Id; Prefix, Flags : String)
      is
         Attr : constant Landin.Machine.Placement :=
           Landin.IR.Placement_Of (Of_Unit, Item);
         Name : constant String :=
           (if Attr.Section = Landin.Source.Names.No_Name
            then Prefix & "landin_" & Trimmed (Item'Image)
            else Landin.Source.Names.Spelling (Names, Attr.Section));
         Retained : Boolean := Attr.Keep;
         BSS : constant Boolean :=
           Ada.Strings.Fixed.Index (Name, ".bss.") = Name'First;
      begin
         if Attr.Section /= Landin.Source.Names.No_Name then
            for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
               declare
                  Other : constant Landin.Machine.Placement :=
                    Landin.IR.Placement_Of
                      (Of_Unit, Landin.IR.Item_Id (Index));
               begin
                  if Other.Section = Attr.Section then
                     Retained := Retained or else Other.Keep;
                  end if;
               end;
            end loop;
         end if;
         Emit (".section " & Name & ",""" & Flags
           & (if Retained then "R" else "") & """,%"
           & (if BSS then "nobits" else "progbits"));
         if Attr.Alignment /= 0 then
            Emit (".balign " & Trimmed (Attr.Alignment'Image));
         end if;
      end Select_Section;

      procedure Emit_Vectors;
      procedure Emit_Vectors is
         Handlers : array (2 .. 47) of Landin.IR.Item_Id :=
           [others => Landin.IR.No_Item];
      begin
         for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
               Slot : constant Natural :=
                 Landin.IR.Placement_Of (Of_Unit, Item).Vector;
            begin
               if Slot /= 0 then
                  Handlers (Slot) := Item;
               end if;
            end;
         end loop;
         Emit (".section .isr_vector,""a"",%progbits");
         Emit (".balign 256");
         Emit (".globl _landin_firmware_vectors");
         Put ("_landin_firmware_vectors:");
         Emit (".word _landin_firmware_stack_top");
         Emit (".word _landin_firmware_reset");
         for Slot in Handlers'Range loop
            if Slot in 4 .. 10 | 12 | 13 | 21 | 42 .. 47 then
               Emit (".word 0");
            elsif Handlers (Slot) /= Landin.IR.No_Item then
               Emit (".word " & Symbol (Handlers (Slot)));
            else
               Emit (".word _landin_firmware_unhandled");
            end if;
         end loop;
      end Emit_Vectors;

      procedure Emit_Routine (Item : Landin.IR.Item_Id);

      procedure Emit_Routine (Item : Landin.IR.Item_Id) is
         Before_Emit : constant Natural := Instruction_Count;
         Layout : constant Frame := Allocated_Frame
           (Of_Unit, Item, Facts, 16#FFFF_FFC0#);
         Result : constant Landin.Types.Type_Kind :=
           Landin.IR.Result_Of (Of_Unit, Item);
         Plan : constant Arm32_ABI.Plan := Arm32_ABI.Signature_Plan
           (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts);
         Homes : constant Landin.Targets.Byte_Count := Extent (Layout) + 16;
         Trap : constant String := Label (Item, 1) & "_trap";
         Current_Value : Landin.IR.Value_Id := Landin.IR.No_Value;
         function Kind (Value : Landin.IR.Value_Id)
           return Landin.Types.Scalar_Name
           is (Landin.IR.Result_Of (Of_Unit, Item, Value));
         function Size_Of_Value (Value : Landin.IR.Value_Id) return Held_Size
           is (Size_Of (Kind (Value), Facts));
         procedure Load_Value
           (Value : Landin.IR.Value_Id; Register : String := "r0");
         procedure Store_Value
           (Value : Landin.IR.Value_Id; Register : String := "r0");
         procedure Load_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "r0");
         procedure Store_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "r0");
         procedure Branch (Condition, Target : String);
         procedure Jump (Target : String);
         procedure Extend (Register : String; Scalar : Landin.Types.Type_Kind);
         procedure Epilogue;

         procedure Jump (Target : String) is
            Id : constant String := Fresh;
         begin
            Emit ("ldr r7, " & Id);
            Emit ("bx r7");
            Emit (".balign 4");
            Put (Id & ":");
            Emit (".word " & Target & " + 1");
         end Jump;

         procedure Branch (Condition, Target : String) is
            Skip : constant String := Fresh;
            Inverse : constant String :=
              (if Condition = "eq" then "ne"
               elsif Condition = "ne" then "eq"
               elsif Condition = "cs" then "cc"
               elsif Condition = "cc" then "cs"
               elsif Condition = "hi" then "ls"
               elsif Condition = "ls" then "hi"
               elsif Condition = "lt" then "ge"
               elsif Condition = "ge" then "lt"
               elsif Condition = "gt" then "le"
               elsif Condition = "le" then "gt"
               elsif Condition = "vs" then "vc"
               elsif Condition = "vc" then "vs"
               else raise Compiler_Defect with "invalid ARM condition");
         begin
            Emit ("b" & Inverse & " " & Skip);
            Jump (Target);
            Put (Skip & ":");
         end Branch;

         procedure Load_Value
           (Value : Landin.IR.Value_Id; Register : String := "r0") is
         begin
            Frame_Address (Value_Offset (Layout, Value));
            Memory (False, Size_Of_Value (Value), Register, "r6");
         end Load_Value;

         procedure Store_Value
           (Value : Landin.IR.Value_Id; Register : String := "r0") is
            Atoms : constant Landin.IR.Atom_Set_Id :=
              Landin.IR.Atom_Set_Of (Of_Unit, Item, Value);
         begin
            if Atoms /= Landin.IR.No_Atom_Set
              and then Landin.IR.Op_Of (Of_Unit, Item, Value) in
                Landin.IR.Load | Landin.IR.Load_Indirect
                | Landin.IR.Load_Datum | Landin.IR.Load_Field
                | Landin.IR.Load_Element | Landin.IR.Load_Variant_Field
            then
               declare
                  Done : constant String := Fresh;
               begin
                  if Landin.IR.Is_Failure_Status_Load
                    (Of_Unit, Item, Value)
                  then
                     Emit ("cmp " & Register & ", #0");
                     Branch ("eq", Done);
                  end if;
                  for Index in 1 .. Landin.IR.Atom_Count (Of_Unit, Atoms) loop
                     Immediate ("r4", Pattern (Atom_Code
                       (Of_Unit, Landin.IR.Nth_Atom (Of_Unit, Atoms, Index))));
                     Emit ("cmp " & Register & ", r4");
                     Branch ("eq", Done);
                  end loop;
                  Jump (Trap);
                  Put (Done & ":");
               end;
            end if;
            Frame_Address (Value_Offset (Layout, Value));
            Memory (True, Size_Of_Value (Value), Register, "r6");
         end Store_Value;

         procedure Load_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "r0") is
         begin
            Frame_Address (Slot_Offset (Layout, Slot));
            Memory (False, Size_Of
              (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts),
              Register, "r6");
         end Load_Slot;

         procedure Store_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "r0") is
         begin
            Frame_Address (Slot_Offset (Layout, Slot));
            Memory (True, Size_Of
              (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts),
              Register, "r6");
         end Store_Slot;

         procedure Extend (Register : String; Scalar : Landin.Types.Type_Kind)
         is
         begin
            if Scalar in Landin.Types.I8 | Landin.Types.I16 then
               Emit ((if Scalar = Landin.Types.I8 then "sxtb " else "sxth ")
                 & Register & ", " & Register);
            end if;
         end Extend;

         procedure Epilogue is
         begin
            Emit ("mov r6, r11");
            Emit ("mov sp, r6");
            Emit ("ldr r7, [r6, #4]");
            Emit ("ldr r6, [r6]");
            Emit ("mov lr, r7");
            Emit ("mov r11, r6");
            Emit ("add sp, #8");
            Emit ("pop {r4, r5, r6, r7}");
            Emit ("bx lr");
         end Epilogue;
         function Array_Length_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps)
            return Landin.IR.Element_Total;
         function Element_Shape_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.IR.Field_Shape;
         function Array_Element_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps)
            return Landin.Types.Scalar_Name;
         function Element_Bytes_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.Targets.Byte_Count;
         procedure Part_Address
           (Place         : Landin.IR.Storage;
            Field         : Landin.IR.Element_Total;
            Register      : String;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps);
         procedure Storage_Address
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Register      : String;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps);
         function Whole_Clear_Extent
           (Place  : Landin.IR.Storage;
            Field  : Natural;
            Nested : Landin.IR.Path_Step_Array)
            return Landin.Targets.Byte_Count;
         function Stored_Field_Shape
           (Place : Landin.IR.Storage; Field : Positive)
            return Landin.IR.Field_Shape;
         --  D126: the part a variant operation reaches, which is its base
         --  field and then whatever run [0420] composed below it.
         function Root_Shape_Of
           (Place : Landin.IR.Storage; Field : Natural)
            return Landin.IR.Field_Shape;
         --  D127: the part a base position names.  For storage that is an
         --  array that is [0520]'s element, which is what a known index of
         --  a scalar array has always meant; for a struct it is [0750]'s
         --  field.
         function Part_Shape_Of
           (Place : Landin.IR.Storage; Which : Landin.IR.Part_Position)
            return Landin.IR.Field_Shape;
         function Reached_Shape
           (Place  : Landin.IR.Storage;
            Field  : Natural;
            Nested : Landin.IR.Path_Step_Array)
            return Landin.IR.Field_Shape;

         function Path_Offset
           (Shape : Landin.IR.Field_Shape;
            Path  : Landin.IR.Path_Step_Array)
            return Landin.Targets.Byte_Count;

         function Array_Length_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.IR.Element_Total
         is
         begin
            if Payload_Field > 0 then
               return Landin.IR.Nth_Variant_Case_Field
                 (Of_Unit, Reached_Shape (Place, Field, Nested),
                  Positive (Which), Positive (Payload_Field)).Length;
            end if;
            if Nested'Length > 0 then
               return Reached_Shape (Place, Field, Nested).Length;
            end if;
            return Root_Shape_Of (Place, Field).Length;
         end Array_Length_Of;

         --  D127: where a run starts.  A positive base field is that
         --  field's shape; base zero is storage that is itself an array,
         --  said as one shape so a run may start there too.
         function Root_Shape_Of
           (Place : Landin.IR.Storage; Field : Natural)
            return Landin.IR.Field_Shape
         is (if Field > 0
             then Part_Shape_Of (Place, Landin.IR.Part_Position (Field))
             else (case Place.Kind is
                      when Landin.IR.Module_Datum =>
                        Landin.IR.Whole_Array_Shape (Of_Unit, Place.Datum),
                      when Landin.IR.Frame_Slot =>
                        Landin.IR.Whole_Slot_Array_Shape
                          (Of_Unit, Item, Place.Slot),
                      when Landin.IR.Runtime_Address =>
                        Landin.IR.Address_Shape
                          (Of_Unit, Item, Place.Address)));

         function Part_Shape_Of
           (Place : Landin.IR.Storage; Which : Landin.IR.Part_Position)
            return Landin.IR.Field_Shape
         is (case Place.Kind is
                when Landin.IR.Module_Datum =>
                  (if Landin.IR.Result_Of (Of_Unit, Place.Datum)
                        = Landin.Types.Fixed_Array
                   then Landin.IR.Array_Element_Shape (Of_Unit, Place.Datum)
                   else Landin.IR.Nth_Field_Shape
                     (Of_Unit, Place.Datum, Positive (Which))),
                when Landin.IR.Frame_Slot =>
                  (if Landin.IR.Is_Array (Of_Unit, Item, Place.Slot)
                   then Landin.IR.Slot_Array_Element_Shape
                     (Of_Unit, Item, Place.Slot)
                   else Landin.IR.Nth_Slot_Field_Shape
                     (Of_Unit, Item, Place.Slot, Positive (Which))),
                when Landin.IR.Runtime_Address =>
                  (if Landin.IR.Address_Shape
                        (Of_Unit, Item, Place.Address).Kind
                        = Landin.IR.Array_Field_Shape
                   then Landin.IR.Array_Element_Shape
                     (Of_Unit,
                      Landin.IR.Address_Shape
                        (Of_Unit, Item, Place.Address))
                   else Landin.IR.Nth_Aggregate_Field
                     (Of_Unit,
                      Landin.IR.Address_Shape
                        (Of_Unit, Item, Place.Address),
                      Positive (Which))));

         --  D121: the shape of one element of the array an operation
         --  reaches.  A scalar element answers as itself, so every caller
         --  that only wants a width still gets one.
         function Reached_Shape
           (Place  : Landin.IR.Storage;
            Field  : Natural;
            Nested : Landin.IR.Path_Step_Array)
            return Landin.IR.Field_Shape
         is (Landin.IR.Shape_At
               (Of_Unit, Root_Shape_Of (Place, Field), Nested));

         function Element_Shape_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.IR.Field_Shape
         is
         begin
            if Payload_Field > 0 then
               return Landin.IR.Array_Element_Shape
                 (Of_Unit,
                  Landin.IR.Nth_Variant_Case_Field
                    (Of_Unit,
                     Reached_Shape (Place, Field, Nested),
                     Positive (Which), Positive (Payload_Field)));
            end if;
            if Nested'Length > 0 then
               return Landin.IR.Array_Element_Shape
                 (Of_Unit,
                  Reached_Shape (Place, Field, Nested));
            end if;
            case Place.Kind is
               when Landin.IR.Module_Datum =>
                  if Field = 0 then
                     return Landin.IR.Array_Element_Shape
                       (Of_Unit, Place.Datum);
                  end if;
                  return Landin.IR.Array_Element_Shape
                    (Of_Unit,
                     Landin.IR.Nth_Field_Shape
                       (Of_Unit, Place.Datum, Positive (Field)));
               when Landin.IR.Frame_Slot =>
                  if Field = 0 then
                     return Landin.IR.Slot_Array_Element_Shape
                       (Of_Unit, Item, Place.Slot);
                  end if;
                  return Landin.IR.Array_Element_Shape
                    (Of_Unit,
                     Landin.IR.Nth_Slot_Field_Shape
                       (Of_Unit, Item, Place.Slot, Positive (Field)));
               when Landin.IR.Runtime_Address =>
                  return Landin.IR.Array_Element_Shape
                    (Of_Unit, Root_Shape_Of (Place, Field));
            end case;
         end Element_Shape_Of;

         function Array_Element_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.Types.Scalar_Name
         is (Element_Shape_Of
               (Place, Field, Which, Payload_Field, Nested).Element);

         --  How many target bytes one element takes.
         function Element_Bytes_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.Targets.Byte_Count
         is
            Shape : constant Landin.IR.Field_Shape :=
              Element_Shape_Of (Place, Field, Which, Payload_Field, Nested);
            Size : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
         begin
            Landin.Backend.Field_Extent
              (Of_Unit, Shape, Facts, Size, Alignment);
            return Size;
         end Element_Bytes_Of;

         procedure Part_Address
           (Place         : Landin.IR.Storage;
            Field         : Landin.IR.Element_Total;
            Register      : String;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps)
         is
            Offset : Landin.Targets.Byte_Count := 0;
            function Shape return Landin.IR.Field_Shape is
              (if Field = 0 then Root_Shape_Of (Place, 0)
               else Part_Shape_Of (Place, Landin.IR.Part_Position (Field)));
         begin
            case Place.Kind is
               when Landin.IR.Module_Datum =>
                  Address (Register, Symbol (Place.Datum));
                  if Field > 0 then
                     Offset := Field_Offset
                       (Place.Datum, Landin.IR.Part_Position (Field));
                  end if;
               when Landin.IR.Frame_Slot =>
                  Frame_Address
                    (Slot_Offset (Layout, Place.Slot), Register);
                  if Field > 0 then
                     Offset := Slot_Offset (Layout, Place.Slot)
                       - Landin.Backend.Field_Offset
                         (Of_Unit, Item, Layout, Place.Slot,
                          Landin.IR.Part_Position (Field), Facts);
                  end if;
               when Landin.IR.Runtime_Address =>
                  Load_Slot (Place.Address, Register);
                  if Field > 0 then
                     Offset := Path_Offset
                       (Landin.IR.Address_Shape
                          (Of_Unit, Item, Place.Address),
                        [1 => (Field => Landin.IR.Part_Position (Field),
                               Case_Index => 0)]);
                  end if;
            end case;
            if Nested'Length > 0 then
               Offset := Offset
                 + Path_Offset (Shape, Nested);
            end if;
            if Payload_Field > 0 then
               Offset := Offset + Landin.Backend.Variant_Payload_Field_Offset
                 (Of_Unit, Landin.IR.Shape_At (Of_Unit, Shape, Nested),
                  Positive (Which), Positive (Payload_Field), Facts);
            end if;
            Add_Offset (Register, Offset);
         end Part_Address;

         procedure Storage_Address
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Register      : String;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) is
         begin
            Part_Address
              (Place, Landin.IR.Element_Total (Field), Register,
               Which, Payload_Field, Nested);
         end Storage_Address;

         function Whole_Clear_Extent
           (Place  : Landin.IR.Storage;
            Field  : Natural;
            Nested : Landin.IR.Path_Step_Array)
            return Landin.Targets.Byte_Count
         is
            Whole_Aggregate : constant Boolean :=
              Field = 0 and then Nested'Length = 0
              and then
                (case Place.Kind is
                    when Landin.IR.Module_Datum =>
                      Landin.IR.Result_Of (Of_Unit, Place.Datum)
                        = Landin.Types.Aggregate,
                    when Landin.IR.Frame_Slot =>
                      Landin.IR.Is_Aggregate
                        (Of_Unit, Item, Place.Slot),
                    when Landin.IR.Runtime_Address =>
                      Landin.IR.Address_Shape
                        (Of_Unit, Item, Place.Address).Kind
                        = Landin.IR.Aggregate_Field_Shape);
         begin
            --  D91 clears one whole child; D119 clears one however far
            --  down the path went; D127 lets that run start at whole array
            --  storage, so an element is reached the same way.  Either way
            --  the extent is the reached part's own, replayed against this
            --  target.
            if (Field > 0 or else Nested'Length > 0)
              and then Reached_Shape (Place, Field, Nested).Kind
                         = Landin.IR.Aggregate_Field_Shape
            then
               declare
                  Size : Landin.Targets.Byte_Count;
                  Alignment : Landin.Targets.Byte_Alignment;
               begin
                  Landin.Backend.Field_Extent
                    (Of_Unit, Reached_Shape (Place, Field, Nested),
                     Facts, Size, Alignment);
                  return Size;
               end;
            end if;

            if not Whole_Aggregate then
               return
                 Landin.Targets.Byte_Count
                   (Array_Length_Of
                      (Place, Field, Nested => Nested))
                 * Element_Bytes_Of (Place, Field, Nested => Nested);
            end if;

            case Place.Kind is
               when Landin.IR.Module_Datum =>
                  declare
                     Placed : Landin.Targets.Placement;
                     Ignored : Landin.Targets.Byte_Count;
                  begin
                     Place_Fields (Place.Datum, Placed, 0, Ignored);
                     return Landin.Targets.Size_Of (Placed);
                  end;

               when Landin.IR.Frame_Slot =>
                  declare
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Aggregate_Extent
                       (Of_Unit, Item, Place.Slot, Facts, Size, Alignment);
                     return Size;
                  end;
               when Landin.IR.Runtime_Address =>
                  declare
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit,
                        Landin.IR.Address_Shape
                          (Of_Unit, Item, Place.Address),
                        Facts, Size, Alignment);
                     return Size;
                  end;
            end case;
         end Whole_Clear_Extent;

         function Stored_Field_Shape
           (Place : Landin.IR.Storage; Field : Positive)
            return Landin.IR.Field_Shape
         is
           (case Place.Kind is
               when Landin.IR.Module_Datum =>
                 Landin.IR.Nth_Field_Shape
                   (Of_Unit, Place.Datum, Field),
               when Landin.IR.Frame_Slot =>
                 Landin.IR.Nth_Slot_Field_Shape
                   (Of_Unit, Item, Place.Slot, Field),
               when Landin.IR.Runtime_Address =>
                 Landin.IR.Nth_Aggregate_Field
                   (Of_Unit,
                    Landin.IR.Address_Shape
                      (Of_Unit, Item, Place.Address),
                    Field));

         --  How far into one field the whole of D118's path reaches.  Each
         --  ordinary step replays [0750]'s placement over the run the step
         --  before it reached; each selected-case step adds the payload
         --  offset the same tag-first rule gives.  The identities come from
         --  the IR and every byte of the answer is derived here.
         function Path_Offset
           (Shape : Landin.IR.Field_Shape;
            Path  : Landin.IR.Path_Step_Array)
            return Landin.Targets.Byte_Count
           is (Landin.Backend.Path_Offset (Of_Unit, Shape, Path, Facts));

         procedure Instruction (Value : Landin.IR.Value_Id);

         procedure Instruction (Value : Landin.IR.Value_Id) is
            Op : constant Landin.IR.Opcode :=
              Landin.IR.Op_Of (Of_Unit, Item, Value);
            Unchecked : constant Boolean :=
              Landin.IR.Is_Unchecked (Of_Unit, Item, Value);
            function Operand (Index : Positive) return Landin.IR.Value_Id
              is (Landin.IR.Nth_Operand (Of_Unit, Item, Value, Index));
            function Place return Landin.IR.Storage is
              (if Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value)
               then (if Landin.IR.Is_Address
                          (Of_Unit, Item,
                           Landin.IR.Slot_Of (Of_Unit, Item, Value))
                     then (Kind => Landin.IR.Runtime_Address,
                           Address => Landin.IR.Slot_Of (Of_Unit, Item, Value))
                     else (Kind => Landin.IR.Frame_Slot,
                           Slot => Landin.IR.Slot_Of (Of_Unit, Item, Value)))
               else (Kind => Landin.IR.Module_Datum,
                     Datum => Landin.IR.Datum_Of (Of_Unit, Item, Value)));
            procedure Check_Fit (Scalar : Landin.Types.Scalar_Name);
            procedure Index_Address
              (Storage : Landin.IR.Storage; Field : Natural;
               Which, Payload : Natural; Nested : Landin.IR.Path_Step_Array;
               Below : Landin.IR.Path_Step_Array := Landin.IR.No_Path_Steps);

            procedure Shift_Pair (Left : Boolean; Signed : Boolean := False);
            procedure Packed_Atom
              (Set_Id : Landin.IR.Atom_Set_Id; Encode : Boolean);
            procedure Packed_Access
              (Shape : Landin.IR.Field_Shape; Writing : Boolean;
               Input : Landin.IR.Value_Id := Landin.IR.No_Value);

            --  r0/r1 is a little-endian word pair; r2 is already in 0..63.
            --  ARMv6-M has no RRX, so carry between right-shifted words is
            --  an explicit low-bit extraction. Only r2/r3 are scratch.
            procedure Shift_Pair (Left : Boolean; Signed : Boolean := False)
            is
               Loop_Name : constant String := Fresh;
            begin
               Emit ("cmp r2, #0");
               Emit ("beq " & Loop_Name & "_done");
               Put (Loop_Name & ":");
               if Left then
                  Emit ("lsls r0, r0, #1");
                  Emit ("adcs r1, r1");
               else
                  Emit ("lsls r3, r1, #31");
                  Emit ((if Signed then "asrs" else "lsrs")
                    & " r1, r1, #1");
                  Emit ("lsrs r0, r0, #1");
                  Emit ("orrs r0, r3");
               end if;
               Emit ("subs r2, #1");
               Emit ("bne " & Loop_Name);
               Put (Loop_Name & "_done:");
            end Shift_Pair;

            procedure Packed_Atom
              (Set_Id : Landin.IR.Atom_Set_Id; Encode : Boolean) is
               Done : constant String := Fresh;
            begin
               if Set_Id = Landin.IR.No_Atom_Set then
                  return;
               end if;
               for Index in 1 .. Landin.IR.Atom_Count (Of_Unit, Set_Id) loop
                  declare
                     Next : constant String := Fresh;
                     Code : constant Pattern := Pattern (Atom_Code
                       (Of_Unit, Landin.IR.Nth_Atom (Of_Unit, Set_Id, Index)));
                     Raw : constant Pattern := Pattern
                       (Landin.IR.Nth_Encoding (Of_Unit, Set_Id, Index));
                     Compared : constant Pattern :=
                       (if Encode then Code else Raw);
                     Answer : constant Pattern :=
                       (if Encode then Raw else Code);
                  begin
                     Immediate ("r4", Compared and 16#FFFF_FFFF#);
                     Emit ("cmp r0, r4");
                     Branch ("ne", Next);
                     Immediate ("r4", Compared / 2 ** 32);
                     Emit ("cmp r1, r4");
                     Branch ("ne", Next);
                     Immediate ("r0", Answer and 16#FFFF_FFFF#);
                     Immediate ("r1", Answer / 2 ** 32);
                     Jump (Done);
                     Put (Next & ":");
                  end;
               end loop;
               Jump (Trap);
               Put (Done & ":");
            end Packed_Atom;

            --  r2 is the ordinary image address, r4 the checked bit offset.
            --  Raw storage never passes through a typed atom load. Only the
            --  extracted member is validated, even when its result is dead.
            procedure Packed_Access
              (Shape : Landin.IR.Field_Shape; Writing : Boolean;
               Input : Landin.IR.Value_Id := Landin.IR.No_Value) is
               Carrier : constant Held_Size :=
                 Landin.Targets.Packed.Carrier (Shape.Packing.Storage);
               Bits : constant Pattern :=
                 (if Shape.Packing.Bits = 64 then Pattern'Last
                  else 2 ** Shape.Packing.Bits - 1);
               Atoms : constant Landin.IR.Atom_Set_Id :=
                 (if Shape.Kind = Landin.IR.Array_Field_Shape
                  then Landin.IR.Array_Element_Shape (Of_Unit, Shape).Atoms
                  else Shape.Atoms);
            begin
               if not Writing then
                  Memory (False, Carrier, "r0", "r2");
                  if Carrier /= Landin.Targets.Byte_8 then
                     Emit ("movs r1, #0");
                  end if;
                  Emit ("mov r2, r4");
                  Shift_Pair (False);
                  Immediate ("r4", Bits and 16#FFFF_FFFF#);
                  Immediate ("r5", Bits / 2 ** 32);
                  Emit ("ands r0, r4");
                  Emit ("ands r1, r5");
                  Packed_Atom (Atoms, False);
                  Store_Value (Value);
               else
                  Emit ("push {r2, r4}");
                  Load_Value (Input);
                  if Size_Of_Value (Input) /= Landin.Targets.Byte_8 then
                     Emit ("movs r1, #0");
                  end if;
                  Packed_Atom (Atoms, True);
                  Immediate ("r4", (not Bits) and 16#FFFF_FFFF#);
                  Immediate ("r5", (not Bits) / 2 ** 32);
                  Emit ("tst r0, r4");
                  Branch ("ne", Trap);
                  Emit ("tst r1, r5");
                  Branch ("ne", Trap);
                  Emit ("ldr r2, [sp, #4]");
                  Shift_Pair (True);
                  Emit ("push {r0, r1}");
                  Immediate ("r0", Bits and 16#FFFF_FFFF#);
                  Immediate ("r1", Bits / 2 ** 32);
                  Emit ("ldr r2, [sp, #12]");
                  Shift_Pair (True);
                  Emit ("ldr r2, [sp, #8]");
                  Memory (False, Carrier, "r4", "r2");
                  if Carrier /= Landin.Targets.Byte_8 then
                     Emit ("movs r5, #0");
                  end if;
                  Emit ("bics r4, r0");
                  Emit ("bics r5, r1");
                  Emit ("pop {r0, r1}");
                  Emit ("orrs r0, r4");
                  Emit ("orrs r1, r5");
                  Emit ("pop {r2, r4}");
                  Memory (True, Carrier, "r0", "r2");
               end if;
            end Packed_Access;

            procedure Check_Fit (Scalar : Landin.Types.Scalar_Name) is
               Bits : constant Natural := Natural
                 (Landin.Types.Width (Scalar, Facts));
            begin
               if Bits < 32 then
                  Emit ("mov r4, r0");
                  Emit ("lsls r4, r4, #"
                    & Trimmed (Natural'Image (32 - Bits)));
                  Emit ((if Landin.Types.Is_Signed (Scalar)
                         then "asrs " else "lsrs ")
                    & "r4, r4, #" & Trimmed (Natural'Image (32 - Bits)));
                  Emit ("cmp r0, r4");
                  Branch ("ne", Trap);
               end if;
            end Check_Fit;

            procedure Index_Address
              (Storage : Landin.IR.Storage; Field : Natural;
               Which, Payload : Natural; Nested : Landin.IR.Path_Step_Array;
               Below : Landin.IR.Path_Step_Array := Landin.IR.No_Path_Steps)
            is
               Length : constant Landin.IR.Element_Total :=
                 Array_Length_Of (Storage, Field, Which, Payload, Nested);
               Stride : constant Landin.Targets.Byte_Count :=
                 Element_Bytes_Of (Storage, Field, Which, Payload, Nested);
            begin
               Load_Value (Operand (1), "r4");
               if not Unchecked then
                  Immediate ("r5", Pattern (Length));
                  Emit ("cmp r4, r5");
                  Branch ("cs", Trap);
               end if;
               Immediate ("r5", Pattern (Stride));
               Emit ("muls r4, r5, r4");
               Storage_Address (Storage, Field, "r2", Which, Payload, Nested);
               Emit ("adds r2, r2, r4");
               if Below'Length > 0 then
                  Add_Offset ("r2", Path_Offset
                    (Element_Shape_Of (Storage, Field, Which, Payload, Nested),
                     Below));
               end if;
            end Index_Address;
         begin
            case Op is
               when Landin.IR.Range_Check =>
                  declare
                     Signed : constant Boolean :=
                       Landin.Types.Is_Signed (Kind (Value));
                  begin
                     Load_Value (Operand (1));
                     Extend ("r0", Kind (Value));
                     if Size_Of_Value (Value) /= Landin.Targets.Byte_8 then
                        if Signed then
                           Emit ("asrs r1, r0, #31");
                        else
                           Emit ("movs r1, #0");
                        end if;
                     end if;
                     for Upper in Boolean loop
                        declare
                           Bound : constant Pattern := To_Pattern
                             ((if Upper then Landin.IR.Range_Upper
                                 (Of_Unit, Item, Value)
                               else Landin.IR.Range_Lower
                                 (Of_Unit, Item, Value)), 64);
                           Next : constant String := Fresh;
                        begin
                           Immediate ("r2", Bound and 16#FFFF_FFFF#);
                           Immediate ("r3", Bound / 2 ** 32);
                           Emit ("cmp r1, r3");
                           Branch ((if Upper then
                             (if Signed then "gt" else "hi")
                             else (if Signed then "lt" else "cc")), Trap);
                           Branch ("ne", Next);
                           Emit ("cmp r0, r2");
                           Branch ((if Upper then "hi" else "cc"), Trap);
                           Put (Next & ":");
                        end;
                     end loop;
                     Store_Value (Value);
                  end;
               when Landin.IR.Conversion | Landin.IR.Pointer_Address =>
                  declare
                     From : constant Landin.Types.Scalar_Name :=
                       Kind (Operand (1));
                     Into_Type : constant Landin.Types.Scalar_Name :=
                       Kind (Value);
                     From_Float : constant Boolean :=
                       From in Landin.Types.Float_Name;
                     Into_Float : constant Boolean :=
                       Into_Type in Landin.Types.Float_Name;
                     From_Signed : constant Boolean := From in
                       Landin.Types.Integer_Name
                       and then Landin.Types.Is_Signed (From);
                     Into_Signed : constant Boolean := Into_Type in
                       Landin.Types.Integer_Name
                       and then Landin.Types.Is_Signed (Into_Type);
                     Wide : constant Boolean :=
                       Size_Of_Value (Value) = Landin.Targets.Byte_8;
                     Done : constant String := Fresh;
                  begin
                     Load_Value (Operand (1));
                     Extend ("r0", From);
                     if From_Float and then Into_Float then
                        if From /= Into_Type then
                           Emit ("bl __aeabi_"
                             & (if From = Landin.Types.F32
                                then "f2d" else "d2f"));
                           if Into_Type = Landin.Types.F32 then
                              Immediate ("r4", 16#7F80_0000#);
                              Emit ("mov r5, r0");
                              Emit ("ands r5, r4");
                              Emit ("cmp r5, r4");
                              Branch ("ne", Done);
                              Load_Value (Operand (1), "r2");
                              Immediate ("r4", 16#7FF0_0000#);
                              Emit ("ands r3, r4");
                              Emit ("cmp r3, r4");
                              Branch ("ne", Trap);
                           end if;
                        end if;
                     elsif Into_Float then
                        Emit ("bl __aeabi_"
                          & (if Size_Of_Value (Operand (1)) =
                               Landin.Targets.Byte_8
                             then (if From_Signed then "l" else "ul")
                             else (if From_Signed then "i" else "ui"))
                          & (if Wide then "2d" else "2f"));
                     elsif From_Float then
                        if Into_Type = Landin.Types.Bool then
                           --  Both signed zero encodings denote false; only
                           --  positive one denotes true. NaNs never match.
                           if From = Landin.Types.F32 then
                              Emit ("lsls r4, r0, #1");
                              Emit ("cmp r4, #0");
                              Branch ("eq", Done & "_zero");
                              Immediate ("r4", 16#3F80_0000#);
                              Emit ("cmp r0, r4");
                              Branch ("ne", Trap);
                           else
                              Emit ("lsls r4, r1, #1");
                              Emit ("orrs r4, r0");
                              Emit ("cmp r4, #0");
                              Branch ("eq", Done & "_zero");
                              Emit ("cmp r0, #0");
                              Branch ("ne", Trap);
                              Immediate ("r4", 16#3FF0_0000#);
                              Emit ("cmp r1, r4");
                              Branch ("ne", Trap);
                           end if;
                           Emit ("movs r0, #1");
                           Jump (Done);
                           Put (Done & "_zero:");
                           Emit ("movs r0, #0");
                        else
                           --  Decode and truncate the IEEE significand using
                           --  integer words. No host FP, FPU or undefined
                           --  out-of-range library conversion is involved.
                           declare
                              Fraction : constant Natural :=
                                (if From = Landin.Types.F32 then 23 else 52);
                              Bias : constant Pattern :=
                                (if From = Landin.Types.F32 then 127
                                 else 1023);
                              Exponent_Mask : constant Pattern :=
                                (if From = Landin.Types.F32 then 255
                                 else 2047);
                           begin
                              Emit ("mov r4, "
                                & (if From = Landin.Types.F32
                                   then "r0" else "r1"));
                              Emit ("lsrs r2, r4, #"
                                & (if From = Landin.Types.F32
                                   then "23" else "20"));
                              Immediate ("r5", Exponent_Mask);
                              Emit ("ands r2, r5");
                              Emit ("cmp r2, r5");
                              Branch ("eq", Trap);
                              Immediate ("r5", Bias);
                              Emit ("subs r2, r2, r5");
                              Branch ("lt", Done & "_zero");
                              Emit ("cmp r2, #64");
                              Branch ("cs", Trap);
                              if From = Landin.Types.F32 then
                                 Immediate ("r5", 16#7F_FFFF#);
                                 Emit ("ands r0, r5");
                                 Immediate ("r5", 16#80_0000#);
                                 Emit ("orrs r0, r5");
                                 Emit ("movs r1, #0");
                              else
                                 Immediate ("r5", 16#F_FFFF#);
                                 Emit ("ands r1, r5");
                                 Immediate ("r5", 16#10_0000#);
                                 Emit ("orrs r1, r5");
                              end if;
                              Emit ("cmp r2, #" & Trimmed (Fraction'Image));
                              Branch ("cc", Done & "_right");
                              Emit ("subs r2, #" & Trimmed (Fraction'Image));
                              Shift_Pair (True);
                              Jump (Done & "_sign");
                              Put (Done & "_right:");
                              Immediate ("r5", Pattern (Fraction));
                              Emit ("subs r2, r5, r2");
                              Shift_Pair (False);
                              Put (Done & "_sign:");
                              Emit ("cmp r4, #0");
                              Branch ("ge", Done & "_positive");
                              if Into_Signed then
                                 Immediate ("r5", 16#8000_0000#);
                                 Emit ("cmp r1, r5");
                                 Branch ("hi", Trap);
                                 Branch ("ne", Done & "_negate");
                                 Emit ("cmp r0, #0");
                                 Branch ("ne", Trap);
                                 Put (Done & "_negate:");
                                 Emit ("movs r5, #0");
                                 Emit ("rsbs r0, r0, #0");
                                 Emit ("sbcs r5, r1");
                                 Emit ("mov r1, r5");
                              else
                                 Emit ("mov r5, r0");
                                 Emit ("orrs r5, r1");
                                 Emit ("cmp r5, #0");
                                 Branch ("ne", Trap);
                              end if;
                              Jump (Done & "_fit");
                              Put (Done & "_positive:");
                              if Into_Signed then
                                 Emit ("cmp r1, #0");
                                 Branch ("lt", Trap);
                              end if;
                              Jump (Done & "_fit");
                              Put (Done & "_zero:");
                              Emit ("movs r0, #0");
                              Emit ("movs r1, #0");
                              Put (Done & "_fit:");
                              if not Wide then
                                 if Into_Signed then
                                    Emit ("asrs r4, r0, #31");
                                 else
                                    Emit ("movs r4, #0");
                                 end if;
                                 Emit ("cmp r1, r4");
                                 Branch ("ne", Trap);
                                 Check_Fit (Into_Type);
                              end if;
                           end;
                        end if;
                     else
                        if Size_Of_Value (Operand (1)) /=
                          Landin.Targets.Byte_8
                        then
                           if From_Signed then
                              Emit ("asrs r1, r0, #31");
                           else
                              Emit ("movs r1, #0");
                           end if;
                        end if;
                        if Into_Type = Landin.Types.Bool then
                           Emit ("cmp r1, #0");
                           Branch ("ne", Trap);
                           Emit ("cmp r0, #1");
                           Branch ("hi", Trap);
                        elsif not Unchecked then
                           if Into_Signed /= From_Signed then
                              Emit ("cmp r1, #0");
                              Branch ("lt", Trap);
                           end if;
                           if not Wide then
                              if Into_Signed then
                                 Emit ("asrs r4, r0, #31");
                              else
                                 Emit ("movs r4, #0");
                              end if;
                              Emit ("cmp r1, r4");
                              Branch ("ne", Trap);
                              Check_Fit (Into_Type);
                           end if;
                        end if;
                     end if;
                     Put (Done & ":");
                     Store_Value (Value);
                  end;
               when Landin.IR.Multiply | Landin.IR.Wrapping_Multiply
                  | Landin.IR.Divide | Landin.IR.Remainder =>
                  declare
                     Wide : constant Boolean :=
                       Size_Of_Value (Value) = Landin.Targets.Byte_8;
                     Float : constant Boolean :=
                       Kind (Value) in Landin.Types.Float_Name;
                     Signed : constant Boolean := not Float
                       and then Landin.Types.Is_Signed (Kind (Value));
                     Multiply : constant Boolean := Op in
                       Landin.IR.Multiply | Landin.IR.Wrapping_Multiply;
                     Checked : constant Boolean :=
                       Op = Landin.IR.Multiply and then not Unchecked;
                     Done : constant String := Fresh;
                  begin
                     Load_Value (Operand (1));
                     Load_Value (Operand (2), "r2");
                     Extend ("r0", Kind (Value));
                     Extend ("r2", Kind (Value));
                     if Float then
                        if not Wide then
                           Emit ("mov r1, r2");
                        end if;
                        Emit ("bl __aeabi_" & (if Wide then "d" else "f")
                          & (if Multiply then "mul" else "div"));
                     elsif Multiply then
                        if not Wide then
                           if Signed then
                              Emit ("asrs r1, r0, #31");
                              Emit ("asrs r3, r2, #31");
                           else
                              Emit ("movs r1, #0");
                              Emit ("movs r3, #0");
                           end if;
                        elsif Checked then
                           --  Compare magnitudes against floor(limit / rhs)
                           --  before multiplying; the helper's quotient is
                           --  an ordinary unsigned 64-bit AAPCS result.
                           Emit ("mov r4, r2");
                           Emit ("orrs r4, r3");
                           Emit ("cmp r4, #0");
                           Branch ("eq", Done & "_multiply");
                           Emit ("push {r0, r1, r2, r3}");
                           if Signed then
                              Emit ("cmp r1, #0");
                              Branch ("ge", Done & "_left");
                              Emit ("movs r4, #0");
                              Emit ("rsbs r0, r0, #0");
                              Emit ("sbcs r4, r1");
                              Emit ("mov r1, r4");
                              Put (Done & "_left:");
                              Emit ("cmp r3, #0");
                              Branch ("ge", Done & "_right");
                              Emit ("movs r4, #0");
                              Emit ("rsbs r2, r2, #0");
                              Emit ("sbcs r4, r3");
                              Emit ("mov r3, r4");
                              Put (Done & "_right:");
                           end if;
                           Emit ("mov r4, r0");
                           Emit ("mov r5, r1");
                           Immediate ("r0", 16#FFFF_FFFF#);
                           Immediate ("r1", (if Signed then 16#7FFF_FFFF#
                             else 16#FFFF_FFFF#));
                           if Signed then
                              Emit ("ldr r6, [sp, #4]");
                              Emit ("ldr r7, [sp, #12]");
                              Emit ("eors r6, r7");
                              Emit ("cmp r6, #0");
                              Branch ("ge", Done & "_limit");
                              Emit ("movs r0, #0");
                              Immediate ("r1", 16#8000_0000#);
                              Put (Done & "_limit:");
                           end if;
                           Emit ("bl __aeabi_uldivmod");
                           Emit ("cmp r5, r1");
                           Branch ("hi", Trap);
                           Branch ("cc", Done & "_fits");
                           Emit ("cmp r4, r0");
                           Branch ("hi", Trap);
                           Put (Done & "_fits:");
                           Emit ("pop {r0, r1, r2, r3}");
                           Put (Done & "_multiply:");
                        end if;
                        Emit ("bl __aeabi_lmul");
                        if Checked and then not Wide then
                           if Signed then
                              Emit ("asrs r4, r0, #31");
                           else
                              Emit ("movs r4, #0");
                           end if;
                           Emit ("cmp r1, r4");
                           Branch ("ne", Trap);
                           Check_Fit (Kind (Value));
                        end if;
                     else
                        if Wide then
                           Emit ("mov r4, r2");
                           Emit ("orrs r4, r3");
                        else
                           Emit ("mov r4, r2");
                        end if;
                        Emit ("cmp r4, #0");
                        Branch ("eq", Trap);
                        if Signed then
                           declare
                              Bits : constant Natural := Natural
                                (Landin.Types.Width (Kind (Value), Facts));
                           begin
                              Immediate ("r4", 16#FFFF_FFFF#);
                              Emit ("cmp r2, r4");
                              Branch ("ne", Done & "_divide");
                              if Wide then
                                 Emit ("cmp r3, r4");
                                 Branch ("ne", Done & "_divide");
                                 Immediate ("r4", 16#8000_0000#);
                                 Emit ("cmp r1, r4");
                                 Branch ("ne", Done & "_divide");
                                 Emit ("cmp r0, #0");
                              else
                                 Immediate ("r4", (0 - 2 ** (Bits - 1))
                                   and 16#FFFF_FFFF#);
                                 Emit ("cmp r0, r4");
                              end if;
                              if Op = Landin.IR.Divide then
                                 Branch ("eq", Trap);
                              else
                                 Branch ("ne", Done & "_divide");
                                 Emit ("movs r0, #0");
                                 Emit ("movs r1, #0");
                                 Jump (Done);
                              end if;
                           end;
                        end if;
                        Put (Done & "_divide:");
                        if Wide then
                           Emit ("bl __aeabi_"
                             & (if Signed then "ldivmod" else "uldivmod"));
                           if Op = Landin.IR.Remainder then
                              Emit ("mov r0, r2");
                              Emit ("mov r1, r3");
                           end if;
                        else
                           Emit ("mov r1, r2");
                           Emit ("bl __aeabi_"
                             & (if Signed then "idivmod" else "uidivmod"));
                           if Op = Landin.IR.Remainder then
                              Emit ("mov r0, r1");
                           end if;
                        end if;
                     end if;
                     Put (Done & ":");
                     Store_Value (Value);
                  end;
               when Landin.IR.Negation | Landin.IR.Complement
                  | Landin.IR.Logical_Not =>
                  Load_Value (Operand (1));
                  Extend ("r0", Kind (Value));
                  if Op = Landin.IR.Logical_Not then
                     Emit ("movs r4, #1");
                     Emit ("eors r0, r4");
                  elsif Op = Landin.IR.Complement then
                     Emit ("mvns r0, r0");
                     if Size_Of_Value (Value) = Landin.Targets.Byte_8 then
                        Emit ("mvns r1, r1");
                     end if;
                  elsif Kind (Value) in Landin.Types.Float_Name then
                     Immediate ("r4", 2 ** 31);
                     Emit ("eors " & (if Kind (Value) = Landin.Types.F32
                       then "r0" else "r1") & ", r4");
                  else
                     if Size_Of_Value (Value) = Landin.Targets.Byte_8 then
                        Emit ("movs r4, #0");
                        Emit ("movs r5, #0");
                        Emit ("subs r0, r4, r0");
                        Emit ("sbcs r5, r1");
                        Emit ("mov r1, r5");
                     else
                        Emit ("rsbs r0, r0, #0");
                     end if;
                     if not Unchecked then
                        Branch ((if Landin.Types.Is_Signed (Kind (Value))
                          then "vs" else "cc"), Trap);
                        Check_Fit (Kind (Value));
                     end if;
                  end if;
                  Store_Value (Value);
               when Landin.IR.Add | Landin.IR.Subtract
                  | Landin.IR.Wrapping_Add | Landin.IR.Wrapping_Subtract
                  | Landin.IR.Bitwise_And | Landin.IR.Bitwise_Or
                  | Landin.IR.Bitwise_Xor =>
                  declare
                     Wide : constant Boolean :=
                       Size_Of_Value (Value) = Landin.Targets.Byte_8;
                     Checked : constant Boolean := not Unchecked
                       and then Op in Landin.IR.Add | Landin.IR.Subtract;
                     Signed : constant Boolean := Kind (Value) in
                       Landin.Types.Integer_Name
                       and then Landin.Types.Is_Signed (Kind (Value));
                  begin
                     Load_Value (Operand (1));
                     Load_Value (Operand (2), "r2");
                     Extend ("r0", Kind (Value));
                     Extend ("r2", Kind (Value));
                     if Kind (Value) in Landin.Types.Float_Name then
                        if not Wide then
                           Emit ("mov r1, r2");
                        end if;
                        Emit ("bl __aeabi_"
                          & (if Wide then "d" else "f")
                          & (if Op = Landin.IR.Add then "add" else "sub"));
                     else
                        case Op is
                           when Landin.IR.Add | Landin.IR.Wrapping_Add =>
                              Emit ("adds r0, r0, r2");
                              if Wide then
                                 Emit ("adcs r1, r3");
                              end if;
                           when Landin.IR.Subtract
                              | Landin.IR.Wrapping_Subtract =>
                              Emit ("subs r0, r0, r2");
                              if Wide then
                                 Emit ("sbcs r1, r3");
                              end if;
                           when others =>
                              declare
                                 Name : constant String :=
                                   (if Op = Landin.IR.Bitwise_And then "ands"
                                    elsif Op = Landin.IR.Bitwise_Or then "orrs"
                                    else "eors");
                              begin
                                 Emit (Name & " r0, r2");
                                 if Wide then
                                    Emit (Name & " r1, r3");
                                 end if;
                              end;
                        end case;
                        if Checked then
                           Branch ((if Signed then "vs"
                             elsif Op = Landin.IR.Add then "cs" else "cc"),
                             Trap);
                           Check_Fit (Kind (Value));
                        end if;
                     end if;
                     Store_Value (Value);
                  end;
               when Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                  | Landin.IR.Less_Than | Landin.IR.Less_Or_Equal
                  | Landin.IR.Greater_Than | Landin.IR.Greater_Or_Equal =>
                  declare
                     Scalar : constant Landin.Types.Scalar_Name :=
                       Kind (Operand (1));
                     Wide : constant Boolean :=
                       Size_Of_Value (Operand (1)) = Landin.Targets.Byte_8;
                     Signed : constant Boolean := Scalar in
                       Landin.Types.Integer_Name
                       and then Landin.Types.Is_Signed (Scalar);
                     Done : constant String := Fresh;
                     Yes : constant String := Fresh;
                     No : constant String := Fresh;
                     Condition : constant String :=
                       (case Op is
                          when Landin.IR.Equal_To => "eq",
                          when Landin.IR.Not_Equal_To => "ne",
                          when Landin.IR.Less_Than =>
                            (if Signed then "lt" else "cc"),
                          when Landin.IR.Less_Or_Equal =>
                            (if Signed then "le" else "ls"),
                          when Landin.IR.Greater_Than =>
                            (if Signed then "gt" else "hi"),
                          when others => (if Signed then "ge" else "cs"));
                     Low_Condition : constant String :=
                       (case Op is
                          when Landin.IR.Less_Than => "cc",
                          when Landin.IR.Less_Or_Equal => "ls",
                          when Landin.IR.Greater_Than => "hi",
                          when Landin.IR.Greater_Or_Equal => "cs",
                          when others => Condition);
                  begin
                     Load_Value (Operand (1));
                     Load_Value (Operand (2), "r2");
                     Extend ("r0", Scalar);
                     Extend ("r2", Scalar);
                     if Scalar in Landin.Types.Float_Name then
                        if not Wide then
                           Emit ("mov r1, r2");
                        end if;
                        Emit ("bl __aeabi_" & (if Wide then "d" else "f")
                          & "cmp" & (case Op is
                            when Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                              => "eq",
                            when Landin.IR.Less_Than => "lt",
                            when Landin.IR.Less_Or_Equal => "le",
                            when Landin.IR.Greater_Than => "gt",
                            when others => "ge"));
                        if Op = Landin.IR.Not_Equal_To then
                           Emit ("movs r4, #1");
                           Emit ("eors r0, r4");
                        end if;
                        Store_Value (Value);
                        return;
                     end if;
                     if Wide then
                        Emit ("cmp r1, r3");
                        if Op = Landin.IR.Equal_To then
                           Branch ("ne", No);
                        elsif Op = Landin.IR.Not_Equal_To then
                           Branch ("ne", Yes);
                        else
                           Branch ((if Op in Landin.IR.Less_Than
                             | Landin.IR.Less_Or_Equal
                             then (if Signed then "lt" else "cc")
                             else (if Signed then "gt" else "hi")), Yes);
                           Branch ("ne", No);
                        end if;
                     end if;
                     Emit ("cmp r0, r2");
                     Branch
                       ((if Wide then Low_Condition else Condition),
                        Yes);
                     Put (No & ":");
                     Emit ("movs r0, #0");
                     Jump (Done);
                     Put (Yes & ":");
                     Emit ("movs r0, #1");
                     Put (Done & ":");
                     Store_Value (Value);
                  end;
               when Landin.IR.Shift_Left | Landin.IR.Shift_Right =>
                  declare
                     Bits : constant Natural := Natural
                       (Landin.Types.Width (Kind (Value), Facts));
                     Wide : constant Boolean := Bits = 64;
                     Signed : constant Boolean :=
                       Landin.Types.Is_Signed (Kind (Value));
                     Do_Shift : constant String := Fresh;
                     Done : constant String := Fresh;
                  begin
                     Load_Value (Operand (1));
                     Load_Value (Operand (2), "r2");
                     Extend ("r0", Kind (Value));
                     Extend ("r2", Kind (Operand (2)));
                     if Signed then
                        Emit ("cmp " & (if Wide then "r3" else "r2")
                          & ", #0");
                        Branch ("lt", Trap);
                     end if;
                     if Wide then
                        Emit ("cmp r3, #0");
                        Branch ("ne", Done & "_zero");
                     end if;
                     Emit ("cmp r2, #" & Trimmed (Bits'Image));
                     Branch ("cc", Do_Shift);
                     Put (Done & "_zero:");
                     Emit ("movs r0, #0");
                     Emit ("movs r1, #0");
                     Jump (Done);
                     Put (Do_Shift & ":");
                     if Wide then
                        Shift_Pair
                          (Op = Landin.IR.Shift_Left, Signed);
                     else
                        Emit ((if Op = Landin.IR.Shift_Left then "lsls"
                          elsif Signed then "asrs" else "lsrs") & " r0, r2");
                     end if;
                     Put (Done & ":");
                     Store_Value (Value);
                  end;
               when Landin.IR.Number =>
                  declare
                     Number : Pattern := Pattern
                       (Landin.IR.Number_Of (Of_Unit, Item, Value));
                  begin
                     if Kind (Value) not in Landin.Types.Float_Name
                       and then Landin.IR.Is_Negated (Of_Unit, Item, Value)
                     then
                        Number := 0 - Number;
                     end if;
                     Immediate ("r0", Number and 16#FFFF_FFFF#);
                     if Size_Of_Value (Value) = Landin.Targets.Byte_8 then
                        Immediate ("r1", Number / 2 ** 32);
                     end if;
                     Store_Value (Value);
                  end;
               when Landin.IR.Truth =>
                  Immediate ("r0", (if Landin.IR.Truth_Of
                    (Of_Unit, Item, Value) then 1 else 0));
                  Store_Value (Value);
               when Landin.IR.Atom =>
                  Immediate ("r0", Pattern (Atom_Code
                    (Of_Unit, Landin.IR.Atom_Of (Of_Unit, Item, Value))));
                  Store_Value (Value);
               when Landin.IR.Measure_Size | Landin.IR.Measure_Align =>
                  declare
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Measurement_Extent
                       (Of_Unit, Item, Value, Facts, Bytes, Alignment);
                     Immediate ("r0", (if Op = Landin.IR.Measure_Size
                       then Pattern (Bytes) else Pattern (Alignment)));
                     Store_Value (Value);
                  end;
               when Landin.IR.Place_Address | Landin.IR.Storage_Address =>
                  declare
                     Storage : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                  begin
                     if Op = Landin.IR.Storage_Address
                       and then Landin.IR.Storage_Address_Has_Index
                         (Of_Unit, Item, Value)
                     then
                        Index_Address (Storage, Field, 0, 0, Nested);
                        Store_Value (Value, "r2");
                     else
                        Storage_Address (Storage, Field, "r0", Nested =>
                          Nested);
                        Store_Value (Value);
                     end if;
                  end;
               when Landin.IR.Load =>
                  Load_Slot (Landin.IR.Slot_Of (Of_Unit, Item, Value));
                  Store_Value (Value);
               when Landin.IR.Store =>
                  Load_Value (Operand (1));
                  Store_Slot (Landin.IR.Slot_Of (Of_Unit, Item, Value));
               when Landin.IR.Load_Indirect =>
                  Load_Value (Operand (1), "r2");
                  Memory (False, Size_Of_Value (Value), "r0", "r2");
                  Store_Value (Value);
               when Landin.IR.Store_Indirect =>
                  Load_Value (Operand (1), "r2");
                  Load_Value (Operand (2));
                  Memory (True, Size_Of_Value (Operand (2)), "r0", "r2");
               when Landin.IR.Load_Datum | Landin.IR.Store_Datum =>
                  Address ("r2", Symbol
                    (Landin.IR.Datum_Of (Of_Unit, Item, Value)));
                  if Op = Landin.IR.Load_Datum then
                     Memory (False, Size_Of_Value (Value), "r0", "r2");
                     Store_Value (Value);
                  else
                     Load_Value (Operand (1));
                     Memory (True, Size_Of_Value (Operand (1)), "r0", "r2");
                  end if;
               when Landin.IR.Load_Field | Landin.IR.Store_Field =>
                  declare
                     Shape : constant Landin.IR.Field_Shape :=
                       Landin.IR.Shape_At
                         (Of_Unit, Part_Shape_Of
                            (Place, Landin.IR.Field_Of (Of_Unit, Item, Value)),
                          Landin.IR.Path_Of (Of_Unit, Item, Value));
                  begin
                     Part_Address
                       (Place, Landin.IR.Element_Total
                          (Landin.IR.Field_Of (Of_Unit, Item, Value)),
                        "r2", Nested => Landin.IR.Path_Of
                          (Of_Unit, Item, Value));
                     if Shape.Packing.Bits /= 0 then
                        Immediate ("r4", Pattern (Shape.Packing.First));
                        Packed_Access
                          (Shape, Op = Landin.IR.Store_Field,
                           (if Op = Landin.IR.Store_Field then Operand (1)
                            else Landin.IR.No_Value));
                        return;
                     end if;
                     if Op = Landin.IR.Load_Field then
                        Memory (False, Size_Of_Value (Value), "r0", "r2");
                        Store_Value (Value);
                     else
                        Load_Value (Operand (1));
                        Memory (True, Size_Of_Value (Operand (1)), "r0", "r2");
                     end if;
                  end;
               when Landin.IR.Load_Element | Landin.IR.Store_Element =>
                  declare
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Place, Field, Nested);
                  begin
                     if Shape.Packing.Bits /= 0 then
                        Load_Value (Operand (1), "r4");
                        Immediate ("r5", Pattern (Shape.Length));
                        Emit ("cmp r4, r5");
                        Branch ("cs", Trap);
                        Immediate ("r5", Pattern (Shape.Packing.Bits));
                        Emit ("muls r4, r5, r4");
                        Add_Offset ("r4", Landin.Targets.Byte_Count
                          (Shape.Packing.First));
                        Storage_Address
                          (Place, Field, "r2", Nested => Nested);
                        Packed_Access
                          (Shape, Op = Landin.IR.Store_Element,
                           (if Op = Landin.IR.Store_Element then Operand (2)
                            else Landin.IR.No_Value));
                        return;
                     end if;
                  end;
                  Index_Address
                    (Place, Landin.IR.Element_Field_Of (Of_Unit, Item, Value),
                     Landin.IR.Variant_Case_Of (Of_Unit, Item, Value),
                     Landin.IR.Variant_Payload_Field_Of (Of_Unit, Item, Value),
                     Landin.IR.Path_Of (Of_Unit, Item, Value),
                     Landin.IR.Element_Path_Of (Of_Unit, Item, Value));
                  if Op = Landin.IR.Load_Element then
                     Memory (False, Size_Of_Value (Value), "r0", "r2");
                     Store_Value (Value);
                  else
                     Load_Value (Operand (2));
                     Memory (True, Size_Of_Value (Operand (2)), "r0", "r2");
                  end if;
               when Landin.IR.Copy_Array | Landin.IR.Copy_Variant =>
                  declare
                     Source : constant Landin.IR.Storage :=
                       Landin.IR.Source_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Source_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Source_Path_Of (Of_Unit, Item, Value);
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     if Op = Landin.IR.Copy_Array then
                        Bytes := Whole_Clear_Extent (Source, Field, Nested);
                     else
                        Field_Extent (Of_Unit,
                          Reached_Shape (Source, Field, Nested), Facts,
                          Bytes, Alignment);
                     end if;
                     Storage_Address
                       (Landin.IR.Destination_Of (Of_Unit, Item, Value),
                        Landin.IR.Element_Field_Of (Of_Unit, Item, Value),
                          "r0",
                        (if Op = Landin.IR.Copy_Array then
                           Landin.IR.Variant_Case_Of (Of_Unit, Item, Value)
                         else 0),
                        (if Op = Landin.IR.Copy_Array then
                           Landin.IR.Variant_Payload_Field_Of
                             (Of_Unit, Item, Value) else 0),
                        Landin.IR.Path_Of (Of_Unit, Item, Value));
                     Storage_Address (Source, Field, "r2", Nested => Nested);
                     Copy_Bytes (Bytes);
                  end;
               when Landin.IR.Clear_Array | Landin.IR.Select_Variant =>
                  declare
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     if Op = Landin.IR.Select_Variant then
                        Field_Extent
                          (Of_Unit, Reached_Shape (Destination, Field, Nested),
                           Facts, Bytes, Alignment);
                     else
                        Bytes := Whole_Clear_Extent
                          (Destination, Field, Nested);
                     end if;
                     Storage_Address (Destination, Field, "r0", Nested =>
                       Nested);
                     Zero_Bytes (Bytes);
                     if Op = Landin.IR.Select_Variant then
                        Storage_Address
                          (Destination, Field, "r2", Nested => Nested);
                        Immediate ("r0", Pattern
                          (Landin.IR.Variant_Case_Of (Of_Unit, Item, Value) -
                            1));
                        Memory (True, Size_Of
                          (Reached_Shape (Destination, Field, Nested).Element,
                           Facts), "r0", "r2");
                     end if;
                  end;
               when Landin.IR.Fill_Array =>
                  declare
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Which : constant Natural :=
                       Landin.IR.Variant_Case_Of (Of_Unit, Item, Value);
                     Payload : constant Natural :=
                       Landin.IR.Variant_Payload_Field_Of (Of_Unit, Item,
                         Value);
                     First : constant Landin.IR.Element_Total :=
                       Landin.IR.Element_Total
                         (Landin.IR.First_Part_Of (Of_Unit, Item, Value)) - 1;
                     Length : constant Landin.IR.Element_Total :=
                       Array_Length_Of (Destination, Field, Which, Payload,
                         Nested);
                     Held : constant Held_Size := Size_Of_Value (Operand (1));
                     Loop_Label : constant String := Fresh;
                  begin
                     Storage_Address
                       (Destination, Field, "r2", Which, Payload, Nested);
                     Add_Offset ("r2", Landin.Targets.Byte_Count (First)
                       * Landin.Targets.Byte_Count (Landin.Targets.Bytes
                         (Held)));
                     Load_Value (Operand (1));
                     Immediate ("r4", Pattern (Length - First));
                     Emit ("cmp r4, #0");
                     Branch ("eq", Loop_Label & "_end");
                     Put (Loop_Label & ":");
                     Memory (True, Held, "r0", "r2");
                     Emit ("adds r2, r2, #"
                       & Trimmed (Positive'Image (Landin.Targets.Bytes
                         (Held))));
                     Emit ("subs r4, r4, #1");
                     Branch ("ne", Loop_Label);
                     Put (Loop_Label & "_end:");
                  end;
               when Landin.IR.Load_Variant_Tag | Landin.IR.Load_Variant_Field
                  | Landin.IR.Store_Variant_Field =>
                  declare
                     Writing : constant Boolean := Op =
                       Landin.IR.Store_Variant_Field;
                  begin
                     Storage_Address
                       ((if Writing then Landin.IR.Destination_Of (Of_Unit,
                         Item, Value)
                         else Landin.IR.Source_Of (Of_Unit, Item, Value)),
                        Landin.IR.Element_Field_Of (Of_Unit, Item, Value),
                          "r2",
                        (if Op = Landin.IR.Load_Variant_Tag then 0
                         else Landin.IR.Variant_Case_Of (Of_Unit, Item,
                           Value)),
                        (if Op = Landin.IR.Load_Variant_Tag then 0
                         else Landin.IR.Variant_Payload_Field_Of (Of_Unit,
                           Item, Value)),
                        Landin.IR.Path_Of (Of_Unit, Item, Value));
                     if Writing then
                        Load_Value (Operand (1));
                        Memory (True, Size_Of_Value (Operand (1)), "r0",
                          "r2");
                     else
                        Memory (False, Size_Of_Value (Value), "r0", "r2");
                        Store_Value (Value);
                     end if;
                  end;
               when Landin.IR.Slice_Address =>
                  declare
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Field_Extent (Of_Unit,
                       Landin.IR.Slice_Element_Shape (Of_Unit, Item, Value),
                       Facts, Bytes, Alignment);
                     Load_Value (Operand (4), "r4");
                     Load_Value (Operand (3), "r2");
                     if not Unchecked then
                        Load_Value (Operand (2), "r0");
                        Emit ("cmp r4, r0");
                        Branch ((if Landin.IR.Slice_Is_Inclusive
                          (Of_Unit, Item, Value) then "cs" else "hi"),
                            Trap);
                        Emit ("cmp r2, r4");
                        Branch ("hi", Trap);
                     end if;
                     Immediate ("r4", Pattern (Bytes));
                     Load_Value (Operand (1));
                     Emit ("muls r2, r4, r2");
                     Emit ("adds r0, r0, r2");
                     Store_Value (Value);
                  end;
               when Landin.IR.Empty_Slice_Base =>
                  declare
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Field_Extent (Of_Unit,
                       Landin.IR.Slice_Element_Shape (Of_Unit, Item, Value),
                       Facts, Bytes, Alignment);
                     Immediate ("r0", Pattern (Alignment));
                     Store_Value (Value);
                  end;
               when Landin.IR.Function_Address =>
                  Address ("r0", Symbol
                    (Landin.IR.Callee_Of (Of_Unit, Item, Value)));
                  Store_Value (Value);
               when Landin.IR.Evidence_Address =>
                  Address ("r0", Evidence_Symbol
                    (Landin.IR.Evidence_Of (Of_Unit, Item, Value)));
                  Store_Value (Value);
               when Landin.IR.Evidence_Function =>
                  Load_Value (Operand (1));
                  if Landin.IR.Evidence_Is_Erased
                    (Of_Unit, Landin.IR.Evidence_Of (Of_Unit, Item, Value))
                  then
                     Emit ("ldr r0, [r0, #4]");
                  end if;
                  Add_Offset ("r0", Landin.Targets.Evidence_Function_Offset
                    (Facts, Landin.IR.Evidence_Entry_Of
                       (Of_Unit, Item, Value)));
                  Emit ("ldr r0, [r0]");
                  Store_Value (Value);
               when Landin.IR.Evidence_Self =>
                  Load_Value (Landin.IR.Nth_Operand
                    (Of_Unit, Item, Operand (1), 1));
                  Emit ("ldr r0, [r0]");
                  Store_Value (Value);
               when Landin.IR.Failure_Test =>
                  declare
                     Done : constant String := Fresh;
                  begin
                     Load_Value (Operand (1));
                     Emit ("cmp r0, #0");
                     Emit ("beq " & Done);
                     Emit ("movs r0, #1");
                     Put (Done & ":");
                     Store_Value (Value);
                  end;
               when Landin.IR.Call | Landin.IR.Indirect_Call =>
                  declare
                     Indirect : constant Boolean := Op =
                       Landin.IR.Indirect_Call;
                     Call : constant Arm32_ABI.Plan :=
                       Arm32_ABI.Call_Plan (Of_Unit, Item, Value, Facts);
                     Offset : constant Natural := (if Indirect then 1 else 0);
                     Hidden : constant Natural :=
                       (if Call.Result.Shape.Indirect then 1 else 0);
                     Bytes : constant Landin.Targets.Byte_Count :=
                       Call.Stack_Bytes + 16;
                  begin
                     Reserve (Bytes);
                     if Hidden > 0 then
                        Load_Value (Operand (Offset + 1));
                        Emit ("mov r6, sp");
                        Add_Offset ("r6", Call.Stack_Bytes);
                        Emit ("str r0, [r6]");
                     end if;
                     for Index in Call.Arguments'Range loop
                        declare
                           Arg : Arm32_ABI.Location renames
                             Call.Arguments (Index);
                           Actual : constant Landin.IR.Value_Id :=
                             Operand (Index + Offset + Hidden);
                        begin
                           Load_Value (Actual);
                           Extend ("r0", Kind (Actual));
                           Emit ("mov r6, sp");
                           if Arg.Core_Count > 0 then
                              Add_Offset ("r6", Call.Stack_Bytes
                                + Landin.Targets.Byte_Count
                                  (Arg.First_Core) * 4);
                           else
                              Add_Offset ("r6", Arg.Stack_At);
                           end if;
                           Emit ("str r0, [r6]");
                           if Size_Of_Value (Actual) = Landin.Targets.Byte_8
                           then
                              Emit ("str r1, [r6, #4]");
                           end if;
                        end;
                     end loop;
                     if Indirect then
                        Load_Value (Operand (1));
                        Emit ("mov r4, r0");
                     end if;
                     Emit ("mov r6, sp");
                     Add_Offset ("r6", Call.Stack_Bytes);
                     Emit ("ldmia r6!, {r0, r1, r2, r3}");
                     if Indirect then
                        Emit ("blx r4");
                     else
                        Emit ("bl " & Symbol
                          (Landin.IR.Callee_Of (Of_Unit, Item, Value)));
                     end if;
                     if Landin.IR.Failure_Slot_Of (Of_Unit, Item, Value)
                       /= Landin.IR.No_Slot
                     then
                        Emit ("mov r4, r12");
                        Store_Slot (Landin.IR.Failure_Slot_Of
                          (Of_Unit, Item, Value), "r4");
                     end if;
                     if Landin.IR.Result_Of (Of_Unit, Item, Value)
                       in Landin.Types.Scalar_Name
                     then
                        Store_Value (Value);
                     end if;
                     Release (Bytes);
                  end;
               when Landin.IR.Memory_Access =>
                  declare
                     use all type Landin.Memory.Operation;
                     M : constant Landin.Memory.Operation :=
                       Landin.IR.Memory_Operation (Of_Unit, Item, Value);
                     Size : constant Landin.Targets.Scalar_Size :=
                       Landin.Types.Storage_Size
                         (Landin.IR.Memory_Scalar (Of_Unit, Item, Value),
                          Facts);
                     Bytes : constant Positive := Landin.Targets.Bytes (Size);
                  begin
                     if Landin.Memory.Operands (M) = 0 then
                        case M is
                           when Compiler_Barrier =>
                              if Landin.IR.Assembly_Text (Of_Unit, Item, Value)
                                /= Landin.Source.Names.No_Name
                              then
                                 declare
                                    After_Block : constant String := Fresh;
                                 begin
                                    if Landin.IR.Operand_Count
                                      (Of_Unit, Item, Value) = 1
                                    then
                                       Load_Value (Landin.IR.Nth_Operand
                                         (Of_Unit, Item, Value, 1));
                                    end if;
                                    Put (Landin.Source.Names.Spelling
                                      (Names, Landin.IR.Assembly_Text
                                         (Of_Unit, Item, Value)));
                                    if Landin.IR.Operand_Count
                                      (Of_Unit, Item, Value) = 1
                                    then
                                       Store_Value (Value);
                                    end if;
                                    Emit ("b " & After_Block);
                                    Emit (".ltorg");
                                    Put (After_Block & ":");
                                 end;
                              end if;
                           when Completion_Barrier => Emit ("dsb sy");
                           when others => Emit ("dmb sy");
                        end case;
                     else
                        if Bytes > 4 or else M not in
                          Atomic_Load | Atomic_Store
                          | Volatile_Load | Volatile_Store
                        then
                           raise Compiler_Defect with "invalid M0 memory IR";
                        end if;
                        Load_Value (Operand (1), "r2");
                        if Bytes > 1 then
                           Immediate ("r4", Pattern (Bytes - 1));
                           Emit ("tst r2, r4");
                           Branch ("ne", Trap);
                        end if;
                        if M not in Volatile_Load | Volatile_Store then
                           Emit ("dmb sy");
                        end if;
                        if M in Atomic_Load | Volatile_Load then
                           Memory (False, Size, "r0", "r2");
                        else
                           Load_Value (Operand (2));
                           Memory (True, Size, "r0", "r2");
                        end if;
                        if M not in Volatile_Load | Volatile_Store then
                           Emit ("dmb sy");
                        end if;
                        if Landin.Memory.Returns_Value (M) then
                           Store_Value (Value);
                        end if;
                     end if;
                  end;
               when Landin.IR.Jump =>
                  Jump (Label (Item, Landin.IR.Target_Of
                    (Of_Unit, Item, Value)));
               when Landin.IR.Branch =>
                  Load_Value (Operand (1));
                  Emit ("cmp r0, #0");
                  Branch ("ne", Label (Item, Landin.IR.Target_Of
                    (Of_Unit, Item, Value)));
                  Jump (Label (Item, Landin.IR.Alternative_Of
                    (Of_Unit, Item, Value)));
               when Landin.IR.Leave =>
                  if Result in Landin.Types.Scalar_Name then
                     Load_Value (Operand (1));
                  elsif Result in Landin.Types.Aggregate |
                    Landin.Types.Fixed_Array
                  then
                     declare
                        Slot : constant Landin.IR.Slot_Id :=
                          Landin.IR.Result_Slot (Of_Unit, Item);
                     begin
                        Load_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1));
                        Frame_Address (Slot_Offset (Layout, Slot), "r2");
                        Copy_Bytes (Whole_Clear_Extent
                          ((Kind => Landin.IR.Frame_Slot, Slot => Slot), 0,
                            Landin.IR.No_Path_Steps));
                     end;
                  end if;
                  Emit ("movs r4, #0");
                  Emit ("mov r12, r4");
                  Epilogue;
               when Landin.IR.Fail =>
                  Load_Value (Operand (1));
                  Emit ("mov r12, r0");
                  Epilogue;
            end case;
         end Instruction;
      begin
         Select_Section (Item, ".text.", "ax");
         Emit (".globl " & Symbol (Item));
         Emit (".balign 2");
         Emit (".type " & Symbol (Item) & ", %function");
         Emit (".thumb_func");
         Put (Symbol (Item) & ":");
         if Landin.IR.Signature_Machine
           (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
             = Landin.Machine.Naked_Routine
         then
            for Position in 1 .. Landin.IR.Length (Of_Unit, Item, 1) loop
               declare
                  Value : constant Landin.IR.Value_Id :=
                    Landin.IR.Nth_Value (Of_Unit, Item, 1, Position);
               begin
                  if Landin.IR.Op_Of (Of_Unit, Item, Value)
                    = Landin.IR.Memory_Access
                  then
                     Put (Landin.Source.Names.Spelling
                       (Names, Landin.IR.Assembly_Text
                          (Of_Unit, Item, Value)));
                  end if;
               end;
            end loop;
            --  A naked block may branch or return explicitly. Falling off
            --  it traps; `none` does not promise nonreturning control flow.
            Emit ("udf #1");
            Emit (".ltorg");
            Emit (".size " & Symbol (Item) & ", . - " & Symbol (Item));
            Landin.Build_Reports.Append (Report,
              Landin.Build_Reports.Routine_Statistics'
                (Item => Item, others => <>));
            return;
         end if;
         Emit ("push {r4, r5, r6, r7}");
         Emit ("mov r4, r11");
         Emit ("mov r5, lr");
         Emit ("push {r4, r5}");
         Emit ("mov r11, sp");
         Reserve (Homes);
         Emit ("mov r6, sp");
         Emit ("stmia r6!, {r0, r1, r2, r3}");
         if Plan.Result.Shape.Indirect then
            Store_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1));
         end if;
         for Index in Plan.Arguments'Range loop
            declare
               Arg : Arm32_ABI.Location renames Plan.Arguments (Index);
               Slot : constant Landin.IR.Slot_Id := Landin.IR.Nth_Parameter
                 (Of_Unit, Item, Index
                  + (if Plan.Result.Shape.Indirect then 1 else 0));
               Aggregate : constant Boolean := Landin.IR.Is_Aggregate
                 (Of_Unit, Item, Slot)
                 or else Landin.IR.Is_Array (Of_Unit, Item, Slot);
            begin
               if Arg.Core_Count > 0 then
                  Frame_Address (Homes - Landin.Targets.Byte_Count
                    (Arg.First_Core) * 4);
               else
                  Emit ("mov r6, r11");
                  Add_Offset ("r6", 24 + Arg.Stack_At);
               end if;
               if Aggregate then
                  Emit ("ldr r2, [r6]");
                  Frame_Address (Slot_Offset (Layout, Slot), "r0");
                  Copy_Bytes (Whole_Clear_Extent
                    ((Kind => Landin.IR.Frame_Slot, Slot => Slot), 0,
                      Landin.IR.No_Path_Steps));
               else
                  Memory (False, Size_Of
                    (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts),
                    "r0", "r6");
                  Store_Slot (Slot);
               end if;
            end;
         end loop;
         for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            Put (Label (Item, Landin.IR.Block_Id (Block)) & ":");
            for Position in 1 .. Landin.IR.Length
              (Of_Unit, Item, Landin.IR.Block_Id (Block))
            loop
               Current_Value := Landin.IR.Nth_Value
                 (Of_Unit, Item, Landin.IR.Block_Id (Block), Position);
               Instruction (Current_Value);
            end loop;
         end loop;
         Put (Trap & ":");
         Emit ("udf #1");
         Emit (".size " & Symbol (Item) & ", . - " & Symbol (Item));
         Landin.Build_Reports.Append (Report,
           Landin.Build_Reports.Routine_Statistics'
             (Item => Item, Frame_Bytes => Homes + 24,
              Spill_Bytes => Spill_Bytes (Layout), Save_Bytes => 24,
              Spill_Count => Natural (Spill_Bytes (Layout) / 8),
              Instructions => Instruction_Count - Before_Emit,
              others => <>));
      end Emit_Routine;
      --  The value a datum's block describes.  [1460] says nothing runs
      --  before the entry point, so this walk is a fold and not an
      --  interpreter: it reaches the block's own Leave and answers with
      --  what that carries.
      function Folded (Item : Landin.IR.Item_Id) return Landin.Types.Folded;

      --  Each datum is folded once.  [0130] makes a module a set, so one
      --  module value may name another as often as it likes: `b = a + a`
      --  reaches `a` twice, and a chain of those without this would cost
      --  two folds per link and so double with every one of them.  The
      --  state is here for the second reason as well -- a cycle names
      --  nothing at all and [1940] refuses it, so meeting one here is a
      --  defect rather than something to fold.
      type Fold_State is (Unseen, Running, Settled);

      Fold_Of : array (1 .. Landin.IR.Item_Count (Of_Unit))
                  of Landin.Types.Folded := [others => 0];
      Fold_At : array (1 .. Landin.IR.Item_Count (Of_Unit)) of Fold_State :=
        [others => Unseen];

      function Folded (Item : Landin.IR.Item_Id) return Landin.Types.Folded is
         Answer : Landin.Types.Folded := 0;

         --  [0410] fixes the order of a binary's operands, so the lowering
         --  carries the left one through a slot.  A fold therefore reads
         --  slots as well as values, even though nothing here runs.
         type Folded_Values is array (Positive range <>)
           of Landin.Types.Folded;
         package Folded_Buffers is new Work_Arrays
           (Landin.Types.Folded, Folded_Values, 0);
         Held_Data : Folded_Buffers.Buffer
           (Landin.IR.Value_Count (Of_Unit, Item));
         Slot_Data : Folded_Buffers.Buffer
           (Landin.IR.Slot_Count (Of_Unit, Item));
         Held : Folded_Values renames Held_Data.Data.all;
         Slots : Folded_Values renames Slot_Data.Data.all;

         function Bits_Of
           (Value : Landin.IR.Value_Id) return Landin.Targets.Bit_Width;

         function Bits_Of
           (Value : Landin.IR.Value_Id) return Landin.Targets.Bit_Width
         is
            Kind : constant Landin.Types.Scalar_Name :=
              Landin.IR.Result_Of (Of_Unit, Item, Value);
         begin
            return Fold_Width (Kind, Facts);
         end Bits_Of;

         function Signed_At (Value : Landin.IR.Value_Id) return Boolean;

         function Signed_At (Value : Landin.IR.Value_Id) return Boolean is
            Kind : constant Landin.Types.Scalar_Name :=
              Landin.IR.Result_Of (Of_Unit, Item, Value);
         begin
            return Kind in Landin.Types.Integer_Name
                   and then Landin.Types.Is_Signed
                              (Landin.Types.Integer_Name (Kind));
         end Signed_At;

         function Of_Value (Value : Landin.IR.Value_Id)
           return Landin.Types.Folded
           is (Held (Natural (Value)));

         function Operand_Of
           (Value : Landin.IR.Value_Id; Index : Positive)
           return Landin.IR.Value_Id
           is (Landin.IR.Nth_Operand (Of_Unit, Item, Value, Index));
      begin
         --  D177 resolves every module bool through the shared static-image
         --  folder.  In particular, a short-circuit Branch is routine CFG
         --  and never reaches this datum-emission walk.
         if Landin.IR.Has_Bool_Image (Of_Unit, Item) then
            return Landin.IR.Bool_Image (Of_Unit, Item);
         end if;

         case Fold_At (Natural (Item)) is
            when Settled =>
               return Fold_Of (Natural (Item));

            when Running =>
               raise Compiler_Defect
                 with "a module value names itself through a chain the "
                      & "checker was to have refused";

            when Unseen =>
               Fold_At (Natural (Item)) := Running;
         end case;

         for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            for Position in 1 .. Landin.IR.Length
                                   (Of_Unit, Item,
                                    Landin.IR.Block_Id (Block))
            loop
               declare
                  Value : constant Landin.IR.Value_Id :=
                    Landin.IR.Nth_Value
                      (Of_Unit, Item, Landin.IR.Block_Id (Block), Position);
                  Op : constant Landin.IR.Opcode :=
                    Landin.IR.Op_Of (Of_Unit, Item, Value);
               begin
                  case Op is
                     when Landin.IR.Number =>
                        --  [1880]'s minus is carried apart from [1770]'s
                        --  magnitude, and this is where the two meet.
                        Held (Natural (Value)) :=
                          (if Landin.IR.Is_Negated (Of_Unit, Item, Value)
                           then -Landin.Types.Folded
                                   (Landin.IR.Number_Of
                                      (Of_Unit, Item, Value))
                           else Landin.Types.Folded
                                  (Landin.IR.Number_Of
                                     (Of_Unit, Item, Value)));

                     when Landin.IR.Truth =>
                        Held (Natural (Value)) :=
                          (if Landin.IR.Truth_Of (Of_Unit, Item, Value)
                           then 1 else 0);

                     when Landin.IR.Atom =>
                        Held (Natural (Value)) :=
                          Landin.Types.Folded
                            (Atom_Code
                               (Of_Unit,
                                Landin.IR.Atom_Of
                                  (Of_Unit, Item, Value)));

                     --  [0370] in a module value, folded here for the
                     --  same reason the shifts are: it needs a target.
                     when Landin.IR.Measure_Size
                        | Landin.IR.Measure_Align =>
                        declare
                           Size : Landin.Targets.Byte_Count;
                           Alignment : Landin.Targets.Byte_Alignment;
                        begin
                           Measurement_Extent
                             (Of_Unit, Item, Value, Facts, Size, Alignment);
                           Held (Natural (Value)) :=
                             (if Op = Landin.IR.Measure_Size
                              then Landin.Types.Folded (Size)
                              else Landin.Types.Folded (Alignment));
                        end;

                     when Landin.IR.Load_Datum =>
                        --  [0130] makes a module a set, so one module value
                        --  may name another written below it.
                        Held (Natural (Value)) :=
                          Folded
                            (Landin.IR.Datum_Of (Of_Unit, Item, Value));

                     when Landin.IR.Load =>
                        Held (Natural (Value)) :=
                          Slots (Natural
                                   (Landin.IR.Slot_Of
                                      (Of_Unit, Item, Value)));

                     when Landin.IR.Store =>
                        Slots (Natural
                                 (Landin.IR.Slot_Of (Of_Unit, Item, Value)))
                          := Of_Value (Operand_Of (Value, 1));

                     when Landin.IR.Range_Check =>
                        --  D188 folds a checked module datum before emission.
                        --  A mandatory integer-to-pointer nonnull check also
                        --  reaches this walk, so an in-range static operand
                        --  passes through while an impossible image remains
                        --  an internal failure.
                        declare
                           Source : constant Landin.IR.Value_Id :=
                             Operand_Of (Value, 1);
                           Folded_Source : constant Landin.Types.Folded :=
                             Of_Value (Source);
                           Lower : constant Landin.Types.Folded :=
                             Landin.IR.Range_Lower (Of_Unit, Item, Value);
                           Upper : constant Landin.Types.Folded :=
                             Landin.IR.Range_Upper (Of_Unit, Item, Value);
                        begin
                           if Folded_Source < Lower
                             or else Folded_Source > Upper
                           then
                              raise Compiler_Defect with
                                "an out-of-range module image passed checking";
                           end if;
                           Held (Natural (Value)) := Folded_Source;
                        end;

                     when Landin.IR.Conversion =>
                        declare
                           Source : constant Landin.IR.Value_Id :=
                             Operand_Of (Value, 1);
                           From : constant Landin.Types.Type_Kind :=
                             Landin.IR.Result_Of (Of_Unit, Item, Source);
                           Into_Type : constant Landin.Types.Type_Kind :=
                             Landin.IR.Result_Of (Of_Unit, Item, Value);
                        begin
                           if From in Landin.Types.Float_Name
                             and then Into_Type in Landin.Types.Float_Name
                           then
                              declare
                                 Converted : Landin.Types.Magnitude;
                                 Overflowed : Boolean;
                              begin
                                 Landin.Types.Convert_Float_Width
                                   (Landin.Types.Magnitude
                                      (Of_Value (Source)),
                                    Landin.Types.Float_Name (From),
                                    Landin.Types.Float_Name (Into_Type),
                                    Converted, Overflowed);
                                 if Overflowed then
                                    raise Compiler_Defect with
                                      "an overflowing module float"
                                      & " conversion passed checking";
                                 end if;
                                 Held (Natural (Value)) :=
                                   Landin.Types.Folded (Converted);
                              end;
                           elsif From = Landin.Types.Bool
                             and then Into_Type in Landin.Types.Float_Name
                           then
                              Held (Natural (Value)) :=
                                Landin.Types.Folded
                                  (Landin.Types.Convert_Bool_To_Float
                                     (Of_Value (Source),
                                      Landin.Types.Float_Name (Into_Type)));
                           elsif From in Landin.Types.Integer_Name
                             and then Into_Type in Landin.Types.Float_Name
                           then
                              Held (Natural (Value)) :=
                                Landin.Types.Folded
                                  (Landin.Types.Convert_Integer_To_Float
                                     (Of_Value (Source),
                                      Landin.Types.Float_Name (Into_Type)));
                           elsif From in Landin.Types.Float_Name
                             and then Into_Type in Landin.Types.Integer_Name
                           then
                              declare
                                 Converted : Landin.Types.Folded;
                                 Overflowed : Boolean;
                              begin
                                 Landin.Types.Convert_Float_To_Integer
                                   (Landin.Types.Magnitude
                                      (Of_Value (Source)),
                                    Landin.Types.Float_Name (From),
                                    Landin.Types.Integer_Name (Into_Type),
                                    Facts, Converted, Overflowed);
                                 if Overflowed then
                                    raise Compiler_Defect with
                                      "an overflowing module float-to-"
                                      & "integer conversion passed checking";
                                 end if;
                                 Held (Natural (Value)) := Converted;
                              end;
                           elsif From in Landin.Types.Float_Name
                             and then Into_Type = Landin.Types.Bool
                           then
                              declare
                                 Converted : Landin.Types.Folded;
                                 Overflowed : Boolean;
                              begin
                                 Landin.Types.Convert_Float_To_Bool
                                   (Landin.Types.Magnitude
                                      (Of_Value (Source)),
                                    Landin.Types.Float_Name (From),
                                    Converted, Overflowed);
                                 if Overflowed then
                                    raise Compiler_Defect with
                                      "an impossible module float-to-bool"
                                      & " conversion passed checking";
                                 end if;
                                 Held (Natural (Value)) := Converted;
                              end;
                           else
                              Held (Natural (Value)) := Of_Value (Source);
                           end if;
                        end;

                     when Landin.IR.Negation =>
                        if Landin.IR.Result_Of (Of_Unit, Item, Value)
                             in Landin.Types.Float_Name
                        then
                           Held (Natural (Value)) :=
                             Landin.Types.Folded
                               (Landin.Types.Negated_Float
                                  (Landin.Types.Magnitude
                                     (Of_Value (Operand_Of (Value, 1))),
                                   Landin.Types.Float_Name
                                     (Landin.IR.Result_Of
                                        (Of_Unit, Item, Value))));
                        else
                           Held (Natural (Value)) :=
                             -Of_Value (Operand_Of (Value, 1));
                        end if;

                     when Landin.IR.Logical_Not =>
                        Held (Natural (Value)) :=
                          1 - Of_Value (Operand_Of (Value, 1));

                     when Landin.IR.Complement =>
                        --  A width operation, so it is the one place the
                        --  pattern rather than the number is what is meant.
                        declare
                           Bits : constant Landin.Targets.Bit_Width :=
                             Bits_Of (Value);
                        begin
                           Held (Natural (Value)) :=
                             As_Number
                               (Mask (not To_Pattern
                                            (Of_Value
                                               (Operand_Of (Value, 1)),
                                             Bits),
                                      Bits),
                                Bits, Signed_At (Value));
                        end;

                     when Landin.IR.Add | Landin.IR.Subtract
                        | Landin.IR.Multiply | Landin.IR.Divide
                        | Landin.IR.Remainder
                        | Landin.IR.Wrapping_Add
                        | Landin.IR.Wrapping_Subtract
                        | Landin.IR.Wrapping_Multiply
                        | Landin.IR.Bitwise_And | Landin.IR.Bitwise_Xor
                        | Landin.IR.Bitwise_Or
                        | Landin.IR.Shift_Left | Landin.IR.Shift_Right
                        | Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                        | Landin.IR.Less_Than | Landin.IR.Less_Or_Equal
                        | Landin.IR.Greater_Than
                        | Landin.IR.Greater_Or_Equal =>
                        declare
                           Left_Id : constant Landin.IR.Value_Id :=
                             Operand_Of (Value, 1);
                           A : constant Landin.Types.Folded :=
                             Of_Value (Left_Id);
                           B : constant Landin.Types.Folded :=
                             Of_Value (Operand_Of (Value, 2));

                           --  A comparison gives a bool back, so its own
                           --  width and sign say nothing about the
                           --  operands'.
                           Compares : constant Boolean :=
                             Op in Landin.IR.Equal_To
                                 .. Landin.IR.Greater_Or_Equal;
                           Bits : constant Landin.Targets.Bit_Width :=
                             (if Compares then Bits_Of (Left_Id)
                              else Bits_Of (Value));
                           Signed : constant Boolean :=
                             (if Compares then Signed_At (Left_Id)
                              else Signed_At (Value));

                           Left : constant Pattern := To_Pattern (A, Bits);
                           Right : constant Pattern := To_Pattern (B, Bits);

                           function Truth (Of_It : Boolean)
                             return Landin.Types.Folded
                             is (if Of_It then 1 else 0);

                           --  A width operation's answer, read back as the
                           --  number that pattern stands for.
                           function Narrowed (Bits_Wide : Pattern)
                             return Landin.Types.Folded
                             is (As_Number (Mask (Bits_Wide, Bits),
                                            Bits, Signed));

                           --  [0320] and D13: an amount at or past the
                           --  width gives zero, on every shift.
                           Exhausted : constant Boolean :=
                             Op in Landin.IR.Shift_Left
                                 | Landin.IR.Shift_Right
                             and then B >= Landin.Types.Folded (Bits);
                        begin
                           if Landin.IR.Result_Of
                                (Of_Unit, Item, Left_Id)
                                  in Landin.Types.Float_Name
                           then
                              if Compares then
                                 Held (Natural (Value)) :=
                                   Truth
                                     (Landin.Types.Float_Comparison_Result
                                        (Landin.Types.Magnitude (A),
                                         Landin.Types.Magnitude (B),
                                         Landin.Types.Float_Name
                                           (Landin.IR.Result_Of
                                              (Of_Unit, Item, Left_Id)),
                                         (case Op is
                                             when Landin.IR.Equal_To =>
                                               Landin.Types.Float_Equal,
                                             when Landin.IR.Not_Equal_To =>
                                               Landin.Types.Float_Not_Equal,
                                             when Landin.IR.Less_Than =>
                                               Landin.Types.Float_Less,
                                             when Landin.IR.Less_Or_Equal =>
                                               Landin.Types
                                                 .Float_Less_Or_Equal,
                                             when Landin.IR.Greater_Than =>
                                               Landin.Types.Float_Greater,
                                             when others =>
                                               Landin.Types
                                                 .Float_Greater_Or_Equal)));
                              else
                                 Held (Natural (Value)) :=
                                   Landin.Types.Folded
                                     (Landin.Types.Float_Arithmetic_Result
                                        (Landin.Types.Magnitude (A),
                                         Landin.Types.Magnitude (B),
                                         Landin.Types.Float_Name
                                           (Landin.IR.Result_Of
                                              (Of_Unit, Item, Left_Id)),
                                         (case Op is
                                             when Landin.IR.Add =>
                                               Landin.Types.Float_Add,
                                             when Landin.IR.Subtract =>
                                               Landin.Types.Float_Subtract,
                                             when Landin.IR.Multiply =>
                                               Landin.Types.Float_Multiply,
                                             when others =>
                                               Landin.Types.Float_Divide)));
                              end if;
                           else
                              Held (Natural (Value)) :=
                                (case Op is
                                 --  A checked operator has no width to
                                 --  answer at: [1460] gives a module value
                                 --  no moment in which to trap, so the
                                 --  whole expression is worked out and the
                                 --  checker refuses the answer no type
                                 --  holds.  That is why these do not mask.
                                 when Landin.IR.Add => A + B,
                                 when Landin.IR.Subtract => A - B,
                                 when Landin.IR.Multiply => A * B,
                                 --  Ada's own division truncates toward
                                 --  zero and its remainder takes the
                                 --  dividend's sign, which is [0290].
                                 when Landin.IR.Divide => A / B,
                                 when Landin.IR.Remainder => A rem B,
                                 --  [0300]'s wrapping forms are width
                                 --  operations and say so by name.
                                 when Landin.IR.Wrapping_Add =>
                                   Narrowed (Left + Right),
                                 when Landin.IR.Wrapping_Subtract =>
                                   Narrowed (Left - Right),
                                 when Landin.IR.Wrapping_Multiply =>
                                   Narrowed (Left * Right),
                                 when Landin.IR.Bitwise_And =>
                                   Narrowed (Left and Right),
                                 when Landin.IR.Bitwise_Xor =>
                                   Narrowed (Left xor Right),
                                 when Landin.IR.Bitwise_Or =>
                                   Narrowed (Left or Right),
                                 when Landin.IR.Shift_Left =>
                                   (if Exhausted then 0
                                    else Narrowed
                                           (Left * 2 ** Natural (Right))),
                                 --  A negative arithmetic shift is the
                                 --  complement of the logical shift of the
                                 --  complement, and every complement in
                                 --  that sentence is at this type's width
                                 --  rather than at the pattern's 64.
                                 when Landin.IR.Shift_Right =>
                                   (if Exhausted then 0
                                    elsif Signed and then A < 0
                                    then Narrowed
                                           (not (Mask (not Left, Bits)
                                                 / 2 ** Natural (Right)))
                                    else Narrowed
                                           (Left / 2 ** Natural (Right))),
                                 when Landin.IR.Equal_To => Truth (A = B),
                                 when Landin.IR.Not_Equal_To =>
                                   Truth (A /= B),
                                 when Landin.IR.Less_Than => Truth (A < B),
                                 when Landin.IR.Less_Or_Equal =>
                                   Truth (A <= B),
                                 when Landin.IR.Greater_Than =>
                                   Truth (A > B),
                                    when others => Truth (A >= B));
                           end if;
                        end;

                     when Landin.IR.Leave =>
                        Answer := Of_Value (Operand_Of (Value, 1));

                     when Landin.IR.Failure_Test
                        | Landin.IR.Function_Address
                        | Landin.IR.Evidence_Address
                        | Landin.IR.Evidence_Function
                        | Landin.IR.Evidence_Self | Landin.IR.Call
                        | Landin.IR.Memory_Access
                        | Landin.IR.Load_Indirect | Landin.IR.Store_Indirect
                        | Landin.IR.Indirect_Call | Landin.IR.Storage_Address
                        | Landin.IR.Place_Address | Landin.IR.Slice_Address
                        | Landin.IR.Empty_Slice_Base
                        | Landin.IR.Pointer_Address
                        | Landin.IR.Store_Datum
                        | Landin.IR.Load_Field | Landin.IR.Store_Field
                        | Landin.IR.Load_Element | Landin.IR.Store_Element
                        | Landin.IR.Copy_Array | Landin.IR.Copy_Variant
                        | Landin.IR.Clear_Array
                        | Landin.IR.Fill_Array
                        | Landin.IR.Load_Variant_Tag
                        | Landin.IR.Load_Variant_Field
                        | Landin.IR.Select_Variant
                        | Landin.IR.Store_Variant_Field
                        | Landin.IR.Jump | Landin.IR.Branch
                        | Landin.IR.Fail =>
                        --  [1940] admits none of these in a module value,
                        --  and [1830] refuses a call there by name.
                        raise Compiler_Defect
                          with "a module value reached the backend holding "
                               & Landin.IR.Opcode'Image (Op);
                  end case;
               end;
            end loop;
         end loop;

         Fold_Of (Natural (Item)) := Answer;
         Fold_At (Natural (Item)) := Settled;
         return Answer;
      end Folded;

      --  How wide a store the assembler is asked for, at each size.
      function Directive (Size : Held_Size) return String
        is (case Size is
               when Landin.Targets.Byte_1 => ".byte",
               when Landin.Targets.Byte_2 => ".short",
               when Landin.Targets.Byte_4 => ".long",
               when Landin.Targets.Byte_8 => ".quad");

      procedure Emit_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Slice_Image_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Aggregate_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Recursive_Image_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Array_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Reserved
        (Item      : Landin.IR.Item_Id;
         Size      : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment);

      --  [0670]'s module state.  The item carries its fields' types and
      --  this works out the same placement the checker did, because it is
      --  Landin.Targets.Placement over the same run against the same
      --  description.  D10 makes the whole of it zero, so the assembler is
      --  asked for that many zero bytes rather than for a value per field.
      procedure Emit_Aggregate_Datum (Item : Landin.IR.Item_Id) is
         Placed  : Landin.Targets.Placement;
         Ignored : Landin.Targets.Byte_Count;
      begin
         Place_Fields (Item, Placed, 0, Ignored);
         Emit_Reserved
           (Item,
            Landin.Targets.Size_Of (Placed),
            Landin.Targets.Alignment_Of (Placed));
      end Emit_Aggregate_Datum;

      --  D132 and recursive arrays share one descriptor-tree writer.  Replay
      --  ordinary-child and selected-payload placement against this target;
      --  array sequences repeat the complete child image at its padded size.
      --  Descriptors carry no byte offsets: every gap and tail is derived
      --  here and emitted as zero, never stored per logical array element.
      procedure Emit_Recursive_Image_Datum
        (Item : Landin.IR.Item_Id)
      is
         Placed : Landin.Targets.Placement;
         Ignored : Landin.Targets.Byte_Count;
         Written : Landin.Targets.Byte_Count := 0;
         Size : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment;
         Is_Array : constant Boolean :=
           Landin.IR.Has_Recursive_Array_Image (Of_Unit, Item);
         Top_Plan : constant Landin.Targets.Layouts.Plan :=
           (if Is_Array then Landin.Targets.Layouts.Make ([])
            else Datum_Layout (Of_Unit, Item, Facts));

         procedure Emit_Packed
           (Shape : Landin.IR.Field_Shape;
            Parent : Landin.IR.Aggregate_Field_Image;
            Top : Boolean := False);

         procedure Emit_Packed
           (Shape : Landin.IR.Field_Shape;
            Parent : Landin.IR.Aggregate_Field_Image;
            Top : Boolean := False)
         is
            use type Landin.Packed.Image;
            Bits : Landin.Packed.Image := 0;
            Storage : Natural := 0;
            Count : constant Natural :=
              (if Top then Landin.IR.Field_Count (Of_Unit, Item)
               else Landin.IR.Aggregate_Field_Count (Of_Unit, Shape));
         begin
            for Index in 1 .. Count loop
               declare
                  Leaf : constant Landin.IR.Field_Shape :=
                    (if Top then Landin.IR.Nth_Field_Shape
                       (Of_Unit, Item, Index)
                     else Landin.IR.Nth_Aggregate_Field
                       (Of_Unit, Shape, Index));
                  Image : constant Landin.IR.Aggregate_Field_Image :=
                    (if Top then Landin.IR.Field_Image_Of
                       (Of_Unit, Item, Index)
                     else Landin.IR.Descendant_Image_Of
                       (Of_Unit, Item, Parent, Index));
                  Scalar : constant Landin.Types.Folded :=
                    (if Top then Landin.IR.Nth_Field_Image
                       (Of_Unit, Item, Index) else Image.Value);
               begin
                  Bits := Bits or Landin.IR.Packed_Field_Image
                    (Of_Unit, Item, Leaf, Image, Scalar);
                  Storage := Leaf.Packing.Storage;
               end;
            end loop;
            Emit (Directive (Landin.Targets.Packed.Carrier (Storage)) & " "
              & Trimmed (Landin.Packed.Image'Image (Bits)));
         end Emit_Packed;

         procedure Emit_Zero (Bytes : Landin.Targets.Byte_Count);

         procedure Emit_Field
           (Shape : Landin.IR.Field_Shape;
            Image : Landin.IR.Aggregate_Field_Image;
            Flat  : Landin.Types.Folded;
            Top   : Boolean := False);

         procedure Emit_Children
           (Shape  : Landin.IR.Field_Shape;
            Parent : Landin.IR.Aggregate_Field_Image);

         procedure Emit_Array
           (Shape : Landin.IR.Field_Shape;
            Image : Landin.IR.Aggregate_Field_Image);

         procedure Emit_Variant
           (Shape : Landin.IR.Field_Shape;
            Image : Landin.IR.Aggregate_Field_Image);

         procedure Emit_Zero (Bytes : Landin.Targets.Byte_Count) is
         begin
            if Bytes > 0 then
               Emit
                 (".zero "
                  & Trimmed (Landin.Targets.Byte_Count'Image (Bytes)));
            end if;
         end Emit_Zero;

         procedure Emit_Array
           (Shape : Landin.IR.Field_Shape;
            Image : Landin.IR.Aggregate_Field_Image)
         is
            Field_Size : Landin.Targets.Byte_Count;
            Field_Alignment : Landin.Targets.Byte_Alignment;
         begin
            Landin.Backend.Field_Extent
              (Of_Unit, Shape, Facts, Field_Size, Field_Alignment);
            pragma Unreferenced (Field_Alignment);

            if Image.Slice then
               declare
                  Element_Size : Landin.Targets.Byte_Count;
                  Element_Alignment : Landin.Targets.Byte_Alignment;
               begin
                  Landin.Backend.Field_Extent
                    (Of_Unit, Image.Slice_Element, Facts,
                     Element_Size, Element_Alignment);
                  declare
                     Offset : constant Landin.Targets.Byte_Count :=
                       Landin.Targets.Byte_Count (Image.Slice_First)
                       * Element_Size;
                     Base : constant String :=
                       (if Image.Target = Landin.IR.No_Item
                        then Trimmed
                          (Landin.Targets.Byte_Alignment'Image
                             (Element_Alignment))
                        else Symbol (Image.Target)
                          & (if Offset = 0 then ""
                             else " + " & Trimmed
                               (Landin.Targets.Byte_Count'Image (Offset))));
                  begin
                     Emit (".long " & Base);
                     Emit
                       (".long "
                        & Trimmed (Landin.Types.Folded'Image (Image.Value)));
                  end;
               end;
            elsif Image.Form = Landin.IR.Element_Sequence then
               --  Count is stored children, not logical elements.  Only
               --  the final child repeats; its complete target-laid-out
               --  image (including tail padding) is the array stride.
               --  Descendant_Image_Of skips descriptor roots, whereas
               --  Nth_Descriptor_Element below skips numeric fields only.
               if (Image.Count = 0
                   and then (Image.Value /= 0 or else Shape.Length /= 0))
                 or else (Image.Count > 0
                   and then
                     (Landin.IR.Element_Total (Image.Count - 1)
                        > Shape.Length
                      or else Image.Value /= Landin.Types.Folded
                        (Shape.Length
                         - Landin.IR.Element_Total (Image.Count - 1))))
               then
                  raise Landin.Compiler_Defect with
                    "a recursive array image has the wrong coverage";
               end if;
               for Position in 1 .. Image.Count loop
                  declare
                     Child : constant Landin.IR.Aggregate_Field_Image :=
                       Landin.IR.Descendant_Image_Of
                         (Of_Unit, Item, Image, Position);
                     Copies : constant Landin.Types.Folded :=
                       (if Position = Image.Count then Image.Value else 1);
                  begin
                     --  A zero suffix was evaluated but stores nothing.
                     if Copies > 0 then
                        if Copies > 1 then
                           Emit
                             (".rept " & Trimmed
                                (Landin.Types.Folded'Image (Copies)));
                        end if;
                        Emit_Field
                          (Landin.IR.Array_Element_Shape (Of_Unit, Shape),
                           Child, Child.Value);
                        if Copies > 1 then
                           Emit (".endr");
                        end if;
                     end if;
                  end;
               end loop;
            elsif Image.Form = Landin.IR.Absent then
               Emit_Zero (Field_Size);
            elsif Landin.IR.Array_Element_Is_Aggregate (Of_Unit, Shape) then
               raise Landin.Compiler_Defect with
                 "a complete array element has a numeric image";
            elsif Image.Form = Landin.IR.Finite then
               for Position in 1 .. Image.Count loop
                  Emit
                    (Directive (Size_Of (Shape.Element, Facts)) & " "
                     & Trimmed
                         (Landin.Types.Folded'Image
                            (Landin.IR.Nth_Descriptor_Element
                               (Of_Unit, Item, Image,
                                Landin.IR.Part_Position (Position)))));
               end loop;
            elsif Image.Form
                    in Landin.IR.Repeated | Landin.IR.Hybrid
            then
               if Image.Form = Landin.IR.Hybrid then
                  for Position in 1 .. Image.Count loop
                     Emit
                       (Directive (Size_Of (Shape.Element, Facts)) & " "
                        & Trimmed
                            (Landin.Types.Folded'Image
                               (Landin.IR.Nth_Descriptor_Element
                                  (Of_Unit, Item, Image,
                                   Landin.IR.Part_Position (Position)))));
                  end loop;
               end if;
               Emit
                 (".rept "
                  & Trimmed
                      (Landin.IR.Element_Total'Image
                         (Shape.Length
                          - Landin.IR.Element_Total (Image.Count))));
               Emit
                 (Directive (Size_Of (Shape.Element, Facts)) & " "
                  & Trimmed (Landin.Types.Folded'Image (Image.Value)));
               Emit (".endr");
            else
               raise Landin.Compiler_Defect with
                 "a malformed recursive array image reached Cortex-M";
            end if;
         end Emit_Array;

         procedure Emit_Variant
           (Shape : Landin.IR.Field_Shape;
            Image : Landin.IR.Aggregate_Field_Image)
         is
            Field_Size : Landin.Targets.Byte_Count;
            Field_Alignment : Landin.Targets.Byte_Alignment;
         begin
            Landin.Backend.Field_Extent
              (Of_Unit, Shape, Facts, Field_Size, Field_Alignment);
            pragma Unreferenced (Field_Alignment);

            if Image.Form = Landin.IR.Absent then
               Emit_Zero (Field_Size);
               return;
            end if;

            if Image.Form /= Landin.IR.Selected then
               raise Landin.Compiler_Defect with
                 "a malformed recursive variant image reached Cortex-M";
            end if;

            declare
               Selected : constant Positive := Positive (Image.Value);
               In_Field : Landin.Targets.Byte_Count :=
                 Landin.Targets.Byte_Count
                   (Landin.Targets.Bytes (Size_Of (Shape.Element, Facts)));
            begin
               Emit
                 (Directive (Size_Of (Shape.Element, Facts)) & " "
                  & Trimmed (Natural'Image (Natural (Selected) - 1)));

               for Payload in 1 .. Image.Count loop
                  declare
                     Leaf : constant Landin.IR.Field_Shape :=
                       Landin.IR.Nth_Variant_Case_Field
                         (Of_Unit, Shape, Selected, Payload);
                     Payload_Image : constant
                       Landin.IR.Aggregate_Field_Image :=
                         Landin.IR.Descendant_Image_Of
                           (Of_Unit, Item, Image, Payload);
                     At_Payload : constant Landin.Targets.Byte_Count :=
                       Landin.Backend.Variant_Payload_Field_Offset
                         (Of_Unit, Shape, Selected, Payload, Facts);
                     Payload_Size : Landin.Targets.Byte_Count;
                     Payload_Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit, Leaf, Facts, Payload_Size,
                        Payload_Alignment);
                     pragma Unreferenced (Payload_Alignment);
                     if At_Payload > In_Field then
                        Emit_Zero (At_Payload - In_Field);
                     end if;
                     Emit_Field
                       (Leaf, Payload_Image, Payload_Image.Value);
                     In_Field := At_Payload + Payload_Size;
                  end;
               end loop;

               if Field_Size > In_Field then
                  Emit_Zero (Field_Size - In_Field);
               end if;
            end;
         end Emit_Variant;

         procedure Emit_Children
           (Shape  : Landin.IR.Field_Shape;
            Parent : Landin.IR.Aggregate_Field_Image)
         is
            Plan : constant Landin.Targets.Layouts.Plan :=
              Aggregate_Layout (Of_Unit, Shape, Facts);
            Child_Written : Landin.Targets.Byte_Count := 0;
            Child_Size : Landin.Targets.Byte_Count;
            Child_Alignment : Landin.Targets.Byte_Alignment;
         begin
            if Landin.IR.Layout_Of (Of_Unit, Shape) = Landin.Layouts.Packed
            then
               Emit_Packed (Shape, Parent);
               return;
            end if;
            for Child of Plan.Order loop
               declare
                  Leaf : constant Landin.IR.Field_Shape :=
                    Landin.IR.Nth_Aggregate_Field
                      (Of_Unit, Shape, Child);
                  Image : constant Landin.IR.Aggregate_Field_Image :=
                    Landin.IR.Descendant_Image_Of
                      (Of_Unit, Item, Parent, Child);
                  At_Child : constant Landin.Targets.Byte_Count :=
                    Plan.Offsets (Child);
               begin
                  Landin.Backend.Field_Extent
                    (Of_Unit, Leaf, Facts, Child_Size, Child_Alignment);
                  if At_Child > Child_Written then
                     Emit_Zero (At_Child - Child_Written);
                  end if;
                  Emit_Field (Leaf, Image, Image.Value);
                  Child_Written := At_Child + Child_Size;
               end;
            end loop;

            if Plan.Size > Child_Written then
               Emit_Zero (Plan.Size - Child_Written);
            end if;
         end Emit_Children;

         procedure Emit_Field
           (Shape : Landin.IR.Field_Shape;
            Image : Landin.IR.Aggregate_Field_Image;
            Flat  : Landin.Types.Folded;
            Top   : Boolean := False)
         is
            Field_Size : Landin.Targets.Byte_Count;
            Field_Alignment : Landin.Targets.Byte_Alignment;
         begin
            case Shape.Kind is
               when Landin.IR.Scalar_Field_Shape =>
                  Emit
                    (Directive (Size_Of (Shape.Element, Facts)) & " "
                     & (if Image.Target /= Landin.IR.No_Item
                        then Symbol (Image.Target)
                        elsif Shape.Atoms /= Landin.IR.No_Atom_Set
                        then Trimmed (Positive'Image
                          (Atom_Code
                             (Of_Unit, Landin.IR.Declaration_Id
                                (if Top then Flat else Image.Value))))
                        else Trimmed
                          (Landin.Types.Folded'Image
                             ((if Top then Flat else Image.Value)))));

               when Landin.IR.Array_Field_Shape =>
                  Emit_Array (Shape, Image);

               when Landin.IR.Aggregate_Field_Shape =>
                  if Image.Form = Landin.IR.Absent then
                     Landin.Backend.Field_Extent
                       (Of_Unit, Shape, Facts, Field_Size,
                        Field_Alignment);
                     Emit_Zero (Field_Size);
                  elsif Image.Form = Landin.IR.Nested then
                     Emit_Children (Shape, Image);
                  else
                     raise Landin.Compiler_Defect with
                       "a malformed nested image reached Cortex-M";
                  end if;

               when Landin.IR.Variant_Field_Shape =>
                  Emit_Variant (Shape, Image);
            end case;
         end Emit_Field;
      begin
         if Is_Array then
            Landin.Backend.Field_Extent
              (Of_Unit, Landin.IR.Whole_Array_Shape (Of_Unit, Item),
               Facts, Size, Alignment);
         else
            Place_Fields (Item, Placed, 0, Ignored);
            Size := Landin.Targets.Size_Of (Placed);
            Alignment := Landin.Targets.Alignment_Of (Placed);
         end if;

         if Is_Public_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;
         Put
           (Character'Val (9) & ".balign "
            & Trimmed (Landin.Targets.Byte_Alignment'Image (Alignment)));
         Put (Symbol (Item) & ":");
         if not Is_Array
           and then Landin.IR.Layout_Of (Of_Unit, Item) = Landin.Layouts.Packed
         then
            Emit_Packed ((others => <>), (others => <>), Top => True);
            return;
         end if;


         if Is_Array then
            Emit_Array
              (Landin.IR.Whole_Array_Shape (Of_Unit, Item),
               Landin.IR.Array_Image_Of (Of_Unit, Item));
            Written := Size;
         end if;
         for Field of Top_Plan.Order loop
            declare
               Shape : constant Landin.IR.Field_Shape :=
                 Landin.IR.Nth_Field_Shape (Of_Unit, Item, Field);
               Image : constant Landin.IR.Aggregate_Field_Image :=
                 Landin.IR.Field_Image_Of (Of_Unit, Item, Field);
               Field_Size : Landin.Targets.Byte_Count;
               Field_Alignment : Landin.Targets.Byte_Alignment;
               At_Field : constant Landin.Targets.Byte_Count :=
                 Top_Plan.Offsets (Field);
            begin
               Landin.Backend.Field_Extent
                 (Of_Unit, Shape, Facts, Field_Size, Field_Alignment);
               pragma Unreferenced (Field_Alignment);
               if At_Field > Written then
                  Emit_Zero (At_Field - Written);
               end if;
               Emit_Field
                 (Shape, Image,
                  Landin.IR.Nth_Field_Image (Of_Unit, Item, Field),
                  Top => True);
               Written := At_Field + Field_Size;
            end;
         end loop;

         if Size > Written then
            Emit_Zero (Size - Written);
         end if;
      end Emit_Recursive_Image_Datum;

      --  Whether a module value has an absent zero image, and so is storage
      --  to reserve rather than bytes to carry.  D66 gives an aggregate its
      --  first written image; omitted and whole-`zeroed` aggregates still
      --  have none.  An
      --  array datum is zero when it has no image at all.  A D24 literal image
      --  that happens to be every-position-zero is written as `.data` anyway;
      --  D34 deliberately represents a repeated zero pattern as no image, so
      --  that form remains storage the loader zeroes in this section.
      function Is_All_Zero (Item : Landin.IR.Item_Id) return Boolean;

      function Is_All_Zero (Item : Landin.IR.Item_Id) return Boolean is
      begin
         if Landin.IR.Signature_Of (Of_Unit, Item)
              /= Landin.IR.No_Signature
           or else Landin.IR.Address_Target (Of_Unit, Item)
             /= Landin.IR.No_Item
         then
            return False;
         end if;

         if Landin.IR.Result_Of (Of_Unit, Item) = Landin.Types.Aggregate then
            return not Landin.IR.Has_Image (Of_Unit, Item);
         end if;

         if Landin.IR.Result_Of (Of_Unit, Item)
            = Landin.Types.Fixed_Array
         then
            return not Landin.IR.Has_Image (Of_Unit, Item);
         end if;

         return Folded (Item) = 0;
      end Is_All_Zero;

      --  Reserved and not written: `.zero` in a section the assembler
      --  marks NOBITS costs no bytes in the object or the image, while
      --  the same directive in `.data` costs every one of them.
      procedure Emit_Reserved
        (Item      : Landin.IR.Item_Id;
         Size      : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment) is
      begin
         Select_Section
           (Item, (if Landin.IR.Is_Immutable (Of_Unit, Item)
                   then ".rodata." else ".bss."),
            (if Landin.IR.Is_Immutable (Of_Unit, Item) then "a" else "aw"));
         Emit (".globl " & Symbol (Item));
         Emit (".balign " & Trimmed (Alignment'Image));
         Put (Symbol (Item) & ":");
         Emit (".zero " & Trimmed (Size'Image));

      end Emit_Reserved;

      procedure Emit_Array_Datum (Item : Landin.IR.Item_Id) is
         Length : constant Landin.IR.Element_Total :=
           Landin.IR.Array_Length (Of_Unit, Item);
         --  D121: the element may be an ordinary struct, whose extent and
         --  alignment are its own padded layout.
         Size : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment;
      begin
         Landin.Backend.Field_Extent
           (Of_Unit, Landin.IR.Array_Element_Shape (Of_Unit, Item),
            Facts, Size, Alignment);
         Emit_Reserved
           (Item,
            Landin.Targets.Byte_Count (Length) * Size,
            (if Length = 0 then 1 else Alignment));
      end Emit_Array_Datum;

      --  D24/D34: an array datum with an image.  Each literal element becomes
      --  one directive of its own size; a repetition becomes one directive
      --  inside `.rept`.  Nonzero or mixed images reach `.data`, while
      --  omitted, explicit-zero and repeated-zero images stay in `.bss`.  A
      --  negative fold is written as the number
      --  the assembler encodes at this width -- the same spelling
      --  Emit_Datum already uses.
      procedure Emit_Array_Image_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Array_Image_Datum (Item : Landin.IR.Item_Id) is
      begin
         if Landin.IR.Has_Recursive_Array_Image (Of_Unit, Item) then
            Emit_Recursive_Image_Datum (Item);
            return;
         end if;

         --  Do not even ask for a scalar width until recursive roots have
         --  been excluded: their immediate element need not be scalar.
         declare
            Length : constant Landin.IR.Element_Total :=
              Landin.IR.Array_Length (Of_Unit, Item);
            Element : constant Landin.Types.Scalar_Name :=
              Landin.IR.Array_Element (Of_Unit, Item);
            Held : constant Held_Size := Size_Of (Element, Facts);
         begin
            if Is_Public_Item (Item) then
               Put (Character'Val (9) & ".globl " & Symbol (Item));
            end if;

               Put (Character'Val (9) & ".balign "
                 & Trimmed
                     (Landin.Targets.Byte_Alignment'Image
                        (Landin.Targets.Alignment_Of (Facts, Held))));
            Put (Symbol (Item) & ":");

            if Landin.IR.Is_Repeated_Image (Of_Unit, Item) then
               --  D34 uses `.rept` around one width-specific scalar directive.
               --  D38 writes its finite prefix first, then repeats one suffix
               --  value for N - k positions.  Assembly size depends on
               --  the written prefix, never the target-sized extent; `.quad`
               --  preserves all eight bytes unlike GNU `.fill`.
               declare
                  Prefix : constant Landin.IR.Element_Total :=
                    Landin.IR.Image_Prefix_Length (Of_Unit, Item);
               begin
                  if Prefix > 0 then
                     for Position in Landin.IR.Part_Position'(1)
                                     .. Landin.IR.Part_Position (Prefix)
                     loop
                        Emit
                          (Directive (Held) & " "
                           & Trimmed
                               (Landin.Types.Folded'Image
                                  (Landin.IR.Nth_Image
                                     (Of_Unit, Item, Position))));
                     end loop;
                  end if;
                  Emit
                    (".rept "
                     & Trimmed
                         (Landin.IR.Element_Total'Image (Length - Prefix)));
                  Emit
                    (Directive (Held) & " "
                     & Trimmed
                         (Landin.Types.Folded'Image
                            (Landin.IR.Repeated_Image_Value (Of_Unit, Item))));
                  Emit (".endr");
               end;
            else
               for Position in Landin.IR.Part_Position'(1)
                               .. Landin.IR.Part_Position (Length)
               loop
                  Emit
                    (Directive (Held) & " "
                     & Trimmed
                         (Landin.Types.Folded'Image
                            (Landin.IR.Nth_Image
                               (Of_Unit, Item, Position))));
               end loop;
            end if;

         end;
      end Emit_Array_Image_Datum;

      procedure Emit_Slice_Image_Datum (Item : Landin.IR.Item_Id) is
         Source : constant Landin.IR.Item_Id :=
           Landin.IR.Slice_Image_Source (Of_Unit, Item);
         Element : constant Landin.IR.Field_Shape :=
           Landin.IR.Slice_Image_Element (Of_Unit, Item);
         Element_Size : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment;
      begin
         Landin.Backend.Field_Extent
           (Of_Unit, Element, Facts, Element_Size, Alignment);
         if Is_Public_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;
         Put (Character'Val (9) & ".balign 8");
         Put (Symbol (Item) & ":");
         declare
            Offset : constant Landin.Targets.Byte_Count :=
              Landin.Targets.Byte_Count
                (Landin.IR.Slice_Image_First (Of_Unit, Item))
              * Element_Size;
            Base : constant String :=
              (if Source = Landin.IR.No_Item
               then Trimmed
                 (Landin.Targets.Byte_Alignment'Image (Alignment))
               else Symbol (Source)
                 & (if Offset = 0 then ""
                    else " + " & Trimmed
                      (Landin.Targets.Byte_Count'Image (Offset))));
         begin
            Emit (".long " & Base);
         end;
         Emit
           (".long "
            & Trimmed
                (Landin.IR.Element_Total'Image
                   (Landin.IR.Slice_Image_Length (Of_Unit, Item))));
      end Emit_Slice_Image_Datum;

      procedure Emit_Datum (Item : Landin.IR.Item_Id) is
         Kind : constant Landin.Types.Scalar_Name :=
           Landin.IR.Result_Of (Of_Unit, Item);
         Held : constant Held_Size := Size_Of (Kind, Facts);
         --  A function datum is a static relocation to its verified routine
         --  target; D181's cstring datum similarly relocates to read-only
         --  bytes.  Every other scalar is the folded number the assembler
         --  encodes at this width.
         Written : constant String :=
           (if Landin.IR.Signature_Of (Of_Unit, Item)
                 /= Landin.IR.No_Signature
            then Symbol (Landin.IR.Function_Target (Of_Unit, Item))
            elsif Landin.IR.Address_Target (Of_Unit, Item)
                    /= Landin.IR.No_Item
            then Symbol (Landin.IR.Address_Target (Of_Unit, Item))
            else Trimmed (Landin.Types.Folded'Image (Folded (Item))));
      begin
         if Is_Public_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".balign "
              & Trimmed
                  (Landin.Targets.Byte_Alignment'Image
                     (Landin.Targets.Alignment_Of (Facts, Held))));
         Put (Symbol (Item) & ":");
         Emit (Directive (Held) & " " & Written);
      end Emit_Datum;

   begin
      if Facts /= Landin.Targets.Cortex_M then
         raise Compiler_Defect with "Cortex emission needs ARMv6-M";
      end if;
      Allocate_Symbols;
      Emit (".syntax unified");
      Emit (".cpu cortex-m0");
      Emit (".thumb");
      Emit (".text");
      if Firmware_Entry /= Landin.IR.No_Item then
         Emit_Vectors;
         Put (Landin.Backend.Firmware.Startup (Symbol (Firmware_Entry)));
      end if;
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then not Landin.IR.Is_External (Of_Unit, Item)
            then
               Emit_Routine (Item);
            end if;
         end;
      end loop;
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum then
               if Landin.IR.Is_Read_Only (Of_Unit, Item) then
                  Select_Section (Item, ".rodata.", "a");
                  Emit_Array_Image_Datum (Item);
               else
                  Select_Section
                    (Item, (if Landin.IR.Is_Immutable (Of_Unit, Item)
                     then ".rodata." elsif Is_All_Zero (Item)
                     then ".bss." else ".data."),
                     (if Landin.IR.Is_Immutable (Of_Unit, Item)
                      then "a" else "aw"));
                  if Is_All_Zero (Item) then
                     if Landin.IR.Result_Of (Of_Unit, Item) =
                       Landin.Types.Aggregate
                     then
                        Emit_Aggregate_Datum (Item);
                     elsif Landin.IR.Result_Of (Of_Unit, Item) =
                       Landin.Types.Fixed_Array
                     then
                        Emit_Array_Datum (Item);
                     else
                        Emit_Reserved (Item, Landin.Targets.Byte_Count
                          (Landin.Targets.Bytes
                          (Size_Of (Landin.IR.Result_Of (Of_Unit, Item),
                            Facts))),
                          Landin.Targets.Alignment_Of (Facts,
                            Size_Of (Landin.IR.Result_Of (Of_Unit, Item),
                              Facts)));
                     end if;
                  elsif Landin.IR.Result_Of (Of_Unit, Item) =
                    Landin.Types.Aggregate
                  then
                     Emit_Recursive_Image_Datum (Item);
                  elsif Landin.IR.Has_Slice_Image (Of_Unit, Item) then
                     Emit_Slice_Image_Datum (Item);
                  elsif Landin.IR.Result_Of (Of_Unit, Item) =
                    Landin.Types.Fixed_Array
                  then
                     Emit_Array_Image_Datum (Item);
                  else
                     Emit_Datum (Item);
                  end if;
               end if;
            end if;
         end;
      end loop;
      if Landin.IR.Evidence_Count (Of_Unit) > 0 then
         Emit (".section .rodata");
         for Index in 1 .. Landin.IR.Evidence_Count (Of_Unit) loop
            declare
               Id : constant Landin.IR.Evidence_Id := Landin.IR.Evidence_Id
                 (Index);
               Bytes : Landin.Targets.Byte_Count;
               Alignment : Landin.Targets.Byte_Alignment;
            begin
               Field_Extent (Of_Unit, Landin.IR.Evidence_Represented (Of_Unit,
                 Id),
                 Facts, Bytes, Alignment);
               Emit (".balign 4");
               Put (Evidence_Symbol (Id) & ":");
               Emit (".long " & Trimmed (Landin.Targets.Byte_Count'Image
                 (Bytes)));
               Emit (".long " & Trimmed (Landin.Targets.Byte_Alignment'Image
                 (Alignment)));
               for Entry_Index in 1 .. Landin.IR.Evidence_Entry_Count
                 (Of_Unit, Id) loop
                  Emit (".long " & Symbol
                    (Landin.IR.Evidence_Entry_Target (Of_Unit, Id,
                      Entry_Index)));
               end loop;
            end;
         end loop;
      end if;
      Emit (".section .note.GNU-stack,"""",%progbits");
      Assembly := Out_Text;
   end Emit;

end Landin.Backend.Cortex_M;
