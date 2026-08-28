with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Types;

package body Landin.Backend.X86_64 is

   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Count;
   use type Landin.IR.Item_Kind;
   use type Landin.IR.Opcode;
   use type Landin.IR.Element_Total;
   use type Landin.IR.Field_Image_Form;
   use type Landin.IR.Field_Shape_Kind;
   use type Landin.Types.Folded;
   use type Landin.Types.Magnitude;
   use type Landin.Types.Type_Kind;

   LF : constant Character := Character'Val (10);

   --  `Image` leads with a blank for a non-negative number and assembly
   --  is bytes, so the blank is a byte.  Landin.IR.Dump's trim, for the
   --  same reason.
   function Trimmed (Value : String) return String
     is (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

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
   --  eleven integers only, and a bool is [1870]'s zero or one in the byte
   --  `Landin.Backend` gives it, so it folds at that byte's width.
   function Fold_Width
     (Kind : Landin.Types.Scalar_Name;
      Facts : Landin.Targets.Target_Facts) return Landin.Targets.Bit_Width
     is (if Kind in Landin.Types.Integer_Name
         then Landin.Types.Width (Landin.Types.Integer_Name (Kind), Facts)
         else 8);

   --  The suffix that makes an instruction operate at one width, and the
   --  accumulator named at that width.  One accumulator is all this shape
   --  needs; see the header.
   function Suffix (Size : Held_Size) return String
     is (case Size is
            when Landin.Targets.Byte_1 => "b",
            when Landin.Targets.Byte_2 => "w",
            when Landin.Targets.Byte_4 => "l",
            when Landin.Targets.Byte_8 => "q");

   function Accumulator (Size : Held_Size) return String
     is (case Size is
            when Landin.Targets.Byte_1 => "%al",
            when Landin.Targets.Byte_2 => "%ax",
            when Landin.Targets.Byte_4 => "%eax",
            when Landin.Targets.Byte_8 => "%rax");

   --  [1650]'s system C ABI hands the first six integer arguments in
   --  these registers, in this order.  A seventh parameter is not
   --  reachable yet and says so rather than picking a register.
   function Argument_Register
     (Index : Positive; Size : Held_Size) return String
     is (case Index is
            when 1 =>
              (case Size is
                  when Landin.Targets.Byte_1 => "%dil",
                  when Landin.Targets.Byte_2 => "%di",
                  when Landin.Targets.Byte_4 => "%edi",
                  when Landin.Targets.Byte_8 => "%rdi"),
            when 2 =>
              (case Size is
                  when Landin.Targets.Byte_1 => "%sil",
                  when Landin.Targets.Byte_2 => "%si",
                  when Landin.Targets.Byte_4 => "%esi",
                  when Landin.Targets.Byte_8 => "%rsi"),
            when 3 =>
              (case Size is
                  when Landin.Targets.Byte_1 => "%dl",
                  when Landin.Targets.Byte_2 => "%dx",
                  when Landin.Targets.Byte_4 => "%edx",
                  when Landin.Targets.Byte_8 => "%rdx"),
            when 4 =>
              (case Size is
                  when Landin.Targets.Byte_1 => "%cl",
                  when Landin.Targets.Byte_2 => "%cx",
                  when Landin.Targets.Byte_4 => "%ecx",
                  when Landin.Targets.Byte_8 => "%rcx"),
            when 5 =>
              (case Size is
                  when Landin.Targets.Byte_1 => "%r8b",
                  when Landin.Targets.Byte_2 => "%r8w",
                  when Landin.Targets.Byte_4 => "%r8d",
                  when Landin.Targets.Byte_8 => "%r8"),
            when 6 =>
              (case Size is
                  when Landin.Targets.Byte_1 => "%r9b",
                  when Landin.Targets.Byte_2 => "%r9w",
                  when Landin.Targets.Byte_4 => "%r9d",
                  when Landin.Targets.Byte_8 => "%r9"),
            when others =>
              raise Compiler_Defect
                with "this ABI passes six integer arguments in registers");

   ------------------------------------------------------------------
   --  Text
   ------------------------------------------------------------------

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts) return Boolean
   is
      Largest_Displacement : constant Landin.Targets.Byte_Count :=
        2 ** 31 - 1;
      Layout : Frame;
   begin
      Layout := Laid_Out (Of_Unit, Item, Facts);
      return Extent (Layout) <= Largest_Displacement;
   exception
      when Constraint_Error | Landin.Compiler_Defect =>
         --  Laid_Out uses target-width arithmetic.  Overflow says the frame
         --  does not fit even the target address space, and is a backend
         --  capability answer here rather than a compiler failure.  Align_Up
         --  names that overflow a defect in general; this preflight is the
         --  place where an accepted, too-wide frame makes it expected.
         return False;
   end Frame_Is_Addressable;

   function Text
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts) return String
   is
      Out_Text : Unbounded.Unbounded_String;

      procedure Put (Line : String);

      procedure Put (Line : String) is
      begin
         Unbounded.Append (Out_Text, Line & LF);
      end Put;

      procedure Emit (Instruction : String);

      procedure Emit (Instruction : String) is
      begin
         Put (Character'Val (9) & Instruction);
      end Emit;

      --  A symbol is the declaration's own spelling.  The kernel has one
      --  module and no name mangling, so a second naming scheme here
      --  would be a fact about this backend that no paragraph states.
      function Symbol (Item : Landin.IR.Item_Id) return String;

      function Symbol (Item : Landin.IR.Item_Id) return String is
         Declared : constant Landin.IR.Declaration_Id :=
           Landin.IR.Declares (Of_Unit, Item);
      begin
         return Landin.Source.Names.Spelling
                  (Names, Landin.Resolution.Name_Of (Meanings, Declared));
      end Symbol;

      --  Labels carry the item, because a Block_Id restarts at 1 in the
      --  next item and two blocks named `.L1` would be one label.
      function Label
        (Item : Landin.IR.Item_Id; Block : Landin.IR.Block_Id)
        return String
        is (".L" & Trimmed (Landin.IR.Item_Id'Image (Item))
            & "_" & Trimmed (Landin.IR.Block_Id'Image (Block)));

      function Cell (Offset : Landin.Targets.Byte_Count) return String
        is ("-" & Trimmed (Landin.Targets.Byte_Count'Image (Offset))
            & "(%rbp)");

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

      function Has_Array_Field
        (Item : Landin.IR.Item_Id) return Boolean;

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
               Held : constant Held_Size :=
                 Size_Of (Landin.IR.Array_Element (Of_Unit, Item), Facts);
            begin
               if Wanted > 0 then
                  Offset :=
                    Landin.Targets.Byte_Count (Wanted - 1)
                    * Landin.Targets.Byte_Count
                        (Landin.Targets.Bytes (Held));
               end if;
            end;

            return;
         end if;

         for Field in 1 .. Landin.IR.Field_Count (Of_Unit, Item) loop
            declare
               Shape : constant Landin.IR.Field_Shape :=
                 Landin.IR.Nth_Field_Shape (Of_Unit, Item, Field);
               Size : Landin.Targets.Byte_Count;
               Alignment : Landin.Targets.Byte_Alignment;
               At_Offset : Landin.Targets.Byte_Count;
            begin
               Landin.Backend.Field_Extent
                 (Shape, Facts, Size, Alignment);
               Landin.Targets.Place
                 (Placed, Size, Alignment, At_Offset);

               if Landin.IR.Element_Total (Field) = Wanted then
                  Offset := At_Offset;
               end if;
            end;
         end loop;
      end Place_Fields;

      function Has_Array_Field (Item : Landin.IR.Item_Id) return Boolean is
      begin
         if Landin.IR.Result_Of (Of_Unit, Item) /= Landin.Types.Aggregate
         then
            return False;
         end if;

         for Field in 1 .. Landin.IR.Field_Count (Of_Unit, Item) loop
            if Landin.IR.Nth_Field_Shape (Of_Unit, Item, Field).Kind
                 = Landin.IR.Array_Field_Shape
            then
               return True;
            end if;
         end loop;
         return False;
      end Has_Array_Field;

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

      procedure Emit_Routine (Item : Landin.IR.Item_Id);

      procedure Emit_Routine (Item : Landin.IR.Item_Id) is
         Layout : constant Frame := Laid_Out (Of_Unit, Item, Facts);
         Result : constant Landin.Types.Type_Kind :=
           Landin.IR.Result_Of (Of_Unit, Item);

         function Value_Cell (Value : Landin.IR.Value_Id) return String
           is (Cell (Value_Offset (Layout, Value)));

         function Slot_Cell (Slot : Landin.IR.Slot_Id) return String
           is (Cell (Slot_Offset (Layout, Slot)));

         function Size_Of_Value
           (Value : Landin.IR.Value_Id) return Held_Size
           is (Size_Of
                 (Landin.IR.Result_Of (Of_Unit, Item, Value), Facts));

         function Size_Of_Slot (Slot : Landin.IR.Slot_Id) return Held_Size
           is (Size_Of (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts));

         --  D49/D50/D53 ask three compact whole-array operations for the
         --  same target-derived shape and base address.  D57 reuses the base
         --  for the complete padded extent of aggregate storage.  Keep that
         --  replay in one place: a field is an IR identity, never an offset.
         function Array_Length_Of
           (Place : Landin.IR.Storage; Field : Natural)
            return Landin.IR.Element_Total;
         function Array_Element_Of
           (Place : Landin.IR.Storage; Field : Natural)
            return Landin.Types.Scalar_Name;
         procedure Storage_Address
           (Place : Landin.IR.Storage;
            Field : Natural;
            Register : String);
         function Whole_Clear_Extent
           (Place : Landin.IR.Storage; Field : Natural)
            return Landin.Targets.Byte_Count;

         function Array_Length_Of
           (Place : Landin.IR.Storage; Field : Natural)
            return Landin.IR.Element_Total is
           (case Place.Kind is
               when Landin.IR.Module_Datum =>
                 (if Field = 0
                  then Landin.IR.Array_Length (Of_Unit, Place.Datum)
                  else Landin.IR.Nth_Field_Shape
                    (Of_Unit, Place.Datum, Positive (Field)).Length),
               when Landin.IR.Frame_Slot =>
                 (if Field = 0
                  then Landin.IR.Slot_Array_Length
                    (Of_Unit, Item, Place.Slot)
                  else Landin.IR.Nth_Slot_Field_Shape
                    (Of_Unit, Item, Place.Slot, Positive (Field)).Length));

         function Array_Element_Of
           (Place : Landin.IR.Storage; Field : Natural)
            return Landin.Types.Scalar_Name is
           (case Place.Kind is
               when Landin.IR.Module_Datum =>
                 (if Field = 0
                  then Landin.IR.Array_Element (Of_Unit, Place.Datum)
                  else Landin.IR.Nth_Field_Shape
                    (Of_Unit, Place.Datum, Positive (Field)).Element),
               when Landin.IR.Frame_Slot =>
                 (if Field = 0
                  then Landin.IR.Slot_Array_Element
                    (Of_Unit, Item, Place.Slot)
                  else Landin.IR.Nth_Slot_Field_Shape
                    (Of_Unit, Item, Place.Slot, Positive (Field)).Element));

         procedure Storage_Address
           (Place : Landin.IR.Storage;
            Field : Natural;
            Register : String) is
         begin
            case Place.Kind is
               when Landin.IR.Module_Datum =>
                  Emit
                    ("leaq " & Symbol (Place.Datum) & "(%rip), " & Register);
                  if Field > 0 then
                     declare
                        At_Offset : constant Landin.Targets.Byte_Count :=
                          Field_Offset
                            (Place.Datum, Landin.IR.Part_Position (Field));
                     begin
                        if At_Offset > 0 then
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (At_Offset))
                              & ", %rdx");
                           Emit ("addq %rdx, " & Register);
                        end if;
                     end;
                  end if;
               when Landin.IR.Frame_Slot =>
                  Emit
                    ("leaq "
                     & Cell
                         ((if Field = 0
                           then Landin.Backend.Slot_Offset
                             (Layout, Place.Slot)
                           else Landin.Backend.Field_Offset
                             (Of_Unit, Item, Layout, Place.Slot,
                              Landin.IR.Part_Position (Field), Facts)))
                     & ", " & Register);
            end case;
         end Storage_Address;

         function Whole_Clear_Extent
           (Place : Landin.IR.Storage; Field : Natural)
            return Landin.Targets.Byte_Count
         is
            Whole_Aggregate : constant Boolean :=
              Field = 0
              and then
                (case Place.Kind is
                    when Landin.IR.Module_Datum =>
                      Landin.IR.Result_Of (Of_Unit, Place.Datum)
                        = Landin.Types.Aggregate,
                    when Landin.IR.Frame_Slot =>
                      Landin.IR.Is_Aggregate
                        (Of_Unit, Item, Place.Slot));
         begin
            if not Whole_Aggregate then
               return
                 Landin.Targets.Byte_Count
                   (Array_Length_Of (Place, Field))
                 * Landin.Targets.Byte_Count
                     (Landin.Targets.Bytes
                        (Size_Of (Array_Element_Of (Place, Field), Facts)));
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
            end case;
         end Whole_Clear_Extent;

         --  A Value_Id restarts in each item, just as a Block_Id does.  The
         --  extra `V` keeps a continuation distinct from a block label.
         function Value_Label (Value : Landin.IR.Value_Id) return String
           is (".L" & Trimmed (Landin.IR.Item_Id'Image (Item))
               & "_V" & Trimmed (Landin.IR.Value_Id'Image (Value)));

         --  A move through the accumulator, at one width.  Every value
         --  that crosses an instruction crosses it this way.
         procedure Carry (Size : Held_Size; From, To : String);

         procedure Carry (Size : Held_Size; From, To : String) is
         begin
            Emit ("mov" & Suffix (Size) & " " & From & ", "
                  & Accumulator (Size));
            Emit ("mov" & Suffix (Size) & " " & Accumulator (Size)
                  & ", " & To);
         end Carry;

         procedure Emit_Epilogue;

         procedure Emit_Epilogue is
         begin
            Emit ("movq %rbp, %rsp");
            Emit ("popq %rbp");
            Emit ("ret");
         end Emit_Epilogue;

         procedure Emit_Instruction (Value : Landin.IR.Value_Id);

         procedure Emit_Instruction (Value : Landin.IR.Value_Id) is
            Op : constant Landin.IR.Opcode :=
              Landin.IR.Op_Of (Of_Unit, Item, Value);

            function Operand (Index : Positive) return Landin.IR.Value_Id
              is (Landin.IR.Nth_Operand (Of_Unit, Item, Value, Index));
         begin
            case Op is
               when Landin.IR.Number =>
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Size : constant Landin.Types.Scalar_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Digits_Of : constant Landin.Types.Magnitude :=
                       Landin.IR.Number_Of (Of_Unit, Item, Value);
                     Highest : constant Landin.Types.Magnitude :=
                       (if Landin.Types.Width (Size, Facts) = 64
                        then Landin.Types.Magnitude'Last
                        else 2 ** Natural
                                    (Landin.Types.Width (Size, Facts))
                             - 1);
                     --  [1770]'s magnitude and [1880]'s minus are carried
                     --  apart, so the two's complement pattern is formed
                     --  here, where a width finally exists.  The checker
                     --  has already refused a literal the type cannot
                     --  hold, so no masking is needed above the negation.
                     Pattern : constant Landin.Types.Magnitude :=
                       (if not Landin.IR.Is_Negated (Of_Unit, Item, Value)
                          or else Digits_Of = 0
                        then Digits_Of
                        else Highest - Digits_Of + 1);
                  begin
                     Emit ("movabsq $"
                           & Trimmed
                               (Landin.Types.Magnitude'Image (Pattern))
                           & ", %rax");
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Measure_Size | Landin.IR.Measure_Align =>
                  --  [0370]: the answer is a target fact, and this is the
                  --  first place in the compiler that has one.
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Measurement_Extent
                       (Of_Unit, Item, Value, Facts, Size, Alignment);
                     declare
                        Answer : constant String :=
                          (if Op = Landin.IR.Measure_Size
                           then Landin.Targets.Byte_Count'Image (Size)
                           else Landin.Targets.Byte_Alignment'Image
                                  (Alignment));
                     begin
                        Emit
                          ("movabsq $" & Trimmed (Answer) & ", %rax");
                        Emit
                          ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                     end;
                  end;

               when Landin.IR.Truth =>
                  --  [1870]'s two literals, and the one byte
                  --  Landin.Backend gives a bool.
                  Emit ("movb $"
                        & (if Landin.IR.Truth_Of (Of_Unit, Item, Value)
                           then "1" else "0")
                        & ", " & Value_Cell (Value));

               when Landin.IR.Load =>
                  declare
                     Slot : constant Landin.IR.Slot_Id :=
                       Landin.IR.Slot_Of (Of_Unit, Item, Value);
                  begin
                     Carry (Size_Of_Slot (Slot), Slot_Cell (Slot),
                            Value_Cell (Value));
                  end;

               when Landin.IR.Store =>
                  declare
                     Slot : constant Landin.IR.Slot_Id :=
                       Landin.IR.Slot_Of (Of_Unit, Item, Value);
                  begin
                     Carry (Size_Of_Slot (Slot),
                            Value_Cell (Operand (1)), Slot_Cell (Slot));
                  end;

               when Landin.IR.Shift_Left | Landin.IR.Shift_Right =>
                  --  Two rules the hardware does not give.  [0320] fills with
                  --  zeros beyond the width for any amount, and x86-64 masks
                  --  the count to five or six bits instead, so the width test
                  --  is emitted here.  And [1950] leaves an amount the
                  --  compiler could not read to the trap; `L0306` has already
                  --  refused the negative ones it knew.  D6 gives the amount
                  --  the left operand's type, so both tests are at that width
                  --  rather than at the count's.
                  declare
                     Kind : constant Landin.Types.Integer_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Signed : constant Boolean :=
                       Landin.Types.Is_Signed (Kind);
                     Bits : constant Landin.Targets.Bit_Width :=
                       Landin.Types.Width (Kind, Facts);
                     Not_Negative : constant String :=
                       Value_Label (Value) & "_nonnegative";
                     In_Range : constant String :=
                       Value_Label (Value) & "_inrange";
                     Done : constant String :=
                       Value_Label (Value) & "_done";
                     Instruction : constant String :=
                       (if Op = Landin.IR.Shift_Left then "shl"
                        elsif Signed then "sar"
                        else "shr");
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (2)) & ", "
                           & Accumulator (Held));

                     if Signed then
                        Emit ("cmp" & Suffix (Held) & " $0, "
                              & Accumulator (Held));
                        Emit ("jge " & Not_Negative);
                        Emit ("ud2");
                        Put (Not_Negative & ":");
                     end if;

                     --  Every remaining amount is at or above zero, so the
                     --  width test is an unsigned one on both signednesses.
                     Emit ("cmp" & Suffix (Held) & " $"
                           & Trimmed
                               (Landin.Targets.Bit_Width'Image (Bits))
                           & ", " & Accumulator (Held));
                     Emit ("jb " & In_Range);
                     Emit ("mov" & Suffix (Held) & " $0, "
                           & Value_Cell (Value));
                     Emit ("jmp " & Done);
                     Put (In_Range & ":");

                     --  The count is below the width, so its low byte is the
                     --  whole of it and `%cl` is where a variable count goes.
                     Emit ("movb " & Value_Cell (Operand (2)) & ", %cl");
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit (Instruction & Suffix (Held) & " %cl, "
                           & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                     Put (Done & ":");
                  end;

               when Landin.IR.Bitwise_And
                  | Landin.IR.Bitwise_Xor
                  | Landin.IR.Bitwise_Or =>
                  --  [0330] gives each of these its own integer type back, so
                  --  every pattern they produce is one the type holds and
                  --  neither signedness nor a flag has anything to say.
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Instruction : constant String :=
                       (case Op is
                           when Landin.IR.Bitwise_And => "and",
                           when Landin.IR.Bitwise_Xor => "xor",
                           when Landin.IR.Bitwise_Or => "or",
                           when others => raise Program_Error);
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit (Instruction & Suffix (Held) & " "
                           & Value_Cell (Operand (2)) & ", "
                           & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Logical_Not =>
                  --  [1870] fixes a bool at zero or one, so the low bit is
                  --  the whole value and `not` over the byte would give 254
                  --  for `not false`.
                  Emit ("movb " & Value_Cell (Operand (1)) & ", %al");
                  Emit ("xorb $1, %al");
                  Emit ("movb %al, " & Value_Cell (Value));

               when Landin.IR.Negation =>
                  --  [1890] gives unary minus its own integer type back, so
                  --  the lowest signed value has no negation the type holds
                  --  and no unsigned value but zero has one at all.  `neg`
                  --  reports the first as overflow and the second as carry.
                  declare
                     Kind : constant Landin.Types.Integer_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Next : constant String := Value_Label (Value);
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ("neg" & Suffix (Held) & " " & Accumulator (Held));
                     Emit ((if Landin.Types.Is_Signed (Kind)
                            then "jno " else "jnc ") & Next);
                     Emit ("ud2");
                     Put (Next & ":");
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Complement =>
                  --  [0330]'s `~` gives its own type back, so every pattern
                  --  it can produce is one the type holds and no edge is
                  --  needed.
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ("not" & Suffix (Held) & " " & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Copy_Array =>
                  --  D20/D50 move bytes directly between storage places.
                  --  Each field is a declaration-order identity; its target
                  --  offset is derived here.  The instruction stays one
                  --  operation even when D18 makes the extent too large for
                  --  the compiler host to enumerate.
                  declare
                     Source : constant Landin.IR.Storage :=
                       Landin.IR.Source_Of (Of_Unit, Item, Value);
                     Source_Field : constant Natural :=
                       Landin.IR.Source_Field_Of (Of_Unit, Item, Value);
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Destination_Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);

                     Bytes : constant Landin.Targets.Byte_Count :=
                       Landin.Targets.Byte_Count
                         (Array_Length_Of (Source, Source_Field))
                       * Landin.Targets.Byte_Count
                           (Landin.Targets.Bytes
                              (Size_Of
                                 (Array_Element_Of (Source, Source_Field),
                                  Facts)));
                  begin
                     Storage_Address
                       (Destination, Destination_Field, "%rdi");
                     Storage_Address (Source, Source_Field, "%rsi");
                     Emit
                       ("movabsq $"
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Bytes))
                        & ", %rcx");
                     Emit ("cld");
                     Emit ("rep movsb");
                  end;

               when Landin.IR.Clear_Array =>
                  --  D28 clears complete array storage without making IR or
                  --  compiler work proportional to D18's extent.  D49 carries
                  --  a declaration-order array-field identity.  D57 gives
                  --  field zero of aggregate storage its complete padded
                  --  extent, so [0540]'s all-bit image includes padding.
                  declare
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Bytes : constant Landin.Targets.Byte_Count :=
                       Whole_Clear_Extent (Destination, Field);
                  begin
                     Storage_Address (Destination, Field, "%rdi");
                     Emit ("xorl %eax, %eax");
                     Emit
                       ("movabsq $"
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Bytes))
                        & ", %rcx");
                     Emit ("cld");
                     Emit ("rep stosb");
                  end;

               when Landin.IR.Fill_Array =>
                  --  D32 evaluates one scalar and repeats its target-width
                  --  pattern through the destination.  D53 may name an array
                  --  field; the element count, width and both containing and
                  --  suffix offsets stay compact and target-derived.
                  declare
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Length : constant Landin.IR.Element_Total :=
                       Array_Length_Of (Destination, Field);
                     Element : constant Landin.Types.Scalar_Name :=
                       Array_Element_Of (Destination, Field);
                     Held : constant Held_Size := Size_Of (Element, Facts);
                     First : constant Landin.IR.Part_Position :=
                       Landin.IR.First_Part_Of (Of_Unit, Item, Value);
                     Count : constant Landin.IR.Element_Total :=
                       Length - (Landin.IR.Element_Total (First) - 1);
                     Offset : constant Landin.Targets.Byte_Count :=
                       Landin.Targets.Byte_Count
                         (Landin.IR.Element_Total (First) - 1)
                       * Landin.Targets.Byte_Count
                           (Landin.Targets.Bytes (Held));
                  begin
                     Storage_Address (Destination, Field, "%rdi");
                     if Offset /= 0 then
                        Emit
                          ("addq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (Offset))
                           & ", %rdi");
                     end if;
                     Emit
                       ("mov" & Suffix (Held) & " "
                        & Value_Cell (Operand (1)) & ", "
                        & Accumulator (Held));
                     Emit
                       ("movabsq $"
                        & Trimmed (Landin.IR.Element_Total'Image (Count))
                        & ", %rcx");
                     Emit ("cld");
                     Emit ("rep stos" & Suffix (Held));
                  end;

               when Landin.IR.Load_Datum | Landin.IR.Store_Datum =>
                  --  A module value is named rather than offset from a
                  --  frame, and RIP-relative is how x86-64 names one
                  --  without a relocation the loader has to fix up.
                  declare
                     Datum : constant Landin.IR.Item_Id :=
                       Landin.IR.Datum_Of (Of_Unit, Item, Value);
                     Kind : constant Landin.Types.Scalar_Name :=
                       Landin.IR.Result_Of (Of_Unit, Datum);
                     Held : constant Held_Size := Size_Of (Kind, Facts);
                     Place : constant String :=
                       Symbol (Datum) & "(%rip)";
                  begin
                     if Op = Landin.IR.Load_Datum then
                        Carry (Held, Place, Value_Cell (Value));
                     else
                        Carry (Held, Value_Cell (Operand (1)), Place);
                     end if;
                  end;

               when Landin.IR.Load_Element | Landin.IR.Store_Element =>
                  --  [0580] requires the bounds check before any address
                  --  computation.  Keep the index in %rax through the
                  --  unsigned comparison, trap on index >= length, and only
                  --  then scale it and add it to the array's base address.
                  --  D22 lets the base be a module datum's symbol or a
                  --  frame slot's %rbp-relative address; D48 may move that
                  --  base to an aggregate field.  The trap and scaling are
                  --  the same.
                  declare
                     Reaches_Slot : constant Boolean :=
                       Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value);
                     Index : constant Landin.IR.Value_Id :=
                       Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Length : constant Landin.IR.Element_Total :=
                       (if Reaches_Slot
                        then Landin.IR.Slot_Element_Length
                               (Of_Unit, Item, Value)
                        elsif Field > 0
                        then Landin.IR.Nth_Field_Shape
                               (Of_Unit,
                                Landin.IR.Datum_Of (Of_Unit, Item, Value),
                                Positive (Field)).Length
                        else Landin.IR.Array_Length
                               (Of_Unit,
                                Landin.IR.Datum_Of (Of_Unit, Item, Value)));
                     Kind : constant Landin.Types.Scalar_Name :=
                       (if Reaches_Slot
                        then Landin.IR.Slot_Element_Type
                               (Of_Unit, Item, Value)
                        elsif Field > 0
                        then Landin.IR.Nth_Field_Shape
                               (Of_Unit,
                                Landin.IR.Datum_Of (Of_Unit, Item, Value),
                                Positive (Field)).Element
                        else Landin.IR.Array_Element
                               (Of_Unit,
                                Landin.IR.Datum_Of (Of_Unit, Item, Value)));
                     Held : constant Held_Size := Size_Of (Kind, Facts);
                     Safe : constant String := Value_Label (Value) & "_index";
                  begin
                     Emit ("movq " & Value_Cell (Index) & ", %rax");
                     Emit
                       ("movabsq $"
                        & Trimmed (Landin.IR.Element_Total'Image (Length))
                        & ", %rdx");
                     Emit ("cmpq %rdx, %rax");
                     Emit ("jb " & Safe);
                     Emit ("ud2");
                     Put (Safe & ":");
                     Emit
                       ("imulq $"
                        & Trimmed
                            (Natural'Image (Landin.Targets.Bytes (Held)))
                        & ", %rax, %rax");

                     if Reaches_Slot then
                        --  An array slot's recorded displacement is its
                        --  element-zero base directly.  Use it rather than
                        --  asking Field_Offset for field 1: a zero-length
                        --  array has no such field, but every computed index
                        --  must still compile to the bounds trap above.
                        Emit
                          ("leaq "
                           & Cell
                               ((if Field = 0
                                 then Landin.Backend.Slot_Offset
                                        (Layout,
                                         Landin.IR.Slot_Of
                                           (Of_Unit, Item, Value))
                                 else Landin.Backend.Field_Offset
                                        (Of_Unit, Item, Layout,
                                         Landin.IR.Slot_Of
                                           (Of_Unit, Item, Value),
                                         Landin.IR.Part_Position (Field),
                                         Facts)))
                           & ", %rcx");
                        Emit ("addq %rax, %rcx");
                     else
                        Emit ("leaq "
                              & Symbol
                                  (Landin.IR.Datum_Of (Of_Unit, Item, Value))
                              & "(%rip), %rcx");
                        if Field > 0 then
                           declare
                              At_Offset : constant Landin.Targets.Byte_Count :=
                                Field_Offset
                                  (Landin.IR.Datum_Of
                                     (Of_Unit, Item, Value),
                                   Landin.IR.Part_Position (Field));
                           begin
                              if At_Offset > 0 then
                                 Emit
                                   ("movabsq $"
                                    & Trimmed
                                        (Landin.Targets.Byte_Count'Image
                                           (At_Offset))
                                    & ", %rdx");
                                 Emit ("addq %rdx, %rcx");
                              end if;
                           end;
                        end if;
                        Emit ("addq %rax, %rcx");
                     end if;

                     if Op = Landin.IR.Load_Element then
                        Carry (Held, "(%rcx)", Value_Cell (Value));
                     else
                        Carry
                          (Held, Value_Cell (Operand (2)), "(%rcx)");
                     end if;
                  end;

               when Landin.IR.Load_Field | Landin.IR.Store_Field =>
                  if Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value) then
                     --  [1810]'s local: a cell in this frame, reached the
                     --  way every other cell is and at the field's own
                     --  displacement inside it.
                     declare
                        Slot : constant Landin.IR.Slot_Id :=
                          Landin.IR.Slot_Of (Of_Unit, Item, Value);
                        Which : constant Landin.IR.Part_Position :=
                          Landin.IR.Field_Of (Of_Unit, Item, Value);
                        Held : constant Held_Size :=
                          Size_Of
                            (Landin.IR.Nth_Slot_Part
                               (Of_Unit, Item, Slot, Which), Facts);
                        Place : constant String :=
                          Cell (Field_Offset
                                  (Of_Unit, Item, Layout, Slot, Which,
                                   Facts));
                     begin
                        if Op = Landin.IR.Load_Field then
                           Carry (Held, Place, Value_Cell (Value));
                        else
                           Carry (Held, Value_Cell (Operand (1)), Place);
                        end if;
                     end;

                     return;
                  end if;

                  --  [0750] puts the field where the same placement the
                  --  checker used puts it.  A small offset is a displacement
                  --  from the datum's symbol; D18 can make an array offset
                  --  wider than that instruction field, so a large one is
                  --  added to the symbol address in registers.
                  declare
                     Datum : constant Landin.IR.Item_Id :=
                       Landin.IR.Datum_Of (Of_Unit, Item, Value);
                     Which : constant Landin.IR.Part_Position :=
                       Landin.IR.Field_Of (Of_Unit, Item, Value);
                     At_Offset : constant Landin.Targets.Byte_Count :=
                       Field_Offset (Datum, Which);
                     Held : constant Held_Size :=
                       (if Op = Landin.IR.Load_Field
                        then Size_Of_Value (Value)
                        else Size_Of
                               (Landin.IR.Nth_Part
                                  (Of_Unit, Datum, Which), Facts));
                  begin
                     --  A RIP-relative memory operand has a signed 32-bit
                     --  displacement, and its relocation is symbol plus
                     --  offset minus instruction: the offset alone cannot
                     --  prove that it fits.  D18 lets an array span the full
                     --  target range, so form every nonzero element address
                     --  in registers rather than leave that placement
                     --  question to an unencodable relocation.
                     if (Landin.IR.Result_Of (Of_Unit, Datum)
                           = Landin.Types.Fixed_Array
                         or else Has_Array_Field (Datum))
                       and then At_Offset > 0
                     then
                        Emit ("leaq " & Symbol (Datum) & "(%rip), %rcx");
                        Emit
                          ("movabsq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (At_Offset))
                           & ", %rdx");
                        Emit ("addq %rdx, %rcx");

                        if Op = Landin.IR.Load_Field then
                           Carry (Held, "(%rcx)", Value_Cell (Value));
                        else
                           Carry
                             (Held, Value_Cell (Operand (1)), "(%rcx)");
                        end if;
                     else
                        declare
                           Place : constant String :=
                             Symbol (Datum)
                             & (if At_Offset = 0 then ""
                                else "+"
                                     & Trimmed
                                         (Landin.Targets.Byte_Count'Image
                                            (At_Offset)))
                             & "(%rip)";
                        begin
                           if Op = Landin.IR.Load_Field then
                              Carry (Held, Place, Value_Cell (Value));
                           else
                              Carry
                                (Held, Value_Cell (Operand (1)), Place);
                           end if;
                        end;
                     end if;
                  end;

               when Landin.IR.Add | Landin.IR.Subtract =>
                  declare
                     Kind : constant Landin.Types.Integer_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Next : constant String := Value_Label (Value);
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ((if Op = Landin.IR.Add then "add" else "sub")
                           & Suffix (Held) & " "
                           & Value_Cell (Operand (2)) & ", "
                           & Accumulator (Held));
                     Emit ((if Landin.Types.Is_Signed (Kind)
                            then "jno " else "jnc ") & Next);
                     Emit ("ud2");
                     Put (Next & ":");
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Wrapping_Add
                  | Landin.IR.Wrapping_Subtract =>
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ((if Op = Landin.IR.Wrapping_Add
                            then "add" else "sub") & Suffix (Held) & " "
                           & Value_Cell (Operand (2)) & ", "
                           & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Divide | Landin.IR.Remainder =>
                  declare
                     Kind : constant Landin.Types.Integer_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Nonzero : constant String :=
                       Value_Label (Value) & "_nonzero";
                     Divide : constant String :=
                       Value_Label (Value) & "_divide";
                     Done : constant String :=
                       Value_Label (Value) & "_done";
                     Signed : constant Boolean :=
                       Landin.Types.Is_Signed (Kind);
                     Minimum_Pattern : constant Landin.Types.Magnitude :=
                       2 ** Natural (Landin.Types.Width (Kind, Facts) - 1);
                  begin
                     Emit ("cmp" & Suffix (Held) & " $0, "
                           & Value_Cell (Operand (2)));
                     Emit ("jne " & Nonzero);
                     Emit ("ud2");
                     Put (Nonzero & ":");

                     if Signed then
                        Emit ("cmp" & Suffix (Held) & " $-1, "
                              & Value_Cell (Operand (2)));
                        Emit ("jne " & Divide);
                        Emit ("movabsq $"
                              & Trimmed
                                  (Landin.Types.Magnitude'Image
                                     (Minimum_Pattern))
                              & ", %rax");
                        Emit ("cmp" & Suffix (Held) & " "
                              & Value_Cell (Operand (1)) & ", "
                              & Accumulator (Held));
                        Emit ("jne " & Divide);
                        if Op = Landin.IR.Divide then
                           Emit ("ud2");
                        else
                           Emit ("mov" & Suffix (Held) & " $0, "
                                 & Value_Cell (Value));
                           Emit ("jmp " & Done);
                        end if;
                        Put (Divide & ":");
                     end if;

                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     if Signed then
                        Emit
                          (case Held is
                              when Landin.Targets.Byte_1 => "cbtw",
                              when Landin.Targets.Byte_2 => "cwtd",
                              when Landin.Targets.Byte_4 => "cltd",
                              when Landin.Targets.Byte_8 => "cqto");
                     else
                        case Held is
                           when Landin.Targets.Byte_1 =>
                              Emit ("movb $0, %ah");
                           when Landin.Targets.Byte_2 =>
                              Emit ("xorw %dx, %dx");
                           when Landin.Targets.Byte_4 =>
                              Emit ("xorl %edx, %edx");
                           when Landin.Targets.Byte_8 =>
                              Emit ("xorq %rdx, %rdx");
                        end case;
                     end if;
                     Emit ((if Signed then "idiv" else "div")
                           & Suffix (Held) & " "
                           & Value_Cell (Operand (2)));
                     Emit ("mov" & Suffix (Held) & " "
                           & (if Op = Landin.IR.Divide
                              then Accumulator (Held)
                              else
                                (case Held is
                                    when Landin.Targets.Byte_1 => "%ah",
                                    when Landin.Targets.Byte_2 => "%dx",
                                    when Landin.Targets.Byte_4 => "%edx",
                                    when Landin.Targets.Byte_8 => "%rdx"))
                           & ", " & Value_Cell (Value));
                     if Op = Landin.IR.Remainder then
                        Put (Done & ":");
                     end if;
                  end;

               when Landin.IR.Multiply =>
                  declare
                     Kind : constant Landin.Types.Integer_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Next : constant String := Value_Label (Value);
                     Signed : constant Boolean :=
                       Landin.Types.Is_Signed (Kind);
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ((if Signed then "imul" else "mul")
                           & Suffix (Held) & " "
                           & Value_Cell (Operand (2)));
                     Emit ((if Signed then "jno " else "jnc ") & Next);
                     Emit ("ud2");
                     Put (Next & ":");
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Wrapping_Multiply =>
                  declare
                     Kind : constant Landin.Types.Integer_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ((if Landin.Types.Is_Signed (Kind)
                            then "imul" else "mul")
                           & Suffix (Held) & " "
                           & Value_Cell (Operand (2)));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Equal_To
                  | Landin.IR.Not_Equal_To
                  | Landin.IR.Less_Than
                  | Landin.IR.Less_Or_Equal
                  | Landin.IR.Greater_Than
                  | Landin.IR.Greater_Or_Equal =>
                  declare
                     Kind : constant Landin.Types.Scalar_Name :=
                       Landin.IR.Result_Of
                         (Of_Unit, Item, Operand (1));
                     Held : constant Held_Size := Size_Of (Kind, Facts);
                     Signed : constant Boolean :=
                       Kind in Landin.Types.Integer_Name
                       and then Landin.Types.Is_Signed
                                  (Landin.Types.Integer_Name (Kind));
                     Condition : constant String :=
                       (case Op is
                           when Landin.IR.Equal_To => "sete",
                           when Landin.IR.Not_Equal_To => "setne",
                           when Landin.IR.Less_Than =>
                             (if Signed then "setl" else "setb"),
                           when Landin.IR.Less_Or_Equal =>
                             (if Signed then "setle" else "setbe"),
                           when Landin.IR.Greater_Than =>
                             (if Signed then "setg" else "seta"),
                           when Landin.IR.Greater_Or_Equal =>
                             (if Signed then "setge" else "setae"),
                           when others => raise Program_Error);
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ("cmp" & Suffix (Held) & " "
                           & Value_Cell (Operand (2)) & ", "
                           & Accumulator (Held));
                     Emit (Condition & " %al");
                     Emit ("movb %al, " & Value_Cell (Value));
                  end;

               when Landin.IR.Call =>
                  --  [1920] names every parameter once and in order, so the
                  --  operands are already the argument list and [1650]'s
                  --  registers are filled from them in that order.  The frame
                  --  is a multiple of the target's stack alignment, so `%rsp`
                  --  still meets the ABI at the call.  A `-> none` callee
                  --  defines nothing, and [1930] says there is no result
                  --  there to store.
                  declare
                     Callee : constant Landin.IR.Item_Id :=
                       Landin.IR.Callee_Of (Of_Unit, Item, Value);
                     Gives : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                  begin
                     for Index in 1 .. Landin.IR.Operand_Count
                                         (Of_Unit, Item, Value)
                     loop
                        declare
                           Argument : constant Landin.IR.Value_Id :=
                             Operand (Index);
                           Held : constant Held_Size :=
                             Size_Of_Value (Argument);
                        begin
                           Emit ("mov" & Suffix (Held) & " "
                                 & Value_Cell (Argument) & ", "
                                 & Argument_Register (Index, Held));
                        end;
                     end loop;

                     Emit ("call " & Symbol (Callee));

                     if Gives in Landin.Types.Scalar_Name then
                        declare
                           Held : constant Held_Size :=
                             Size_Of (Gives, Facts);
                        begin
                           Emit ("mov" & Suffix (Held) & " "
                                 & Accumulator (Held) & ", "
                                 & Value_Cell (Value));
                        end;
                     end if;
                  end;

               when Landin.IR.Jump =>
                  Emit ("jmp "
                        & Label (Item,
                                 Landin.IR.Target_Of
                                   (Of_Unit, Item, Value)));

               when Landin.IR.Branch =>
                  --  A bool is a byte, and zero is [1870]'s `false`.
                  Emit ("cmpb $0, " & Value_Cell (Operand (1)));
                  Emit ("jne "
                        & Label (Item,
                                 Landin.IR.Target_Of
                                   (Of_Unit, Item, Value)));
                  Emit ("jmp "
                        & Label (Item,
                                 Landin.IR.Alternative_Of
                                   (Of_Unit, Item, Value)));

               when Landin.IR.Leave =>
                  --  [1810]'s return carries what the named return place
                  --  held; a `-> none` routine carries nothing.
                  if Result in Landin.Types.Scalar_Name then
                     declare
                        Held : constant Held_Size :=
                          Size_Of (Result, Facts);
                     begin
                        Emit ("mov" & Suffix (Held) & " "
                              & Value_Cell (Operand (1)) & ", "
                              & Accumulator (Held));
                     end;
                  end if;

                  Emit_Epilogue;
            end case;
         end Emit_Instruction;

      begin
         if Landin.Resolution.Is_Public
              (Meanings, Landin.IR.Declares (Of_Unit, Item))
         then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".type " & Symbol (Item)
              & ", @function");
         Put (Symbol (Item) & ":");

         --  [1550]'s frame pointer, set up before anything reads a cell.
         Emit ("pushq %rbp");
         Emit ("movq %rsp, %rbp");

         if Extent (Layout) > 0 then
            Emit ("subq $"
                  & Trimmed
                      (Landin.Targets.Byte_Count'Image (Extent (Layout)))
                  & ", %rsp");
         end if;

         --  A parameter is a slot the caller filled, so the prologue is
         --  where the ABI's registers become cells like any other.
         for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
            declare
               Slot : constant Landin.IR.Slot_Id :=
                 Landin.IR.Nth_Parameter (Of_Unit, Item, Index);
               Held : constant Held_Size := Size_Of_Slot (Slot);
            begin
               Emit ("mov" & Suffix (Held) & " "
                     & Argument_Register (Index, Held) & ", "
                     & Slot_Cell (Slot));
            end;
         end loop;

         for Index in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            declare
               Block : constant Landin.IR.Block_Id :=
                 Landin.IR.Block_Id (Index);
            begin
               Put (Label (Item, Block) & ":");

               for Position in 1 .. Landin.IR.Length
                                      (Of_Unit, Item, Block)
               loop
                  Emit_Instruction
                    (Landin.IR.Nth_Value
                       (Of_Unit, Item, Block, Position));
               end loop;
            end;
         end loop;

         Put (Character'Val (9) & ".size " & Symbol (Item) & ", .-"
              & Symbol (Item));
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
         Held : array (1 .. Landin.IR.Value_Count (Of_Unit, Item))
                  of Landin.Types.Folded := [others => 0];
         Slots : array (1 .. Landin.IR.Slot_Count (Of_Unit, Item))
                   of Landin.Types.Folded := [others => 0];

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

                     when Landin.IR.Negation =>
                        Held (Natural (Value)) :=
                          -Of_Value (Operand_Of (Value, 1));

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
                        end;

                     when Landin.IR.Leave =>
                        Answer := Of_Value (Operand_Of (Value, 1));

                     when Landin.IR.Call | Landin.IR.Store_Datum
                        | Landin.IR.Load_Field | Landin.IR.Store_Field
                        | Landin.IR.Load_Element | Landin.IR.Store_Element
                        | Landin.IR.Copy_Array | Landin.IR.Clear_Array
                        | Landin.IR.Fill_Array
                        | Landin.IR.Jump | Landin.IR.Branch =>
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
               when Landin.Targets.Byte_2 => ".word",
               when Landin.Targets.Byte_4 => ".long",
               when Landin.Targets.Byte_8 => ".quad");

      procedure Emit_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Aggregate_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Aggregate_Image_Datum (Item : Landin.IR.Item_Id);

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

      --  D66 keeps the written aggregate image target-neutral: one fold per
      --  declaration-order field.  Replay the shared placement here to insert
      --  this target's padding, write scalar fields at their target widths,
      --  reserve zero array fields at their compact extents, and keep every
      --  padding byte zero as [0540] requires.
      procedure Emit_Aggregate_Image_Datum (Item : Landin.IR.Item_Id) is
         Placed  : Landin.Targets.Placement;
         Ignored : Landin.Targets.Byte_Count;
         Written : Landin.Targets.Byte_Count := 0;
      begin
         Place_Fields (Item, Placed, 0, Ignored);

         if Landin.Resolution.Is_Public
              (Meanings, Landin.IR.Declares (Of_Unit, Item))
         then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".type " & Symbol (Item) & ", @object");
         Put (Character'Val (9) & ".align "
              & Trimmed
                  (Landin.Targets.Byte_Alignment'Image
                     (Landin.Targets.Alignment_Of (Placed))));
         Put (Symbol (Item) & ":");

         for Field in 1 .. Landin.IR.Field_Count (Of_Unit, Item) loop
            declare
               Shape : constant Landin.IR.Field_Shape :=
                 Landin.IR.Nth_Field_Shape (Of_Unit, Item, Field);
               Image : constant Landin.IR.Aggregate_Field_Image :=
                 Landin.IR.Field_Image_Of (Of_Unit, Item, Field);
               Field_Size : Landin.Targets.Byte_Count;
               Field_Alignment : Landin.Targets.Byte_Alignment;
               At_Field : Landin.Targets.Byte_Count;
               Field_Placement : Landin.Targets.Placement;
            begin
               Place_Fields
                 (Item, Field_Placement, Landin.IR.Element_Total (Field),
                  At_Field);
               Landin.Backend.Field_Extent
                 (Shape, Facts, Field_Size, Field_Alignment);
               pragma Unreferenced (Field_Placement, Field_Alignment);

               if At_Field > Written then
                  Emit
                    (".zero "
                     & Trimmed
                         (Landin.Targets.Byte_Count'Image
                            (At_Field - Written)));
               end if;

               if Shape.Kind = Landin.IR.Scalar_Field_Shape then
                  Emit
                    (Directive (Size_Of (Shape.Element, Facts)) & " "
                     & Trimmed
                         (Landin.Types.Folded'Image
                            (Landin.IR.Nth_Field_Image
                               (Of_Unit, Item, Field))));
               elsif Image.Form = Landin.IR.Finite then
                  for Position in 1 .. Image.Count loop
                     Emit
                       (Directive (Size_Of (Shape.Element, Facts)) & " "
                        & Trimmed
                            (Landin.Types.Folded'Image
                               (Landin.IR.Nth_Field_Element
                                  (Of_Unit, Item, Field,
                                   Landin.IR.Part_Position (Position)))));
                  end loop;
               elsif Image.Form = Landin.IR.Absent then
                  if Field_Size > 0 then
                     Emit
                       (".zero "
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Field_Size)));
                  end if;
               else
                  raise Landin.Compiler_Defect with
                    "an aggregate array-field image form reached x86-64"
                    & " before its backend rule";
               end if;

               Written := At_Field + Field_Size;
            end;
         end loop;

         if Landin.Targets.Size_Of (Placed) > Written then
            Emit
              (".zero "
               & Trimmed
                   (Landin.Targets.Byte_Count'Image
                      (Landin.Targets.Size_Of (Placed) - Written)));
         end if;

         Put (Character'Val (9) & ".size " & Symbol (Item) & ", "
              & Trimmed
                  (Landin.Targets.Byte_Count'Image
                     (Landin.Targets.Size_Of (Placed))));
      end Emit_Aggregate_Image_Datum;

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
         Alignment : Landin.Targets.Byte_Alignment)
      is
         Bytes : constant String :=
           Trimmed (Landin.Targets.Byte_Count'Image (Size));
      begin
         if Landin.Resolution.Is_Public
              (Meanings, Landin.IR.Declares (Of_Unit, Item))
         then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".type " & Symbol (Item) & ", @object");
         Put (Character'Val (9) & ".align "
              & Trimmed (Landin.Targets.Byte_Alignment'Image (Alignment)));
         Put (Symbol (Item) & ":");
         Emit (".zero " & Bytes);
         Put (Character'Val (9) & ".size " & Symbol (Item) & ", " & Bytes);
      end Emit_Reserved;

      --  [0520]'s array: the element repeated, so its extent is one
      --  multiplication and its alignment is the element's own.  A length
      --  of zero takes no room and aligns to a byte, having no element to
      --  be aligned as.
      procedure Emit_Array_Datum (Item : Landin.IR.Item_Id) is
         Length : constant Landin.IR.Element_Total :=
           Landin.IR.Array_Length (Of_Unit, Item);
         Held : constant Held_Size :=
           Size_Of (Landin.IR.Array_Element (Of_Unit, Item), Facts);
      begin
         Emit_Reserved
           (Item,
            Landin.Targets.Byte_Count (Length)
            * Landin.Targets.Byte_Count (Landin.Targets.Bytes (Held)),
            (if Length = 0 then 1
             else Landin.Targets.Alignment_Of (Facts, Held)));
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
         Length : constant Landin.IR.Element_Total :=
           Landin.IR.Array_Length (Of_Unit, Item);
         Element : constant Landin.Types.Scalar_Name :=
           Landin.IR.Array_Element (Of_Unit, Item);
         Held : constant Held_Size := Size_Of (Element, Facts);
         Bytes : constant String :=
           Trimmed
             (Landin.Targets.Byte_Count'Image
                (Landin.Targets.Byte_Count (Length)
                 * Landin.Targets.Byte_Count (Landin.Targets.Bytes (Held))));
      begin
         if Landin.Resolution.Is_Public
              (Meanings, Landin.IR.Declares (Of_Unit, Item))
         then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".type " & Symbol (Item) & ", @object");
         Put (Character'Val (9) & ".align "
              & Trimmed
                  (Landin.Targets.Byte_Alignment'Image
                     (Landin.Targets.Alignment_Of (Facts, Held))));
         Put (Symbol (Item) & ":");

         if Landin.IR.Is_Repeated_Image (Of_Unit, Item) then
            --  D34 uses `.rept` around one width-specific scalar directive.
            --  D38 writes its finite prefix first, then repeats one suffix
            --  value for N - k positions.  Assembly size therefore depends on
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

         Put (Character'Val (9) & ".size " & Symbol (Item) & ", " & Bytes);
      end Emit_Array_Image_Datum;

      procedure Emit_Datum (Item : Landin.IR.Item_Id) is
         Kind : constant Landin.Types.Scalar_Name :=
           Landin.IR.Result_Of (Of_Unit, Item);
         Held : constant Held_Size := Size_Of (Kind, Facts);
         --  A negative value is written as one rather than as the pattern
         --  it becomes, because the assembler is the thing that knows how
         --  wide the store is and both spellings assemble the same bytes.
         --  The checker has already refused a fold this type cannot hold.
         Written : constant String :=
           Trimmed (Landin.Types.Folded'Image (Folded (Item)));
         Bytes : constant String :=
           Trimmed (Positive'Image (Landin.Targets.Bytes (Held)));
      begin
         if Landin.Resolution.Is_Public
              (Meanings, Landin.IR.Declares (Of_Unit, Item))
         then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".type " & Symbol (Item) & ", @object");
         Put (Character'Val (9) & ".align "
              & Trimmed
                  (Landin.Targets.Byte_Alignment'Image
                     (Landin.Targets.Alignment_Of (Facts, Held))));
         Put (Symbol (Item) & ":");
         Emit (Directive (Held) & " " & Written);
         Put (Character'Val (9) & ".size " & Symbol (Item) & ", " & Bytes);
      end Emit_Datum;

      Any_Written  : Boolean := False;
      Any_Reserved : Boolean := False;

   begin
      Put (Character'Val (9) & ".text");

      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine then
               Emit_Routine (Item);
            elsif Is_All_Zero (Item) then
               Any_Reserved := True;
            else
               Any_Written := True;
            end if;
         end;
      end loop;

      --  Data follows every routine rather than interrupting them, and each
      --  section is one run, so each directive is written once however many
      --  objects it holds.  Written first and reserved second, in the order
      --  the declarations were made inside each.
      if Any_Written then
         Put (Character'Val (9) & ".data");

         for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Index);
            begin
               if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum
                 and then not Is_All_Zero (Item)
               then
                  if Landin.IR.Result_Of (Of_Unit, Item)
                     = Landin.Types.Aggregate
                  then
                     Emit_Aggregate_Image_Datum (Item);
                  elsif Landin.IR.Result_Of (Of_Unit, Item)
                        = Landin.Types.Fixed_Array
                  then
                     Emit_Array_Image_Datum (Item);
                  else
                     Emit_Datum (Item);
                  end if;
               end if;
            end;
         end loop;
      end if;

      if Any_Reserved then
         Put (Character'Val (9) & ".bss");

         for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Index);
            begin
               if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum
                 and then Is_All_Zero (Item)
               then
                  if Landin.IR.Result_Of (Of_Unit, Item)
                     = Landin.Types.Aggregate
                  then
                     Emit_Aggregate_Datum (Item);
                  elsif Landin.IR.Result_Of (Of_Unit, Item)
                        = Landin.Types.Fixed_Array
                  then
                     Emit_Array_Datum (Item);
                  else
                     Emit_Reserved
                       (Item,
                        Landin.Targets.Byte_Count
                          (Landin.Targets.Bytes
                             (Size_Of
                                (Landin.IR.Result_Of (Of_Unit, Item),
                                 Facts))),
                        Landin.Targets.Alignment_Of
                          (Facts,
                           Size_Of
                             (Landin.IR.Result_Of (Of_Unit, Item),
                              Facts)));
                  end if;
               end if;
            end;
         end loop;
      end if;

      --  An executable stack is inherited when nothing says otherwise,
      --  and nothing this compiler emits needs one.
      Put (Character'Val (9)
           & ".section .note.GNU-stack,"""",@progbits");
      return Unbounded.To_String (Out_Text);
   end Text;

end Landin.Backend.X86_64;
