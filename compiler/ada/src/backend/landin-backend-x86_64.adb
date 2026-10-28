with Ada.Containers.Hashed_Maps;
with Ada.Containers.Vectors;
with Ada.Finalization;
with Ada.Unchecked_Deallocation;
with Landin.Layouts;
with Landin.Machine;
with Landin.IR.Control_Flow;
with Landin.IR.Liveness;
with Landin.IR.Shape_Measurement;
with Landin.Memory;
with Landin.Provenance;
with Landin.Packed;
with Landin.Targets.Packed;
with Ada.Strings.Fixed;

with Landin.Targets.Capabilities;

with Landin.Backend.C_ABI;
with Landin.Backend.ELF;
with Landin.Backend.Entry_Point;
with Landin.Backend.Reciprocals;
with Landin.Backend.Trap_Reports;
with Landin.Backend.Work_Arrays;
with Landin.Backend.X86_64.Allocation;
with Landin.Backend.X86_64.Dwarf;
with Landin.Backend.X86_64.Machine;
with Landin.Targets.Layouts;
with Landin.Types;

package body Landin.Backend.X86_64 is

   use type Landin.Targets.Target_Facts;
   use type Landin.Machine.Convention;
   use type Landin.Targets.Capabilities.Backend_Kind;
   use type Landin.Targets.Capabilities.Hosted_System;
   use type Landin.Layouts.Policy;

   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Optimization.Objective;
   use type Allocation.Location_Kind;
   use type Dwarf.Plan_Access;
   use type Dwarf.Frame_Access;
   use type Landin.Backend.C_ABI.Eightbyte_Class;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Scalar_Size;
   use type Landin.IR.Atom_Set_Id;
   use type Landin.IR.Block_Id;
   use type Landin.IR.Declaration_Id;
   use type Landin.IR.Item_Kind;
   use type Landin.IR.Item_Id;
   use type Landin.IR.Nominal_Type_Id;
   use type Landin.IR.Opcode;
   use type Landin.IR.Parameter_Convention;
   use type Landin.IR.Signature_Id;
   use type Landin.IR.Slot_Id;
   use type Landin.IR.Value_Id;
   use type Landin.Panics.Kind;
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
   --  module value is folded rather than run [1940].  Checking already
   --  folded with target facts to validate it; this backend folds the
   --  verified scalar datum instructions to make the stored image.
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

   --  The condition code that holds when Condition does not.
   function Inverse_Condition (Condition : String) return String
     is (if Condition = "e" then "ne"
         elsif Condition = "ne" then "e"
         elsif Condition = "l" then "ge"
         elsif Condition = "le" then "g"
         elsif Condition = "g" then "le"
         elsif Condition = "ge" then "l"
         elsif Condition = "b" then "ae"
         elsif Condition = "be" then "a"
         elsif Condition = "a" then "be"
         elsif Condition = "ae" then "b"
         else raise Landin.Compiler_Defect with "unknown branch condition");

   --  A general register's 32-bit name, or "" for anything else: memory,
   --  an immediate, an XMM register or `%ah`, which has none.
   function Doubleword (Register : String) return String
     is (if Register'Length >= 4
           and then Register (Register'First .. Register'First + 1) = "%r"
           and then Register (Register'First + 2) in '0' .. '9'
         then (if Register (Register'Last) in 'b' | 'w' | 'd'
               then Register (Register'First .. Register'Last - 1) & "d"
               else Register & "d")
         elsif Register in "%al" | "%ax" | "%eax" | "%rax" then "%eax"
         elsif Register in "%bl" | "%bx" | "%ebx" | "%rbx" then "%ebx"
         elsif Register in "%cl" | "%cx" | "%ecx" | "%rcx" then "%ecx"
         elsif Register in "%dl" | "%dx" | "%edx" | "%rdx" then "%edx"
         elsif Register in "%sil" | "%si" | "%esi" | "%rsi" then "%esi"
         elsif Register in "%dil" | "%di" | "%edi" | "%rdi" then "%edi"
         else "");

   --  The internal scalar convention uses the System V integer registers
   --  in their ordinary order, then one eight-byte stack slot per remaining
   --  argument.  C's complete classification is the C boundary's; this is
   --  only the scalar convention the enabled Landin kernel needs.  Naming
   --  the prefix once keeps caller and callee placement in agreement.
   Register_Arguments : constant := 6;

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
                with "an argument register index is outside its ABI run");

   Stack_Argument_Bytes : constant Landin.Targets.Byte_Count := 8;

   function Native_Argument_Bytes
     (Count : Natural;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count := 16#7fff_ffff#)
      return Landin.Targets.Byte_Count
   is
   begin
      if Count <= Register_Arguments then
         return 0;
      elsif Landin.Targets.Byte_Count (Count - Register_Arguments)
        > Maximum / Stack_Argument_Bytes
      then
         raise Stack_Limit_Exceeded with
           "internal arguments exceed the stack budget";
      end if;
      return Stack_Align
        (Landin.Targets.Byte_Count (Count - Register_Arguments)
         * Stack_Argument_Bytes,
         Landin.Targets.Stack_Alignment (Facts), Maximum);
   end Native_Argument_Bytes;

   ------------------------------------------------------------------
   --  Text
   ------------------------------------------------------------------

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts) return Boolean
   is (Frame_Is_Addressable
         (Of_Unit, Item, Facts, Landin.Optimization.Reference_Options));

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Boolean
   is
      Largest_Displacement : constant Landin.Targets.Byte_Count :=
        2 ** 31 - 1;
      Layout : Frame;

      --  Whether the reference frame, in which every slot and every scalar
      --  value has a home of its own, leaves room for anything allocation
      --  can add to it.  An allocated frame places a subset of the same
      --  slot cells in the same order, which ends no lower; then at most
      --  one spill home per value and one save per saved register, each
      --  at most eight bytes padded to an alignment the stack's divides;
      --  then the frame's own rounding.  So a frame within the bound is
      --  addressable without being allocated twice, once here and once
      --  by emission, and only one outside it needs the exact answer.
      function Within_Reference_Bound return Boolean;
      function Within_Reference_Bound return Boolean is
         Cell : constant Landin.Targets.Byte_Count :=
           8 + Landin.Targets.Byte_Count
             (Landin.Targets.Stack_Alignment (Facts));
         --  The rounding is counted as one more cell.
         Cells : constant Landin.Targets.Byte_Count :=
           Landin.Targets.Byte_Count (Landin.IR.Value_Count (Of_Unit, Item))
           + Allocation.Register_Set'Length + 1;
      begin
         if Cells > Largest_Displacement / Cell then
            return False;
         end if;
         return Extent
           (Laid_Out (Of_Unit, Item, Facts, Largest_Displacement
                        - Cells * Cell))
           <= Largest_Displacement - Cells * Cell;
      exception
         when Stack_Limit_Exceeded =>
            --  Over the bound is no answer: the exact frame may fit.
            return False;
      end Within_Reference_Bound;
   begin
      if Landin.IR.Is_External (Of_Unit, Item) then
         return True;
      end if;
      if not Within_Reference_Bound then
         Layout := Allocation.Frame_For
           (Of_Unit, Item, Facts,
            Allocation.Make (Of_Unit, Item, Facts, Options), Options,
            Largest_Displacement);
         if Extent (Layout) > Largest_Displacement then
            return False;
         end if;
      end if;
      if Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
        and then Landin.IR.Signature_Uses_C_ABI
          (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
      then
         if C_ABI.Signature_Plan
           (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts,
            Largest_Displacement - 16).Stack_Bytes
             > Largest_Displacement - 16
         then
            return False;
         end if;
      elsif Native_Argument_Bytes
        (Landin.IR.Parameter_Count (Of_Unit, Item), Facts,
         Largest_Displacement - 16) > Largest_Displacement - 16
      then
         return False;
      end if;
      --  C passes MEMORY arguments inline rather than as Landin addresses.
      --  A huge module object can therefore fit this frame while its outgoing
      --  stack area cannot be encoded by the baseline displacement form.
      for Index in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
         declare
            Value : constant Landin.IR.Value_Id := Landin.IR.Value_Id (Index);
            Op : constant Landin.IR.Opcode :=
              Landin.IR.Op_Of (Of_Unit, Item, Value);
         begin
            if Op in Landin.IR.Call | Landin.IR.Indirect_Call then
               declare
                  Signature : constant Landin.IR.Signature_Id :=
                    (if Op = Landin.IR.Indirect_Call
                     then Landin.IR.Call_Signature (Of_Unit, Item, Value)
                     else Landin.IR.Signature_Of
                       (Of_Unit, Landin.IR.Callee_Of (Of_Unit, Item, Value)));
               begin
                  if Landin.IR.Signature_Uses_C_ABI (Of_Unit, Signature) then
                     if C_ABI.Call_Plan
                       (Of_Unit, Item, Value, Facts,
                        Largest_Displacement).Stack_Bytes
                          > Largest_Displacement
                     then
                        return False;
                     end if;
                  elsif Native_Argument_Bytes
                    (Landin.IR.Operand_Count (Of_Unit, Item, Value)
                     - (if Op = Landin.IR.Indirect_Call then 1 else 0),
                     Facts, Largest_Displacement) > Largest_Displacement
                  then
                     return False;
                  end if;
               end;
            end if;
         end;
      end loop;
      return True;
   exception
      when Stack_Limit_Exceeded =>
         --  Only expected stack-budget exhaustion is a capability answer.
         --  Allocation, shape and ABI invariant failures must stay visible.
         return False;
   end Frame_Is_Addressable;

   function Text
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item) return String
   is (Text (Of_Unit, Meanings, Names, Facts,
             Landin.Optimization.Reference_Options, Hosted_Entry));

   function Text
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Options  : Landin.Optimization.Options;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item) return String
   is
      Assembly : Unbounded.Unbounded_String;
      Report : Landin.Build_Reports.Report;
   begin
      Emit (Of_Unit, Meanings, Names, Facts, Options, Assembly, Report,
            Hosted_Entry);
      return Unbounded.To_String (Assembly);
   end Text;

   --  Per-routine scratch of Emit's.  Instantiated here, once, rather than
   --  in each routine's emission: every instance elaborates a controlled
   --  type, and registering a tagged type per routine is not free.
   package Use_Buffers is new Work_Arrays (Natural, Use_Counts, 0);

   --  A failed check's trap is laid out after the routine's body, so a
   --  passing check falls through instead of branching over it.  One trap
   --  serves every guard of one operation and kind: D232 gives those
   --  guards one site.
   type Pending_Trap is record
      Value : Landin.IR.Value_Id;
      Reason : Landin.Panics.Kind;
   end record;
   package Trap_Vectors is new Ada.Containers.Vectors
     (Positive, Pending_Trap);

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
      Panic : access constant Landin.Panics.Plan := null;
      Level : Landin.Targets.Levels.Feature_Level :=
        Landin.Targets.Levels.Default_Level (Landin.Targets.Linux_X86_64))
   is
      --  D255: x86-64-v3's BMI2 shifts by any register, so a variable
      --  shift at 32 or 64 bits needs neither %cl nor its operand loaded.
      Has_BMI2 : constant Boolean :=
        Landin.Targets.Levels.Has (Level, Landin.Targets.Levels.Bmi2);
      --  Synthetic widths remain a Linux assembly-text layout probe.
      Link_Facts : constant Landin.Targets.Target_Facts :=
        (if Facts = Landin.Targets.Synthetic_32
         then Landin.Targets.Linux_X86_64 else Facts);
      Out_Text : Unbounded.Unbounded_String;
      --  Dense nonzero u32 atom codes, in declaration-identity order; zero
      --  stays available for the successful half of the failing-call
      --  carrier.
      Atoms_Ranked : constant Atom_Codes := Ranked (Of_Unit);
      Optimized : constant Boolean :=
        Options.Optimize /= Landin.Optimization.None;
      Bodies : array (1 .. Landin.IR.Item_Count (Of_Unit)) of
        Unbounded.Unbounded_String;
      Streams : array (1 .. Landin.IR.Item_Count (Of_Unit)) of Machine.Stream;
      Statistics : array (1 .. Landin.IR.Item_Count (Of_Unit)) of
        Landin.Build_Reports.Routine_Statistics;
      type Plan_Array is array (Positive range <>) of Dwarf.Plan_Access;
      type Frame_Array is array (Positive range <>) of Dwarf.Frame_Access;
      procedure Free_Plan is new Ada.Unchecked_Deallocation
        (Allocation.Plan, Dwarf.Plan_Access);
      procedure Free_Frame is new Ada.Unchecked_Deallocation
        (Frame, Dwarf.Frame_Access);
      --  Which of a routine's values have traps after its body, by value.
      type Trap_Mask is access Home_Mask;
      type Trap_Array is array (Positive range <>) of Trap_Mask;
      procedure Free_Traps is new Ada.Unchecked_Deallocation
        (Home_Mask, Trap_Mask);
      type Retained_Facts (Last : Natural) is
        new Ada.Finalization.Limited_Controlled with record
         Plans : Plan_Array (1 .. Last) := [others => null];
         Frames : Frame_Array (1 .. Last) := [others => null];
         Traps : Trap_Array (1 .. Last) := [others => null];
      end record;
      overriding procedure Finalize (Owned : in out Retained_Facts);
      overriding procedure Finalize (Owned : in out Retained_Facts) is
      begin
         for Index in Owned.Plans'Range loop
            if Owned.Traps (Index) /= null then
               Free_Traps (Owned.Traps (Index));
            end if;
            --  Frame_For can fail after the plan has been retained.
            if Owned.Frames (Index) /= null then
               Free_Frame (Owned.Frames (Index));
            end if;
            if Owned.Plans (Index) /= null then
               Free_Plan (Owned.Plans (Index));
            end if;
         end loop;
      end Finalize;
      Saved : Retained_Facts (Bodies'Length);
      Capturing : Landin.IR.Item_Id := Landin.IR.No_Item;
      --  Whether the last instruction emitted is an unconditional transfer,
      --  so that nothing falls through into what follows it until the next
      --  block's label: padding placed there is never executed.  Labels the
      --  debugger alone needs leave it alone, so a debug build pads alike.
      Transferred : Boolean := False;
      --  The emission unit is immutable. One retained-reference traversal
      --  excludes exposed routines before final-body equality comparisons.
      Shareable : Home_Mask (1 .. Landin.IR.Item_Count (Of_Unit)) :=
        [others => False];
      --  Inline mapping words are assembly directives and therefore absent
      --  from Machine's final-instruction comparison.  A routine carrying
      --  them cannot use instruction-only body sharing.
      Has_Inline_Map_Table : Home_Mask
        (1 .. Landin.IR.Item_Count (Of_Unit)) := [others => False];

      procedure Exclude_Exposed (Item : Landin.IR.Item_Id);

      function Cached_Plan (Item : Landin.IR.Item_Id)
        return Dwarf.Plan_Access is (Saved.Plans (Positive (Item)));
      function Cached_Frame (Item : Landin.IR.Item_Id)
        return Dwarf.Frame_Access is (Saved.Frames (Positive (Item)));
      function Trapped
        (Item : Landin.IR.Item_Id; Value : Landin.IR.Value_Id)
         return Boolean
        is (Saved.Traps (Positive (Item)) /= null
            and then Saved.Traps (Positive (Item)) (Positive (Value)));

      procedure Exclude_Exposed (Item : Landin.IR.Item_Id) is
      begin
         Shareable (Positive (Item)) := False;
      end Exclude_Exposed;

      procedure Put (Line : String);

      procedure Put (Line : String) is
      begin
         if Capturing /= Landin.IR.No_Item and then Line'Length > 0
           and then Line (Line'Last) = ':'
         then
            Machine.Define_Label
              (Streams (Positive (Capturing)),
               Line (Line'First .. Line'Last - 1));
         end if;
         Unbounded.Append (Out_Text, Line & LF);
      end Put;

      procedure Emit (Instruction : String);
      procedure Emit_Verbatim (Instruction : String);

      function Is_Transfer (Instruction : String) return Boolean
        is (Instruction = "ret" or else Instruction = "ud2"
            or else (Instruction'Length > 4
                     and then Instruction
                       (Instruction'First .. Instruction'First + 3) = "jmp "));

      --  An instruction no selection may rewrite, which [1630]'s text and
      --  the moves around it are: the assembler reads what was written.
      procedure Emit_Verbatim (Instruction : String) is
      begin
         if Capturing /= Landin.IR.No_Item then
            Machine.Instruction (Streams (Positive (Capturing)), Instruction);
         end if;
         if Instruction'Length > 0
           and then Instruction (Instruction'First) /= '.'
         then
            Transferred := Is_Transfer (Instruction);
         end if;
         Put (Character'Val (9) & Instruction);
      end Emit_Verbatim;

      --  A naked body's text, one instruction per line, as written.
      procedure Emit_Naked_Text (Text : String);

      procedure Emit_Naked_Text (Text : String) is
         First : Positive := Text'First;
      begin
         for Index in Text'Range loop
            if Text (Index) = Character'Val (10) then
               if Index > First then
                  Emit_Verbatim (Text (First .. Index - 1));
               end if;
               First := Index + 1;
            end if;
         end loop;
         if First <= Text'Last then
            Emit_Verbatim (Text (First .. Text'Last));
         end if;
      end Emit_Naked_Text;

      procedure Emit (Instruction : String) is
         Selected : constant String :=
           (if Optimized then Machine.Selected (Instruction) else Instruction);
      begin
         if Selected'Length = 0 then
            return;
         end if;
         if Selected (Selected'First) /= '.' then
            if Capturing /= Landin.IR.No_Item then
               Machine.Instruction (Streams (Positive (Capturing)), Selected);
            end if;
            Transferred := Is_Transfer (Selected);
         end if;
         Put (Character'Val (9) & Selected);
      end Emit;

      --  A by-value parameter this small moves at routine entry as plain
      --  moves rather than a string instruction, whose startup dominates
      --  a few words.  x86-64 needs no alignment for them.
      Unrolled_Transfer : constant Landin.Targets.Byte_Count := 32;

      --  Speed spends code on the same trade for every fixed extent through
      --  Speed_Transfer bytes, wherever one would take a string instruction.
      --  The moves stay at most eight bytes wide: a wider load spanning two
      --  narrower stores just made, as a slice's two words are, cannot be
      --  forwarded from them and stalls for longer than the string startup.
      Speed_Transfer : constant Landin.Targets.Byte_Count := 64;

      function Speed_Unrolled
        (Bytes : Landin.Targets.Byte_Count) return Boolean
        is (Options.Optimize = Landin.Optimization.Speed
            and then Bytes in 1 .. Speed_Transfer);

      --  Copy Bytes from (%rsi) to (%rdi) through %rax, or store the zero
      --  already in %rax, widest moves first.  The ranges are disjoint.
      procedure Move_Unrolled
        (Bytes : Landin.Targets.Byte_Count; Copy : Boolean);

      procedure Move_Unrolled
        (Bytes : Landin.Targets.Byte_Count; Copy : Boolean)
      is
         At_Offset : Landin.Targets.Byte_Count := 0;
      begin
         while At_Offset < Bytes loop
            declare
               Left : constant Landin.Targets.Byte_Count :=
                 Bytes - At_Offset;
               Width : constant Landin.Targets.Byte_Count :=
                 (if Left >= 8 then 8 elsif Left >= 4 then 4
                  elsif Left >= 2 then 2 else 1);
               Suffix : constant String :=
                 (case Width is
                     when 8 => "q", when 4 => "l", when 2 => "w",
                     when others => "b");
               Register : constant String :=
                 (case Width is
                     when 8 => "%rax", when 4 => "%eax", when 2 => "%ax",
                     when others => "%al");
               Where : constant String :=
                 Trimmed (Landin.Targets.Byte_Count'Image (At_Offset));
            begin
               if Copy then
                  Emit ("mov" & Suffix & " " & Where & "(%rsi), "
                        & Register);
               end if;
               Emit ("mov" & Suffix & " " & Register & ", " & Where
                     & "(%rdi)");
               At_Offset := At_Offset + Width;
            end;
         end loop;
      end Move_Unrolled;

      --  Allocate one namespace before emitting anything.  Forced linker
      --  identities are reserved first, including imports whose source names
      --  differ.  Ordinary routines, anonymous items and data then keep their
      --  readable names when free, or else D417's module-qualified name,
      --  `core.arena.reset`, with `.1`, `.2` and so on while another item
      --  holds that.  A candidate must avoid both forced names and other
      --  source names: an explicit C name can hold a qualified spelling too.
      function Symbol (Item : Landin.IR.Item_Id) return String;
      function Evidence_Symbol (Id : Landin.IR.Evidence_Id) return String;
      function Is_Exported_Item (Item : Landin.IR.Item_Id) return Boolean;

      --  The library's argument initializer the hosted entry calls with
      --  C's argc, argv and envp, when the program defines one.
      Initializer : constant Landin.IR.Item_Id :=
        (if Hosted_Entry = Landin.IR.No_Item then Landin.IR.No_Item
         else Landin.Backend.Entry_Point.Argument_Initializer
           (Of_Unit, Names));
      Allocated_Symbols : array
        (1 .. Positive'Max (1, Landin.IR.Item_Count (Of_Unit))) of
          Unbounded.Unbounded_String;

      function Is_C_Item (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
            and then Landin.IR.Signature_Uses_C_ABI
              (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item)));

      --  Every routine, datum and evidence table has its own input section,
      --  so the hosted link's --gc-sections keeps exactly what the entry, a
      --  C object or another retained item reaches.  A dead caller, or dead
      --  data holding a routine's address, then keeps no library routine.
      procedure Begin_Item_Section
        (Prefix, Flags : String; Position : Positive);

      procedure Begin_Item_Section
        (Prefix, Flags : String; Position : Positive) is
      begin
         Put (Character'Val (9) & ".section " & Prefix
              & Trimmed (Positive'Image (Position)) & "," & Flags);
      end Begin_Item_Section;

      function Is_Forced (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Link_Symbol (Of_Unit, Item)
              /= Landin.Source.Names.No_Name
            or else Item = Hosted_Entry
            or else Landin.IR.Is_External (Of_Unit, Item));

      --  Explicit ELF spellings may start with `.L` too.  Pick a disjoint
      --  prefix for every generated local label (blocks, evidence and
      --  anonymous data), rather than reserving a new source-language
      --  namespace.  Most units retain exactly the original `.L` spelling.
      function Unused_Local_Prefix
        (Seed : String := ELF.Local_Prefix) return String;

      function Unused_Local_Prefix
        (Seed : String := ELF.Local_Prefix) return String
      is
         Candidate : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String (Seed);
         Collides : Boolean;
      begin
         loop
            Collides := False;
            for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
               declare
                  Link : constant Landin.Source.Names.Name_Id :=
                    Landin.IR.Link_Symbol
                      (Of_Unit, Landin.IR.Item_Id (Position));
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

      --  D361's report lines, each a read-only datum, and the one routine
      --  that writes a line to standard error and ends the process.
      Reports : Landin.Backend.Trap_Reports.Table;
      Reporter : constant String := Local_Prefix & "landin_trap_report";
      function Report_Label (Index : Positive) return String
        is (Local_Prefix & "landin_trap_line_"
            & Ada.Strings.Fixed.Trim
                (Positive'Image (Index), Ada.Strings.Left));

      Float_Decode_Used : array (Landin.Types.Float_Name) of Boolean :=
        [others => False];

      --  D450: a program that prepares or switches a stack carries one
      --  switch routine and one start routine, emitted after its bodies;
      --  the comment there says what each does.  Both are local function
      --  symbols, `landin.stack_switch` and `landin.stack_start` (D469),
      --  so that a debugger names them in a backtrace: no Landin routine
      --  is spelled with the dot, and an explicit link name that starts
      --  so moves the prefix as it moves a local label's.  A prepared
      --  stack's first frame returns to Stack_Entered, past the start
      --  routine's opening nop, and is Stack_First_Frame bytes below its
      --  aligned top.
      Stack_Used : Boolean := False;
      Routine_Prefix : constant String := Unused_Local_Prefix ("landin.");
      Stack_Switcher : constant String := Routine_Prefix & "stack_switch";
      Stack_Start : constant String := Routine_Prefix & "stack_start";
      Stack_Entered : constant String :=
        Local_Prefix & "landin_stack_entered";
      Stack_First_Frame : constant := 72;

      function Float_Decode_Label
        (From : Landin.Types.Float_Name) return String
      is (Local_Prefix & "landin_float_decode_"
          & (case From is
               when Landin.Types.F32 => "f32",
               when Landin.Types.F64 => "f64"));

      --  Input: IEEE carrier bits in %rax. Output: sign in %r8, truncated
      --  magnitude in %rdx, carry set only for NaN, infinity or exponent
      --  overflow. The caller retains its own destination check and panic
      --  site. Only caller-saved registers are touched.
      procedure Emit_Float_Decode (From : Landin.Types.Float_Name);

      procedure Emit_Float_Decode (From : Landin.Types.Float_Name) is
         Fraction_Bits : constant Natural :=
           (if From = Landin.Types.F32 then 23 else 52);
         Exponent_All : constant Natural :=
           (if From = Landin.Types.F32 then 255 else 2_047);
         Bias : constant Natural :=
           (if From = Landin.Types.F32 then 127 else 1_023);
         Sign_Shift : constant Natural :=
           (if From = Landin.Types.F32 then 31 else 63);
         Fraction_Mask : constant Landin.Types.Magnitude :=
           (if From = Landin.Types.F32 then 8_388_607
            else 4_503_599_627_370_495);
         Hidden : constant Landin.Types.Magnitude := 2 ** Fraction_Bits;
         Decode_Entry : constant String := Float_Decode_Label (From);
         Shift_Right : constant String := Decode_Entry & "_right";
         Ready : constant String := Decode_Entry & "_ready";
         Zero : constant String := Decode_Entry & "_zero";
         Bad : constant String := Decode_Entry & "_bad";
      begin
         Put (Character'Val (9) & ".type " & Decode_Entry & ", @function");
         Put (Decode_Entry & ":");
         if Debug /= null then
            Emit (".cfi_startproc");
            Emit (".cfi_def_cfa %rsp, 8");
         end if;
         Emit ("movq %rax, %r8");
         Emit ("shrq $" & Trimmed (Natural'Image (Sign_Shift)) & ", %r8");
         Emit ("movq %rax, %rcx");
         Emit ("shrq $" & Trimmed (Natural'Image (Fraction_Bits))
               & ", %rcx");
         Emit ("andq $" & Trimmed (Natural'Image (Exponent_All))
               & ", %rcx");
         Emit ("movq %rax, %rdx");
         Emit ("movabsq $"
               & Trimmed (Landin.Types.Magnitude'Image (Fraction_Mask))
               & ", %r9");
         Emit ("andq %r9, %rdx");
         Emit ("cmpq $" & Trimmed (Natural'Image (Exponent_All))
               & ", %rcx");
         Emit ("je " & Bad);
         Emit ("testq %rcx, %rcx");
         Emit ("jz " & Zero);
         Emit ("cmpq $" & Trimmed (Natural'Image (Bias)) & ", %rcx");
         Emit ("jb " & Zero);
         Emit ("subq $" & Trimmed (Natural'Image (Bias)) & ", %rcx");
         Emit ("cmpq $63, %rcx");
         Emit ("ja " & Bad);
         Emit ("movabsq $"
               & Trimmed (Landin.Types.Magnitude'Image (Hidden))
               & ", %r9");
         Emit ("addq %r9, %rdx");
         Emit ("cmpq $" & Trimmed (Natural'Image (Fraction_Bits))
               & ", %rcx");
         Emit ("jb " & Shift_Right);
         Emit ("subq $" & Trimmed (Natural'Image (Fraction_Bits))
               & ", %rcx");
         Emit ("shlq %cl, %rdx");
         Emit ("jmp " & Ready);
         Put (Shift_Right & ":");
         Emit ("movq $" & Trimmed (Natural'Image (Fraction_Bits))
               & ", %r9");
         Emit ("subq %rcx, %r9");
         Emit ("movq %r9, %rcx");
         Emit ("shrq %cl, %rdx");
         Put (Ready & ":");
         Emit ("clc");
         Emit ("ret");
         Put (Zero & ":");
         Emit ("xorq %rdx, %rdx");
         Emit ("clc");
         Emit ("ret");
         Put (Bad & ":");
         Emit ("stc");
         Emit ("ret");
         if Debug /= null then
            Emit (".cfi_endproc");
         end if;
         Put (Character'Val (9) & ".size " & Decode_Entry & ", .-"
               & Decode_Entry);
      end Emit_Float_Decode;

      --  Linker identity, not assembly syntax.  This is also available before
      --  allocation, when discovery decides which runtime names to reserve.
      function Source_Symbol (Item : Landin.IR.Item_Id) return String;

      function Source_Symbol (Item : Landin.IR.Item_Id) return String is
         Declared : constant Landin.IR.Declaration_Id :=
           Landin.Backend.Symbol_Declaration (Of_Unit, Item);
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

      --  This target sees actual linker spellings; the target-neutral
      --  verifier sees only interned name IDs.  Refuse an override of the
      --  hosted entry before returning any assembly, in release too.
      --  Source linkage checking must diagnose these earlier.
      procedure Validate_Linkage;

      procedure Validate_Linkage is
      begin
         for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Position);
               Spelling : constant String := Source_Symbol (Item);
            begin
               if Item = Hosted_Entry then
                  if Landin.IR.Kind_Of (Of_Unit, Item) /= Landin.IR.Routine
                    or else Is_C_Item (Item)
                    or else Spelling /= "main"
                  then
                     raise Landin.Compiler_Defect with
                       "a hosted entry must retain native main linkage";
                  end if;
               elsif Is_Forced (Item)
                 and then Hosted_Entry /= Landin.IR.No_Item
                 and then Spelling = "main"
                 --  C's view of the entry, which a process entry calls:
                 --  an import of C's (argc, argv, envp) -> int.
                 and then not (Landin.IR.Is_External (Of_Unit, Item)
                               and then Is_C_Item (Item)
                               and then Landin.IR.Signature_Parameter_Count
                                 (Of_Unit, Landin.IR.Signature_Of
                                    (Of_Unit, Item)) = 3
                               and then Landin.IR.Signature_Result_Count
                                 (Of_Unit, Landin.IR.Signature_Of
                                    (Of_Unit, Item)) = 1)
               then
                  raise Landin.Compiler_Defect with
                    "a link symbol overrides the hosted main entry";
               end if;
            end;
         end loop;
      end Validate_Linkage;

      procedure Allocate_Symbols;

      procedure Allocate_Symbols is
         Allocated : Spelling_Counts;
         Sources : Spelling_Counts;
         --  For each base a colliding item probes, how many of its
         --  attempts, the base itself first, an earlier item found taken.
         --  Nothing is freed while names are given and Sources is fixed,
         --  so those stay taken: every instance of a generic routine
         --  shares its routine's spelling (D421), and probing each from
         --  the start made giving them names quadratic.
         Tried : Spelling_Counts;

         function Available
           (Candidate : String; Item : Landin.IR.Item_Id) return Boolean;

         function Available
           (Candidate : String; Item : Landin.IR.Item_Id) return Boolean
         is
         begin
            --  Held by an item other than this one: every holder of the
            --  spelling, less this item's own allocated and source names.
            return Count (Allocated, Candidate)
              - (if Unbounded.To_String
                   (Allocated_Symbols (Positive (Item))) = Candidate
                 then 1 else 0)
              + Count (Sources, Candidate)
              - (if Source_Symbol (Item) = Candidate then 1 else 0) = 0;
         end Available;

         procedure Allocate
           (Position : Positive; Spelling : Unbounded.Unbounded_String);

         procedure Allocate
           (Position : Positive; Spelling : Unbounded.Unbounded_String) is
         begin
            Remove (Allocated, Unbounded.To_String
                      (Allocated_Symbols (Position)));
            Allocated_Symbols (Position) := Spelling;
            Add (Allocated, Unbounded.To_String (Spelling));
         end Allocate;
      begin
         for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            Add (Allocated, Unbounded.To_String
                   (Allocated_Symbols (Position)));
            Add (Sources, Source_Symbol (Landin.IR.Item_Id (Position)));
         end loop;
         for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Position);
            begin
               if Is_Forced (Item) then
                  Allocate
                    (Position,
                     Unbounded.To_Unbounded_String (Source_Symbol (Item)));
               end if;
            end;
         end loop;
         for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Position);
               Declared : constant Landin.IR.Declaration_Id :=
                 Landin.Backend.Symbol_Declaration (Of_Unit, Item);
               Spelling : constant String := Source_Symbol (Item);
            begin
               if not Is_Forced (Item) then
                  if Available (Spelling, Item) then
                     Allocate
                       (Position, Unbounded.To_Unbounded_String (Spelling));
                  else
                     declare
                        Base : constant String :=
                          (if Declared = Landin.IR.No_Declaration
                           then Spelling
                           else Landin.Backend.Qualified_Symbol
                             (Meanings, Declared, Spelling));
                        Attempt : Natural := Count (Tried, Base);
                        Candidate : Unbounded.Unbounded_String :=
                          Unbounded.To_Unbounded_String
                            (if Attempt = 0 then Base
                             else Base & "." & Trimmed
                               (Natural'Image (Attempt)));
                     begin
                        while not Available
                          (Unbounded.To_String (Candidate), Item)
                        loop
                           Add (Tried, Base);
                           Attempt := Attempt + 1;
                           Candidate := Unbounded.To_Unbounded_String
                             (Base & "." & Trimmed (Natural'Image (Attempt)));
                        end loop;
                        Allocate (Position, Candidate);
                     end;
                  end if;
               end if;
            end;
         end loop;
      end Allocate_Symbols;

      --  `$` is part of the requested ELF identity but starts an AT&T
      --  immediate operand; unquoted `.` names the location counter.  Quote
      --  at the rendering seam, not in the symbol
      --  table: calls, addresses, data relocations and directives all use this
      --  spelling, while namespace comparisons keep the unquoted identity.
      function Symbol (Item : Landin.IR.Item_Id) return String is
         Spelling : constant String :=
           Landin.Targets.Capabilities.Link_Symbol
             (Link_Facts, Unbounded.To_String
                (Allocated_Symbols (Positive (Item))));
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

      function Is_Exported_Item (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.Backend.Is_Exported
              (Of_Unit, Meanings, Item, Hosted_Entry, Landin.IR.No_Item));

      --  Labels carry the item, because a Block_Id restarts at 1 in the
      --  next item and two blocks named `.L1` would be one label.
      function Label
        (Item : Landin.IR.Item_Id; Block : Landin.IR.Block_Id)
        return String
        is (Local_Prefix & Trimmed (Landin.IR.Item_Id'Image (Item))
            & "_" & Trimmed (Landin.IR.Block_Id'Image (Block)));

      --  Baseline evidence sharing is representation-class sharing: two
      --  concrete views may use one machine body only when every retained
      --  operation has the same physical meaning.  Evidence identity may
      --  differ, because the hidden table parameter supplies that choice;
      --  signed arithmetic and every operation carrying another concrete
      --  identity remain separate rather than being guessed equivalent.
      Shared_With : array
        (1 .. Positive'Max (1, Landin.IR.Item_Count (Of_Unit))) of
          Landin.IR.Item_Id := [others => Landin.IR.No_Item];

      function Carriers_Agree
        (Left, Right : Landin.Types.Type_Kind) return Boolean;
      function Atom_Values_Agree
        (Left, Right : Landin.IR.Atom_Set_Id) return Boolean;
      function Signatures_Have_One_ABI
        (Left, Right : Landin.IR.Signature_Id;
         Limit       : Natural) return Boolean;
      function Routines_Can_Share
        (Left, Right : Landin.IR.Item_Id) return Boolean;
      function Final_Bodies_Can_Share
        (Left, Right : Landin.IR.Item_Id) return Boolean;

      function Final_Bodies_Can_Share
        (Left, Right : Landin.IR.Item_Id) return Boolean
      is
      begin
         if Debug /= null then
            return False;
         elsif not Optimized then
            return Routines_Can_Share (Left, Right);
         end if;
         return Shareable (Positive (Left))
           and then Shareable (Positive (Right))
           and then not Has_Inline_Map_Table (Positive (Left))
           and then not Has_Inline_Map_Table (Positive (Right))
           and then Signatures_Have_One_ABI
             (Landin.IR.Signature_Of (Of_Unit, Left),
              Landin.IR.Signature_Of (Of_Unit, Right),
              Landin.IR.Signature_Count (Of_Unit) + 1)
           and then Machine.Equivalent
             (Streams (Positive (Left)), Streams (Positive (Right)));
      end Final_Bodies_Can_Share;

      function Carriers_Agree
        (Left, Right : Landin.Types.Type_Kind) return Boolean
      is
      begin
         if Left = Right then
            return True;
         elsif Left in Landin.Types.Scalar_Name
           and then Right in Landin.Types.Scalar_Name
         then
            if Left in Landin.Types.Float_Name
              or else Right in Landin.Types.Float_Name
            then
               return False;
            end if;
            return Landin.Types.Storage_Size
              (Landin.Types.Scalar_Name (Left), Facts)
              = Landin.Types.Storage_Size
                  (Landin.Types.Scalar_Name (Right), Facts);
         end if;
         return False;
      end Carriers_Agree;

      function Atom_Values_Agree
        (Left, Right : Landin.IR.Atom_Set_Id) return Boolean
      is (Left = Right or else
          (Left /= Landin.IR.No_Atom_Set
           and then Right /= Landin.IR.No_Atom_Set
           and then Landin.IR.Atom_Sets_Agree (Of_Unit, Left, Right)));

      function Signatures_Have_One_ABI
        (Left, Right : Landin.IR.Signature_Id;
         Limit       : Natural) return Boolean
      is
         function Parts_Agree
           (A, B : Landin.IR.Signature_Part) return Boolean;

         function Parts_Agree
           (A, B : Landin.IR.Signature_Part) return Boolean
         is
         begin
            if A.Convention /= B.Convention
              or else A.Escaping /= B.Escaping
              or else not Carriers_Agree (A.Kind, B.Kind)
            then
               return False;
            elsif A.Kind = Landin.Types.Function_Value then
               return Limit > 0
                 and then Signatures_Have_One_ABI
                   (A.Signature, B.Signature, Limit - 1);
            elsif A.Kind in Landin.Types.Aggregate
                                | Landin.Types.Fixed_Array
            then
               return A.Kind = B.Kind
                 and then A.Length = B.Length
                 and then A.Element = B.Element
                 and then A.Nominal = B.Nominal
                 and then
                   ((A.Element_Shape.Kind = Landin.IR.Scalar_Field_Shape
                     and then B.Element_Shape.Kind
                       = Landin.IR.Scalar_Field_Shape)
                    or else Landin.IR.Same_Shape
                      (Of_Unit, A.Element_Shape, B.Element_Shape));
            end if;
            return True;
         end Parts_Agree;
      begin
         if Left = Right then
            return True;
         elsif Limit = 0
           or else Landin.IR.Signature_Uses_C_ABI (Of_Unit, Left)
             /= Landin.IR.Signature_Uses_C_ABI (Of_Unit, Right)
           or else Landin.IR.Signature_Has_Erased_Self (Of_Unit, Left)
             /= Landin.IR.Signature_Has_Erased_Self (Of_Unit, Right)
           or else Landin.IR.Signature_Never_Returns (Of_Unit, Left)
             /= Landin.IR.Signature_Never_Returns (Of_Unit, Right)
           or else Landin.IR.Signature_Is_Variadic (Of_Unit, Left)
             /= Landin.IR.Signature_Is_Variadic (Of_Unit, Right)
           or else Landin.IR.Signature_Parameter_Count (Of_Unit, Left)
             /= Landin.IR.Signature_Parameter_Count (Of_Unit, Right)
           or else Landin.IR.Signature_Result_Count (Of_Unit, Left)
             /= Landin.IR.Signature_Result_Count (Of_Unit, Right)
           or else
             ((Landin.IR.Signature_Errors (Of_Unit, Left)
                 = Landin.IR.No_Atom_Set)
              /= (Landin.IR.Signature_Errors (Of_Unit, Right)
                    = Landin.IR.No_Atom_Set))
         then
            return False;
         end if;
         if Landin.IR.Signature_Errors (Of_Unit, Left)
              /= Landin.IR.No_Atom_Set
           and then not Landin.IR.Atom_Sets_Agree
             (Of_Unit,
              Landin.IR.Signature_Errors (Of_Unit, Left),
              Landin.IR.Signature_Errors (Of_Unit, Right))
         then
            return False;
         end if;
         for Index in 1 .. Landin.IR.Signature_Parameter_Count
           (Of_Unit, Left)
         loop
            if not Parts_Agree
              (Landin.IR.Nth_Signature_Parameter (Of_Unit, Left, Index),
               Landin.IR.Nth_Signature_Parameter (Of_Unit, Right, Index))
            then
               return False;
            end if;
         end loop;
         for Index in 1 .. Landin.IR.Signature_Result_Count
           (Of_Unit, Left)
         loop
            if not Parts_Agree
              (Landin.IR.Nth_Signature_Result (Of_Unit, Left, Index),
               Landin.IR.Nth_Signature_Result (Of_Unit, Right, Index))
            then
               return False;
            end if;
         end loop;
         return True;
      end Signatures_Have_One_ABI;

      function Routines_Can_Share
        (Left, Right : Landin.IR.Item_Id) return Boolean
      is
      begin
         if Landin.IR.Generic_Template_Of (Of_Unit, Left)
              = Landin.IR.No_Declaration
           or else Landin.IR.Generic_Template_Of (Of_Unit, Left)
             /= Landin.IR.Generic_Template_Of (Of_Unit, Right)
           or else Landin.IR.Slot_Count (Of_Unit, Left)
             /= Landin.IR.Slot_Count (Of_Unit, Right)
           or else Landin.IR.Block_Count (Of_Unit, Left)
             /= Landin.IR.Block_Count (Of_Unit, Right)
           or else not Signatures_Have_One_ABI
             (Landin.IR.Signature_Of (Of_Unit, Left),
              Landin.IR.Signature_Of (Of_Unit, Right),
              Landin.IR.Signature_Count (Of_Unit) + 1)
         then
            return False;
         end if;
         for Slot in 1 .. Landin.IR.Slot_Count (Of_Unit, Left) loop
            if Landin.IR.Is_Aggregate
                 (Of_Unit, Left, Landin.IR.Slot_Id (Slot))
              or else Landin.IR.Is_Array
                (Of_Unit, Left, Landin.IR.Slot_Id (Slot))
              or else Landin.IR.Is_Address
                (Of_Unit, Left, Landin.IR.Slot_Id (Slot))
              or else Landin.IR.Is_Aggregate
                (Of_Unit, Right, Landin.IR.Slot_Id (Slot))
              or else Landin.IR.Is_Array
                (Of_Unit, Right, Landin.IR.Slot_Id (Slot))
              or else Landin.IR.Is_Address
                (Of_Unit, Right, Landin.IR.Slot_Id (Slot))
              or else not Carriers_Agree
                (Landin.IR.Type_Of
                   (Of_Unit, Left, Landin.IR.Slot_Id (Slot)),
                 Landin.IR.Type_Of
                   (Of_Unit, Right, Landin.IR.Slot_Id (Slot)))
              or else not Atom_Values_Agree
                (Landin.IR.Atom_Set_Of
                   (Of_Unit, Left, Landin.IR.Slot_Id (Slot)),
                 Landin.IR.Atom_Set_Of
                   (Of_Unit, Right, Landin.IR.Slot_Id (Slot)))
            then
               return False;
            end if;
         end loop;
         for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Left) loop
            if Landin.IR.Length
                 (Of_Unit, Left, Landin.IR.Block_Id (Block))
              /= Landin.IR.Length
                (Of_Unit, Right, Landin.IR.Block_Id (Block))
            then
               return False;
            end if;
            for Position in 1 .. Landin.IR.Length
              (Of_Unit, Left, Landin.IR.Block_Id (Block))
            loop
               declare
                  A : constant Landin.IR.Value_Id := Landin.IR.Nth_Value
                    (Of_Unit, Left, Landin.IR.Block_Id (Block), Position);
                  B : constant Landin.IR.Value_Id := Landin.IR.Nth_Value
                    (Of_Unit, Right, Landin.IR.Block_Id (Block), Position);
                  Op : constant Landin.IR.Opcode :=
                    Landin.IR.Op_Of (Of_Unit, Left, A);
               begin
                  if Op not in Landin.IR.Number | Landin.IR.Truth
                               | Landin.IR.Load | Landin.IR.Store
                               | Landin.IR.Evidence_Function
                               | Landin.IR.Indirect_Call
                               | Landin.IR.Failure_Test | Landin.IR.Jump
                               | Landin.IR.Branch | Landin.IR.Leave
                    or else Op /= Landin.IR.Op_Of (Of_Unit, Right, B)
                    or else not Carriers_Agree
                      (Landin.IR.Result_Of (Of_Unit, Left, A),
                       Landin.IR.Result_Of (Of_Unit, Right, B))
                    or else not Atom_Values_Agree
                      (Landin.IR.Atom_Set_Of (Of_Unit, Left, A),
                       Landin.IR.Atom_Set_Of (Of_Unit, Right, B))
                    or else Landin.IR.Operand_Count (Of_Unit, Left, A)
                      /= Landin.IR.Operand_Count (Of_Unit, Right, B)
                  then
                     return False;
                  end if;
                  for Operand in 1 .. Landin.IR.Operand_Count
                    (Of_Unit, Left, A)
                  loop
                     if Landin.IR.Nth_Operand
                       (Of_Unit, Left, A, Operand)
                       /= Landin.IR.Nth_Operand
                         (Of_Unit, Right, B, Operand)
                     then
                        return False;
                     end if;
                  end loop;
                  if Op = Landin.IR.Number
                    and then
                      (Landin.IR.Number_Of (Of_Unit, Left, A)
                         /= Landin.IR.Number_Of (Of_Unit, Right, B)
                       or else Landin.IR.Is_Negated (Of_Unit, Left, A)
                         /= Landin.IR.Is_Negated (Of_Unit, Right, B))
                  then
                     return False;
                  elsif Op = Landin.IR.Truth
                    and then Landin.IR.Truth_Of (Of_Unit, Left, A)
                      /= Landin.IR.Truth_Of (Of_Unit, Right, B)
                  then
                     return False;
                  elsif Op in Landin.IR.Load | Landin.IR.Store
                    and then Landin.IR.Slot_Of (Of_Unit, Left, A)
                      /= Landin.IR.Slot_Of (Of_Unit, Right, B)
                  then
                     return False;
                  elsif Op = Landin.IR.Evidence_Function
                    and then
                      (Landin.IR.Evidence_Is_Erased
                         (Of_Unit, Landin.IR.Evidence_Of (Of_Unit, Left, A))
                       or else Landin.IR.Evidence_Is_Erased
                         (Of_Unit, Landin.IR.Evidence_Of (Of_Unit, Right, B))
                       or else Landin.IR.Evidence_Entry_Of
                         (Of_Unit, Left, A)
                           /= Landin.IR.Evidence_Entry_Of (Of_Unit, Right, B))
                  then
                     return False;
                  elsif Op = Landin.IR.Indirect_Call
                    and then
                      (not Signatures_Have_One_ABI
                         (Landin.IR.Call_Signature (Of_Unit, Left, A),
                          Landin.IR.Call_Signature (Of_Unit, Right, B),
                          Landin.IR.Signature_Count (Of_Unit) + 1)
                       or else Landin.IR.Failure_Slot_Of (Of_Unit, Left, A)
                         /= Landin.IR.Failure_Slot_Of (Of_Unit, Right, B))
                  then
                     return False;
                  elsif Op = Landin.IR.Jump
                    and then Landin.IR.Target_Of (Of_Unit, Left, A)
                      /= Landin.IR.Target_Of (Of_Unit, Right, B)
                  then
                     return False;
                  elsif Op = Landin.IR.Branch
                    and then
                      (Landin.IR.Target_Of (Of_Unit, Left, A)
                         /= Landin.IR.Target_Of (Of_Unit, Right, B)
                       or else Landin.IR.Alternative_Of (Of_Unit, Left, A)
                         /= Landin.IR.Alternative_Of (Of_Unit, Right, B))
                  then
                     return False;
                  end if;
               end;
            end loop;
         end loop;
         return True;
      end Routines_Can_Share;

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

      function Has_Wide_Field
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

      --  A compact array or unfolded variant can make a later module field's
      --  target-derived offset exceed a signed relocation displacement.
      function Has_Wide_Field (Item : Landin.IR.Item_Id) return Boolean is
      begin
         if Landin.IR.Result_Of (Of_Unit, Item) /= Landin.Types.Aggregate
         then
            return False;
         end if;

         for Field in 1 .. Landin.IR.Field_Count (Of_Unit, Item) loop
            if Landin.IR.Nth_Field_Shape (Of_Unit, Item, Field).Kind
                 in Landin.IR.Array_Field_Shape
                    | Landin.IR.Aggregate_Field_Shape
                    | Landin.IR.Variant_Field_Shape
            then
               return True;
            end if;
         end loop;
         return False;
      end Has_Wide_Field;

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

      procedure Emit_Routine
        (Item : Landin.IR.Item_Id;
         Allocation_Plan : Allocation.Plan; Layout : Frame);

      procedure Emit_Routine
        (Item : Landin.IR.Item_Id;
         Allocation_Plan : Allocation.Plan; Layout : Frame) is
         Path_Layouts : Landin.IR.Shape_Measurement.Layout_Cache;
         Result : constant Landin.Types.Type_Kind :=
           Landin.IR.Result_Of (Of_Unit, Item);
         C_Plan : constant C_ABI.Plan :=
           (if Is_C_Item (Item) then
              C_ABI.Signature_Plan
                (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts)
            else (Count => 0, others => <>));
         Use_Data : Use_Buffers.Buffer
           (if Optimized then Landin.IR.Value_Count (Of_Unit, Item) else 0);
         Uses : Use_Counts renames Use_Data.Data.all;
         --  How many instructions name each slot, at size and speed.
         Reference_Data : Use_Buffers.Buffer
           (if Optimized then Landin.IR.Slot_Count (Of_Unit, Item) else 0);
         References : Use_Counts renames Reference_Data.Data.all;
         --  At size and speed, one for each load of an atom whose check
         --  cannot fail, which Prove_Atom_Loads finds.
         Proven_Data : Use_Buffers.Buffer
           (if Optimized then Landin.IR.Value_Count (Of_Unit, Item) else 0);
         Proven : Use_Counts renames Proven_Data.Data.all;
         --  At speed, one for each block a loop begins at.
         Head_Data : Use_Buffers.Buffer
           (if Options.Optimize = Landin.Optimization.Speed
            then Landin.IR.Block_Count (Of_Unit, Item) else 0);
         Loop_Heads : Use_Counts renames Head_Data.Data.all;
         Current_Position : Natural := 0;
         Current_Block : Landin.IR.Block_Id := Landin.IR.No_Block;
         Next_Instruction : Landin.IR.Value_Id := Landin.IR.No_Value;
         Fused_Branch : Landin.IR.Value_Id := Landin.IR.No_Value;
         --  D338's choice whose condition a comparison left in the flags,
         --  and the condition code that holds it.
         Fused_Choice : Landin.IR.Value_Id := Landin.IR.No_Value;
         Choice_Flags : Unbounded.Unbounded_String;
         --  An element address whose one use is the next instruction's
         --  indirect access is not formed: that access reads through the
         --  memory operand Folded_Address instead.
         Folded_User : Landin.IR.Value_Id := Landin.IR.No_Value;
         Folded_Address : Unbounded.Unbounded_String;
         --  Lowering carries a checked address to its access through an
         --  address slot, the access's type witness.  When that slot is a
         --  compiler temporary named by just the one store and the one
         --  load between, neither moves anything the fold leaves behind.
         Skipped_Store, Skipped_Load : Landin.IR.Value_Id :=
           Landin.IR.No_Value;
         Exit_Count : Natural := 0;
         Shared_Epilogue : constant String := Label (Item, 1) & "_epilogue";

         --  Each failed check's trap, laid out after the body.
         Traps : Trap_Vectors.Vector;
         --  D467: the largest area the body reserves or pushes below its
         --  frame, and whether a failed check calls out on this stack.
         Deepest_Area : Landin.Targets.Byte_Count := 0;
         Calls_Panic : Boolean := False;
         Pushed_Arguments : Landin.Targets.Byte_Count := 0;

         function Size_Of_Value
           (Value : Landin.IR.Value_Id) return Held_Size
           is (Size_Of
                 (Landin.IR.Result_Of (Of_Unit, Item, Value), Facts));

         function Size_Of_Slot (Slot : Landin.IR.Slot_Id) return Held_Size
           is (Size_Of (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts));

         --  Locations retain their carrier width.  A byte projection is
         --  explicit (not a qword register accidentally used by movb); an
         --  address query is separate and refuses an unhomed register.
         function Value_Operand
           (Value : Landin.IR.Value_Id; Width : Held_Size) return String;
         function Value_Operand (Value : Landin.IR.Value_Id) return String
           is (Value_Operand (Value, Size_Of_Value (Value)));
         function Value_Address (Value : Landin.IR.Value_Id) return String;
         function Slot_Cell (Slot : Landin.IR.Slot_Id) return String;
         function Slot_Address (Slot : Landin.IR.Slot_Id) return String;
         procedure Load_Value (Value : Landin.IR.Value_Id);
         function Value_Label (Value : Landin.IR.Value_Id) return String;
         procedure Store_Value (Value : Landin.IR.Value_Id; From : String);
         function Source_Operand (Value : Landin.IR.Value_Id) return String;

         function Is_XMM (Operand : String) return Boolean is
           (Operand'Length >= 4
            and then Operand (Operand'First .. Operand'First + 3)
              = "%xmm");

         --  One float move.  Between two XMM registers it copies the
         --  whole register: movss and movsd merge into the destination's
         --  upper lanes and so wait for whatever wrote it last, which is
         --  a dependence the scalar value never had.  A move with a memory
         --  side stays scalar, the width that place holds.
         function Float_Move
           (Single : Boolean; From, To : String) return String
           is ((if Is_XMM (From) and then Is_XMM (To)
                then (if Single then "movaps " else "movapd ")
                else (if Single then "movss " else "movsd "))
               & From & ", " & To);

         --  An immediate's image as the unsigned pattern of one or two
         --  bytes it stands for, so a 32-bit move of it zero-extends.
         function Unsigned_Image
           (Size : Held_Size; Immediate : String) return String;

         function Unsigned_Image
           (Size : Held_Size; Immediate : String) return String
         is
            Number : constant Landin.Types.Folded := Landin.Types.Folded'Value
              (Immediate (Immediate'First + 1 .. Immediate'Last));
            Modulus : constant Landin.Types.Folded :=
              (if Size = Landin.Targets.Byte_1 then 2 ** 8 else 2 ** 16);
         begin
            return Trimmed (Landin.Types.Folded'Image
              (if Number < 0 then Number + Modulus else Number));
         end Unsigned_Image;

         --  One general move at one width.  Size and speed write a one- or
         --  two-byte value moving into a register to the whole of its
         --  32-bit name, zero-extended: a narrower write merges into the
         --  register and so waits for whatever wrote it last.  Every
         --  reader names that register at the value's own width, and the
         --  accumulator so loaded holds the value zero-extended.
         function Move (Size : Held_Size; From, To : String) return String
           is (if Optimized
                 and then Size in Landin.Targets.Byte_1
                                | Landin.Targets.Byte_2
                 and then Doubleword (To) /= ""
                 and then From /= "%ah"
               then (if From = To then ""
                     elsif From (From'First) = '$'
                     then "movl $" & Unsigned_Image (Size, From)
                       & ", " & Doubleword (To)
                     else (if Size = Landin.Targets.Byte_1 then "movzbl "
                           else "movzwl ")
                       & From & ", " & Doubleword (To))
               else "mov" & Suffix (Size) & " " & From & ", " & To);

         function Value_Operand
           (Value : Landin.IR.Value_Id; Width : Held_Size) return String
         is
            Place : Allocation.Location renames
              Allocation_Plan.Value (Positive (Value));
         begin
            if Width > Place.Size or else Place.Kind = Allocation.Absent then
               raise Landin.Compiler_Defect with
                 "invalid value location width";
            elsif Place.Kind = Allocation.GP then
               return Allocation.Name (Place.Register, Width);
            elsif Place.Kind = Allocation.SSE then
               return Allocation.Name (Place.Float_Register);
            end if;
            return Cell (Value_Offset (Layout, Value));
         end Value_Operand;

         function Value_Address (Value : Landin.IR.Value_Id) return String is
         begin
            if Allocation_Plan.Value (Positive (Value)).Kind
                 /= Allocation.Stack
              or else not Has_Value_Home (Layout, Value)
            then
               raise Landin.Compiler_Defect with
                 "an unhomed value was addressed";
            end if;
            return Cell (Value_Offset (Layout, Value));
         end Value_Address;

         function Slot_Cell (Slot : Landin.IR.Slot_Id) return String is
            Place : Allocation.Location renames
              Allocation_Plan.Slot (Positive (Slot));
         begin
            if Place.Kind = Allocation.GP then
               return Allocation.Name (Place.Register, Place.Size);
            elsif Place.Kind = Allocation.SSE then
               return Allocation.Name (Place.Float_Register);
            end if;
            return Cell (Slot_Offset (Layout, Slot));
         end Slot_Cell;

         function Slot_Address (Slot : Landin.IR.Slot_Id) return String is
         begin
            if not Has_Slot_Home (Layout, Slot) then
               raise Landin.Compiler_Defect with
                 "an unhomed slot was addressed";
            end if;
            return Cell (Slot_Offset (Layout, Slot));
         end Slot_Address;

         --  A value as an instruction's source operand: size and speed
         --  write an integer constant as its immediate where it fits one.
         function Source_Operand (Value : Landin.IR.Value_Id) return String
         is
            Constant_Image : constant String :=
              (if Optimized
               then Allocation.Immediate (Of_Unit, Item, Value, Facts)
               else "");
         begin
            return (if Constant_Image /= "" then Constant_Image
                    else Value_Operand (Value));
         end Source_Operand;

         procedure Load_Value (Value : Landin.IR.Value_Id) is
            Held : constant Held_Size := Size_Of_Value (Value);
         begin
            if Allocation_Plan.Value (Positive (Value)).Kind
              = Allocation.SSE
            then
               Emit ((if Held = Landin.Targets.Byte_4 then "movd "
                      else "movq ") & Value_Operand (Value)
                     & ", " & Accumulator (Held));
            else
               Emit (Move (Held, Source_Operand (Value), Accumulator (Held)));
            end if;
         end Load_Value;

         --  %rax compared with Bound at 64 bits.  Size and speed write a
         --  bound that fits a sign-extended imm32 as one, which is the
         --  same 64-bit number at either signedness.
         procedure Compare_Accumulator (Bound : Landin.Types.Folded);

         procedure Compare_Accumulator (Bound : Landin.Types.Folded) is
            Image : constant String :=
              Trimmed (Landin.Types.Folded'Image (Bound));
         begin
            if Optimized and then Bound in -(2 ** 31) .. 2 ** 31 - 1 then
               Emit ("cmpq $" & Image & ", %rax");
            else
               Emit ("movabsq $" & Image & ", %rcx");
               Emit ("cmpq %rcx, %rax");
            end if;
         end Compare_Accumulator;

         --  Value zero-extended into the whole of %rax from Width.
         procedure Load_Unsigned
           (Value : Landin.IR.Value_Id; Width : Held_Size);

         procedure Load_Unsigned
           (Value : Landin.IR.Value_Id; Width : Held_Size) is
         begin
            if Optimized then
               Emit ((case Width is
                         when Landin.Targets.Byte_1 => "movzbl ",
                         when Landin.Targets.Byte_2 => "movzwl ",
                         when Landin.Targets.Byte_4 => "movl ",
                         when Landin.Targets.Byte_8 => "movq ")
                     & Value_Operand (Value)
                     & (if Width = Landin.Targets.Byte_8 then ", %rax"
                        else ", %eax"));
            else
               Emit ("movq $0, %rax");
               Emit ("mov" & Suffix (Width) & " " & Value_Operand (Value)
                     & ", " & Accumulator (Width));
            end if;
         end Load_Unsigned;

         procedure Store_Value (Value : Landin.IR.Value_Id; From : String) is
            Held : constant Held_Size := Size_Of_Value (Value);
         begin
            --  AH cannot be encoded with any REX prefix.  The allocator's
            --  high registers require one even for a one-byte destination.
            if Allocation_Plan.Value (Positive (Value)).Kind
              = Allocation.SSE
            then
               Emit ((if Held = Landin.Targets.Byte_4 then "movd "
                      else "movq ") & From & ", " & Value_Operand (Value));
            elsif From = "%ah"
              and then Allocation_Plan.Value (Positive (Value)).Kind
                = Allocation.GP
            then
               Emit ("movb %ah, %al");
               Emit ("movb %al, " & Value_Operand (Value));
            else
               Emit (Move (Held, From, Value_Operand (Value)));
            end if;
         end Store_Value;

         --  D49/D50/D53 ask three compact whole-array operations for the
         --  same target-derived shape and base address.  D57 reuses the base
         --  for the complete padded extent of aggregate storage.  Keep that
         --  replay in one place: a field is an IR identity, never an offset.
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
         procedure Add_Storage_Offset
           (At_Offset : Landin.Targets.Byte_Count;
            Register  : String);
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

         procedure Add_Storage_Offset
           (At_Offset : Landin.Targets.Byte_Count;
            Register  : String) is
         begin
            if At_Offset = 0 then
               return;
            end if;

            if Machine.Fits_Arithmetic_Immediate (At_Offset) then
               Emit
                 ("addq $"
                  & Trimmed (Landin.Targets.Byte_Count'Image (At_Offset))
                  & ", " & Register);
            else
               Emit
                 ("movabsq $"
                  & Trimmed (Landin.Targets.Byte_Count'Image (At_Offset))
                  & ", %rdx");
               Emit ("addq %rdx, " & Register);
            end if;
         end Add_Storage_Offset;

         procedure Storage_Address
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Register      : String;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) is
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
                        Add_Storage_Offset (At_Offset, Register);
                     end;
                  end if;
               when Landin.IR.Frame_Slot =>
                  if not Has_Slot_Home (Layout, Place.Slot) then
                     raise Landin.Compiler_Defect with
                       "an unhomed storage slot was addressed";
                  end if;
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
               when Landin.IR.Runtime_Address =>
                  Emit ("movq " & Slot_Cell (Place.Address) & ", "
                        & Register);
                  if Field > 0 then
                     declare
                        At_Offset : constant Landin.Targets.Byte_Count :=
                          Path_Offset
                            (Landin.IR.Address_Shape
                               (Of_Unit, Item, Place.Address),
                             [1 =>
                                (Field => Landin.IR.Part_Position (Field),
                                 Case_Index => 0)]);
                     begin
                        Add_Storage_Offset (At_Offset, Register);
                     end;
                  end if;
            end case;

            --  The base field first, then D118's run down to the part the
            --  operation names, and then the case it selected inside that
            --  part.  D126 is what makes the run come before the case: the
            --  variant part may sit below the base field, and its payload
            --  offset is its own shape's and not the base field's.  A run
            --  *below* a selected payload is a Case_Index step of the same
            --  run, so nothing is ever added after the payload.
            if Nested'Length > 0 then
               declare
                  At_Offset : constant Landin.Targets.Byte_Count :=
                    Path_Offset (Root_Shape_Of (Place, Field), Nested);
               begin
                  Add_Storage_Offset (At_Offset, Register);
               end;
            end if;

            if Payload_Field > 0 then
               declare
                  At_Offset : constant Landin.Targets.Byte_Count :=
                    Landin.Backend.Variant_Payload_Field_Offset
                      (Of_Unit, Reached_Shape (Place, Field, Nested),
                       Positive (Which), Positive (Payload_Field), Facts,
                       Path_Layouts);
               begin
                  Add_Storage_Offset (At_Offset, Register);
               end;
            end if;
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
           is (Landin.Backend.Path_Offset
                 (Of_Unit, Shape, Path, Facts, Path_Layouts));

         --  A Value_Id restarts in each item, just as a Block_Id does.  The
         --  extra `V` keeps a continuation distinct from a block label.
         function Value_Label (Value : Landin.IR.Value_Id) return String
           is (Local_Prefix & Trimmed (Landin.IR.Item_Id'Image (Item))
               & "_V" & Trimmed (Landin.IR.Value_Id'Image (Value)));

         function Trap_Label
           (Value : Landin.IR.Value_Id; Reason : Landin.Panics.Kind)
            return String
           is (Value_Label (Value) & "_trap_"
               & (case Reason is
                     when Landin.Panics.Out_Of_Range => "range",
                     when Landin.Panics.Overflow => "overflow",
                     when Landin.Panics.Bad_Conversion => "conversion",
                     when Landin.Panics.Unreachable => "unreachable",
                     when Landin.Panics.Stack_Exhausted => "stack"));

         --  Value's trap for Reason is queued once, however many of its
         --  guards branch to it.  One instruction's guards are emitted
         --  together, so its traps are the last ones queued.
         procedure Queue_Trap
           (Value : Landin.IR.Value_Id; Reason : Landin.Panics.Kind);

         procedure Queue_Trap
           (Value : Landin.IR.Value_Id; Reason : Landin.Panics.Kind) is
         begin
            for Index in reverse 1 .. Traps.Last_Index loop
               exit when Traps (Index).Value /= Value;
               if Traps (Index).Reason = Reason then
                  return;
               end if;
            end loop;
            Traps.Append (Pending_Trap'(Value => Value, Reason => Reason));
         end Queue_Trap;

         --  A move through the accumulator, at one width.  Every value
         --  that crosses an instruction crosses it this way.  Size and
         --  speed move directly when either side is a register or the
         --  source is an immediate.
         procedure Carry (Size : Held_Size; From, To : String);

         procedure Carry (Size : Held_Size; From, To : String) is
         begin
            if Optimized and then From = To then
               return;
            elsif Is_XMM (From) or else Is_XMM (To) then
               if Size not in Landin.Targets.Byte_4
                            | Landin.Targets.Byte_8
               then
                  raise Landin.Compiler_Defect with
                    "a non-float carrier reached an XMM register";
               end if;
               if (Is_XMM (From) and then not Is_XMM (To)
                    and then To (To'First) = '%')
                 or else (Is_XMM (To) and then not Is_XMM (From)
                   and then From (From'First) = '%')
               then
                  Emit ((if Size = Landin.Targets.Byte_4
                         then "movd " else "movq ")
                        & From & ", " & To);
               else
                  Emit (Float_Move (Size = Landin.Targets.Byte_4, From, To));
               end if;
            elsif Optimized
              and then (From (From'First) in '%' | '$'
                        or else To (To'First) = '%')
            then
               Emit (Move (Size, From, To));
            else
               Emit (Move (Size, From, Accumulator (Size)));
               Emit ("mov" & Suffix (Size) & " " & Accumulator (Size)
                     & ", " & To);
            end if;
         end Carry;

         --  %r11 at one width: the scratch a store stages a value from
         --  memory through when the accumulator is part of its address.
         function Staging (Size : Held_Size) return String
           is (case Size is
                  when Landin.Targets.Byte_1 => "%r11b",
                  when Landin.Targets.Byte_2 => "%r11w",
                  when Landin.Targets.Byte_4 => "%r11d",
                  when Landin.Targets.Byte_8 => "%r11");

         --  A store to a memory operand that may name the accumulator,
         --  which size and speed address elements with.
         procedure Store_Through (Size : Held_Size; From, To : String);

         procedure Store_Through (Size : Held_Size; From, To : String) is
         begin
            if not Optimized or else From (From'First) in '%' | '$' then
               Carry (Size, From, To);
            else
               Carry (Size, From, Staging (Size));
               Carry (Size, Staging (Size), To);
            end if;
         end Store_Through;

         function Displacement
           (Offset : Landin.Targets.Byte_Count; Base : String) return String
           is (Trimmed (Landin.Targets.Byte_Count'Image (Offset))
               & "(" & Base & ")");

         --  Assembly of the seven-byte scalar copy/clear is 18/16 bytes,
         --  versus 13/15 for the string path.  All other extents through
         --  eight bytes save code with scalar chunks.  Keep this path bounded
         --  so large arrays never make emitted code proportional to extent.
         --  Speed's own bound is Speed_Transfer.
         function Use_Scalar_Transfer
           (Bytes : Landin.Targets.Byte_Count) return Boolean
           is (Bytes in 1 .. 6 or else Bytes = 8
               or else Speed_Unrolled (Bytes));

         function Transfer_Chunk
           (Remaining : Landin.Targets.Byte_Count) return Held_Size
           is (if Remaining >= 8 then Landin.Targets.Byte_8
               elsif Remaining >= 4 then Landin.Targets.Byte_4
               elsif Remaining >= 2 then Landin.Targets.Byte_2
               else Landin.Targets.Byte_1);

         procedure Emit_Small_Copy (Bytes : Landin.Targets.Byte_Count);
         procedure Emit_Small_Clear (Bytes : Landin.Targets.Byte_Count);

         procedure Emit_Small_Copy (Bytes : Landin.Targets.Byte_Count) is
            Offset : Landin.Targets.Byte_Count := 0;
         begin
            while Offset < Bytes loop
               declare
                  Chunk : constant Held_Size :=
                    Transfer_Chunk (Bytes - Offset);
               begin
                  Emit ("mov" & Suffix (Chunk) & " "
                        & Displacement (Offset, "%rsi") & ", "
                        & Accumulator (Chunk));
                  Emit ("mov" & Suffix (Chunk) & " "
                        & Accumulator (Chunk) & ", "
                        & Displacement (Offset, "%rdi"));
                  Offset := Offset + Landin.Targets.Byte_Count
                    (Landin.Targets.Bytes (Chunk));
               end;
            end loop;
         end Emit_Small_Copy;

         procedure Emit_Small_Clear (Bytes : Landin.Targets.Byte_Count) is
            Offset : Landin.Targets.Byte_Count := 0;
         begin
            while Offset < Bytes loop
               declare
                  Chunk : constant Held_Size :=
                    Transfer_Chunk (Bytes - Offset);
               begin
                  Emit ("mov" & Suffix (Chunk) & " $0, "
                        & Displacement (Offset, "%rdi"));
                  Offset := Offset + Landin.Targets.Byte_Count
                    (Landin.Targets.Bytes (Chunk));
               end;
            end loop;
         end Emit_Small_Clear;

         --  C ABI chunk transport never touches argument or result registers
         --  as scratch.  %r11 is the object base and %r10 holds one eightbyte.
         --  Partial final chunks read/write only bytes inside the object.
         function Chunk_Bytes
           (Shape : C_ABI.Classification; Index : Positive)
            return Landin.Targets.Byte_Count
           is (Landin.Targets.Byte_Count'Min
                 (8, Shape.Size - Landin.Targets.Byte_Count (Index - 1) * 8));

         function C_Register
           (Place : C_ABI.Location;
            Index : Positive;
            Returning : Boolean := False) return String
           is (if Place.Shape.Classes (Index) = C_ABI.SSE_Class
               then "%xmm" & Trimmed
                 (Natural'Image (Place.Registers (Index) - 1))
               elsif Returning
               then (if Place.Registers (Index) = 1
                     then "%rax" else "%rdx")
               else Argument_Register
                 (Place.Registers (Index), Landin.Targets.Byte_8));

         procedure Load_C_Chunk
           (Offset, Bytes : Landin.Targets.Byte_Count);
         procedure Store_C_Chunk
           (Offset, Bytes : Landin.Targets.Byte_Count);
         procedure Extend_C_Integer
           (Kind : Landin.Types.Type_Kind);
         procedure Load_C_Scalar (Value : Landin.IR.Value_Id);
         procedure Reserve_Stack
           (Bytes : Landin.Targets.Byte_Count; Identity : String);
         procedure Emit_C_Entry;
         procedure Emit_C_Call (Value : Landin.IR.Value_Id);
         procedure Emit_C_Result (Value : Landin.IR.Value_Id);

         procedure Load_C_Chunk
           (Offset, Bytes : Landin.Targets.Byte_Count) is
         begin
            if Bytes = 8 then
               Emit ("movq " & Displacement (Offset, "%r11") & ", %r10");
            elsif Bytes = 4 then
               Emit ("movl " & Displacement (Offset, "%r11") & ", %r10d");
            elsif Bytes = 2 then
               Emit ("movzwq " & Displacement (Offset, "%r11") & ", %r10");
            elsif Bytes = 1 then
               Emit ("movzbq " & Displacement (Offset, "%r11") & ", %r10");
            else
               Emit ("xorq %r10, %r10");
               for Byte in reverse 0 .. Bytes - 1 loop
                  Emit ("shlq $8, %r10");
                  Emit ("movb " & Displacement (Offset + Byte, "%r11")
                        & ", %r10b");
               end loop;
            end if;
         end Load_C_Chunk;

         procedure Store_C_Chunk
           (Offset, Bytes : Landin.Targets.Byte_Count) is
         begin
            if Bytes = 8 then
               Emit ("movq %r10, " & Displacement (Offset, "%r11"));
            elsif Bytes = 4 then
               Emit ("movl %r10d, " & Displacement (Offset, "%r11"));
            elsif Bytes = 2 then
               Emit ("movw %r10w, " & Displacement (Offset, "%r11"));
            elsif Bytes = 1 then
               Emit ("movb %r10b, " & Displacement (Offset, "%r11"));
            else
               for Byte in 0 .. Bytes - 1 loop
                  Emit ("movb %r10b, "
                        & Displacement (Offset + Byte, "%r11"));
                  Emit ("shrq $8, %r10");
               end loop;
            end if;
         end Store_C_Chunk;

         procedure Extend_C_Integer
           (Kind : Landin.Types.Type_Kind) is
         begin
            case Kind is
               when Landin.Types.I8 => Emit ("movsbl %r10b, %r10d");
               when Landin.Types.I16 => Emit ("movswl %r10w, %r10d");
               when others => null;
            end case;
         end Extend_C_Integer;

         procedure Load_C_Scalar (Value : Landin.IR.Value_Id) is
            Bytes : constant Held_Size := Size_Of_Value (Value);
            Source : constant String := Value_Operand (Value, Bytes);
         begin
            case Bytes is
               when Landin.Targets.Byte_1 =>
                  Emit ("movzbq " & Source & ", %r10");
               when Landin.Targets.Byte_2 =>
                  Emit ("movzwq " & Source & ", %r10");
               when Landin.Targets.Byte_4 =>
                  Emit ("movl " & Source & ", %r10d");
               when Landin.Targets.Byte_8 =>
                  Emit ("movq " & Source & ", %r10");
            end case;
            Extend_C_Integer
              (Landin.IR.Result_Of (Of_Unit, Item, Value));
         end Load_C_Scalar;

         procedure Emit_C_Entry is
            Plan : C_ABI.Plan renames C_Plan;
            Hidden : constant Natural :=
              (if Plan.Result.Shape.Aggregate then 1 else 0);
            GP_Bytes : constant Landin.Targets.Byte_Count :=
              Landin.Targets.Byte_Count (Plan.GP_Used) * 8;
            SSE_Bytes : constant Landin.Targets.Byte_Count :=
              Landin.Targets.Byte_Count (Plan.SSE_Used) * 8;
            Saved_Bytes : constant Landin.Targets.Byte_Count :=
              Stack_Align (GP_Bytes + SSE_Bytes,
                           Landin.Targets.Stack_Alignment (Facts), 112);
         begin
            --  The plan allocates each bank in order, including the hidden
            --  result pointer.  Save only the used prefixes before a copy or
            --  partial-chunk helper can clobber them.  This temporary area
            --  does not become IR state.
            Reserve_Stack (Saved_Bytes, "c_entry");
            for Index in 1 .. Plan.GP_Used loop
               Emit ("movq "
                     & Argument_Register (Index, Landin.Targets.Byte_8)
                     & ", " & Displacement
                       (Landin.Targets.Byte_Count (Index - 1) * 8, "%rsp"));
            end loop;
            for Index in 1 .. Plan.SSE_Used loop
               Emit ("movq %xmm" & Trimmed (Natural'Image (Index - 1))
                     & ", " & Displacement
                       (GP_Bytes + Landin.Targets.Byte_Count (Index - 1) * 8,
                        "%rsp"));
            end loop;
            if Hidden = 1 then
               if Plan.Result.Shape.Memory then
                  Emit ("movq 0(%rsp), %r10");
               else
                  Emit ("leaq " & Slot_Address
                        (Landin.IR.Result_Slot (Of_Unit, Item))
                        & ", %r10");
               end if;
               Emit ("movq %r10, " & Slot_Cell
                     (Landin.IR.Nth_Parameter (Of_Unit, Item, 1)));
            end if;
            for Index in Plan.Arguments'Range loop
               declare
                  Place : C_ABI.Location renames Plan.Arguments (Index);
                  Slot : constant Landin.IR.Slot_Id :=
                    Landin.IR.Nth_Parameter (Of_Unit, Item, Index + Hidden);
               begin
                  if Place.On_Stack then
                     Emit ("leaq " & Displacement
                           (16 + Place.Stack_At, "%rbp") & ", %rsi");
                     Emit ("leaq " & Slot_Address (Slot) & ", %rdi");
                     if Speed_Unrolled (Place.Shape.Size) then
                        Emit_Small_Copy (Place.Shape.Size);
                     else
                        Emit ("movabsq $" & Trimmed
                              (Landin.Targets.Byte_Count'Image
                                 (Place.Shape.Size)) & ", %rcx");
                        Emit ("cld");
                        Emit ("rep movsb");
                     end if;
                  else
                     Emit ("leaq " & Slot_Address (Slot) & ", %r11");
                     for Chunk in 1 .. Place.Shape.Count loop
                        if Place.Shape.Classes (Chunk) /= C_ABI.No_Class then
                           Emit ("movq " & Displacement
                                 ((if Place.Shape.Classes (Chunk)
                                       = C_ABI.SSE_Class
                                   then GP_Bytes
                                   else Landin.Targets.Byte_Count'(0))
                                  + Landin.Targets.Byte_Count
                                    (Place.Registers (Chunk) - 1) * 8,
                                  "%rsp") & ", %r10");
                           Store_C_Chunk
                             (Landin.Targets.Byte_Count (Chunk - 1) * 8,
                              Chunk_Bytes (Place.Shape, Chunk));
                        end if;
                     end loop;
                  end if;
               end;
            end loop;
            if Saved_Bytes > 0 then
               Emit ("addq $" & Trimmed
                     (Landin.Targets.Byte_Count'Image (Saved_Bytes))
                     & ", %rsp");
            end if;
         end Emit_C_Entry;

         procedure Emit_C_Call (Value : Landin.IR.Value_Id) is
            Indirect : constant Boolean :=
              Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Indirect_Call;
            Signature : constant Landin.IR.Signature_Id :=
              (if Indirect then Landin.IR.Call_Signature (Of_Unit, Item, Value)
               else Landin.IR.Signature_Of
                 (Of_Unit, Landin.IR.Callee_Of (Of_Unit, Item, Value)));
            Plan : constant C_ABI.Plan :=
              C_ABI.Call_Plan (Of_Unit, Item, Value, Facts);
            Hidden : constant Natural :=
              (if Plan.Result.Shape.Aggregate then 1 else 0);
            Offset : constant Natural := (if Indirect then 1 else 0);

            function Argument (Index : Positive) return Landin.IR.Value_Id
              is (Landin.IR.Nth_Operand
                    (Of_Unit, Item, Value, Index + Offset + Hidden));
         begin
            Reserve_Stack
              (Plan.Stack_Bytes, "call_"
               & Trimmed (Landin.IR.Value_Id'Image (Value)));
            --  Copy stack objects before filling either register bank.
            for Index in Plan.Arguments'Range loop
               declare
                  Place : C_ABI.Location renames Plan.Arguments (Index);
               begin
                  if Place.On_Stack then
                     if Place.Shape.Aggregate then
                        Emit ("movq " & Value_Operand (Argument (Index))
                              & ", %rsi");
                        Emit ("leaq " & Displacement
                              (Place.Stack_At, "%rsp") & ", %rdi");
                        if Speed_Unrolled (Place.Shape.Size) then
                           Emit_Small_Copy (Place.Shape.Size);
                        else
                           Emit ("movabsq $" & Trimmed
                                 (Landin.Targets.Byte_Count'Image
                                    (Place.Shape.Size)) & ", %rcx");
                           Emit ("cld");
                           Emit ("rep movsb");
                        end if;
                     else
                        Load_C_Scalar (Argument (Index));
                        Emit ("movq %r10, "
                              & Displacement (Place.Stack_At, "%rsp"));
                     end if;
                  end if;
               end;
            end loop;
            if Plan.Result.Shape.Memory then
               Emit ("movq " & Value_Operand
                     (Landin.IR.Nth_Operand
                        (Of_Unit, Item, Value, Offset + 1)) & ", %rdi");
            end if;
            for Index in Plan.Arguments'Range loop
               declare
                  Place : C_ABI.Location renames Plan.Arguments (Index);
               begin
                  if not Place.On_Stack then
                     if Place.Shape.Aggregate then
                        Emit ("movq " & Value_Operand (Argument (Index))
                              & ", %r11");
                        for Chunk in 1 .. Place.Shape.Count loop
                           if Place.Shape.Classes (Chunk) /= C_ABI.No_Class
                           then
                              Load_C_Chunk
                                (Landin.Targets.Byte_Count (Chunk - 1) * 8,
                                 Chunk_Bytes (Place.Shape, Chunk));
                              Emit ("movq %r10, "
                                    & C_Register (Place, Chunk));
                           end if;
                        end loop;
                     else
                        Load_C_Scalar (Argument (Index));
                        Emit ("movq %r10, " & C_Register (Place, 1));
                     end if;
                  end if;
               end;
            end loop;
            if Landin.IR.Signature_Is_Variadic (Of_Unit, Signature) then
               Emit ("movb $" & Trimmed (Natural'Image (Plan.SSE_Used))
                     & ", %al");
            end if;
            if Indirect then
               Emit ("call *" & Value_Operand
                     (Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1)));
            else
               Emit ("call " & Symbol
                     (Landin.IR.Callee_Of (Of_Unit, Item, Value)));
            end if;
            if not Plan.Result.Shape.Memory
              and then Plan.Result.Shape.Size > 0
            then
               if Hidden = 1 then
                  Emit ("movq " & Value_Operand
                        (Landin.IR.Nth_Operand
                           (Of_Unit, Item, Value, Offset + 1)) & ", %r11");
               else
                  Emit ("leaq " & Value_Address (Value) & ", %r11");
               end if;
               for Chunk in 1 .. Plan.Result.Shape.Count loop
                  if Plan.Result.Shape.Classes (Chunk) /= C_ABI.No_Class
                  then
                     Emit ("movq " & C_Register
                           (Plan.Result, Chunk, Returning => True)
                           & ", %r10");
                     Store_C_Chunk
                       (Landin.Targets.Byte_Count (Chunk - 1) * 8,
                        Chunk_Bytes (Plan.Result.Shape, Chunk));
                  end if;
               end loop;
            end if;
            if Plan.Stack_Bytes > 0 then
               Emit ("addq $" & Trimmed
                     (Landin.Targets.Byte_Count'Image (Plan.Stack_Bytes))
                     & ", %rsp");
            end if;
         end Emit_C_Call;

         procedure Emit_C_Result (Value : Landin.IR.Value_Id) is
            Place : C_ABI.Location renames C_Plan.Result;
         begin
            if Place.Shape.Size = 0 then
               return;
            elsif Place.Shape.Memory then
               Emit ("movq " & Slot_Cell
                     (Landin.IR.Nth_Parameter (Of_Unit, Item, 1)) & ", %rdi");
               Emit ("leaq " & Slot_Address
                     (Landin.IR.Result_Slot (Of_Unit, Item)) & ", %rsi");
               if Speed_Unrolled (Place.Shape.Size) then
                  Emit_Small_Copy (Place.Shape.Size);
               else
                  Emit ("movabsq $" & Trimmed
                        (Landin.Targets.Byte_Count'Image (Place.Shape.Size))
                        & ", %rcx");
                  Emit ("cld");
                  Emit ("rep movsb");
               end if;
               Emit ("movq " & Slot_Cell
                     (Landin.IR.Nth_Parameter (Of_Unit, Item, 1)) & ", %rax");
               return;
            elsif Place.Shape.Aggregate then
               Emit ("leaq " & Slot_Address
                     (Landin.IR.Result_Slot (Of_Unit, Item)) & ", %r11");
            else
               Emit ("leaq " & Value_Address
                     (Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1))
                     & ", %r11");
            end if;
            for Chunk in 1 .. Place.Shape.Count loop
               if Place.Shape.Classes (Chunk) /= C_ABI.No_Class then
                  Load_C_Chunk
                    (Landin.Targets.Byte_Count (Chunk - 1) * 8,
                     Chunk_Bytes (Place.Shape, Chunk));
                  if not Place.Shape.Aggregate then
                     Extend_C_Integer (Result);
                  end if;
                  Emit ("movq %r10, "
                        & C_Register (Place, Chunk, Returning => True));
               end if;
            end loop;
         end Emit_C_Result;

         --  Linux stack growth touches at most 4096 bytes apart.  R11 is
         --  scratch at each reservation boundary; argument banks, R10 failure
         --  state and allocated callee-saves remain live and untouched.
         procedure Reserve_Stack
           (Bytes : Landin.Targets.Byte_Count; Identity : String)
         is
            Pages : constant Landin.Targets.Byte_Count := Bytes / 4096;
            Partial : constant Landin.Targets.Byte_Count := Bytes mod 4096;
            Loop_Label : constant String := Local_Prefix
              & Trimmed (Landin.IR.Item_Id'Image (Item))
              & "_probe_" & Identity;
         begin
            --  A small frame may not have touched its bottom yet.  Anchor
            --  outgoing probing there before two individually small reserves
            --  could combine into an unprobed page.  Stack extents are aligned
            --  to 16, so a remaining sub-page run plus CALL's push stays below
            --  4096.  Tiny leaves retain the reference prologue unchanged.
            if Identity /= "frame" and then Extent (Layout) < 4096
              and then Extent (Layout) + Bytes >= 4096
            then
               Emit ("orq $0, (%rsp)");
            end if;
            if Identity /= "frame" then
               Deepest_Area :=
                 Landin.Targets.Byte_Count'Max (Deepest_Area, Bytes);
            end if;
            if Bytes = 0 then
               return;
            elsif Pages = 0 then
               Emit ("subq $" & Trimmed
                     (Landin.Targets.Byte_Count'Image (Bytes)) & ", %rsp");
               return;
            end if;
            Emit ("leaq -" & Trimmed
                  (Landin.Targets.Byte_Count'Image (Pages * 4096))
                  & "(%rsp), %r11");
            Put (Loop_Label & ":");
            Emit ("subq $4096, %rsp");
            Emit ("orq $0, (%rsp)");
            Emit ("cmpq %r11, %rsp");
            Emit ("jne " & Loop_Label);
            if Partial > 0 then
               Emit ("subq $" & Trimmed
                     (Landin.Targets.Byte_Count'Image (Partial)) & ", %rsp");
               Emit ("orq $0, (%rsp)");
            end if;
         end Reserve_Stack;

         procedure Emit_Epilogue (Value : Landin.IR.Value_Id);
         procedure Emit_Epilogue_Body;

         procedure Emit_Epilogue (Value : Landin.IR.Value_Id) is
         begin
            if Debug /= null then
               --  Every variable home is still intact through return-value
               --  preparation. End location ranges before the first restore.
               Put (Dwarf.Label_Name
                 (Local_Prefix, "epilogue", Item, Natural (Value)) & ":");
            end if;
            if Exit_Count > 1 then
               --  The final exit can fall through to the shared teardown.
               if Current_Block /= Landin.IR.Block_Id
                    (Landin.IR.Block_Count (Of_Unit, Item))
                 or else Next_Instruction /= Landin.IR.No_Value
               then
                  Emit ("jmp " & Shared_Epilogue);
               end if;
            else
               if Debug /= null then
                  --  A later block may follow this sole exit in assembly.
                  --  Keep its CFI state while emitting that block.
                  Emit (".cfi_remember_state");
               end if;
               Emit_Epilogue_Body;
               if Debug /= null then
                  Emit (".cfi_restore_state");
               end if;
            end if;
         end Emit_Epilogue;

         procedure Emit_Epilogue_Body is
         begin
            for Register in Allocation.Saved_Register loop
               if Allocation_Plan.Used (Register) then
                  Emit ("movq " & Cell (Save_Offset
                        (Layout, Allocation.Save_Index
                           (Allocation_Plan, Register))) & ", "
                        & Allocation.Name (Register, Landin.Targets.Byte_8));
                  if Debug /= null then
                     Emit (".cfi_restore " & Trimmed (Natural'Image
                       (Dwarf.Register_Number (Register))));
                  end if;
               end if;
            end loop;
            Emit ("movq %rbp, %rsp");
            Emit ("popq %rbp");
            if Debug /= null then
               Emit (".cfi_def_cfa %rsp, 8");
               Emit (".cfi_restore %rbp");
            end if;
            Emit ("ret");
         end Emit_Epilogue_Body;

         --  D232: a selected handler receives the failed check's kind and
         --  site; the default handler is the trap instruction itself.
         procedure Emit_Panic
           (Value : Landin.IR.Value_Id; Reason : Landin.Panics.Kind);
         procedure Emit_Traps;

         procedure Emit_Panic
           (Value : Landin.IR.Value_Id; Reason : Landin.Panics.Kind) is
         begin
            if Panic /= null and then Landin.Panics.Handler (Panic.all)
              /= Landin.IR.No_Item
            then
               Emit ("movl $" & Trimmed (Positive'Image
                 (Landin.Panics.Code (Panic.all, Reason))) & ", %edi");
               Emit ("movl $" & Trimmed (Landin.Panics.Site_Number'Image
                 (Landin.Panics.Site (Panic.all, Landin.IR.Origin_Of
                   (Of_Unit, Item, Value), Reason))) & ", %esi");
               Emit ("call " & Symbol (Landin.Panics.Handler (Panic.all)));
               Calls_Panic := True;
            elsif Panic /= null and then Landin.Panics.Reports_Default
              (Panic.all)
            then
               --  D361: the line for this operation, and its length, to
               --  the routine that writes it and ends the process.
               declare
                  Line : constant String := Landin.Panics.Report
                    (Panic.all, Landin.IR.Origin_Of (Of_Unit, Item, Value),
                     Reason);
                  Index : constant Positive :=
                    Reports.Index_Of (Line);
               begin
                  Emit ("leaq " & Report_Label (Index) & "(%rip), %rdi");
                  Emit ("movl $" & Trimmed (Natural'Image (Line'Length))
                        & ", %esi");
                  Emit ("call " & Reporter);
                  Calls_Panic := True;
               end;
            end if;
            Emit ("ud2");
         end Emit_Panic;

         --  The queued traps follow the body with its frame unchanged.
         --  Each keeps its operation's line, and the debug labels around
         --  one operation's traps let its variables and scopes cover them.
         procedure Emit_Traps is
            First : Positive := 1;
         begin
            for Index in 1 .. Traps.Last_Index loop
               declare
                  Trap : constant Pending_Trap := Traps (Index);
               begin
                  if Debug /= null and then Index = First then
                     if Saved.Traps (Positive (Item)) = null then
                        Saved.Traps (Positive (Item)) := new Home_Mask'
                          (1 .. Landin.IR.Value_Count (Of_Unit, Item)
                             => False);
                     end if;
                     Saved.Traps (Positive (Item)) (Positive (Trap.Value))
                       := True;
                     Put (Dwarf.Label_Name
                       (Local_Prefix, "trap", Item, Natural (Trap.Value))
                       & ":");
                     Put (Dwarf.Source_Line
                       (Debug.all, Landin.IR.Origin_Of
                          (Of_Unit, Item, Trap.Value)));
                  end if;
                  Put (Trap_Label (Trap.Value, Trap.Reason) & ":");
                  Emit_Panic (Trap.Value, Trap.Reason);
                  if Index = Traps.Last_Index
                    or else Traps (Index + 1).Value /= Trap.Value
                  then
                     if Debug /= null then
                        Put (Dwarf.Label_Name
                          (Local_Prefix, "trapped", Item,
                           Natural (Trap.Value)) & ":");
                     end if;
                     First := Index + 1;
                  end if;
               end;
            end loop;
         end Emit_Traps;

         function Threaded
           (Block : Landin.IR.Block_Id) return Landin.IR.Block_Id;

         --  Speed sends a jump straight past blocks that only jump on.  It
         --  never shortens code, so size keeps each jump where it was.  A
         --  chain is followed at most once round, so a cycle still ends.
         function Threaded
           (Block : Landin.IR.Block_Id) return Landin.IR.Block_Id
         is
            Target : Landin.IR.Block_Id := Block;
         begin
            if Options.Optimize = Landin.Optimization.Speed then
               for Hop in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
                  exit when Landin.IR.Length (Of_Unit, Item, Target) /= 1
                    or else Landin.IR.Op_Of
                      (Of_Unit, Item,
                       Landin.IR.Nth_Value (Of_Unit, Item, Target, 1))
                      /= Landin.IR.Jump;
                  Target := Landin.IR.Target_Of
                    (Of_Unit, Item,
                     Landin.IR.Nth_Value (Of_Unit, Item, Target, 1));
               end loop;
            end if;
            return Target;
         end Threaded;

         procedure Conditional_Branch
           (Condition : String; Yes, No : Landin.IR.Block_Id);

         procedure Conditional_Branch
           (Condition : String; Yes, No : Landin.IR.Block_Id)
         is
            Following : constant Landin.IR.Block_Id := Current_Block + 1;
            Inverse : constant String := Inverse_Condition (Condition);
         begin
            if Optimized and then Yes = Following then
               Emit ("j" & Inverse & " " & Label (Item, Threaded (No)));
            else
               Emit ("j" & Condition & " " & Label (Item, Threaded (Yes)));
               if not Optimized or else No /= Following then
                  Emit ("jmp " & Label (Item, Threaded (No)));
               end if;
            end if;
         end Conditional_Branch;

         procedure Find_Loop_Heads;
         procedure Prove_Atom_Loads;

         --  A block some block at or after it branches back to begins a
         --  loop when control enters it from outside that loop: some
         --  predecessor is less deeply nested.  A later block that only
         --  rejoins earlier code is no loop.  Speed aligns a loop's head
         --  to thirty-two bytes when nothing falls through into it, since
         --  then no padding is executed: a word counter's loop starting
         --  sixteen bytes into a line ran a fifth slower than at thirty-two.
         --  A head that is fallen into is aligned as GCC's -O2 does, to
         --  sixteen bytes when that pads ten or fewer, else to eight,
         --  because its padding runs on every entry.  Linear in the
         --  routine.
         procedure Find_Loop_Heads is
            Graph : constant Landin.IR.Control_Flow.Graph :=
              Landin.IR.Control_Flow.Make (Of_Unit, Item);
            Depth : constant Landin.IR.Liveness.Count_Vectors.Vector :=
              Landin.IR.Liveness.Loop_Depths (Graph);

            procedure Mark (Source, Target : Landin.IR.Block_Id);
            procedure Mark (Source, Target : Landin.IR.Block_Id) is
               Head : constant Landin.IR.Block_Id := Threaded (Target);
               Edge : Natural :=
                 Landin.IR.Control_Flow.First_Predecessor (Graph, Head);
            begin
               if Head > Source or else Depth (Positive (Head)) = 0
                 or else Loop_Heads (Positive (Head)) /= 0
               then
                  return;
               end if;
               --  Two once found to be no head, so each is searched once.
               Loop_Heads (Positive (Head)) := 2;
               while Edge /= 0 loop
                  if Depth (Positive (Landin.IR.Control_Flow.Predecessor
                                       (Graph, Edge)))
                    < Depth (Positive (Head))
                  then
                     Loop_Heads (Positive (Head)) := 1;
                     return;
                  end if;
                  Edge := Landin.IR.Control_Flow.Next_Predecessor
                    (Graph, Edge);
               end loop;
            end Mark;
         begin
            for Index in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
               declare
                  Block : constant Landin.IR.Block_Id :=
                    Landin.IR.Block_Id (Index);
                  Last : constant Landin.IR.Value_Id := Landin.IR.Nth_Value
                    (Of_Unit, Item, Block,
                     Landin.IR.Length (Of_Unit, Item, Block));
               begin
                  case Landin.IR.Op_Of (Of_Unit, Item, Last) is
                     when Landin.IR.Jump =>
                        Mark
                          (Block, Landin.IR.Target_Of (Of_Unit, Item, Last));
                     when Landin.IR.Branch =>
                        Mark
                          (Block, Landin.IR.Target_Of (Of_Unit, Item, Last));
                        Mark (Block,
                              Landin.IR.Alternative_Of (Of_Unit, Item, Last));
                     when others => null;
                  end case;
               end;
            end loop;
         end Find_Loop_Heads;

         --  A load of an atom checks the code it reads against the atom's
         --  set.  The check cannot fail when the store reaching the load
         --  in its block wrote an atom of that set and nothing that may
         --  write the slot otherwise came between: a call, assembly or a
         --  store through an address.  Linear in the routine, each such
         --  load searching its set once.
         procedure Prove_Atom_Loads is
            Known_Data, Stamp_Data : Use_Buffers.Buffer
              (Landin.IR.Slot_Count (Of_Unit, Item));
            Known : Use_Counts renames Known_Data.Data.all;
            Stamp : Use_Counts renames Stamp_Data.Data.all;
            Epoch : Natural := 0;
         begin
            for Index in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
               Epoch := Epoch + 1;
               for Position in 1 .. Landin.IR.Length
                 (Of_Unit, Item, Landin.IR.Block_Id (Index))
               loop
                  declare
                     Value : constant Landin.IR.Value_Id :=
                       Landin.IR.Nth_Value
                         (Of_Unit, Item, Landin.IR.Block_Id (Index),
                          Position);
                  begin
                     case Landin.IR.Op_Of (Of_Unit, Item, Value) is
                        when Landin.IR.Store =>
                           declare
                              Slot : constant Positive := Positive
                                (Landin.IR.Slot_Of (Of_Unit, Item, Value));
                              Stored : constant Landin.IR.Value_Id :=
                                Landin.IR.Nth_Operand
                                  (Of_Unit, Item, Value, 1);
                           begin
                              if Landin.IR.Op_Of (Of_Unit, Item, Stored)
                                = Landin.IR.Atom
                              then
                                 Known (Slot) := Positive (Stored);
                                 Stamp (Slot) := Epoch;
                              else
                                 Stamp (Slot) := 0;
                              end if;
                           end;
                        when Landin.IR.Load =>
                           declare
                              Slot : constant Positive := Positive
                                (Landin.IR.Slot_Of (Of_Unit, Item, Value));
                              Set : constant Landin.IR.Atom_Set_Id :=
                                Landin.IR.Atom_Set_Of (Of_Unit, Item, Value);
                           begin
                              if Stamp (Slot) = Epoch
                                and then Set /= Landin.IR.No_Atom_Set
                              then
                                 for Which in 1 .. Landin.IR.Atom_Count
                                   (Of_Unit, Set)
                                 loop
                                    if Landin.IR.Nth_Atom (Of_Unit, Set, Which)
                                      = Landin.IR.Atom_Of
                                        (Of_Unit, Item,
                                         Landin.IR.Value_Id (Known (Slot)))
                                    then
                                       Proven (Positive (Value)) := 1;
                                    end if;
                                 end loop;
                              end if;
                           end;
                        when Landin.IR.Call | Landin.IR.Indirect_Call
                           | Landin.IR.Assembly | Landin.IR.Store_Indirect
                           | Landin.IR.Store_Field | Landin.IR.Store_Element
                           | Landin.IR.Store_Datum | Landin.IR.Copy_Array
                           | Landin.IR.Copy_Variant | Landin.IR.Clear_Array
                           | Landin.IR.Fill_Array | Landin.IR.Select_Variant
                           | Landin.IR.Store_Variant_Field =>
                           Epoch := Epoch + 1;
                        when Landin.IR.Memory_Access =>
                           --  D446: another fibre runs inside a switch.
                           if Allocation.Is_Switch (Of_Unit, Item, Value)
                           then
                              Epoch := Epoch + 1;
                           end if;
                        when others => null;
                     end case;
                  end;
               end loop;
            end loop;
         end Prove_Atom_Loads;

         procedure Emit_Instruction (Value : Landin.IR.Value_Id);

         procedure Emit_Assembly (Value : Landin.IR.Value_Id);

         --  [1630] on x86-64.  No value lives in a register a block
         --  declares or overwrites -- the allocator hands out only the
         --  callee-saved five and keeps a declared one out -- so each input
         --  is loaded straight into its register, extended to the whole
         --  register as its type says, and each output is stored from its
         --  register into its slot, which is always a frame cell.  The text
         --  is recorded as written: no selection rewrites it.
         procedure Emit_Assembly (Value : Landin.IR.Value_Id) is
            package Asm renames Landin.Targets.Assembly;
            Chosen : constant Asm.Operand_Register_Array :=
              Landin.Backend.Assembly_Registers
                (Of_Unit, Item, Value, Names, Facts);
            Text : constant String := Landin.Backend.Assembly_Text
              (Of_Unit, Item, Value, Names, Facts);
            Inputs : Natural := 0;
            Start : Natural := Text'First;

            function Operand (Index : Positive)
              return Landin.IR.Assembly_Operand
              is (Landin.IR.Nth_Assembly_Operand
                    (Of_Unit, Item, Value, Index));

            function Register (Index : Positive; Bits : Positive)
              return String
              is (Asm.Spelled
                    (Facts, Unbounded.To_String (Chosen (Index).Register),
                     Landin.Targets.Bit_Width (Bits)));
         begin
            for Index in Chosen'Range loop
               if Operand (Index).Direction
                 in Landin.IR.Input | Landin.IR.Both
               then
                  Inputs := Inputs + 1;
                  declare
                     Kind : constant Landin.Types.Type_Kind :=
                       Operand (Index).Kind;
                     Held : constant Held_Size := Size_Of (Kind, Facts);
                     From : constant String := Value_Operand
                       (Landin.IR.Nth_Operand (Of_Unit, Item, Value, Inputs));
                  begin
                     case Held is
                        when Landin.Targets.Byte_8 =>
                           Emit_Verbatim
                             ("movq " & From & ", " & Register (Index, 64));
                        when Landin.Targets.Byte_4 =>
                           Emit_Verbatim
                             ((if Landin.Types.Is_Signed (Kind)
                               then "movslq " & From & ", "
                                    & Register (Index, 64)
                               else "movl " & From & ", "
                                    & Register (Index, 32)));
                        when others =>
                           Emit_Verbatim
                             ((if Landin.Types.Is_Signed (Kind)
                               then "movs" else "movz")
                              & Suffix (Held) & "q " & From & ", "
                              & Register (Index, 64));
                     end case;
                  end;
               end if;
            end loop;
            for Index in Text'First .. Text'Last + 1 loop
               if Index > Text'Last or else Text (Index) = LF then
                  declare
                     Line : constant String :=
                       Trimmed (Text (Start .. Index - 1));
                  begin
                     if Line'Length > 0 then
                        Emit_Verbatim (Line);
                     end if;
                  end;
                  Start := Index + 1;
               end if;
            end loop;
            for Index in Chosen'Range loop
               if Operand (Index).Output /= Landin.IR.No_Slot then
                  declare
                     Held : constant Held_Size :=
                       Size_Of (Operand (Index).Kind, Facts);
                  begin
                     Emit_Verbatim
                       ("mov" & Suffix (Held) & " "
                        & Register
                            (Index, Landin.Targets.Bytes (Held) * 8)
                        & ", " & Slot_Cell (Operand (Index).Output));
                  end;
               end if;
            end loop;
         end Emit_Assembly;

         procedure Emit_Instruction (Value : Landin.IR.Value_Id) is
            Op : constant Landin.IR.Opcode :=
              Landin.IR.Op_Of (Of_Unit, Item, Value);

            --  D187: this instruction is lexically inside [1120]'s region,
            --  so the edges that decision names are not emitted for it.
            --  Every other edge below is emitted whatever this says --
            --  a divisor, a shift count, a float or bool conversion and a
            --  text boundary keep their trap because their behaviour
            --  without one is not one thing on every target Landin
            --  describes.
            Unchecked : constant Boolean :=
              Landin.IR.Is_Unchecked (Of_Unit, Item, Value);

            function Operand (Index : Positive) return Landin.IR.Value_Id
              is (Landin.IR.Nth_Operand (Of_Unit, Item, Value, Index));
            procedure Emit_Panic (Reason : Landin.Panics.Kind);
            procedure Emit_Panic;
            procedure Trap_On (Jump : String; Reason : Landin.Panics.Kind);
            procedure Trap_On (Jump : String);
            function Trap (Reason : Landin.Panics.Kind) return String
              is (Trap_Label (Value, Reason));
            function Trap return String
              is (Trap (Landin.Panics.For_Value (Of_Unit, Item, Value)));
            procedure Emit_Fixed_Bounds_Check
              (Length : Landin.IR.Element_Total;
               Index : String := "%rax");

            --  A panic in line, where no passing path falls into it.
            procedure Emit_Panic (Reason : Landin.Panics.Kind) is
            begin
               Emit_Panic (Value, Reason);
            end Emit_Panic;

            procedure Emit_Panic is
            begin
               Emit_Panic (Landin.Panics.For_Value (Of_Unit, Item, Value));
            end Emit_Panic;

            --  A check's failed edge: Jump branches to this operation's
            --  trap after the body, and the passing path falls through.
            procedure Trap_On (Jump : String; Reason : Landin.Panics.Kind) is
            begin
               Queue_Trap (Value, Reason);
               Emit (Jump & " " & Trap (Reason));
            end Trap_On;

            procedure Trap_On (Jump : String) is
            begin
               Trap_On (Jump, Landin.Panics.For_Value (Of_Unit, Item, Value));
            end Trap_On;

            procedure Emit_Fixed_Bounds_Check
              (Length : Landin.IR.Element_Total;
               Index : String := "%rax") is
            begin
               --  cmpq sign-extends its imm32 operand.  A larger unsigned
               --  length must still be loaded as a full 64-bit value.
               if Machine.Fits_Arithmetic_Immediate
                 (Landin.Targets.Byte_Count (Length))
               then
                  Emit ("cmpq $" & Trimmed
                    (Landin.IR.Element_Total'Image (Length)) & ", "
                    & Index);
               else
                  Emit ("movabsq $" & Trimmed
                    (Landin.IR.Element_Total'Image (Length)) & ", %rdx");
                  Emit ("cmpq %rdx, " & Index);
               end if;
               Trap_On ("jae");
            end Emit_Fixed_Bounds_Check;

            --  Size and speed reach element Index of an array as one
            --  memory operand, `disp(%base,%index,scale)`, rather than
            --  forming its address with a multiply and two adds.  The
            --  bounds check comes first, as [0580] has it, on the index
            --  where it lives when that is a register; a stride that is
            --  no scale is multiplied into %rax after the check.  A frame
            --  array is addressed from %rbp and an array behind an address
            --  slot from that slot's register, when the place needs no
            --  further offset; any other base is formed in %rcx.
            function Indexed_Operand
              (Place : Landin.IR.Storage;
               Field : Natural;
               Which : Natural;
               Payload_Field : Natural;
               Nested : Landin.IR.Path_Step_Array;
               Index : Landin.IR.Value_Id;
               Length : Landin.IR.Element_Total;
               Stride : Landin.Targets.Byte_Count;
               Inside : Landin.Targets.Byte_Count) return String;

            function Indexed_Operand
              (Place : Landin.IR.Storage;
               Field : Natural;
               Which : Natural;
               Payload_Field : Natural;
               Nested : Landin.IR.Path_Step_Array;
               Index : Landin.IR.Value_Id;
               Length : Landin.IR.Element_Total;
               Stride : Landin.Targets.Byte_Count;
               Inside : Landin.Targets.Byte_Count) return String
            is
               use type Landin.IR.Storage_Kind;
               Own : constant Boolean :=
                 Allocation_Plan.Value (Positive (Index)).Kind
                   = Allocation.GP;
               Scaled : constant Boolean := Stride in 1 | 2 | 4 | 8;
               Checked : constant String :=
                 (if Own then Value_Operand (Index) else "%rax");
               Plain : constant Boolean :=
                 Nested'Length = 0 and then Payload_Field = 0
                 and then Machine.Fits_Arithmetic_Immediate (Inside);
               Frame_Base : constant Boolean :=
                 Plain and then Place.Kind = Landin.IR.Frame_Slot;
               Slot_Base : constant Boolean :=
                 Plain and then Place.Kind = Landin.IR.Runtime_Address
                 and then Field = 0
                 and then Allocation_Plan.Slot (Positive (Place.Address)).Kind
                   = Allocation.GP;
               Frame_Offset : constant Landin.Targets.Byte_Count :=
                 (if not Frame_Base then 0
                  elsif Field = 0
                  then Landin.Backend.Slot_Offset (Layout, Place.Slot)
                  else Landin.Backend.Field_Offset
                    (Of_Unit, Item, Layout, Place.Slot,
                     Landin.IR.Part_Position (Field), Facts));
               Displacement : constant Landin.Types.Folded :=
                 (if Plain then Landin.Types.Folded (Inside) else 0)
                 - Landin.Types.Folded (Frame_Offset);
               Base : constant String :=
                 (if Frame_Base then "%rbp"
                  elsif Slot_Base then Slot_Cell (Place.Address)
                  else "%rcx");
            begin
               if not Own then
                  Emit ("movq " & Value_Operand (Index) & ", %rax");
               end if;
               if not Unchecked then
                  Emit_Fixed_Bounds_Check (Length, Checked);
               end if;
               if Scaled then
                  null;
               elsif Machine.Fits_Arithmetic_Immediate (Stride) then
                  Emit ("imulq $"
                        & Trimmed (Landin.Targets.Byte_Count'Image (Stride))
                        & ", " & Checked & ", %rax");
               else
                  if Own then
                     Emit ("movq " & Checked & ", %rax");
                  end if;
                  Emit ("movabsq $"
                        & Trimmed (Landin.Targets.Byte_Count'Image (Stride))
                        & ", %rdx");
                  Emit ("imulq %rdx, %rax");
               end if;
               if Frame_Base and then not Has_Slot_Home (Layout, Place.Slot)
               then
                  raise Landin.Compiler_Defect with
                    "an unhomed storage slot was addressed";
               elsif not Frame_Base and then not Slot_Base then
                  Storage_Address
                    (Place, Field, "%rcx", Which, Payload_Field, Nested);
                  if not Plain then
                     Add_Storage_Offset (Inside, "%rcx");
                  end if;
               end if;
               return (if Displacement = 0 then ""
                       else Trimmed (Landin.Types.Folded'Image
                                       (Displacement)))
                 & "(" & Base & ","
                 & (if Scaled and then Own then Checked else "%rax")
                 & (if Scaled and then Stride > 1
                    then "," & Trimmed (Landin.Targets.Byte_Count'Image
                                          (Stride))
                    else "")
                 & ")";
            end Indexed_Operand;

            --  An address this instruction computes, as Address, a memory
            --  operand: handed to the next instruction when that is the
            --  one indirect access through it, else formed with `leaq`.
            procedure Deliver_Address (Address : String);

            --  The memory operand an indirect access reads or writes
            --  through: the address an earlier instruction folded into it,
            --  or at size and speed the register its address lives in, or
            --  else %rcx loaded with that address.
            function Indirect_Operand return String;

            --  Size and speed form a place's address where its value
            --  lives, or hand it to the one access using it.
            procedure Place_Address
              (Place : Landin.IR.Storage;
               Field : Natural;
               Nested : Landin.IR.Path_Step_Array);

            procedure Deliver_Address (Address : String) is
               Fold : constant Address_Fold :=
                 Fold_Of (Of_Unit, Item, Current_Block, Current_Position,
                          Uses, References);
            begin
               if Fold.Access_Value /= Landin.IR.No_Value then
                  Skipped_Store := Fold.Store;
                  Skipped_Load := Fold.Load;
                  Folded_User := Fold.Access_Value;
                  Folded_Address := Unbounded.To_Unbounded_String (Address);
               elsif Allocation_Plan.Value (Positive (Value)).Kind
                 = Allocation.GP
               then
                  Emit ("leaq " & Address & ", " & Value_Operand (Value));
               else
                  Emit ("leaq " & Address & ", %rax");
                  Carry (Landin.Targets.Byte_8, "%rax", Value_Operand (Value));
               end if;
            end Deliver_Address;

            procedure Place_Address
              (Place : Landin.IR.Storage;
               Field : Natural;
               Nested : Landin.IR.Path_Step_Array)
            is
               use type Landin.IR.Storage_Kind;
               --  What Storage_Address adds to an address slot's address:
               --  the field, then the run below it.
               Offset : constant Landin.Targets.Byte_Count :=
                 (if Place.Kind /= Landin.IR.Runtime_Address then 0
                  else (if Field = 0 then 0
                        else Path_Offset
                          (Landin.IR.Address_Shape
                             (Of_Unit, Item, Place.Address),
                           [1 => (Field => Landin.IR.Part_Position (Field),
                                  Case_Index => 0)]))
                     + (if Nested'Length = 0 then 0
                        else Path_Offset
                          (Root_Shape_Of (Place, Field), Nested)));
            begin
               if Fold_Of (Of_Unit, Item, Current_Block, Current_Position,
                           Uses, References).Access_Value
                 /= Landin.IR.No_Value
               then
                  if Place.Kind = Landin.IR.Runtime_Address
                    and then Allocation_Plan.Slot
                      (Positive (Place.Address)).Kind = Allocation.GP
                    and then Machine.Fits_Arithmetic_Immediate (Offset)
                  then
                     Deliver_Address
                       ((if Offset = 0 then ""
                         else Trimmed
                           (Landin.Targets.Byte_Count'Image (Offset)))
                        & "(" & Slot_Cell (Place.Address) & ")");
                  else
                     Storage_Address (Place, Field, "%rcx", Nested => Nested);
                     Deliver_Address ("(%rcx)");
                  end if;
               elsif Allocation_Plan.Value (Positive (Value)).Kind
                 = Allocation.GP
               then
                  Storage_Address
                    (Place, Field, Value_Operand (Value), Nested => Nested);
               else
                  Storage_Address (Place, Field, "%rax", Nested => Nested);
                  Carry (Landin.Targets.Byte_8, "%rax", Value_Operand (Value));
               end if;
            end Place_Address;

            function Indirect_Operand return String is
            begin
               if Folded_User = Value then
                  Folded_User := Landin.IR.No_Value;
                  return Unbounded.To_String (Folded_Address);
               elsif Optimized
                 and then Allocation_Plan.Value (Positive (Operand (1))).Kind
                   = Allocation.GP
               then
                  return "(" & Value_Operand (Operand (1)) & ")";
               end if;
               Emit ("movq " & Value_Operand (Operand (1)) & ", %rcx");
               return "(%rcx)";
            end Indirect_Operand;

            --  Size and speed compute an operation where its result lives
            --  when that is a register: the left operand moves there and
            --  the operation applies the right one to it, so nothing passes
            --  through the accumulator.  That register is never one where
            --  an operand still to be read lives: a result in the right
            --  operand's register applies the left one instead when the
            --  operation commutes, and is otherwise computed in the
            --  accumulator, as a result in memory is.  A product by an
            --  immediate is `imul`'s three-operand form.  Check, when not
            --  empty, branches to this operation's trap straight after the
            --  operation, on the flags it set, wherever it computed.
            procedure Integer_Binary
              (Instruction : String; Commutes : Boolean; Check : String);

            --  The same for one operand, Instruction naming the operation
            --  up to the register it applies to.
            procedure Integer_Unary (Instruction : String; Check : String);

            --  The same for SSE arithmetic, whose operations are not
            --  commuted: with both operands NaN, the first one's payload is
            --  the one that survives.
            procedure Float_Binary (Instruction : String);

            procedure Integer_Binary
              (Instruction : String; Commutes : Boolean; Check : String)
            is
               Held : constant Held_Size := Size_Of_Value (Value);
               Left : constant String := Value_Operand (Operand (1));
               Right : constant String := Source_Operand (Operand (2));
               Into : constant String := Value_Operand (Value);
               In_Place : constant Boolean := Optimized
                 and then Allocation_Plan.Value (Positive (Value)).Kind
                   = Allocation.GP;
               Operation : constant String :=
                 Instruction & Suffix (Held) & " ";
               Immediate_Product : constant Boolean :=
                 Instruction = "imul" and then Right (Right'First) = '$';
               Clear : constant Boolean := Right /= Into or else Left = Into;
               Direct : constant Boolean :=
                 In_Place and then (Clear or else Commutes);
               Target : constant String :=
                 (if Direct then Into else Accumulator (Held));
            begin
               if Immediate_Product then
                  Emit (Operation & Right & ", " & Left & ", " & Target);
               elsif Direct and then Clear then
                  Carry (Held, Left, Into);
                  Emit (Operation & Right & ", " & Into);
               elsif Direct then
                  Emit (Operation & Left & ", " & Into);
               else
                  Load_Value (Operand (1));
                  Emit (Operation & Right & ", " & Target);
               end if;
               if Check /= "" then
                  Trap_On (Check);
               end if;
               if not Direct then
                  Store_Value (Value, Target);
               end if;
            end Integer_Binary;

            procedure Integer_Unary (Instruction : String; Check : String)
            is
               Held : constant Held_Size := Size_Of_Value (Value);
               Into : constant String := Value_Operand (Value);
               In_Place : constant Boolean := Optimized
                 and then Allocation_Plan.Value (Positive (Value)).Kind
                   = Allocation.GP;
               Target : constant String :=
                 (if In_Place then Into else Accumulator (Held));
            begin
               if In_Place then
                  Carry (Held, Value_Operand (Operand (1)), Into);
               else
                  Load_Value (Operand (1));
               end if;
               if Instruction /= "" then
                  Emit (Instruction & Target);
               end if;
               if Check /= "" then
                  Trap_On (Check);
               end if;
               if not In_Place then
                  Store_Value (Value, Target);
               end if;
            end Integer_Unary;

            procedure Float_Binary (Instruction : String) is
               Held : constant Held_Size := Size_Of_Value (Value);
               Single : constant Boolean := Held = Landin.Targets.Byte_4;
               Left : constant String := Value_Operand (Operand (1));
               Right : constant String := Value_Operand (Operand (2));
               Into : constant String := Value_Operand (Value);
            begin
               if Optimized
                 and then Allocation_Plan.Value (Positive (Value)).Kind
                   = Allocation.SSE
                 and then (Right /= Into or else Left = Into)
               then
                  Carry (Held, Left, Into);
                  Emit (Instruction & " " & Right & ", " & Into);
               else
                  Emit (Float_Move (Single, Left, "%xmm0"));
                  Emit (Instruction & " " & Right & ", %xmm0");
                  Emit (Float_Move (Single, "%xmm0", Into));
               end if;
            end Float_Binary;

            procedure Packed_Atom
              (Set_Id : Landin.IR.Atom_Set_Id; Encode : Boolean);

            procedure Packed_Atom
              (Set_Id : Landin.IR.Atom_Set_Id; Encode : Boolean)
            is
               use type Landin.Packed.Image;
               Done : constant String := Value_Label (Value) & "_encoded";
               Table : constant String := Done & "_table";
               Search : constant String := Done & "_search";
               Lower : constant String := Done & "_lower";
               Found : constant String := Done & "_found";
               Count : constant Natural :=
                 (if Set_Id = Landin.IR.No_Atom_Set then 0
                  else Landin.IR.Atom_Count (Of_Unit, Set_Id));
               type Mapping is record
                  From, Into : Landin.Packed.Image;
               end record;
               Mappings : array (1 .. Count) of Mapping;
            begin
               if Set_Id = Landin.IR.No_Atom_Set then
                  return;
               end if;
               for Index in Mappings'Range loop
                  declare
                     Code : constant Landin.Packed.Image := Landin.Packed.Image
                       (Atom_Code (Atoms_Ranked,
                        Landin.IR.Nth_Atom (Of_Unit, Set_Id, Index)));
                     Raw : constant Landin.Packed.Image :=
                       Landin.IR.Nth_Encoding (Of_Unit, Set_Id, Index);
                  begin
                     Mappings (Index) :=
                       (From => (if Encode then Code else Raw),
                        Into => (if Encode then Raw else Code));
                  end;
               end loop;

               --  A few names cost less as direct comparisons than as a
               --  search setup.  This path has a fixed maximum of four.
               if Count <= 4 then
                  for Index in Mappings'Range loop
                     declare
                        Next : constant String := Done & "_"
                          & Trimmed (Natural'Image (Index));
                     begin
                        Emit ("movabsq $" & Trimmed
                          (Landin.Packed.Image'Image (Mappings (Index).From))
                          & ", %r11");
                        Emit ("cmpq %r11, %rax");
                        if Index = Mappings'Last then
                           Trap_On ("jne", Landin.Panics.Bad_Conversion);
                        else
                           Emit ("jne " & Next);
                        end if;
                        Emit ("movabsq $" & Trimmed
                          (Landin.Packed.Image'Image (Mappings (Index).Into))
                          & ", %rax");
                        if Index < Mappings'Last then
                           Emit ("jmp " & Done);
                           Put (Next & ":");
                        end if;
                     end;
                  end loop;
                  if Count = 0 then
                     Emit_Panic (Landin.Panics.Bad_Conversion);
                  end if;
                  Put (Done & ":");
                  return;
               end if;

               --  Sort once at compile time.  The search's instruction
               --  count is independent of the number of atom names; each
               --  entry adds only two 64-bit table words.  Unsigned `jb`
               --  keeps full-width encodings in their bit-pattern order.
               for Index in 2 .. Count loop
                  declare
                     Current : constant Mapping := Mappings (Index);
                     Position : Positive := Index;
                  begin
                     while Position > 1 and then
                       Mappings (Position - 1).From > Current.From
                     loop
                        Mappings (Position) := Mappings (Position - 1);
                        Position := Position - 1;
                     end loop;
                     Mappings (Position) := Current;
                  end;
               end loop;

               Has_Inline_Map_Table (Positive (Item)) := True;
               Emit ("jmp " & Search);
               Emit (".p2align 3");
               Put (Table & ":");
               for Pair of Mappings loop
                  Emit (".quad " & Trimmed
                    (Landin.Packed.Image'Image (Pair.From)) & ", "
                    & Trimmed (Landin.Packed.Image'Image (Pair.Into)));
               end loop;
               Put (Search & ":");
               Emit ("leaq " & Table & "(%rip), %r11");
               Emit ("xorl %r8d, %r8d");
               Emit ("movl $" & Trimmed (Natural'Image (Count))
                 & ", %edx");
               declare
                  Loop_Label : constant String := Done & "_loop";
               begin
                  Put (Loop_Label & ":");
                  Emit ("cmpq %rdx, %r8");
                  Trap_On ("jae", Landin.Panics.Bad_Conversion);
                  Emit ("leaq (%r8,%rdx), %r9");
                  Emit ("shrq $1, %r9");
                  Emit ("shlq $4, %r9");
                  Emit ("cmpq (%r11,%r9), %rax");
                  Emit ("je " & Found);
                  Emit ("jb " & Lower);
                  Emit ("shrq $4, %r9");
                  Emit ("leaq 1(%r9), %r8");
                  Emit ("jmp " & Loop_Label);
                  Put (Lower & ":");
                  Emit ("shrq $4, %r9");
                  Emit ("movq %r9, %rdx");
                  Emit ("jmp " & Loop_Label);
               end;
               Put (Found & ":");
               Emit ("movq 8(%r11,%r9), %rax");
               Put (Done & ":");
            end Packed_Atom;
         begin
            if Value = Skipped_Store or else Value = Skipped_Load then
               return;
            end if;
            case Op is
               when Landin.IR.Assembly =>
                  Emit_Assembly (Value);
               when Landin.IR.Number =>
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Size : constant Landin.Types.Scalar_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Digits_Of : constant Landin.Types.Magnitude :=
                       Landin.IR.Number_Of (Of_Unit, Item, Value);
                     Width : constant Landin.Targets.Bit_Width :=
                       (if Size in Landin.Types.Float_Name
                        then Landin.Types.Float_Width
                          (Landin.Types.Float_Name (Size))
                        else Landin.Types.Width
                          (Landin.Types.Integer_Name (Size), Facts));
                     Highest : constant Landin.Types.Magnitude :=
                       (if Width = 64
                        then Landin.Types.Magnitude'Last
                        else 2 ** Natural (Width) - 1);
                     --  [1770]'s magnitude and [1880]'s minus are carried
                     --  apart, so the two's complement pattern is formed
                     --  here, where a width finally exists.  The checker
                     --  has already refused a literal the type cannot
                     --  hold, so no masking is needed above the negation.
                     Pattern : constant Landin.Types.Magnitude :=
                       (if Size in Landin.Types.Float_Name
                        then Digits_Of
                        elsif not Landin.IR.Is_Negated (Of_Unit, Item, Value)
                          or else Digits_Of = 0
                        then Digits_Of
                        else Highest - Digits_Of + 1);
                     Place : Allocation.Location renames
                       Allocation_Plan.Value (Positive (Value));
                     Constant_Image : constant String :=
                       Source_Operand (Value);
                  begin
                     --  Size and speed put a constant straight where it
                     --  lives: one used only as an immediate lives nowhere,
                     --  one that fits an immediate is moved as one, and a
                     --  zero float is cleared in its XMM register.
                     if Optimized and then Place.Kind = Allocation.Absent then
                        null;
                     elsif Optimized
                       and then Constant_Image (Constant_Image'First) = '$'
                     then
                        Emit (Move (Held, Constant_Image,
                                    Value_Operand (Value)));
                     elsif Optimized and then Place.Kind = Allocation.GP then
                        Emit ("movabsq $"
                              & Trimmed
                                  (Landin.Types.Magnitude'Image (Pattern))
                              & ", " & Value_Operand (Value));
                     elsif Optimized and then Place.Kind = Allocation.SSE
                       and then Pattern = 0
                     then
                        Emit ("xorps " & Value_Operand (Value) & ", "
                              & Value_Operand (Value));
                     else
                        Emit ("movabsq $"
                              & Trimmed
                                  (Landin.Types.Magnitude'Image (Pattern))
                              & ", %rax");
                        Store_Value (Value, Accumulator (Held));
                     end if;
                  end;

               when Landin.IR.Measurement_Kind =>
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
                          (if Op /= Landin.IR.Measure_Align
                           then Landin.Targets.Byte_Count'Image (Size)
                           else Landin.Targets.Byte_Alignment'Image
                                  (Alignment));
                     begin
                        Emit
                          ("movabsq $" & Trimmed (Answer) & ", %rax");
                        Emit
                          ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Operand (Value));
                     end;
                  end;

               when Landin.IR.Truth =>
                  --  [1870]'s two literals, and the one byte
                  --  Landin.Backend gives a bool.
                  Emit ("movb $"
                        & (if Landin.IR.Truth_Of (Of_Unit, Item, Value)
                           then "1" else "0")
                        & ", " & Value_Operand (Value));

               when Landin.IR.Atom =>
                  Emit
                    ("movl $"
                     & Trimmed
                         (Positive'Image
                            (Atom_Code
                               (Atoms_Ranked,
                                Landin.IR.Atom_Of
                                  (Of_Unit, Item, Value))))
                     & ", " & Value_Operand (Value));

               when Landin.IR.Place_Address =>
                  declare
                     Place : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                  begin
                     if Optimized then
                        Place_Address (Place, Field, Nested);
                        return;
                     end if;
                     Storage_Address
                       (Place, Field, "%rax", Nested => Nested);
                     Carry
                       (Landin.Targets.Byte_8, "%rax", Value_Operand (Value));
                  end;

               when Landin.IR.Storage_Address =>
                  declare
                     Place : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                  begin
                     if Optimized and then not
                       Landin.IR.Storage_Address_Has_Index
                         (Of_Unit, Item, Value)
                     then
                        Place_Address (Place, Field, Nested);
                     elsif not Landin.IR.Storage_Address_Has_Index
                       (Of_Unit, Item, Value)
                     then
                        Storage_Address
                          (Place, Field, "%rax", Nested => Nested);
                        Carry
                          (Landin.Targets.Byte_8, "%rax",
                           Value_Operand (Value));
                     elsif Optimized then
                        Deliver_Address
                          (Indexed_Operand
                             (Place, Field, 0, 0, Nested, Operand (1),
                              Array_Length_Of
                                (Place, Field, Nested => Nested),
                              Element_Bytes_Of
                                (Place, Field, Nested => Nested),
                              0));
                     else
                        Storage_Address
                          (Place, Field, "%rcx", Nested => Nested);
                        declare
                           Index : constant Landin.IR.Value_Id :=
                             Operand (1);
                           Length : constant Landin.IR.Element_Total :=
                             Array_Length_Of
                               (Place, Field, Nested => Nested);
                           Stride : constant Landin.Targets.Byte_Count :=
                             Element_Bytes_Of
                               (Place, Field, Nested => Nested);
                        begin
                           Emit ("movq " & Value_Operand (Index) & ", %rax");
                           --  D187 leaves the access at the computed
                           --  address, which is [0430]'s existing pointer
                           --  non-guarantee and nothing worse.
                           if not Unchecked then
                              Emit_Fixed_Bounds_Check (Length);
                           end if;
                           if Stride = 1 then
                              null;
                           elsif Machine.Fits_Arithmetic_Immediate
                             (Stride)
                           then
                              Emit
                                ("imulq $"
                                 & Trimmed
                                     (Landin.Targets.Byte_Count'Image
                                        (Stride))
                                 & ", %rax, %rax");
                           else
                              Emit
                                ("movabsq $"
                                 & Trimmed
                                     (Landin.Targets.Byte_Count'Image
                                        (Stride))
                                 & ", %rdx");
                              Emit ("imulq %rdx, %rax");
                           end if;
                           Emit ("addq %rax, %rcx");
                           Carry
                             (Landin.Targets.Byte_8, "%rcx",
                              Value_Operand (Value));
                        end;
                     end if;
                  end;

               when Landin.IR.Pointer_Address | Landin.IR.Code_Address =>
                  Carry
                    (Landin.Targets.Byte_8,
                     Value_Operand (Operand (1)), Value_Operand (Value));

               when Landin.IR.Conversion =>
                  declare
                     Source : constant Landin.IR.Value_Id := Operand (1);
                     From_Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Source);
                     Into_Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                  begin
                     if From_Kind in Landin.Types.Float_Name
                       and then Into_Kind in Landin.Types.Float_Name
                     then
                        declare
                           From : constant Landin.Types.Float_Name :=
                             Landin.Types.Float_Name (From_Kind);
                           Into_Type : constant Landin.Types.Float_Name :=
                             Landin.Types.Float_Name (Into_Kind);
                        begin
                           if From = Into_Type then
                              Carry
                                (Size_Of (From, Facts), Value_Operand (Source),
                                 Value_Operand (Value));
                           elsif From = Landin.Types.F32 then
                              Emit
                                (Float_Move
                                   (True, Value_Operand (Source), "%xmm0"));
                              Emit ("cvtss2sd %xmm0, %xmm0");
                              Emit
                                (Float_Move
                                   (False, "%xmm0", Value_Operand (Value)));
                           else
                              declare
                                 Safe : constant String :=
                                   Value_Label (Value) & "_finite";
                              begin
                                 Emit
                                   (Float_Move
                                      (False, Value_Operand (Source),
                                       "%xmm0"));
                                 Emit ("cvtsd2ss %xmm0, %xmm0");
                                 --  Infinity and NaN are values of both
                                 --  widths.  Only a finite source which
                                 --  rounded to infinity must trap [0310].
                                 Emit ("movd %xmm0, %eax");
                                 Emit ("andl $2139095040, %eax");
                                 Emit ("cmpl $2139095040, %eax");
                                 Emit ("jne " & Safe);
                                 Emit
                                   ("movq " & Value_Operand (Source)
                                    & ", %rdx");
                                 Emit
                                   ("movabsq $9218868437227405312, %rax");
                                 Emit ("movq %rdx, %rcx");
                                 Emit ("andq %rax, %rcx");
                                 Emit ("cmpq %rax, %rcx");
                                 Trap_On ("jne");
                                 Put (Safe & ":");
                                 Emit
                                   (Float_Move
                                      (True, "%xmm0", Value_Operand (Value)));
                              end;
                           end if;
                        end;
                     elsif From_Kind = Landin.Types.Bool
                       and then Into_Kind in Landin.Types.Float_Name
                     then
                        declare
                           Into_Type : constant Landin.Types.Float_Name :=
                             Landin.Types.Float_Name (Into_Kind);
                           Convert : constant String :=
                             (if Into_Type = Landin.Types.F32
                              then "cvtsi2ssq" else "cvtsi2sdq");
                        begin
                           Load_Unsigned (Source, Landin.Targets.Byte_1);
                           Emit (Convert & " %rax, %xmm0");
                           Emit
                             (Float_Move
                                (Into_Type = Landin.Types.F32,
                                 "%xmm0", Value_Operand (Value)));
                        end;
                     elsif Into_Kind in Landin.Types.Float_Name then
                        declare
                           From : constant Landin.Types.Integer_Name :=
                             Landin.Types.Integer_Name (From_Kind);
                           Into_Type : constant Landin.Types.Float_Name :=
                             Landin.Types.Float_Name (Into_Kind);
                           From_Size : constant Held_Size :=
                             Size_Of (From, Facts);
                           High_Unsigned : constant String :=
                             Value_Label (Value) & "_unsigned";
                           Converted : constant String :=
                             Value_Label (Value) & "_converted";
                           Convert : constant String :=
                             (if Into_Type = Landin.Types.F32
                              then "cvtsi2ssq" else "cvtsi2sdq");
                           Add : constant String :=
                             (if Into_Type = Landin.Types.F32
                              then "addss" else "addsd");
                        begin
                           if Landin.Types.Is_Signed (From) then
                              Emit
                                ((case From_Size is
                                    when Landin.Targets.Byte_1 => "movsbq ",
                                    when Landin.Targets.Byte_2 => "movswq ",
                                    when Landin.Targets.Byte_4 => "movslq ",
                                    when Landin.Targets.Byte_8 => "movq ")
                                 & Value_Operand (Source) & ", %rax");
                           else
                              Load_Unsigned (Source, From_Size);
                           end if;

                           if not Landin.Types.Is_Signed (From)
                             and then From_Size = Landin.Targets.Byte_8
                           then
                              --  SSE converts a signed qword.  For the upper
                              --  half of u64, convert the sticky half and
                              --  double it; this is the same nearest-even
                              --  answer as converting the unsigned value.
                              Emit ("testq %rax, %rax");
                              Emit ("js " & High_Unsigned);
                              Emit (Convert & " %rax, %xmm0");
                              Emit ("jmp " & Converted);
                              Put (High_Unsigned & ":");
                              Emit ("movq %rax, %rdx");
                              Emit ("shrq $1, %rax");
                              Emit ("andq $1, %rdx");
                              Emit ("orq %rdx, %rax");
                              Emit (Convert & " %rax, %xmm0");
                              Emit (Add & " %xmm0, %xmm0");
                              Put (Converted & ":");
                           else
                              Emit (Convert & " %rax, %xmm0");
                           end if;
                           Emit
                             (Float_Move
                                (Into_Type = Landin.Types.F32,
                                 "%xmm0", Value_Operand (Value)));
                        end;
                     elsif Into_Kind = Landin.Types.Bool then
                        if From_Kind in Landin.Types.Float_Name then
                           declare
                              From : constant Landin.Types.Float_Name :=
                                Landin.Types.Float_Name (From_Kind);
                              False_Value : constant String :=
                                Value_Label (Value) & "_false";
                              Store : constant String :=
                                Value_Label (Value) & "_bool";
                              Magnitude_Mask : constant
                                Landin.Types.Magnitude :=
                                  (case From is
                                      when Landin.Types.F32 =>
                                        2_147_483_647,
                                      when Landin.Types.F64 =>
                                        9_223_372_036_854_775_807);
                              One : constant Landin.Types.Magnitude :=
                                (case From is
                                    when Landin.Types.F32 =>
                                      1_065_353_216,
                                    when Landin.Types.F64 =>
                                      4_607_182_418_800_017_408);
                           begin
                              Emit
                                ((if From = Landin.Types.F32
                                  then "movl " else "movq ")
                                 & Value_Operand (Source)
                                 & (if From = Landin.Types.F32
                                    then ", %eax" else ", %rax"));
                              Emit ("movq %rax, %rdx");
                              Emit
                                ("movabsq $"
                                 & Trimmed
                                     (Landin.Types.Magnitude'Image
                                        (Magnitude_Mask))
                                 & ", %rcx");
                              Emit ("andq %rcx, %rdx");
                              Emit ("testq %rdx, %rdx");
                              Emit ("jz " & False_Value);
                              Emit
                                ("movabsq $"
                                 & Trimmed
                                     (Landin.Types.Magnitude'Image (One))
                                 & ", %rcx");
                              Emit ("cmpq %rcx, %rax");
                              Trap_On ("jne");
                              Emit ("movq $1, %rax");
                              Emit ("jmp " & Store);
                              Put (False_Value & ":");
                              Emit ("movq $0, %rax");
                              Put (Store & ":");
                              Emit
                                ("movb %al, " & Value_Operand (Value));
                           end;
                        else
                           declare
                              From : constant Landin.Types.Integer_Name :=
                                Landin.Types.Integer_Name (From_Kind);
                              From_Size : constant Held_Size :=
                                Size_Of (From, Facts);
                           begin
                              Load_Unsigned (Source, From_Size);
                              Emit ("cmpq $1, %rax");
                              Trap_On ("ja");
                              Emit
                                ("movb %al, " & Value_Operand (Value));
                           end;
                        end if;
                     elsif From_Kind = Landin.Types.Bool then
                        declare
                           Into_Type : constant Landin.Types.Integer_Name :=
                             Landin.Types.Integer_Name (Into_Kind);
                           Into_Size : constant Held_Size :=
                             Size_Of (Into_Type, Facts);
                        begin
                           Load_Unsigned (Source, Landin.Targets.Byte_1);
                           Emit ("mov" & Suffix (Into_Size) & " "
                                 & Accumulator (Into_Size) & ", "
                                 & Value_Operand (Value));
                        end;
                     elsif From_Kind in Landin.Types.Float_Name then
                        declare
                           From : constant Landin.Types.Float_Name :=
                             Landin.Types.Float_Name (From_Kind);
                           Into_Type : constant Landin.Types.Integer_Name :=
                             Landin.Types.Integer_Name (Into_Kind);
                           Into_Size : constant Held_Size :=
                             Size_Of (Into_Type, Facts);
                           Into_Bits : constant Landin.Targets.Bit_Width :=
                             Landin.Types.Width (Into_Type, Facts);
                           Fraction_Bits : constant Natural :=
                             (case From is
                                 when Landin.Types.F32 => 23,
                                 when Landin.Types.F64 => 52);
                           Exponent_All : constant Natural :=
                             (case From is
                                 when Landin.Types.F32 => 255,
                                 when Landin.Types.F64 => 2_047);
                           Bias : constant Natural :=
                             (case From is
                                 when Landin.Types.F32 => 127,
                                 when Landin.Types.F64 => 1_023);
                           Sign_Shift : constant Natural :=
                             (case From is
                                 when Landin.Types.F32 => 31,
                                 when Landin.Types.F64 => 63);
                           Fraction_Mask : constant
                             Landin.Types.Magnitude :=
                               (case From is
                                   when Landin.Types.F32 => 8_388_607,
                                   when Landin.Types.F64 =>
                                     4_503_599_627_370_495);
                           Hidden : constant Landin.Types.Magnitude :=
                             2 ** Fraction_Bits;
                           Shift_Right : constant String :=
                             Value_Label (Value) & "_right";
                           Magnitude_Ready : constant String :=
                             Value_Label (Value) & "_magnitude";
                           Negative : constant String :=
                             Value_Label (Value) & "_negative";
                           Zero : constant String :=
                             Value_Label (Value) & "_zero";
                           Store : constant String :=
                             Value_Label (Value) & "_store";
                        begin
                           --  Decode the IEEE carrier rather than relying on
                           --  cvttss2si/cvttsd2si: those instructions cannot
                           --  distinguish every valid u64 result from their
                           --  indefinite overflow result.  This is exactly
                           --  the target-neutral truncation and range check.
                           --  Every failed edge below branches to one trap.
                           Queue_Trap
                             (Value,
                              Landin.Panics.For_Value (Of_Unit, Item, Value));
                           Load_Value (Source);
                           if Options.Optimize = Landin.Optimization.Size
                           then
                              Float_Decode_Used (From) := True;
                              --  The helper is a leaf: its return address.
                              Deepest_Area := Landin.Targets.Byte_Count'Max
                                (Deepest_Area, 8);
                              Emit ("call " & Float_Decode_Label (From));
                              Emit ("jc " & Trap);
                           else
                              Emit ("movq %rax, %r8");
                              Emit
                                ("shrq $"
                                 & Trimmed (Natural'Image (Sign_Shift))
                                 & ", %r8");
                              Emit ("movq %rax, %rcx");
                              Emit
                                ("shrq $"
                                 & Trimmed (Natural'Image (Fraction_Bits))
                                 & ", %rcx");
                              Emit
                                ("andq $"
                                 & Trimmed (Natural'Image (Exponent_All))
                                 & ", %rcx");
                              Emit ("movq %rax, %rdx");
                              Emit
                                ("movabsq $"
                                 & Trimmed
                                     (Landin.Types.Magnitude'Image
                                        (Fraction_Mask))
                                 & ", %r9");
                              Emit ("andq %r9, %rdx");

                              Emit
                                ("cmpq $"
                                 & Trimmed (Natural'Image (Exponent_All))
                                 & ", %rcx");
                              Emit ("je " & Trap);
                              Emit ("testq %rcx, %rcx");
                              Emit ("jz " & Zero);
                              Emit
                                ("cmpq $" & Trimmed (Natural'Image (Bias))
                                 & ", %rcx");
                              Emit ("jb " & Zero);
                              Emit
                                ("subq $" & Trimmed (Natural'Image (Bias))
                                 & ", %rcx");
                              Emit ("cmpq $63, %rcx");
                              Emit ("ja " & Trap);
                              Emit
                                ("movabsq $"
                                 & Trimmed
                                     (Landin.Types.Magnitude'Image (Hidden))
                                 & ", %r9");
                              Emit ("addq %r9, %rdx");
                              Emit
                                ("cmpq $"
                                 & Trimmed (Natural'Image (Fraction_Bits))
                                 & ", %rcx");
                              Emit ("jb " & Shift_Right);
                              Emit
                                ("subq $"
                                 & Trimmed (Natural'Image (Fraction_Bits))
                                 & ", %rcx");
                              Emit ("shlq %cl, %rdx");
                              Emit ("jmp " & Magnitude_Ready);
                              Put (Shift_Right & ":");
                              Emit
                                ("movq $"
                                 & Trimmed (Natural'Image (Fraction_Bits))
                                 & ", %r9");
                              Emit ("subq %rcx, %r9");
                              Emit ("movq %r9, %rcx");
                              Emit ("shrq %cl, %rdx");

                              Put (Magnitude_Ready & ":");
                           end if;
                           Emit ("testq %rdx, %rdx");
                           Emit ("jz " & Zero);
                           Emit ("testq %r8, %r8");
                           Emit ("jnz " & Negative);
                           if Landin.Types.Is_Signed (Into_Type)
                             or else Into_Bits < 64
                           then
                              declare
                                 Maximum : constant Landin.Types.Magnitude :=
                                   (if Landin.Types.Is_Signed (Into_Type)
                                    then 2 ** (Natural (Into_Bits) - 1) - 1
                                    else 2 ** Natural (Into_Bits) - 1);
                              begin
                                 Emit
                                   ("movabsq $"
                                    & Trimmed
                                        (Landin.Types.Magnitude'Image
                                           (Maximum))
                                    & ", %r9");
                                 Emit ("cmpq %r9, %rdx");
                                 Emit ("ja " & Trap);
                              end;
                           end if;
                           Emit ("jmp " & Store);

                           Put (Negative & ":");
                           if Landin.Types.Is_Signed (Into_Type) then
                              declare
                                 Maximum : constant Landin.Types.Magnitude :=
                                   2 ** (Natural (Into_Bits) - 1);
                              begin
                                 Emit
                                   ("movabsq $"
                                    & Trimmed
                                        (Landin.Types.Magnitude'Image
                                           (Maximum))
                                    & ", %r9");
                                 Emit ("cmpq %r9, %rdx");
                                 Emit ("ja " & Trap);
                                 Emit ("negq %rdx");
                                 Emit ("jmp " & Store);
                              end;
                           else
                              Emit ("jmp " & Trap);
                           end if;

                           Put (Zero & ":");
                           Emit ("xorq %rdx, %rdx");
                           Put (Store & ":");
                           Emit ("movq %rdx, %rax");
                           Emit ("mov" & Suffix (Into_Size) & " "
                                 & Accumulator (Into_Size) & ", "
                                 & Value_Operand (Value));
                        end;
                     else
                        declare
                           From : constant Landin.Types.Integer_Name :=
                             Landin.Types.Integer_Name (From_Kind);
                           Into_Type : constant Landin.Types.Integer_Name :=
                             Landin.Types.Integer_Name (Into_Kind);
                           From_Size : constant Held_Size :=
                             Size_Of (From, Facts);
                           Into_Size : constant Held_Size :=
                             Size_Of (Into_Type, Facts);
                           Into_Bits : constant Landin.Targets.Bit_Width :=
                             Landin.Types.Width (Into_Type, Facts);
                           From_Bits : constant Natural :=
                             Natural (Landin.Types.Width (From, Facts));
                           --  The source type's own bounds.  Size and speed
                           --  leave out an edge no value of it can take.
                           From_Low : constant Landin.Types.Folded :=
                             (if Landin.Types.Is_Signed (From)
                              then -(2 ** (From_Bits - 1)) else 0);
                           From_High : constant Landin.Types.Folded :=
                             (if Landin.Types.Is_Signed (From)
                              then 2 ** (From_Bits - 1) - 1
                              else (2 ** (From_Bits - 1) - 1) * 2 + 1);
                           --  Size and speed widen straight into a result
                           --  held in a register, and check it there.
                           Direct : constant Boolean :=
                             Optimized and then Into_Size >= From_Size
                             and then Allocation_Plan.Value
                               (Positive (Value)).Kind = Allocation.GP;
                           Work : constant String :=
                             (if Direct
                              then Allocation.Name
                                (Allocation_Plan.Value
                                   (Positive (Value)).Register,
                                 Landin.Targets.Byte_8)
                              else "%rax");

                           --  Whether a source value may lie below Low, or
                           --  above High: always so at none.
                           function Below
                             (Low : Landin.Types.Folded) return Boolean
                           is (not Optimized or else From_Low < Low);
                           function Above
                             (High : Landin.Types.Folded) return Boolean
                           is (not Optimized or else From_High > High);

                           --  Work compared with Bound at 64 bits, as
                           --  Compare_Accumulator does for %rax.
                           procedure Compare_Work
                             (Bound : Landin.Types.Folded);

                           procedure Compare_Work
                             (Bound : Landin.Types.Folded) is
                           begin
                              if Direct and then Bound in -(2 ** 31)
                                                          .. 2 ** 31 - 1
                              then
                                 Emit ("cmpq $" & Trimmed
                                   (Landin.Types.Folded'Image (Bound))
                                   & ", " & Work);
                              elsif Direct then
                                 Emit ("movabsq $" & Trimmed
                                   (Landin.Types.Folded'Image (Bound))
                                   & ", %rcx");
                                 Emit ("cmpq %rcx, " & Work);
                              else
                                 Compare_Accumulator (Bound);
                              end if;
                           end Compare_Work;
                        begin
                           if Landin.Types.Is_Signed (From) then
                              Emit
                                ((case From_Size is
                                    when Landin.Targets.Byte_1 => "movsbq ",
                                    when Landin.Targets.Byte_2 => "movswq ",
                                    when Landin.Targets.Byte_4 => "movslq ",
                                    when Landin.Targets.Byte_8 => "movq ")
                                 & Value_Operand (Source) & ", " & Work);
                           elsif Direct then
                              Emit ((case From_Size is
                                        when Landin.Targets.Byte_1 =>
                                          "movzbl ",
                                        when Landin.Targets.Byte_2 =>
                                          "movzwl ",
                                        when Landin.Targets.Byte_4 =>
                                          "movl ",
                                        when Landin.Targets.Byte_8 =>
                                          "movq ")
                                    & Value_Operand (Source) & ", "
                                    & (if From_Size = Landin.Targets.Byte_8
                                       then Work
                                       else Allocation.Name
                                         (Allocation_Plan.Value
                                            (Positive (Value)).Register,
                                          Landin.Targets.Byte_4)));
                           else
                              Load_Unsigned (Source, From_Size);
                           end if;

                           --  D187 removes the destination-range edge of
                           --  an integer-to-integer conversion only.  The
                           --  narrowing store below already keeps the
                           --  low-order bits of the source, which is the
                           --  one result every target gives.
                           if Unchecked then
                              null;
                           elsif Landin.Types.Is_Signed (Into_Type) then
                              declare
                                 Maximum : constant Landin.Types.Magnitude :=
                                   2 ** (Natural (Into_Bits) - 1) - 1;
                              begin
                                 if Landin.Types.Is_Signed (From)
                                   and then Below
                                     (-Landin.Types.Folded (Maximum + 1))
                                 then
                                    Compare_Work
                                      (-Landin.Types.Folded (Maximum + 1));
                                    Trap_On ("jl");
                                 end if;
                                 if Above (Landin.Types.Folded (Maximum))
                                 then
                                    Compare_Work
                                      (Landin.Types.Folded (Maximum));
                                    Trap_On
                                      (if Landin.Types.Is_Signed (From)
                                       then "jg" else "ja");
                                 end if;
                              end;
                           elsif Landin.Types.Is_Signed (From) then
                              Emit ("testq " & Work & ", " & Work);
                              Trap_On ("js");
                           end if;

                           if not Unchecked
                             and then not Landin.Types.Is_Signed (Into_Type)
                             and then Into_Bits < 64
                           then
                              declare
                                 Maximum : constant Landin.Types.Magnitude :=
                                   2 ** Natural (Into_Bits) - 1;
                              begin
                                 if Above (Landin.Types.Folded (Maximum))
                                 then
                                    Compare_Work
                                      (Landin.Types.Folded (Maximum));
                                    Trap_On ("ja");
                                 end if;
                              end;
                           end if;
                           if not Direct then
                              Emit ("mov" & Suffix (Into_Size) & " "
                                    & Accumulator (Into_Size) & ", "
                                    & Value_Operand (Value));
                           end if;
                        end;
                     end if;
                  end;

               when Landin.IR.Range_Check =>
                  --  D188/[0660].  Source and result are one type, so this
                  --  neither widens nor narrows: it widens to the
                  --  accumulator in that type's own signedness, compares
                  --  against the two folded bounds, and passes the value
                  --  through.  [1120]'s region does not reach it: a value
                  --  outside the bounds is not one the destination holds,
                  --  so removing the edge would not leave one meaning.
                  declare
                     Source : constant Landin.IR.Value_Id := Operand (1);
                     Kind : constant Landin.Types.Integer_Name :=
                       Landin.Types.Integer_Name
                         (Landin.IR.Result_Of (Of_Unit, Item, Value));
                     Width : constant Held_Size := Size_Of (Kind, Facts);
                     Lower : constant Landin.Types.Folded :=
                       Landin.IR.Range_Lower (Of_Unit, Item, Value);
                     Upper : constant Landin.Types.Folded :=
                       Landin.IR.Range_Upper (Of_Unit, Item, Value);
                     Signed : constant Boolean :=
                       Landin.Types.Is_Signed (Kind);
                  begin
                     if Signed then
                        Emit
                          ((case Width is
                              when Landin.Targets.Byte_1 => "movsbq ",
                              when Landin.Targets.Byte_2 => "movswq ",
                              when Landin.Targets.Byte_4 => "movslq ",
                              when Landin.Targets.Byte_8 => "movq ")
                           & Value_Operand (Source) & ", %rax");
                     else
                        Load_Unsigned (Source, Width);
                     end if;

                     --  An edge at the type's own extreme passes every
                     --  value, so it is not tested: `ptr(n)`'s upper edge
                     --  is the largest `usize`.
                     if Lower > Landin.Types.Lowest (Kind, Facts) then
                        Compare_Accumulator (Lower);
                        Trap_On (if Signed then "jl" else "jb");
                     end if;

                     if Upper < Landin.Types.Highest (Kind, Facts) then
                        Compare_Accumulator (Upper);
                        Trap_On (if Signed then "jg" else "ja");
                     end if;

                     Emit ("mov" & Suffix (Width) & " "
                           & Accumulator (Width) & ", "
                           & Value_Operand (Value));
                  end;

               when Landin.IR.Slice_Address =>
                  declare
                     Element : constant Landin.IR.Field_Shape :=
                       Landin.IR.Slice_Element_Shape
                         (Of_Unit, Item, Value);
                     Stride : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit, Element, Facts, Stride, Alignment);
                     pragma Unreferenced (Alignment);
                     --  D187 removes both range edges together.  The
                     --  text boundary traps of D182--D184 are emitted
                     --  through this same operation and are marked
                     --  required where they are lowered, so they arrive
                     --  here checked whatever region they sit in.
                     if not Unchecked then
                        Emit
                          ("movq " & Value_Operand (Operand (4)) & ", %rax");
                        Emit
                          ("cmpq " & Value_Operand (Operand (2)) & ", %rax");
                        Trap_On
                          (if Landin.IR.Slice_Is_Inclusive
                                (Of_Unit, Item, Value)
                           then "jae" else "ja");
                     end if;
                     Emit ("movq " & Value_Operand (Operand (3)) & ", %rcx");
                     --  Lower and upper read from one place hold one value,
                     --  so the lower edge cannot fail: `a[i..i]`, or two
                     --  values the allocator gave one register.  The upper
                     --  edge above is still checked.
                     if not Unchecked
                       and then Value_Operand (Operand (3))
                         /= Value_Operand (Operand (4))
                     then
                        Emit
                          ("cmpq " & Value_Operand (Operand (4)) & ", %rcx");
                        Trap_On ("ja");
                     end if;
                     --  Size and speed scale the lower bound in the memory
                     --  operand when the stride is a scale, from the base
                     --  where it lives when that is a register.
                     if Optimized and then Stride in 0 .. 8
                       and then Stride not in 3 | 5 | 6 | 7
                     then
                        declare
                           Base : constant String :=
                             (if Allocation_Plan.Value
                                   (Positive (Operand (1))).Kind
                                 = Allocation.GP
                              then Value_Operand (Operand (1)) else "%rax");
                        begin
                           if Base = "%rax" then
                              Emit ("movq " & Value_Operand (Operand (1))
                                    & ", %rax");
                           end if;
                           Deliver_Address
                             ("(" & Base & ",%rcx"
                              & (if Stride > 1
                                 then "," & Trimmed
                                   (Landin.Targets.Byte_Count'Image (Stride))
                                 else "")
                              & ")");
                        end;
                        return;
                     end if;
                     if Stride > 1 then
                        if Machine.Fits_Arithmetic_Immediate (Stride) then
                           Emit
                             ("imulq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (Stride))
                              & ", %rcx, %rcx");
                        else
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (Stride))
                              & ", %rdx");
                           Emit ("imulq %rdx, %rcx");
                        end if;
                     end if;
                     Emit ("movq " & Value_Operand (Operand (1)) & ", %rax");
                     Emit ("addq %rcx, %rax");
                     Carry
                       (Landin.Targets.Byte_8, "%rax", Value_Operand (Value));
                  end;

               when Landin.IR.Empty_Slice_Base =>
                  declare
                     Element : constant Landin.IR.Field_Shape :=
                       Landin.IR.Slice_Element_Shape
                         (Of_Unit, Item, Value);
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit, Element, Facts, Size, Alignment);
                     pragma Unreferenced (Size);
                     Emit
                       ("movq $"
                        & Trimmed
                            (Landin.Targets.Byte_Alignment'Image (Alignment))
                        & ", " & Value_Operand (Value));
                  end;

               when Landin.IR.Memory_Access =>
                  declare
                     use all type Landin.Memory.Operation;
                     M : constant Landin.Memory.Operation :=
                       Landin.IR.Memory_Operation (Of_Unit, Item, Value);
                     Size : constant Held_Size := Landin.Types.Storage_Size
                       (Landin.IR.Memory_Scalar (Of_Unit, Item, Value), Facts);
                     S : constant String := Suffix (Size);
                     A : constant String := Accumulator (Size);
                  begin
                     if M = Stack_Prepare then
                        --  D450: the operands are the stack's base and
                        --  length, the entry and its argument.  The top is
                        --  aligned down to sixteen and the first frame laid
                        --  below it as the switch routine's pops read it:
                        --  r15, r14, r13 (the argument), r12 (the entry),
                        --  rbx, rbp (zero), then the start routine as the
                        --  return address and sixteen bytes of padding, so
                        --  the entry is called with the stack aligned.  A
                        --  slice that cannot hold those 72 bytes traps
                        --  stack_exhausted (D451); the difference is
                        --  signed, since aligning a short slice's top may
                        --  take it below the base.
                        Emit ("movq " & Value_Operand (Operand (1))
                              & ", %rax");
                        Emit ("movq " & Value_Operand (Operand (2))
                              & ", %rcx");
                        Emit ("addq %rax, %rcx");
                        Emit ("andq $-16, %rcx");
                        Emit ("subq %rax, %rcx");
                        Emit ("cmpq $" & Trimmed (Natural'Image
                          (Stack_First_Frame)) & ", %rcx");
                        Trap_On ("jl");
                        Emit ("addq %rcx, %rax");
                        Emit ("subq $" & Trimmed (Natural'Image
                          (Stack_First_Frame)) & ", %rax");
                        Emit ("movq " & Value_Operand (Operand (4))
                              & ", %rdx");
                        Emit ("movq %rdx, 16(%rax)");
                        Emit ("movq " & Value_Operand (Operand (3))
                              & ", %rdx");
                        Emit ("movq %rdx, 24(%rax)");
                        Emit ("xorl %edx, %edx");
                        Emit ("movq %rdx, (%rax)");
                        Emit ("movq %rdx, 8(%rax)");
                        Emit ("movq %rdx, 32(%rax)");
                        Emit ("movq %rdx, 40(%rax)");
                        Emit ("movq %rdx, 56(%rax)");
                        Emit ("movq %rdx, 64(%rax)");
                        Emit ("leaq " & Stack_Entered & "(%rip), %rdx");
                        Emit ("movq %rdx, 48(%rax)");
                        Stack_Used := True;
                        Store_Value (Value, "%rax");
                     elsif M = Stack_Switch then
                        --  D450/D447: the limit is checked here, against
                        --  the leaving stack, so the trap is this call's
                        --  own site; the switch itself is one call of the
                        --  program's switch routine, which the allocator
                        --  treats as a call (Allocation.Is_Switch).
                        Emit ("movq " & Value_Operand (Operand (3))
                              & ", %rax");
                        Emit ("cmpq %rax, %rsp");
                        Trap_On ("jb");
                        Emit ("movq " & Value_Operand (Operand (1))
                              & ", %rdi");
                        Emit ("movq " & Value_Operand (Operand (2))
                              & ", %rsi");
                        Emit ("call " & Stack_Switcher);
                        Stack_Used := True;
                     elsif Landin.Memory.Operands (M) = 0 then
                        if M /= Compiler_Barrier then
                           Emit ("mfence");
                        end if;
                     else
                        Emit ("movq " & Value_Operand (Operand (1))
                              & ", %rcx");
                        if Size /= Landin.Targets.Byte_1 then
                           Emit ("testq $" & Trimmed (Positive'Image
                             (Landin.Targets.Bytes (Size) - 1)) & ", %rcx");
                           Trap_On ("jnz");
                        end if;
                        if M not in Volatile_Load | Volatile_Store then
                           Emit ("mfence");
                        end if;
                        if M in Atomic_Load | Volatile_Load then
                           Emit ("mov" & S & " (%rcx), " & A);
                        else
                           Emit ("mov" & S & " "
                             & Value_Operand (Operand (2)) & ", " & A);
                           case M is
                              when Atomic_Store | Atomic_Exchange =>
                                 Emit ("xchg" & S & " " & A & ", (%rcx)");
                              when Volatile_Store =>
                                 Emit ("mov" & S & " " & A & ", (%rcx)");
                              when Atomic_Add =>
                                 Emit ("lock xadd" & S & " " & A
                                       & ", (%rcx)");
                              when Atomic_Compare_Exchange =>
                                 Emit ("mov" & S & " "
                                   & Value_Operand (Operand (3)) & ", "
                                   & (case Size is
                                        when Landin.Targets.Byte_1 => "%dl",
                                        when Landin.Targets.Byte_2 => "%dx",
                                        when Landin.Targets.Byte_4 => "%edx",
                                        when others => "%rdx"));
                                 Emit ("lock cmpxchg" & S & " "
                                   & (case Size is
                                        when Landin.Targets.Byte_1 => "%dl",
                                        when Landin.Targets.Byte_2 => "%dx",
                                        when Landin.Targets.Byte_4 => "%edx",
                                        when others => "%rdx") & ", (%rcx)");
                              when others =>
                                 raise Landin.Compiler_Defect;
                           end case;
                        end if;
                        if M not in Volatile_Load | Volatile_Store then
                           Emit ("mfence");
                        end if;
                        if Landin.Memory.Returns_Value (M) then
                           Store_Value (Value, A);
                        end if;
                     end if;
                  end;

               when Landin.IR.Load_Indirect =>
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     Carry (Held, Indirect_Operand, Value_Operand (Value));
                  end;

               when Landin.IR.Store_Indirect =>
                  declare
                     Held : constant Held_Size := Size_Of_Value (Operand (2));
                  begin
                     Store_Through
                       (Held, Source_Operand (Operand (2)), Indirect_Operand);
                  end;

               when Landin.IR.Load =>
                  declare
                     Slot : constant Landin.IR.Slot_Id :=
                       Landin.IR.Slot_Of (Of_Unit, Item, Value);
                  begin
                     Carry (Size_Of_Slot (Slot), Slot_Cell (Slot),
                            Value_Operand (Value));
                  end;

               when Landin.IR.Store =>
                  declare
                     Slot : constant Landin.IR.Slot_Id :=
                       Landin.IR.Slot_Of (Of_Unit, Item, Value);
                     Pair : constant Address_Fold :=
                       (if Optimized
                        then Carried (Of_Unit, Item, Current_Block,
                                      Current_Position, Uses, References)
                        else (others => <>));
                  begin
                     --  An address another use keeps formed still reaches
                     --  its access through the temporary carrying it, so
                     --  the access reads through it where it lives.
                     if Pair.Access_Value /= Landin.IR.No_Value then
                        Skipped_Load := Pair.Load;
                        Folded_User := Pair.Access_Value;
                        if Allocation_Plan.Value (Positive (Operand (1))).Kind
                          = Allocation.GP
                        then
                           Folded_Address := Unbounded.To_Unbounded_String
                             ("(" & Value_Operand (Operand (1)) & ")");
                        else
                           Emit ("movq " & Source_Operand (Operand (1))
                                 & ", %rcx");
                           Folded_Address :=
                             Unbounded.To_Unbounded_String ("(%rcx)");
                        end if;
                        return;
                     end if;
                     Carry (Size_Of_Slot (Slot),
                            Source_Operand (Operand (1)), Slot_Cell (Slot));
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
                     In_Range : constant String :=
                       Value_Label (Value) & "_inrange";
                     Done : constant String :=
                       Value_Label (Value) & "_done";
                     Instruction : constant String :=
                       (if Op = Landin.IR.Shift_Left then "shl"
                        elsif Signed then "sar"
                        else "shr");
                  begin
                     if Optimized and then Landin.IR.Op_Of
                       (Of_Unit, Item, Operand (2)) = Landin.IR.Number
                       and then not Landin.IR.Is_Negated
                         (Of_Unit, Item, Operand (2))
                     then
                        declare
                           Amount : constant Landin.Types.Magnitude :=
                             Landin.IR.Number_Of (Of_Unit, Item, Operand (2));
                        begin
                           if Amount >= Landin.Types.Magnitude (Bits) then
                              Emit ("mov" & Suffix (Held) & " $0, "
                                    & Value_Operand (Value));
                           else
                              Integer_Unary
                                ((if Amount > 0
                                  then Instruction & Suffix (Held) & " $"
                                    & Trimmed
                                        (Landin.Types.Magnitude'Image
                                           (Amount))
                                    & ", "
                                  else ""),
                                 Check => "");
                           end if;
                           return;
                        end;
                     end if;
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Operand (Operand (2)) & ", "
                           & Accumulator (Held));

                     if Signed then
                        Emit ("cmp" & Suffix (Held) & " $0, "
                              & Accumulator (Held));
                        Trap_On ("jl");
                     end if;

                     --  Every remaining amount is at or above zero, so the
                     --  width test is an unsigned one on both signednesses.
                     Emit ("cmp" & Suffix (Held) & " $"
                           & Trimmed
                               (Landin.Targets.Bit_Width'Image (Bits))
                           & ", " & Accumulator (Held));
                     Emit ("jb " & In_Range);
                     Emit ("mov" & Suffix (Held) & " $0, "
                           & Value_Operand (Value));
                     Emit ("jmp " & Done);
                     Put (In_Range & ":");

                     --  BMI2 takes the count from any register, here the
                     --  accumulator that already holds it, and the shifted
                     --  operand from where it is; it has no 8- or 16-bit
                     --  form, so a narrow shift keeps the legacy one.
                     if Has_BMI2 and then Held in Landin.Targets.Byte_4
                                                | Landin.Targets.Byte_8
                     then
                        Emit (Instruction & "x " & Accumulator (Held) & ", "
                              & Value_Operand (Operand (1), Held) & ", "
                              & Accumulator (Held));
                        Emit ("mov" & Suffix (Held) & " "
                              & Accumulator (Held) & ", "
                              & Value_Operand (Value));
                        Put (Done & ":");
                        return;
                     end if;

                     --  The count is below the width, so its low byte is the
                     --  whole of it and `%cl` is where a variable count goes.
                     Emit ("movb "
                           & Value_Operand (Operand (2), Landin.Targets.Byte_1)
                           & ", %cl");
                     Load_Value (Operand (1));
                     Emit (Instruction & Suffix (Held) & " %cl, "
                           & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Operand (Value));
                     Put (Done & ":");
                  end;

               when Landin.IR.Bitwise_And
                  | Landin.IR.Bitwise_Xor
                  | Landin.IR.Bitwise_Or =>
                  --  [0330] gives each of these its own integer type back, so
                  --  every pattern they produce is one the type holds and
                  --  neither signedness nor a flag has anything to say.
                  Integer_Binary
                    ((case Op is
                         when Landin.IR.Bitwise_And => "and",
                         when Landin.IR.Bitwise_Xor => "xor",
                         when Landin.IR.Bitwise_Or => "or",
                         when others =>
                           raise Landin.Compiler_Defect
                             with "an unreachable operator case"),
                     Commutes => True, Check => "");

               when Landin.IR.Logical_Not =>
                  --  [1870] fixes a bool at zero or one, so the low bit is
                  --  the whole value and `not` over the byte would give 254
                  --  for `not false`.
                  Integer_Unary ("xorb $1, ", Check => "");

               when Landin.IR.Negation =>
                  --  [1890] gives unary minus its own integer type back, so
                  --  the lowest signed value has no negation the type holds
                  --  and no unsigned value but zero has one at all.  `neg`
                  --  reports the first as overflow and the second as carry.
                  declare
                     Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     if Kind in Landin.Types.Float_Name then
                        Emit ("mov" & Suffix (Held) & " "
                              & Value_Operand (Operand (1)) & ", "
                              & Accumulator (Held));
                        Emit
                          ((if Kind = Landin.Types.F32
                            then "xorl $2147483648, %eax"
                            else "btcq $63, %rax"));
                        Emit ("mov" & Suffix (Held) & " "
                              & Accumulator (Held) & ", "
                              & Value_Operand (Value));
                        return;
                     end if;

                     Integer_Unary
                       ("neg" & Suffix (Held) & " ",
                        Check =>
                          (if Unchecked then ""
                           elsif Landin.Types.Is_Signed
                             (Landin.Types.Integer_Name (Kind))
                           then "jo" else "jc"));
                  end;

               when Landin.IR.Complement =>
                  --  [0330]'s `~` gives its own type back, so every pattern
                  --  it can produce is one the type holds and no edge is
                  --  needed.
                  Integer_Unary
                    ("not" & Suffix (Size_Of_Value (Value)) & " ",
                     Check => "");

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
                     Source_Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Source_Path_Of
                         (Of_Unit, Item, Value);
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Destination_Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Destination_Nested :
                       constant Landin.IR.Path_Step_Array :=
                         Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Destination_Case : constant Natural :=
                       Landin.IR.Variant_Case_Of (Of_Unit, Item, Value);
                     Destination_Payload_Field : constant Natural :=
                       Landin.IR.Variant_Payload_Field_Of
                         (Of_Unit, Item, Value);

                     Bytes : constant Landin.Targets.Byte_Count :=
                       Whole_Clear_Extent
                         (Source, Source_Field, Source_Nested);
                  begin
                     --  The places were already evaluated by lowering.
                     --  An empty transfer needs no endpoint setup or DF
                     --  change; nonempty string operations still clear DF.
                     if Bytes > 0 then
                        Storage_Address
                          (Destination, Destination_Field, "%rdi",
                           Destination_Case, Destination_Payload_Field,
                           Destination_Nested);
                        Storage_Address
                          (Source, Source_Field, "%rsi",
                           Nested => Source_Nested);
                        if Use_Scalar_Transfer (Bytes) then
                           Emit_Small_Copy (Bytes);
                        else
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (Bytes))
                              & ", %rcx");
                           Emit ("cld");
                           Emit ("rep movsb");
                        end if;
                     end if;
                  end;

               when Landin.IR.Copy_Variant =>
                  --  D80 moves the complete padded unfolded part.  Both
                  --  endpoints were proved to have the same neutral shape;
                  --  offsets and extent are derived for this target here.
                  declare
                     Source : constant Landin.IR.Storage :=
                       Landin.IR.Source_Of (Of_Unit, Item, Value);
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     --  D126: the two endpoints have one shape and need
                     --  not sit in the same place, so each names its own.
                     Field : constant Positive := Positive
                       (Landin.IR.Source_Field_Of
                          (Of_Unit, Item, Value));
                     Into_Field : constant Positive := Positive
                       (Landin.IR.Element_Field_Of
                          (Of_Unit, Item, Value));
                     From_Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Source_Path_Of (Of_Unit, Item, Value);
                     Into_Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Source, Field, From_Nested);
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit, Shape, Facts, Bytes, Alignment);
                     Storage_Address
                       (Destination, Into_Field, "%rdi",
                        Nested => Into_Nested);
                     Storage_Address
                       (Source, Field, "%rsi", Nested => From_Nested);
                     if Use_Scalar_Transfer (Bytes) then
                        Emit_Small_Copy (Bytes);
                     else
                        Emit
                          ("movabsq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (Bytes))
                           & ", %rcx");
                        Emit ("cld");
                        Emit ("rep movsb");
                     end if;
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
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Bytes : constant Landin.Targets.Byte_Count :=
                       Whole_Clear_Extent (Destination, Field, Nested);
                  begin
                     if Bytes > 0 then
                        Storage_Address
                          (Destination, Field, "%rdi", Nested => Nested);
                        if Use_Scalar_Transfer (Bytes) then
                           Emit_Small_Clear (Bytes);
                        else
                           Emit ("xorl %eax, %eax");
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (Bytes))
                              & ", %rcx");
                           Emit ("cld");
                           Emit ("rep stosb");
                        end if;
                     end if;
                  end;

               when Landin.IR.Load_Variant_Tag =>
                  declare
                     Source : constant Landin.IR.Storage :=
                       Landin.IR.Source_Of (Of_Unit, Item, Value);
                     Field : constant Positive := Positive
                       (Landin.IR.Element_Field_Of
                          (Of_Unit, Item, Value));
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Source, Field, Nested);
                     Held : constant Held_Size :=
                       Size_Of (Shape.Element, Facts);
                  begin
                     Storage_Address
                       (Source, Field, "%rcx", Nested => Nested);
                     Carry (Held, "(%rcx)", Value_Operand (Value));
                  end;

               when Landin.IR.Load_Variant_Field =>
                  declare
                     Source : constant Landin.IR.Storage :=
                       Landin.IR.Source_Of (Of_Unit, Item, Value);
                     Field : constant Positive := Positive
                       (Landin.IR.Element_Field_Of
                          (Of_Unit, Item, Value));
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Source, Field, Nested);
                     Which : constant Positive := Positive
                       (Landin.IR.Variant_Case_Of
                          (Of_Unit, Item, Value));
                     Payload_Field : constant Positive := Positive
                       (Landin.IR.Variant_Payload_Field_Of
                          (Of_Unit, Item, Value));
                     Leaf : constant Landin.IR.Field_Shape :=
                       Landin.IR.Nth_Variant_Case_Field
                         (Of_Unit, Shape, Which, Payload_Field);
                     At_Offset : constant Landin.Targets.Byte_Count :=
                       Landin.Backend.Variant_Payload_Field_Offset
                         (Of_Unit, Shape, Which, Payload_Field, Facts,
                          Path_Layouts);
                     Held : constant Held_Size :=
                       Size_Of (Leaf.Element, Facts);
                  begin
                     Storage_Address
                       (Source, Field, "%rcx", Nested => Nested);
                     Add_Storage_Offset (At_Offset, "%rcx");
                     Carry (Held, "(%rcx)", Value_Operand (Value));
                  end;

               when Landin.IR.Select_Variant =>
                  declare
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Positive := Positive
                       (Landin.IR.Element_Field_Of
                          (Of_Unit, Item, Value));
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Destination, Field, Nested);
                     Offset : Landin.Targets.Byte_Count;
                     Size : Landin.Targets.Byte_Count;
                     Tag : constant Natural :=
                       Landin.IR.Variant_Case_Of
                         (Of_Unit, Item, Value) - 1;
                     Held : constant Held_Size :=
                       Size_Of (Shape.Element, Facts);
                  begin
                     Landin.Backend.Variant_Selected_Payload_Extent
                       (Of_Unit, Shape, Positive (Tag + 1), Facts,
                        Offset, Size);
                     if Size > 0 then
                        Storage_Address
                          (Destination, Field, "%rdi", Nested => Nested);
                        Emit
                          ("movabsq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (Offset))
                           & ", %rcx");
                        Emit ("addq %rcx, %rdi");
                        if Speed_Unrolled (Size) then
                           Emit_Small_Clear (Size);
                        else
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (Size))
                              & ", %rcx");
                           Emit ("xorl %eax, %eax");
                           Emit ("cld");
                           Emit ("rep stosb");
                        end if;
                     end if;

                     --  Form the part base for the source-order tag.
                     Storage_Address
                       (Destination, Field, "%rcx", Nested => Nested);
                     Emit
                       ("mov" & Suffix (Held) & " $"
                        & Trimmed (Natural'Image (Tag)) & ", (%rcx)");
                  end;

               when Landin.IR.Store_Variant_Field =>
                  declare
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Positive := Positive
                       (Landin.IR.Element_Field_Of
                          (Of_Unit, Item, Value));
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Destination, Field, Nested);
                     Which : constant Positive :=
                       Positive
                         (Landin.IR.Variant_Case_Of
                            (Of_Unit, Item, Value));
                     Payload_Field : constant Positive :=
                       Positive
                         (Landin.IR.Variant_Payload_Field_Of
                            (Of_Unit, Item, Value));
                     Leaf : constant Landin.IR.Field_Shape :=
                       Landin.IR.Nth_Variant_Case_Field
                         (Of_Unit, Shape, Which, Payload_Field);
                     At_Offset : constant Landin.Targets.Byte_Count :=
                       Landin.Backend.Variant_Payload_Field_Offset
                         (Of_Unit, Shape, Which, Payload_Field, Facts,
                          Path_Layouts);
                     Held : constant Held_Size :=
                       Size_Of (Leaf.Element, Facts);
                  begin
                     Storage_Address
                       (Destination, Field, "%rcx", Nested => Nested);
                     Add_Storage_Offset (At_Offset, "%rcx");
                     Carry (Held, Value_Operand (Operand (1)), "(%rcx)");
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
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Which : constant Natural :=
                       Landin.IR.Variant_Case_Of (Of_Unit, Item, Value);
                     Payload_Field : constant Natural :=
                       Landin.IR.Variant_Payload_Field_Of
                         (Of_Unit, Item, Value);
                     Length : constant Landin.IR.Element_Total :=
                       Array_Length_Of
                         (Destination, Field, Which, Payload_Field, Nested);
                     Element : constant Landin.Types.Scalar_Name :=
                       Array_Element_Of
                         (Destination, Field, Which, Payload_Field, Nested);
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
                     Storage_Address
                       (Destination, Field, "%rdi", Which, Payload_Field,
                        Nested);
                     if Offset /= 0 then
                        if Machine.Fits_Arithmetic_Immediate (Offset) then
                           Emit
                             ("addq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (Offset))
                              & ", %rdi");
                        else
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (Offset))
                              & ", %rdx");
                           Emit ("addq %rdx, %rdi");
                        end if;
                     end if;
                     Emit
                       ("mov" & Suffix (Held) & " "
                        & Value_Operand (Operand (1)) & ", "
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
                        Carry (Held, Place, Value_Operand (Value));
                     else
                        Carry (Held, Source_Operand (Operand (1)), Place);
                     end if;
                  end;

               when Landin.IR.Load_Element | Landin.IR.Store_Element =>
                  --  [0580] requires the bounds check before any address
                  --  computation.  Keep the index in %rax through the
                  --  unsigned comparison, trap on index >= length, and only
                  --  then scale it and add it to the array's base address.
                  --  D22 lets the base be a module datum's symbol or a
                  --  frame slot's %rbp-relative address; D48 may move that
                  --  base to an aggregate field.  D89 may move it once more
                  --  to a fixed array inside that ordinary child.
                  declare
                     Reaches_Slot : constant Boolean :=
                       Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value);
                     Index : constant Landin.IR.Value_Id :=
                       Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Which : constant Natural :=
                       Landin.IR.Variant_Case_Of (Of_Unit, Item, Value);
                     Payload_Field : constant Natural :=
                       Landin.IR.Variant_Payload_Field_Of
                         (Of_Unit, Item, Value);
                     Place : constant Landin.IR.Storage :=
                       (if Reaches_Slot
                        then (if Landin.IR.Is_Address
                          (Of_Unit, Item,
                           Landin.IR.Slot_Of (Of_Unit, Item, Value))
                          then (Kind => Landin.IR.Runtime_Address,
                                Address => Landin.IR.Slot_Of
                                  (Of_Unit, Item, Value))
                          else (Kind => Landin.IR.Frame_Slot,
                                Slot => Landin.IR.Slot_Of
                                  (Of_Unit, Item, Value)))
                        else (Kind => Landin.IR.Module_Datum,
                              Datum => Landin.IR.Datum_Of
                                (Of_Unit, Item, Value)));
                     Length : constant Landin.IR.Element_Total :=
                       Array_Length_Of
                         (Place, Field, Which, Payload_Field, Nested);
                     Element : constant Landin.IR.Field_Shape :=
                       Element_Shape_Of
                         (Place, Field, Which, Payload_Field, Nested);
                     Stride : constant Landin.Targets.Byte_Count :=
                       Element_Bytes_Of
                         (Place, Field, Which, Payload_Field, Nested);
                     --  D121: the element may be an aggregate, and then
                     --  what the operation loads is a leaf inside it.
                     Below : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Element_Path_Of (Of_Unit, Item, Value);
                     Kind : constant Landin.Types.Scalar_Name :=
                       Landin.IR.Shape_At (Of_Unit, Element, Below).Element;
                     Inside : constant Landin.Targets.Byte_Count :=
                       Path_Offset (Element, Below);
                     Held : constant Held_Size := Size_Of (Kind, Facts);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Place, Field, Nested);
                  begin
                     if Shape.Packing.Bits /= 0 then
                        declare
                           Carrier : constant Held_Size :=
                             Landin.Targets.Packed.Carrier
                               (Shape.Packing.Storage);
                           Mask : constant Landin.Packed.Image :=
                             Landin.Packed.Mask (Shape.Packing.Bits);
                        begin
                           Storage_Address
                             (Place, Field, "%r10", Nested => Nested);
                           Emit ("movq " & Value_Operand (Index)
                             & ", %rcx");
                           Emit ("cmpq $" & Trimmed
                             (Landin.IR.Element_Total'Image (Length))
                             & ", %rcx");
                           Trap_On ("jae");
                           Emit ("imulq $" & Trimmed
                             (Natural'Image (Shape.Packing.Bits))
                             & ", %rcx");
                           Emit ("addq $" & Trimmed
                             (Natural'Image (Shape.Packing.First))
                             & ", %rcx");
                           Emit ("xorq %rax, %rax");
                           if Op = Landin.IR.Load_Element then
                              Emit ("mov" & Suffix (Carrier)
                                & " (%r10), " & Accumulator (Carrier));
                              Emit ("shrq %cl, %rax");
                              Emit ("movabsq $" & Trimmed
                                (Landin.Packed.Image'Image (Mask))
                                & ", %rdx");
                              Emit ("andq %rdx, %rax");
                              Packed_Atom (Landin.IR.Array_Element_Shape
                                (Of_Unit, Shape).Atoms, Encode => False);
                              Store_Value (Value, Accumulator (Held));
                           else
                              Load_Value (Operand (2));
                              Packed_Atom (Landin.IR.Array_Element_Shape
                                (Of_Unit, Shape).Atoms, Encode => True);
                              if Shape.Packing.Bits < 64 then
                                 Emit ("movq %rax, %rdx");
                                 Emit ("shrq $" & Trimmed
                                   (Natural'Image (Shape.Packing.Bits))
                                   & ", %rdx");
                                 Trap_On
                                   ("jne", Landin.Panics.Bad_Conversion);
                              end if;
                              Emit ("shlq %cl, %rax");
                              Emit ("movq %rax, %rdx");
                              Emit ("movabsq $" & Trimmed
                                (Landin.Packed.Image'Image (Mask))
                                & ", %r11");
                              Emit ("shlq %cl, %r11");
                              Emit ("notq %r11");
                              Emit ("xorq %rax, %rax");
                              Emit ("mov" & Suffix (Carrier)
                                & " (%r10), " & Accumulator (Carrier));
                              Emit ("andq %r11, %rax");
                              Emit ("orq %rdx, %rax");
                              Emit ("mov" & Suffix (Carrier) & " "
                                & Accumulator (Carrier) & ", (%r10)");
                           end if;
                        end;
                        return;
                     end if;
                     if Optimized then
                        declare
                           Access_Operand : constant String :=
                             Indexed_Operand
                               (Place, Field, Which, Payload_Field, Nested,
                                Index, Length, Stride, Inside);
                        begin
                           if Op = Landin.IR.Load_Element then
                              Carry
                                (Held, Access_Operand, Value_Operand (Value));
                           else
                              Store_Through
                                (Held, Source_Operand (Operand (2)),
                                 Access_Operand);
                           end if;
                        end;
                        return;
                     end if;
                     Emit ("movq " & Value_Operand (Index) & ", %rax");
                     if not Unchecked then
                        Emit_Fixed_Bounds_Check (Length);
                     end if;
                     --  An `imul` immediate is a signed 32-bit field, and
                     --  D121's element may be wider than one, so a stride
                     --  that does not fit is formed in a register first.
                     --  A unit stride leaves the checked index unchanged.
                     if Stride = 1 then
                        null;
                     elsif Machine.Fits_Arithmetic_Immediate (Stride) then
                        Emit
                          ("imulq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (Stride))
                           & ", %rax, %rax");
                     else
                        Emit
                          ("movabsq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (Stride))
                           & ", %rdx");
                        Emit ("imulq %rdx, %rax");
                     end if;

                     --  Storage_Address first derives the top-level field
                     --  and D84's selected payload offset; only after the
                     --  bounds check above is the scaled index added, and
                     --  only then the run inside the element.
                     Storage_Address
                       (Place, Field, "%rcx", Which, Payload_Field, Nested);
                     Emit ("addq %rax, %rcx");
                     Add_Storage_Offset (Inside, "%rcx");

                     if Op = Landin.IR.Load_Element then
                        Carry (Held, "(%rcx)", Value_Operand (Value));
                     else
                        Carry
                          (Held, Source_Operand (Operand (2)), "(%rcx)");
                     end if;
                  end;

               when Landin.IR.Load_Field | Landin.IR.Store_Field =>
                  declare
                     Place : constant Landin.IR.Storage :=
                       (if Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value)
                        then (if Landin.IR.Is_Address
                          (Of_Unit, Item,
                           Landin.IR.Slot_Of (Of_Unit, Item, Value))
                          then (Kind => Landin.IR.Runtime_Address,
                                Address => Landin.IR.Slot_Of
                                  (Of_Unit, Item, Value))
                          else (Kind => Landin.IR.Frame_Slot,
                                Slot => Landin.IR.Slot_Of
                                  (Of_Unit, Item, Value)))
                        else (Kind => Landin.IR.Module_Datum,
                              Datum => Landin.IR.Datum_Of
                                (Of_Unit, Item, Value)));
                     Which : constant Landin.IR.Part_Position :=
                       Landin.IR.Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Landin.IR.Shape_At
                         (Of_Unit, Part_Shape_Of (Place, Which), Nested);
                  begin
                     if Shape.Packing.Bits /= 0 then
                        declare
                           use type Landin.Packed.Image;
                           Held : constant Held_Size :=
                             Landin.Targets.Packed.Carrier
                               (Shape.Packing.Storage);
                           Mask : constant Landin.Packed.Image :=
                             Landin.Packed.Mask (Shape.Packing.Bits);
                           Shift : constant String := Trimmed
                             (Natural'Image (Shape.Packing.First));
                        begin
                           Storage_Address
                             (Place, Natural (Which), "%rcx",
                              Nested => Nested);
                           Emit ("xorq %rax, %rax");
                           if Op = Landin.IR.Load_Field then
                              Emit ("mov" & Suffix (Held)
                                & " (%rcx), " & Accumulator (Held));
                              Emit ("shrq $" & Shift & ", %rax");
                              Emit ("movabsq $" & Trimmed
                                (Landin.Packed.Image'Image (Mask))
                                & ", %rdx");
                              Emit ("andq %rdx, %rax");
                              Packed_Atom (Shape.Atoms, Encode => False);
                              Store_Value (Value, Accumulator
                                (Size_Of_Value (Value)));
                           else
                              Emit (Move
                                (Size_Of_Value (Operand (1)),
                                 Source_Operand (Operand (1)),
                                 Accumulator (Size_Of_Value (Operand (1)))));
                              Packed_Atom (Shape.Atoms, Encode => True);
                              if Shape.Packing.Bits < 64 then
                                 Emit ("movq %rax, %rdx");
                                 Emit ("shrq $" & Trimmed
                                   (Natural'Image (Shape.Packing.Bits))
                                   & ", %rdx");
                                 Trap_On
                                   ("jne", Landin.Panics.Bad_Conversion);
                              end if;
                              Emit ("shlq $" & Shift & ", %rax");
                              Emit ("movq %rax, %rdx");
                              Emit ("xorq %rax, %rax");
                              Emit ("mov" & Suffix (Held)
                                & " (%rcx), " & Accumulator (Held));
                              Emit ("movabsq $" & Trimmed
                                (Landin.Packed.Image'Image
                                  (not (Mask * 2 ** Shape.Packing.First)))
                                & ", %r11");
                              Emit ("andq %r11, %rax");
                              Emit ("orq %rdx, %rax");
                              Emit ("mov" & Suffix (Held) & " "
                                & Accumulator (Held) & ", (%rcx)");
                           end if;
                        end;
                        return;
                     end if;
                  end;
                  if Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value) then
                     --  [1810]'s local: a cell in this frame, reached the
                     --  way every other cell is and at the field's own
                     --  displacement inside it.
                     declare
                        Slot : constant Landin.IR.Slot_Id :=
                          Landin.IR.Slot_Of (Of_Unit, Item, Value);
                        Which : constant Landin.IR.Part_Position :=
                          Landin.IR.Field_Of (Of_Unit, Item, Value);
                        Nested : constant Landin.IR.Path_Step_Array :=
                          Landin.IR.Path_Of (Of_Unit, Item, Value);
                     begin
                        if Landin.IR.Is_Address (Of_Unit, Item, Slot) then
                           declare
                              Place : constant Landin.IR.Storage :=
                                (Kind => Landin.IR.Runtime_Address,
                                 Address => Slot);
                              Shape : constant Landin.IR.Field_Shape :=
                                (if Nested'Length = 0
                                 then Part_Shape_Of (Place, Which)
                                 else Landin.IR.Shape_At
                                   (Of_Unit,
                                    Part_Shape_Of (Place, Which), Nested));
                              Held : constant Held_Size :=
                                Size_Of (Shape.Element, Facts);
                              --  What Storage_Address would add to the
                              --  address: the field, then the run below.
                              Offset : constant Landin.Targets.Byte_Count :=
                                Path_Offset
                                  (Landin.IR.Address_Shape
                                     (Of_Unit, Item, Slot),
                                   [1 => (Field => Which, Case_Index => 0)])
                                + (if Nested'Length = 0 then 0
                                   else Path_Offset
                                     (Part_Shape_Of (Place, Which), Nested));
                              Held_In_Register : constant Boolean :=
                                Allocation_Plan.Slot (Positive (Slot)).Kind
                                  = Allocation.GP;
                              Target : Unbounded.Unbounded_String;
                           begin
                              --  Size and speed read at a displacement from
                              --  the address itself, in its register or
                              --  loaded from its home.
                              if Optimized
                                and then Machine.Fits_Arithmetic_Immediate
                                           (Offset)
                              then
                                 if not Held_In_Register then
                                    Emit ("movq " & Slot_Cell (Slot)
                                          & ", %rcx");
                                 end if;
                                 Target := Unbounded.To_Unbounded_String
                                   ((if Offset = 0 then ""
                                     else Trimmed
                                       (Landin.Targets.Byte_Count'Image
                                          (Offset)))
                                    & "("
                                    & (if Held_In_Register
                                       then Slot_Cell (Slot) else "%rcx")
                                    & ")");
                              else
                                 Storage_Address
                                   (Place, Natural (Which), "%rcx",
                                    Nested => Nested);
                                 Target :=
                                   Unbounded.To_Unbounded_String ("(%rcx)");
                              end if;
                              if Op = Landin.IR.Load_Field then
                                 Carry
                                   (Held, Unbounded.To_String (Target),
                                    Value_Operand (Value));
                              else
                                 Carry
                                   (Held, Source_Operand (Operand (1)),
                                    Unbounded.To_String (Target));
                              end if;
                              return;
                           end;
                        end if;

                        declare
                           Kind : constant Landin.Types.Scalar_Name :=
                             (if Nested'Length = 0
                              then Landin.IR.Nth_Slot_Part
                                (Of_Unit, Item, Slot, Which)
                              else Landin.IR.Shape_At
                                (Of_Unit,
                                 Part_Shape_Of
                                   ((Kind => Landin.IR.Frame_Slot,
                                     Slot => Slot), Which),
                                 Nested).Element);
                           Held : constant Held_Size := Size_Of (Kind, Facts);
                           Top : constant Landin.Targets.Byte_Count :=
                             Field_Offset
                               (Of_Unit, Item, Layout, Slot, Which, Facts);
                           --  A cell grows downward and [0750] lays a struct
                           --  out upward, so the whole path moves the leaf
                           --  back toward the frame pointer.
                           At_Offset : constant Landin.Targets.Byte_Count :=
                             (if Nested'Length = 0 then Top
                              else Top - Path_Offset
                                (Part_Shape_Of
                                   ((Kind => Landin.IR.Frame_Slot,
                                     Slot => Slot), Which),
                                 Nested));
                           Place : constant String := Cell (At_Offset);
                        begin
                           if Op = Landin.IR.Load_Field then
                              Carry (Held, Place, Value_Operand (Value));
                           else
                              Carry
                                (Held, Source_Operand (Operand (1)), Place);
                           end if;
                        end;
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
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     At_Offset : constant Landin.Targets.Byte_Count :=
                       Field_Offset (Datum, Which)
                       + (if Nested'Length = 0
                          then Landin.Targets.Byte_Count'(0)
                          else Path_Offset
                            (Part_Shape_Of
                               ((Kind  => Landin.IR.Module_Datum,
                                 Datum => Datum), Which),
                             Nested));
                     Kind : constant Landin.Types.Scalar_Name :=
                       (if Nested'Length = 0
                        then Landin.IR.Nth_Part (Of_Unit, Datum, Which)
                        else Landin.IR.Shape_At
                               (Of_Unit,
                                Part_Shape_Of
                                  ((Kind  => Landin.IR.Module_Datum,
                                    Datum => Datum), Which),
                                Nested).Element);
                     Held : constant Held_Size := Size_Of (Kind, Facts);
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
                         or else Has_Wide_Field (Datum))
                       and then At_Offset > 0
                     then
                        Emit ("leaq " & Symbol (Datum) & "(%rip), %rcx");
                        Add_Storage_Offset (At_Offset, "%rcx");

                        if Op = Landin.IR.Load_Field then
                           Carry (Held, "(%rcx)", Value_Operand (Value));
                        else
                           Carry
                             (Held, Source_Operand (Operand (1)), "(%rcx)");
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
                              Carry (Held, Place, Value_Operand (Value));
                           else
                              Carry
                                (Held, Source_Operand (Operand (1)), Place);
                           end if;
                        end;
                     end if;
                  end;

               when Landin.IR.Add | Landin.IR.Subtract =>
                  declare
                     Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                  begin
                     if Kind in Landin.Types.Float_Name then
                        Float_Binary
                          ((if Op = Landin.IR.Add then "add" else "sub")
                           & (if Kind = Landin.Types.F32 then "ss"
                              else "sd"));
                        return;
                     end if;

                     --  D187 leaves [0320]'s two's-complement result
                     --  where it was computed, which is what the wrapping
                     --  operators already mean on every target.
                     Integer_Binary
                       ((if Op = Landin.IR.Add then "add" else "sub"),
                        Commutes => Op = Landin.IR.Add,
                        Check =>
                          (if Unchecked then ""
                           elsif Landin.Types.Is_Signed
                             (Landin.Types.Integer_Name (Kind))
                           then "jo" else "jc"));
                  end;

               when Landin.IR.Wrapping_Add
                  | Landin.IR.Wrapping_Subtract =>
                  Integer_Binary
                    ((if Op = Landin.IR.Wrapping_Add then "add" else "sub"),
                     Commutes => Op = Landin.IR.Wrapping_Add, Check => "");

               when Landin.IR.Divide | Landin.IR.Remainder =>
                  declare
                     Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Divide : constant String :=
                       Value_Label (Value) & "_divide";
                     Done : constant String :=
                       Value_Label (Value) & "_done";
                  begin
                     if Kind in Landin.Types.Float_Name then
                        if Op /= Landin.IR.Divide then
                           raise Compiler_Defect with
                             "float remainder passed IR verification";
                        end if;
                        Emit (Float_Move
                                (Kind = Landin.Types.F32,
                                 Value_Operand (Operand (1)), "%xmm0"));
                        Emit ((if Kind = Landin.Types.F32
                               then "divss " else "divsd ")
                              & Value_Operand (Operand (2)) & ", %xmm0");
                        Emit (Float_Move
                                (Kind = Landin.Types.F32,
                                 "%xmm0", Value_Operand (Value)));
                        return;
                     end if;

                     declare
                        Integer_Kind : constant Landin.Types.Integer_Name :=
                          Landin.Types.Integer_Name (Kind);
                        Signed : constant Boolean :=
                          Landin.Types.Is_Signed (Integer_Kind);
                        Minimum_Pattern : constant Landin.Types.Magnitude :=
                          2 ** Natural
                            (Landin.Types.Width (Integer_Kind, Facts) - 1);
                        Fixed : constant Boolean := Landin.IR.Op_Of
                          (Of_Unit, Item, Operand (2)) = Landin.IR.Number;
                        Magnitude : constant Landin.Types.Magnitude :=
                          (if Fixed then Landin.IR.Number_Of
                             (Of_Unit, Item, Operand (2)) else 0);
                        Negative : constant Boolean :=
                          Fixed and then Landin.IR.Is_Negated
                            (Of_Unit, Item, Operand (2));
                        Data_Register : constant String :=
                          (case Held is
                              when Landin.Targets.Byte_1 => "%dl",
                              when Landin.Targets.Byte_2 => "%dx",
                              when Landin.Targets.Byte_4 => "%edx",
                              when Landin.Targets.Byte_8 => "%rdx");
                        Counter_Register : constant String :=
                          (case Held is
                              when Landin.Targets.Byte_1 => "%cl",
                              when Landin.Targets.Byte_2 => "%cx",
                              when Landin.Targets.Byte_4 => "%ecx",
                              when Landin.Targets.Byte_8 => "%rcx");
                        Power : Landin.Types.Magnitude := Magnitude;
                        Shift : Natural := 0;
                     begin
                        --  A known nonzero divisor needs neither runtime
                        --  guard.  For a power of two, avoid the divide
                        --  instruction as well.  Signed division biases a
                        --  negative numerator before shifting so that its
                        --  quotient truncates toward zero.
                        if Magnitude /= 0 then
                           while Power mod 2 = 0 loop
                              Power := Power / 2;
                              Shift := Shift + 1;
                           end loop;
                        end if;
                        if Fixed and then Magnitude /= 0
                          and then Power = 1
                        then
                           if Op = Landin.IR.Remainder and then Shift = 0
                           then
                              Emit ("mov" & Suffix (Held) & " $0, "
                                    & Value_Operand (Value));
                              return;
                           end if;
                           Load_Value (Operand (1));
                           if Signed and then Negative and then Shift = 0
                           then
                              Emit ("movabsq $"
                                    & Trimmed
                                        (Landin.Types.Magnitude'Image
                                           (Minimum_Pattern))
                                    & ", %rdx");
                              Emit ("cmp" & Suffix (Held) & " "
                                    & Data_Register & ", "
                                    & Accumulator (Held));
                              Trap_On ("je");
                           end if;
                           if not Signed and then
                             Op = Landin.IR.Remainder
                           then
                              if Shift <= 31 then
                                 Emit ("and" & Suffix (Held) & " $"
                                       & Trimmed
                                           (Landin.Types.Magnitude'Image
                                              (Magnitude - 1)) & ", "
                                       & Accumulator (Held));
                              else
                                 Emit ("movabsq $"
                                       & Trimmed
                                           (Landin.Types.Magnitude'Image
                                              (Magnitude - 1))
                                       & ", %rdx");
                                 Emit ("andq %rdx, %rax");
                              end if;
                              Store_Value (Value, Accumulator (Held));
                              return;
                           end if;
                           if Signed and then
                             Op = Landin.IR.Remainder
                           then
                              Emit ("mov" & Suffix (Held) & " "
                                    & Accumulator (Held) & ", "
                                    & Counter_Register);
                           end if;
                           if Shift > 0 then
                              if Signed then
                                 Emit ("mov" & Suffix (Held) & " "
                                       & Accumulator (Held) & ", "
                                       & Data_Register);
                                 Emit ("sar" & Suffix (Held) & " $"
                                       & Trimmed (Natural'Image
                                           (Natural (Landin.Types.Width
                                              (Integer_Kind, Facts)) - 1))
                                       & ", " & Data_Register);
                                 Emit ("shr" & Suffix (Held) & " $"
                                       & Trimmed (Natural'Image
                                           (Natural (Landin.Types.Width
                                              (Integer_Kind, Facts)) - Shift))
                                       & ", " & Data_Register);
                                 Emit ("add" & Suffix (Held) & " "
                                       & Data_Register & ", "
                                       & Accumulator (Held));
                              end if;
                              Emit ((if Signed then "sar" else "shr")
                                    & Suffix (Held) & " $"
                                    & Trimmed (Natural'Image (Shift)) & ", "
                                    & Accumulator (Held));
                           end if;
                           if Op = Landin.IR.Remainder then
                              --  x - trunc(x / |d|) * |d| has the sign of x,
                              --  regardless of the divisor's sign.
                              Emit ("shl" & Suffix (Held) & " $"
                                    & Trimmed (Natural'Image (Shift)) & ", "
                                    & Accumulator (Held));
                              Emit ("sub" & Suffix (Held) & " "
                                    & Accumulator (Held) & ", "
                                    & Counter_Register);
                              Store_Value (Value, Counter_Register);
                           else
                              if Negative then
                                 Emit ("neg" & Suffix (Held) & " "
                                       & Accumulator (Held));
                              end if;
                              Store_Value (Value, Accumulator (Held));
                           end if;
                           return;
                        end if;

                        --  Speed multiplies by any other known divisor's
                        --  reciprocal: a high multiply and a shift or two,
                        --  where `div` takes tens of cycles.  The divisor
                        --  is not zero, and minus one is a power of two
                        --  above, so this division has no trap to keep.
                        --  The dividend is widened into RCX, which the
                        --  remainder subtracts from; RDX holds the
                        --  quotient.
                        if Fixed and then Magnitude /= 0
                          and then Options.Optimize
                            = Landin.Optimization.Speed
                        then
                           declare
                              package Reciprocals renames
                                Landin.Backend.Reciprocals;
                              Bits : constant Reciprocals.Dividend_Bits :=
                                Natural (Landin.Types.Width
                                  (Integer_Kind, Facts));
                              Inverse : constant Reciprocals.Reciprocal :=
                                (if Signed
                                 then Reciprocals.Signed_Reciprocal
                                   (Reciprocals.Word (Magnitude), Bits)
                                 else Reciprocals.Unsigned_Reciprocal
                                   (Reciprocals.Word (Magnitude), Bits));
                              Widen : constant String :=
                                (if Signed then
                                   (case Held is
                                       when Landin.Targets.Byte_1 =>
                                         "movsbq ",
                                       when Landin.Targets.Byte_2 =>
                                         "movswq ",
                                       when Landin.Targets.Byte_4 =>
                                         "movslq ",
                                       when Landin.Targets.Byte_8 =>
                                         "movq ")
                                 else
                                   (case Held is
                                       when Landin.Targets.Byte_1 =>
                                         "movzbl ",
                                       when Landin.Targets.Byte_2 =>
                                         "movzwl ",
                                       when Landin.Targets.Byte_4 =>
                                         "movl ",
                                       when Landin.Targets.Byte_8 =>
                                         "movq "));
                           begin
                              Emit (Widen & Value_Operand (Operand (1))
                                    & ", "
                                    & (if Signed
                                         or else Held = Landin.Targets.Byte_8
                                       then "%rcx" else "%ecx"));
                              Emit ("movabsq $"
                                    & Trimmed (Reciprocals.Word'Image
                                        (Inverse.Multiplier))
                                    & ", %rax");
                              Emit ((if Signed then "imulq" else "mulq")
                                    & " %rcx");
                              if Inverse.Add and then Signed then
                                 Emit ("addq %rcx, %rdx");
                              elsif Inverse.Add then
                                 --  (N - T) / 2 + T is (N + T) / 2
                                 --  without the 65th bit.
                                 Emit ("movq %rcx, %rax");
                                 Emit ("subq %rdx, %rax");
                                 Emit ("shrq $1, %rax");
                                 Emit ("addq %rax, %rdx");
                              end if;
                              if Inverse.Shift > 0 then
                                 Emit ((if Signed then "sarq $" else "shrq $")
                                       & Trimmed (Natural'Image
                                           (Inverse.Shift))
                                       & ", %rdx");
                              end if;
                              if Signed then
                                 --  Floor to truncation: a negative
                                 --  quotient is one too low.
                                 Emit ("movq %rdx, %rax");
                                 Emit ("shrq $63, %rax");
                                 Emit ("addq %rax, %rdx");
                              end if;
                              if Op = Landin.IR.Remainder then
                                 --  N - Q * |d| has the dividend's sign
                                 --  whatever the divisor's.
                                 if Magnitude <= 2 ** 31 - 1 then
                                    Emit ("imulq $"
                                          & Trimmed
                                              (Landin.Types.Magnitude'Image
                                                 (Magnitude))
                                          & ", %rdx, %rdx");
                                 else
                                    Emit ("movabsq $"
                                          & Trimmed
                                              (Landin.Types.Magnitude'Image
                                                 (Magnitude))
                                          & ", %rax");
                                    Emit ("imulq %rax, %rdx");
                                 end if;
                                 Emit ("subq %rdx, %rcx");
                                 Store_Value (Value, Counter_Register);
                              else
                                 if Negative then
                                    Emit ("neg" & Suffix (Held) & " "
                                          & Data_Register);
                                 end if;
                                 Store_Value (Value, Data_Register);
                              end if;
                              return;
                           end;
                        end if;

                        if not Fixed or else Magnitude = 0 then
                           Emit ("cmp" & Suffix (Held) & " $0, "
                                 & Value_Operand (Operand (2)));
                           Trap_On ("je");
                        end if;

                        if Signed and then not Fixed then
                           Emit ("cmp" & Suffix (Held) & " $-1, "
                                 & Value_Operand (Operand (2)));
                           Emit ("jne " & Divide);
                           Emit ("movabsq $"
                                 & Trimmed
                                     (Landin.Types.Magnitude'Image
                                        (Minimum_Pattern))
                                 & ", %rax");
                           Emit ("cmp" & Suffix (Held) & " "
                                 & Value_Operand (Operand (1)) & ", "
                                 & Accumulator (Held));
                           if Op = Landin.IR.Divide then
                              Trap_On ("je");
                           else
                              Emit ("jne " & Divide);
                              Emit ("mov" & Suffix (Held) & " $0, "
                                    & Value_Operand (Value));
                              Emit ("jmp " & Done);
                           end if;
                           Put (Divide & ":");
                        end if;

                        Emit ("mov" & Suffix (Held) & " "
                              & Value_Operand (Operand (1)) & ", "
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
                              & Value_Operand (Operand (2)));
                        Store_Value
                          (Value,
                           (if Op = Landin.IR.Divide
                            then Accumulator (Held)
                            else
                              (case Held is
                                  when Landin.Targets.Byte_1 => "%ah",
                                  when Landin.Targets.Byte_2 => "%dx",
                                  when Landin.Targets.Byte_4 => "%edx",
                                  when Landin.Targets.Byte_8 => "%rdx")));
                        if Op = Landin.IR.Remainder then
                           Put (Done & ":");
                        end if;
                     end;
                  end;

               when Landin.IR.Multiply =>
                  declare
                     Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     if Kind in Landin.Types.Float_Name then
                        Float_Binary
                          (if Kind = Landin.Types.F32 then "mulss"
                           else "mulsd");
                        return;
                     end if;

                     declare
                        Signed : constant Boolean :=
                          Landin.Types.Is_Signed
                            (Landin.Types.Integer_Name (Kind));
                     begin
                        --  Size and speed take a signed product in the
                        --  two- or three-operand `imul`, whose overflow
                        --  flag is the one-operand form's; an unsigned one
                        --  needs `mul`'s high half, and a byte has neither.
                        if Optimized and then Signed
                          and then Held /= Landin.Targets.Byte_1
                        then
                           Integer_Binary
                             ("imul", Commutes => True,
                              Check => (if Unchecked then "" else "jo"));
                           return;
                        end if;
                        Emit ("mov" & Suffix (Held) & " "
                              & Value_Operand (Operand (1)) & ", "
                              & Accumulator (Held));
                        Emit ((if Signed then "imul" else "mul")
                              & Suffix (Held) & " "
                              & Value_Operand (Operand (2)));
                        if not Unchecked then
                           Trap_On (if Signed then "jo" else "jc");
                        end if;
                        Emit ("mov" & Suffix (Held) & " "
                              & Accumulator (Held) & ", "
                              & Value_Operand (Value));
                     end;
                  end;

               when Landin.IR.Wrapping_Multiply =>
                  declare
                     Kind : constant Landin.Types.Integer_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     --  The low half is the same product at either
                     --  signedness, and `imul` has it without a high one.
                     if Optimized and then Held /= Landin.Targets.Byte_1 then
                        Integer_Binary
                          ("imul", Commutes => True, Check => "");
                        return;
                     end if;
                     Load_Value (Operand (1));
                     Emit ((if Landin.Types.Is_Signed (Kind)
                            then "imul" else "mul")
                           & Suffix (Held) & " "
                           & Value_Operand (Operand (2)));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Operand (Value));
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
                           when others =>
                             raise Landin.Compiler_Defect
                               with "an unreachable operator case");
                     --  A comparison whose one use is the branch right
                     --  after it leaves its verdict in the flags.
                     Fuses : constant Boolean :=
                       Optimized and then Uses (Positive (Value)) = 1
                       and then Next_Instruction /= Landin.IR.No_Value
                       and then Landin.IR.Op_Of
                         (Of_Unit, Item, Next_Instruction) = Landin.IR.Branch
                       and then Landin.IR.Nth_Operand
                         (Of_Unit, Item, Next_Instruction, 1) = Value;
                     --  So does one whose one use is the choice after it.
                     Feeds_Choice : constant Boolean :=
                       Optimized and then Uses (Positive (Value)) = 1
                       and then Allocation.Flags_Choice
                         (Of_Unit, Item, Value);

                     procedure Ordered_Equal_Branch
                       (Equal, Other : Landin.IR.Block_Id);

                     --  Equality is ZF set with PF clear: an unordered
                     --  pair sets both.
                     procedure Ordered_Equal_Branch
                       (Equal, Other : Landin.IR.Block_Id)
                     is
                        Following : constant Landin.IR.Block_Id :=
                          Current_Block + 1;
                     begin
                        Emit ("jne " & Label (Item, Threaded (Other)));
                        if Equal = Following then
                           Emit ("jp " & Label (Item, Threaded (Other)));
                        else
                           Emit ("jnp " & Label (Item, Threaded (Equal)));
                           if Other /= Following then
                              Emit ("jmp " & Label (Item, Threaded (Other)));
                           end if;
                        end if;
                     end Ordered_Equal_Branch;
                  begin
                     if Kind in Landin.Types.Float_Name and then Feeds_Choice
                     then
                        --  As below: "above" and "above or equal" are
                        --  false for an unordered pair, and less and
                        --  less-or-equal swap their operands to be those.
                        declare
                           Swapped : constant Boolean :=
                             Op in Landin.IR.Less_Than
                                 | Landin.IR.Less_Or_Equal;
                           Left : constant String :=
                             Value_Operand
                               (if Swapped then Operand (2)
                                else Operand (1));
                           Right : constant String :=
                             Value_Operand
                               (if Swapped then Operand (1)
                                else Operand (2));
                        begin
                           if not Is_XMM (Left) then
                              Emit (Float_Move
                                      (Kind = Landin.Types.F32,
                                       Left, "%xmm0"));
                           end if;
                           Emit ((if Kind = Landin.Types.F32
                                  then "ucomiss " else "ucomisd ")
                                 & Right & ", "
                                 & (if Is_XMM (Left) then Left
                                    else "%xmm0"));
                           Choice_Flags := Unbounded.To_Unbounded_String
                             (if Op in Landin.IR.Less_Than
                                     | Landin.IR.Greater_Than
                              then "a" else "ae");
                        end;
                        Fused_Choice := Next_Instruction;
                        return;
                     elsif Kind in Landin.Types.Float_Name and then Fuses then
                        --  D162's comparisons are false for an unordered
                        --  NaN, except inequality.  ucomis sets ZF, PF and
                        --  CF for one, so "above" and "above or equal",
                        --  which need CF clear, are false without a parity
                        --  test, and less and less-or-equal swap their
                        --  operands to be those.  The left operand is
                        --  compared where it lives when that is a register.
                        declare
                           Swapped : constant Boolean :=
                             Op in Landin.IR.Less_Than
                                 | Landin.IR.Less_Or_Equal;
                           Left : constant String :=
                             Value_Operand
                               (if Swapped then Operand (2)
                                else Operand (1));
                           Right : constant String :=
                             Value_Operand
                               (if Swapped then Operand (1)
                                else Operand (2));
                           Yes : constant Landin.IR.Block_Id :=
                             Landin.IR.Target_Of
                               (Of_Unit, Item, Next_Instruction);
                           No : constant Landin.IR.Block_Id :=
                             Landin.IR.Alternative_Of
                               (Of_Unit, Item, Next_Instruction);
                        begin
                           if not Is_XMM (Left) then
                              Emit (Float_Move
                                      (Kind = Landin.Types.F32,
                                       Left, "%xmm0"));
                           end if;
                           Emit ((if Kind = Landin.Types.F32
                                  then "ucomiss " else "ucomisd ")
                                 & Right & ", "
                                 & (if Is_XMM (Left) then Left
                                    else "%xmm0"));
                           case Op is
                              when Landin.IR.Less_Than
                                 | Landin.IR.Greater_Than =>
                                 Conditional_Branch ("a", Yes, No);
                              when Landin.IR.Less_Or_Equal
                                 | Landin.IR.Greater_Or_Equal =>
                                 Conditional_Branch ("ae", Yes, No);
                              when Landin.IR.Equal_To =>
                                 Ordered_Equal_Branch (Yes, No);
                              when Landin.IR.Not_Equal_To =>
                                 Ordered_Equal_Branch (No, Yes);
                              when others =>
                                 raise Compiler_Defect with
                                   "non-comparison in comparison emission";
                           end case;
                        end;
                        Fused_Branch := Next_Instruction;
                        return;
                     elsif Kind in Landin.Types.Float_Name then
                        Emit (Float_Move
                                (Kind = Landin.Types.F32,
                                 Value_Operand (Operand (1)), "%xmm0"));
                        Emit ((if Kind = Landin.Types.F32
                               then "ucomiss " else "ucomisd ")
                              & Value_Operand (Operand (2)) & ", %xmm0");
                        case Op is
                           when Landin.IR.Equal_To =>
                              Emit ("sete %al");
                              Emit ("setnp %cl");
                              Emit ("andb %cl, %al");
                           when Landin.IR.Not_Equal_To =>
                              Emit ("setne %al");
                              Emit ("setp %cl");
                              Emit ("orb %cl, %al");
                           when Landin.IR.Less_Than
                              | Landin.IR.Less_Or_Equal =>
                              Emit
                                ((if Op = Landin.IR.Less_Than
                                  then "setb " else "setbe ") & "%al");
                              Emit ("setnp %cl");
                              Emit ("andb %cl, %al");
                           when Landin.IR.Greater_Than =>
                              Emit ("seta %al");
                           when Landin.IR.Greater_Or_Equal =>
                              Emit ("setae %al");
                           when others =>
                              raise Compiler_Defect with
                                "non-comparison in comparison emission";
                        end case;
                        Emit ("movb %al, " & Value_Operand (Value));
                        return;
                     end if;

                     --  Size and speed compare a left operand held in a
                     --  register where it lives, and a right one that fits
                     --  as its immediate.
                     if Optimized
                       and then Allocation_Plan.Value
                         (Positive (Operand (1))).Kind = Allocation.GP
                     then
                        Emit ("cmp" & Suffix (Held) & " "
                              & Source_Operand (Operand (2)) & ", "
                              & Value_Operand (Operand (1), Held));
                     else
                        Load_Value (Operand (1));
                        Emit ("cmp" & Suffix (Held) & " "
                              & Source_Operand (Operand (2)) & ", "
                              & Accumulator (Held));
                     end if;
                     if Fuses then
                        Conditional_Branch
                          (Condition (Condition'First + 3 .. Condition'Last),
                           Landin.IR.Target_Of
                             (Of_Unit, Item, Next_Instruction),
                           Landin.IR.Alternative_Of
                             (Of_Unit, Item, Next_Instruction));
                        Fused_Branch := Next_Instruction;
                     elsif Feeds_Choice then
                        Choice_Flags := Unbounded.To_Unbounded_String
                          (Condition (Condition'First + 3 .. Condition'Last));
                        Fused_Choice := Next_Instruction;
                     else
                        Emit (Condition & " %al");
                        Store_Value (Value, "%al");
                     end if;
                  end;

               when Landin.IR.Choose =>
                  --  D338: the false value in the accumulator, replaced
                  --  by the true one when the condition holds.  cmov has
                  --  no immediate and no byte form, so a constant or a
                  --  narrow true value goes through %rcx first; a float
                  --  travels in its bits.  No move touches the flags a
                  --  comparison right before may have left the condition
                  --  in.  A choice of one or zero is the condition itself.
                  declare
                     Condition : constant Landin.IR.Value_Id := Operand (1);
                     If_True : constant Landin.IR.Value_Id := Operand (2);
                     If_False : constant Landin.IR.Value_Id := Operand (3);
                     Kind : constant Landin.Types.Scalar_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Wide : constant Boolean := Held = Landin.Targets.Byte_8;
                     Fused : constant Boolean := Value = Fused_Choice;
                     Flags : constant String :=
                       (if Fused then Unbounded.To_String (Choice_Flags)
                        else "ne");
                     True_Place : Allocation.Location renames
                       Allocation_Plan.Value (Positive (If_True));

                     function Is_Number
                       (Which : Landin.IR.Value_Id;
                        Of_Value : Landin.Types.Magnitude) return Boolean
                       is (Landin.IR.Op_Of (Of_Unit, Item, Which)
                             = Landin.IR.Number
                           and then Kind in Landin.Types.Integer_Name
                           and then Landin.IR.Number_Of
                             (Of_Unit, Item, Which) = Of_Value
                           and then (Of_Value = 0
                                     or else not Landin.IR.Is_Negated
                                       (Of_Unit, Item, Which)));

                     Counts_Up : constant Boolean :=
                       Is_Number (If_True, 1) and then Is_Number (If_False, 0);
                     Counts_Down : constant Boolean :=
                       Is_Number (If_True, 0) and then Is_Number (If_False, 1);
                  begin
                     if Optimized and then (Counts_Up or else Counts_Down)
                     then
                        if Fused then
                           Emit ("set"
                                 & (if Counts_Up then Flags
                                    else Inverse_Condition (Flags))
                                 & " %al");
                           Emit ("movzbl %al, %eax");
                        else
                           Emit ("movzbl " & Value_Operand (Condition)
                                 & ", %eax");
                           if Counts_Down then
                              Emit ("xorl $1, %eax");
                           end if;
                        end if;
                        Store_Value (Value, Accumulator (Held));
                        return;
                     end if;
                     Load_Value (If_False);
                     declare
                        Direct : constant Boolean :=
                          Held >= Landin.Targets.Byte_4
                          and then True_Place.Kind
                            in Allocation.GP | Allocation.Stack;
                        Other : constant String :=
                          (if Direct then Value_Operand (If_True)
                           elsif Wide then "%rcx" else "%ecx");
                     begin
                        if not Direct then
                           if True_Place.Kind = Allocation.SSE then
                              Emit ((if Wide then "movq " else "movd ")
                                    & Value_Operand (If_True) & ", "
                                    & Other);
                           else
                              Emit (Move
                                (Held, Source_Operand (If_True),
                                 (case Held is
                                     when Landin.Targets.Byte_1 => "%cl",
                                     when Landin.Targets.Byte_2 => "%cx",
                                     when Landin.Targets.Byte_4 => "%ecx",
                                     when Landin.Targets.Byte_8 => "%rcx")));
                           end if;
                        end if;
                        if not Fused then
                           Emit ("cmpb $0, " & Value_Operand (Condition));
                        end if;
                        Emit ("cmov" & Flags & " " & Other & ", "
                              & (if Wide then "%rax" else "%eax"));
                     end;
                     Store_Value (Value, Accumulator (Held));
                  end;

               when Landin.IR.Failure_Test =>
                  Emit ("cmpl $0, " & Value_Operand (Operand (1)));
                  Emit ("setne %al");
                  Emit ("movb %al, " & Value_Operand (Value));

               when Landin.IR.Function_Address =>
                  declare
                     Callee : constant Landin.IR.Item_Id :=
                       Landin.IR.Callee_Of (Of_Unit, Item, Value);
                     Imported : constant Boolean :=
                       Landin.IR.Is_External (Of_Unit, Callee);
                  begin
                     --  A PIE cannot use a PC32 address relocation to an
                     --  imported definition. The GOT supplies its address.
                     Emit
                       ((if Imported then "movq " else "leaq ")
                        & Symbol (Callee)
                        & (if Imported then "@GOTPCREL" else "")
                        & "(%rip), %rax");
                  end;
                  Emit ("movq %rax, " & Value_Operand (Value));

               when Landin.IR.Evidence_Address =>
                  Emit
                    ("leaq "
                     & Evidence_Symbol
                         (Landin.IR.Evidence_Of (Of_Unit, Item, Value))
                     & "(%rip), %rax");
                  Emit ("movq %rax, " & Value_Operand (Value));

               when Landin.IR.Evidence_Function =>
                  declare
                     Which : constant Natural :=
                       Landin.IR.Evidence_Entry_Of (Of_Unit, Item, Value);
                     Offset : constant Landin.Targets.Byte_Count :=
                       Landin.Targets.Evidence_Function_Offset
                         (Facts, Positive (Which));
                  begin
                     Emit ("movq " & Value_Operand (Operand (1)) & ", %rax");
                     if Landin.IR.Evidence_Is_Erased
                       (Of_Unit, Landin.IR.Evidence_Of (Of_Unit, Item, Value))
                     then
                        --  The saved descriptor is data then table. The
                        --  paired self projection reads this same snapshot.
                        Emit ("movq 8(%rax), %rax");
                     end if;
                     Emit
                       ("movq "
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Offset))
                        & "(%rax), %rax");
                     Emit ("movq %rax, " & Value_Operand (Value));
                  end;

               when Landin.IR.Evidence_Self =>
                  declare
                     Receiver : constant Landin.IR.Value_Id :=
                       Landin.IR.Nth_Operand
                         (Of_Unit, Item, Operand (1), 1);
                  begin
                     Emit ("movq " & Value_Operand (Receiver) & ", %rax");
                     Emit ("movq (%rax), %rax");
                     Emit ("movq %rax, " & Value_Operand (Value));
                  end;

               when Landin.IR.Call | Landin.IR.Indirect_Call =>
                  if (if Op = Landin.IR.Indirect_Call
                      then Landin.IR.Signature_Uses_C_ABI
                        (Of_Unit,
                         Landin.IR.Call_Signature (Of_Unit, Item, Value))
                      else Is_C_Item
                        (Landin.IR.Callee_Of (Of_Unit, Item, Value)))
                  then
                     Emit_C_Call (Value);
                     return;
                  end if;
                  --  [1920] names every parameter once and in order, so the
                  --  operands are already the argument list.  The first six
                  --  scalars fill the internal convention's integer
                  --  registers; each later scalar occupies an eight-byte
                  --  stack slot, in source order from the current `%rsp`.
                  --  Round the whole outgoing run to the target's stack
                  --  alignment, keeping the call boundary aligned without
                  --  making padding part of the argument run.  A `-> none`
                  --  callee defines nothing, and [1930] says there is no
                  --  result there to store.
                  declare
                     Gives : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Indirect : constant Boolean :=
                       Landin.IR.Op_Of (Of_Unit, Item, Value)
                         = Landin.IR.Indirect_Call;
                     Callee : constant Landin.IR.Item_Id :=
                       (if Indirect then Landin.IR.No_Item
                        else Landin.IR.Callee_Of
                          (Of_Unit, Item, Value));
                     Offset : constant Natural :=
                       (if Indirect then 1 else 0);
                     --  A C callee reads a narrow integer argument as the
                     --  32-bit register: GCC and Clang assume the caller
                     --  extended it, and passing only the low byte left the
                     --  upper bits to chance.  The internal
                     --  convention keeps the exact width for Landin callees,
                     --  which copy the width they declared.
                     External : constant Boolean :=
                       not Indirect
                       and then Landin.IR.Is_External (Of_Unit, Callee);
                     Count : constant Natural :=
                       Landin.IR.Operand_Count (Of_Unit, Item, Value) - Offset;

                     function Extension
                       (Argument : Landin.IR.Value_Id;
                        Held     : Held_Size;
                        Wide     : Held_Size) return String;

                     function Extension
                       (Argument : Landin.IR.Value_Id;
                        Held     : Held_Size;
                        Wide     : Held_Size) return String
                     is
                        Signed : constant Boolean :=
                          Landin.IR.Result_Of (Of_Unit, Item, Argument)
                            in Landin.Types.I8 | Landin.Types.I16;
                     begin
                        return "mov" & (if Signed then "s" else "z")
                          & Suffix (Held) & Suffix (Wide);
                     end Extension;
                     Stack_Bytes : constant Landin.Targets.Byte_Count :=
                       Native_Argument_Bytes (Count, Facts);
                  begin
                     Reserve_Stack
                       (Stack_Bytes, "call_"
                        & Trimmed (Landin.IR.Value_Id'Image (Value)));

                     for Index in 1 .. Count loop
                        declare
                           Argument : constant Landin.IR.Value_Id :=
                             Operand (Index + Offset);
                           Held : constant Held_Size :=
                             Size_Of_Value (Argument);
                           Narrow : constant Boolean :=
                             External
                             and then Held in Landin.Targets.Byte_1
                                              | Landin.Targets.Byte_2;
                        begin
                           if Index <= Register_Arguments then
                              if Narrow then
                                 Emit (Extension
                                         (Argument, Held,
                                          Landin.Targets.Byte_4)
                                       & " " & Value_Operand (Argument) & ", "
                                       & Argument_Register
                                           (Index, Landin.Targets.Byte_4));
                              else
                                 Emit ("mov" & Suffix (Held) & " "
                                       & Value_Operand (Argument) & ", "
                                       & Argument_Register (Index, Held));
                              end if;
                           elsif Narrow then
                              Emit (Extension
                                      (Argument, Held, Landin.Targets.Byte_8)
                                    & " " & Value_Operand (Argument)
                                    & ", %rax");
                              Emit ("movq %rax, "
                                    & Trimmed
                                        (Landin.Targets.Byte_Count'Image
                                           (Landin.Targets.Byte_Count
                                              (Index - Register_Arguments - 1)
                                            * Stack_Argument_Bytes))
                                    & "(%rsp)");
                           else
                              Carry
                                (Held, Value_Operand (Argument),
                                 Trimmed
                                   (Landin.Targets.Byte_Count'Image
                                      (Landin.Targets.Byte_Count
                                         (Index - Register_Arguments - 1)
                                       * Stack_Argument_Bytes))
                                 & "(%rsp)");
                           end if;
                        end;
                     end loop;

                     if Indirect then
                        Emit ("call *" & Value_Operand (Operand (1)));
                     else
                        Emit ("call " & Symbol (Callee));
                     end if;

                     if Landin.IR.Failure_Slot_Of
                          (Of_Unit, Item, Value) /= Landin.IR.No_Slot
                     then
                        Emit
                          ("movl %r10d, "
                           & Slot_Cell
                               (Landin.IR.Failure_Slot_Of
                                  (Of_Unit, Item, Value)));
                     end if;

                     if Stack_Bytes > 0 then
                        Emit ("addq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image
                                     (Stack_Bytes))
                              & ", %rsp");
                     end if;

                     if Gives in Landin.Types.Scalar_Name then
                        declare
                           Held : constant Held_Size :=
                             Size_Of (Gives, Facts);
                        begin
                           if Allocation_Plan.Value (Positive (Value)).Kind
                             = Allocation.SSE
                           then
                              Store_Value (Value, Accumulator (Held));
                           else
                              Emit ("mov" & Suffix (Held) & " "
                                    & Accumulator (Held) & ", "
                                    & Value_Operand (Value));
                           end if;
                        end;
                     end if;
                  end;

               when Landin.IR.Jump =>
                  if not Optimized or else Landin.IR.Target_Of
                    (Of_Unit, Item, Value) /= Current_Block + 1
                  then
                     Emit ("jmp " & Label (Item, Threaded
                           (Landin.IR.Target_Of (Of_Unit, Item, Value))));
                  end if;

               when Landin.IR.Branch =>
                  if Value /= Fused_Branch then
                     --  A bool is a byte, and zero is [1870]'s false.
                     Emit ("cmpb $0, " & Value_Operand (Operand (1)));
                     Conditional_Branch
                       ("ne", Landin.IR.Target_Of (Of_Unit, Item, Value),
                        Landin.IR.Alternative_Of (Of_Unit, Item, Value));
                  end if;

               when Landin.IR.Leave =>
                  if Is_C_Item (Item) then
                     Emit_C_Result (Value);
                     Emit_Epilogue (Value);
                     return;
                  end if;
                  --  [1810]'s return carries what the named return place
                  --  held; a `-> none` routine carries nothing.
                  if Result in Landin.Types.Scalar_Name then
                     Load_Value (Operand (1));
                  elsif Result in Landin.Types.Aggregate
                                   | Landin.Types.Fixed_Array
                  then
                     declare
                        Return_Address : constant Landin.IR.Slot_Id :=
                          Landin.IR.Nth_Parameter (Of_Unit, Item, 1);
                        Return_Value : constant Landin.IR.Slot_Id :=
                          Landin.IR.Result_Slot (Of_Unit, Item);
                        Bytes : constant Landin.Targets.Byte_Count :=
                          Whole_Clear_Extent
                            ((Kind => Landin.IR.Frame_Slot,
                              Slot => Return_Value), 0,
                             Landin.IR.No_Path_Steps);
                     begin
                        Emit ("movq " & Slot_Cell (Return_Address)
                              & ", %rdi");
                        Storage_Address
                          ((Kind => Landin.IR.Frame_Slot,
                            Slot => Return_Value), 0, "%rsi");
                        if Speed_Unrolled (Bytes) then
                           Emit_Small_Copy (Bytes);
                        else
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (Bytes))
                              & ", %rcx");
                           Emit ("cld");
                           Emit ("rep movsb");
                        end if;
                        Emit ("movq " & Slot_Cell (Return_Address)
                              & ", %rax");
                     end;
                  end if;

                  if Landin.IR.Signature_Of (Of_Unit, Item)
                       /= Landin.IR.No_Signature
                    and then Landin.IR.Signature_Errors
                      (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
                        /= Landin.IR.No_Atom_Set
                  then
                     Emit ("xorl %r10d, %r10d");
                  end if;
                  Emit_Epilogue (Value);

               when Landin.IR.Halt =>
                  Emit_Panic;

               when Landin.IR.Fail =>
                  Emit ("movl " & Value_Operand (Operand (1)) & ", %r10d");
                  Emit_Epilogue (Value);
            end case;
            declare
               Atoms : constant Landin.IR.Atom_Set_Id :=
                 Landin.IR.Atom_Set_Of (Of_Unit, Item, Value);
            begin
               if Landin.IR.Validates_Atoms (Of_Unit, Item, Value)
                 and then not
                   (Optimized and then Proven (Positive (Value)) = 1)
               then
                  declare
                     Done : constant String := Value_Label (Value) & "_valid";
                  begin
                     if Landin.IR.Admits_Reserved_Zero
                       (Of_Unit, Item, Value)
                     then
                        Emit ("cmpl $0, " & Value_Operand (Value));
                        Emit ("je " & Done);
                     end if;
                     declare
                        Runs : constant Code_Runs :=
                          Runs_Of (Of_Unit, Atoms_Ranked, Atoms);
                     begin
                        --  A code outside the last run fails, so a valid
                        --  code there falls through to the load's use.
                        for Index in Runs'Range loop
                           declare
                              Run : constant Code_Run := Runs (Index);
                              Next : constant String :=
                                Done & "_" & Trimmed (Positive'Image (Index));
                              Last : constant Boolean := Index = Runs'Last;
                           begin
                              if Run.Low = Run.High then
                                 Emit ("cmpl $" & Trimmed
                                   (Positive'Image (Run.Low))
                                   & ", " & Value_Operand (Value));
                                 if Last then
                                    Trap_On
                                      ("jne", Landin.Panics.Bad_Conversion);
                                 else
                                    Emit ("je " & Done);
                                 end if;
                              else
                                 Emit ("cmpl $" & Trimmed
                                   (Positive'Image (Run.Low))
                                   & ", " & Value_Operand (Value));
                                 if Last then
                                    Trap_On
                                      ("jb", Landin.Panics.Bad_Conversion);
                                 else
                                    Emit ("jb " & Next);
                                 end if;
                                 Emit ("cmpl $" & Trimmed
                                   (Positive'Image (Run.High))
                                   & ", " & Value_Operand (Value));
                                 if Last then
                                    Trap_On
                                      ("ja", Landin.Panics.Bad_Conversion);
                                 else
                                    Emit ("jbe " & Done);
                                    Put (Next & ":");
                                 end if;
                              end if;
                           end;
                        end loop;
                        if Runs'Length = 0 then
                           Emit_Panic (Landin.Panics.Bad_Conversion);
                        end if;
                     end;
                     Put (Done & ":");
                  end;
               end if;
            end;
         end Emit_Instruction;

      begin
         for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            for Position in 1 .. Landin.IR.Length
              (Of_Unit, Item, Landin.IR.Block_Id (Block))
            loop
               declare
                  Value : constant Landin.IR.Value_Id := Landin.IR.Nth_Value
                    (Of_Unit, Item, Landin.IR.Block_Id (Block), Position);
               begin
                  if Landin.IR.Op_Of (Of_Unit, Item, Value) in
                    Landin.IR.Leave | Landin.IR.Fail
                  then
                     Exit_Count := Exit_Count + 1;
                  end if;
               end;
            end loop;
         end loop;

         if Is_Exported_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ELF.Function_Type (Symbol (Item)));
         Put (Symbol (Item) & ":");
         Machine.Start
           (Streams (Positive (Item)), Shareable (Positive (Item)));
         Capturing := Item;
         if Debug /= null then
            Put (Dwarf.Label_Name (Local_Prefix, "begin", Item) & ":");
            Put (Dwarf.Source_Line
              (Debug.all, Landin.IR.Origin_Of (Of_Unit, Item)));
            Emit (".cfi_startproc");
         end if;

         --  A naked routine is its text and nothing else: no frame record
         --  and no saved register.  It is a process's own entry, which no
         --  caller entered, so its return address is undefined; text that
         --  falls off its end traps.
         if Landin.IR.Signature_Machine
           (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
             = Landin.Machine.Naked_Routine
         then
            if Debug /= null then
               Emit (".cfi_undefined %rip");
            end if;
            for Position in 1 .. Landin.IR.Length (Of_Unit, Item, 1) loop
               declare
                  Value : constant Landin.IR.Value_Id :=
                    Landin.IR.Nth_Value (Of_Unit, Item, 1, Position);
               begin
                  if Debug /= null then
                     Put (Dwarf.Label_Name
                       (Local_Prefix, "value", Item, Natural (Value)) & ":");
                     Put (Dwarf.Source_Line
                       (Debug.all, Landin.IR.Origin_Of
                          (Of_Unit, Item, Value)));
                  end if;
                  if Landin.IR.Op_Of (Of_Unit, Item, Value)
                    = Landin.IR.Assembly
                  then
                     Emit_Naked_Text
                       (Landin.Source.Names.Spelling
                          (Names, Landin.IR.Assembly_Text
                             (Of_Unit, Item, Value)));
                  end if;
                  if Debug /= null then
                     Put (Dwarf.Label_Name
                       (Local_Prefix, "after", Item, Natural (Value)) & ":");
                  end if;
               end;
            end loop;
            Emit_Verbatim ("ud2");
            if Debug /= null then
               Put (Dwarf.Label_Name (Local_Prefix, "end", Item) & ":");
               Emit (".cfi_endproc");
            end if;
            Capturing := Landin.IR.No_Item;
            Statistics (Positive (Item)) :=
              (Item => Item, Naked => True, others => <>);
            Put (Character'Val (9) & ELF.Size_To_Here (Symbol (Item)));
            return;
         end if;

         --  [1550]'s frame pointer, set up before anything reads a cell.
         Emit ("pushq %rbp");
         if Debug /= null then
            Emit (".cfi_def_cfa_offset 16");
            Emit (".cfi_offset %rbp, -16");
         end if;
         Emit ("movq %rsp, %rbp");
         if Debug /= null then
            Emit (".cfi_def_cfa_register %rbp");
         end if;

         --  The hosted entry keeps its source-level no-argument shape.  The
         --  frame-pointer push aligned the stack for this C call, before any
         --  body code can clobber argc, argv and envp in rdi, rsi and rdx.
         --  C-owned startup calls the same initializer explicitly; ordinary
         --  exports and callbacks never do.
         if Item = Hosted_Entry and then Initializer /= Landin.IR.No_Item then
            Emit ("call " & Symbol (Initializer));
         end if;

         Reserve_Stack (Extent (Layout), "frame");
         if Panic /= null and then Item = Landin.Panics.Handler (Panic.all)
         then
            Emit ("movl $1, %eax");
            Emit ("xchgl %eax, " & Local_Prefix
              & "landin_panic_active(%rip)");
            Emit ("testl %eax, %eax");
            Emit ("jz " & Label (Item, 1) & "_panic_first");
            Emit ("ud2");
            Put (Label (Item, 1) & "_panic_first:");
         end if;

         for Register in Allocation.Saved_Register loop
            if Allocation_Plan.Used (Register) then
               Emit ("movq "
                     & Allocation.Name (Register, Landin.Targets.Byte_8)
                     & ", " & Cell (Save_Offset
                       (Layout, Allocation.Save_Index
                          (Allocation_Plan, Register))));
               if Debug /= null then
                  Emit (".cfi_offset " & Trimmed (Natural'Image
                    (Dwarf.Register_Number (Register))) & ", -"
                    & Trimmed (Landin.Targets.Byte_Count'Image
                      (Save_Offset (Layout, Allocation.Save_Index
                        (Allocation_Plan, Register)) + 16)));
               end if;
            end if;
         end loop;

         if Is_C_Item (Item) then
            Emit_C_Entry;
         else
            --  A scalar parameter is copied directly into its slot.  D94's
            --  aggregate argument transports an address in the same position;
            --  preserve every such address before any byte copy clobbers the
            --  integer argument registers, then copy into the parameter's own
            --  aggregate frame slot.  The copy is what keeps `in` by value.
            for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
               declare
                  Slot : constant Landin.IR.Slot_Id :=
                    Landin.IR.Nth_Parameter (Of_Unit, Item, Index);
               begin
                  if not Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                    and then not Landin.IR.Is_Array (Of_Unit, Item, Slot)
                  then
                     declare
                        Held : constant Held_Size := Size_Of_Slot (Slot);
                     begin
                        if Index <= Register_Arguments and then Optimized
                        then
                           --  Nothing when the slot is held where it
                           --  arrives; a float slot in an XMM register.
                           Carry
                             (Held, Argument_Register (Index, Held),
                              Slot_Cell (Slot));
                        elsif Index <= Register_Arguments then
                           Emit ("mov" & Suffix (Held) & " "
                                 & Argument_Register (Index, Held) & ", "
                                 & Slot_Cell (Slot));
                        else
                           Carry
                             (Held,
                              Trimmed
                                (Landin.Targets.Byte_Count'Image
                                   (16 + Landin.Targets.Byte_Count
                                           (Index - Register_Arguments - 1)
                                         * Stack_Argument_Bytes))
                              & "(%rbp)",
                              Slot_Cell (Slot));
                        end if;
                     end;
                  end if;
               end;
            end loop;

            for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
               declare
                  Slot : constant Landin.IR.Slot_Id :=
                    Landin.IR.Nth_Parameter (Of_Unit, Item, Index);
               begin
                  if Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                    or else Landin.IR.Is_Array (Of_Unit, Item, Slot)
                  then
                     Pushed_Arguments := Pushed_Arguments + 8;
                     Deepest_Area := Landin.Targets.Byte_Count'Max
                       (Deepest_Area, Pushed_Arguments);
                     if Index <= Register_Arguments then
                        Emit
                          ("pushq "
                           & Argument_Register (Index, Landin.Targets.Byte_8));
                     else
                        Emit
                          ("pushq "
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image
                                  (16 + Landin.Targets.Byte_Count
                                          (Index - Register_Arguments - 1)
                                        * Stack_Argument_Bytes))
                           & "(%rbp)");
                     end if;
                  end if;
               end;
            end loop;

            for Index in reverse
              1 .. Landin.IR.Parameter_Count (Of_Unit, Item)
            loop
               declare
                  Slot : constant Landin.IR.Slot_Id :=
                    Landin.IR.Nth_Parameter (Of_Unit, Item, Index);
               begin
                  if Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                    or else Landin.IR.Is_Array (Of_Unit, Item, Slot)
                  then
                     declare
                        Bytes : Landin.Targets.Byte_Count;
                        Alignment : Landin.Targets.Byte_Alignment;
                        Zero_Label : constant String := Label (Item, 1)
                          & "_zero_arg_" & Trimmed (Natural'Image (Index));
                        Done_Label : constant String := Zero_Label & "_done";
                     begin
                        if Landin.IR.Is_Aggregate (Of_Unit, Item, Slot) then
                           Landin.Backend.Aggregate_Extent
                             (Of_Unit, Item, Slot, Facts, Bytes, Alignment);
                        else
                           Landin.Backend.Field_Extent
                             (Of_Unit,
                              Landin.IR.Whole_Slot_Array_Shape
                                (Of_Unit, Item, Slot),
                              Facts, Bytes, Alignment);
                        end if;
                        Emit ("popq %rsi");
                        Storage_Address
                          ((Kind => Landin.IR.Frame_Slot, Slot => Slot),
                           0, "%rdi");
                        Emit ("testq %rsi, %rsi");
                        Emit ("jz " & Zero_Label);
                        if Bytes <= Unrolled_Transfer
                          or else Speed_Unrolled (Bytes)
                        then
                           Move_Unrolled (Bytes, Copy => True);
                        else
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (Bytes))
                              & ", %rcx");
                           Emit ("cld");
                           Emit ("rep movsb");
                        end if;
                        Emit ("jmp " & Done_Label);
                        Put (Zero_Label & ":");
                        Emit ("xorl %eax, %eax");
                        if Bytes <= Unrolled_Transfer
                          or else Speed_Unrolled (Bytes)
                        then
                           Move_Unrolled (Bytes, Copy => False);
                        else
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (Bytes))
                              & ", %rcx");
                           Emit ("cld");
                           Emit ("rep stosb");
                        end if;
                        Put (Done_Label & ":");
                     end;
                  end if;
               end;
            end loop;

            --  Landin.IR.In_Place's parameter is an address slot, stored
            --  above like a scalar, through which the body reads its
            --  caller's storage.  D97's zero carrier still clears the
            --  parameter's own home, which the parameter then addresses.
            for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
               declare
                  Slot : constant Landin.IR.Slot_Id :=
                    Landin.IR.Nth_Parameter (Of_Unit, Item, Index);
                  Home : constant Landin.IR.Slot_Id :=
                    Landin.IR.In_Place_Home (Of_Unit, Item, Slot);
               begin
                  if Home /= Landin.IR.No_Slot then
                     declare
                        Bytes : Landin.Targets.Byte_Count;
                        Alignment : Landin.Targets.Byte_Alignment;
                        Done_Label : constant String := Label (Item, 1)
                          & "_zero_arg_" & Trimmed (Natural'Image (Index))
                          & "_done";
                        Held : constant String := Slot_Cell (Slot);
                     begin
                        if Landin.IR.Is_Aggregate (Of_Unit, Item, Home) then
                           Landin.Backend.Aggregate_Extent
                             (Of_Unit, Item, Home, Facts, Bytes, Alignment);
                        else
                           Landin.Backend.Field_Extent
                             (Of_Unit,
                              Landin.IR.Whole_Slot_Array_Shape
                                (Of_Unit, Item, Home),
                              Facts, Bytes, Alignment);
                        end if;
                        if Allocation_Plan.Slot (Positive (Slot)).Kind
                          = Allocation.GP
                        then
                           Emit ("testq " & Held & ", " & Held);
                        else
                           Emit ("cmpq $0, " & Held);
                        end if;
                        Emit ("jnz " & Done_Label);
                        Storage_Address
                          ((Kind => Landin.IR.Frame_Slot, Slot => Home),
                           0, "%rdi");
                        Emit ("xorl %eax, %eax");
                        if Bytes <= Unrolled_Transfer
                          or else Speed_Unrolled (Bytes)
                        then
                           Move_Unrolled (Bytes, Copy => False);
                        else
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (Bytes))
                              & ", %rcx");
                           Emit ("cld");
                           Emit ("rep stosb");
                        end if;
                        Storage_Address
                          ((Kind => Landin.IR.Frame_Slot, Slot => Home),
                           0, "%rax");
                        Emit ("movq %rax, " & Held);
                        Put (Done_Label & ":");
                     end;
                  end if;
               end;
            end loop;
         end if;

         if Optimized then
            Count_Uses (Of_Unit, Item, Uses, References);
            Prove_Atom_Loads;
         end if;
         if Options.Optimize = Landin.Optimization.Speed then
            Find_Loop_Heads;
         end if;
         for Index in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            declare
               Block : constant Landin.IR.Block_Id :=
                 Landin.IR.Block_Id (Index);
            begin
               Current_Block := Block;
               if Loop_Heads'Length > 0 and then Loop_Heads (Index) = 1 then
                  if Transferred then
                     Emit (".p2align 5");
                  else
                     Emit (".p2align 4,,10");
                     Emit (".p2align 3");
                  end if;
               end if;
               Put (Label (Item, Block) & ":");
               Transferred := False;

               for Position in 1 .. Landin.IR.Length
                                      (Of_Unit, Item, Block)
               loop
                  Current_Position := Position;
                  Next_Instruction :=
                    (if Position < Landin.IR.Length (Of_Unit, Item, Block)
                     then Landin.IR.Nth_Value
                       (Of_Unit, Item, Block, Position + 1)
                     else Landin.IR.No_Value);
                  declare
                     Value : constant Landin.IR.Value_Id :=
                       Landin.IR.Nth_Value (Of_Unit, Item, Block, Position);
                  begin
                     if Debug /= null then
                        Put (Dwarf.Label_Name
                          (Local_Prefix, "value", Item, Natural (Value))
                          & ":");
                        Put (Dwarf.Source_Line
                          (Debug.all, Landin.IR.Origin_Of
                            (Of_Unit, Item, Value)));
                     end if;
                     Emit_Instruction (Value);
                     if Debug /= null then
                        Put (Dwarf.Label_Name
                          (Local_Prefix, "after", Item, Natural (Value))
                          & ":");
                     end if;
                  end;
               end loop;
            end;
         end loop;

         if Exit_Count > 1 then
            Put (Shared_Epilogue & ":");
            --  The traps after this teardown run in the body's frame.
            if Debug /= null and then not Traps.Is_Empty then
               Emit (".cfi_remember_state");
            end if;
            Emit_Epilogue_Body;
            if Debug /= null and then not Traps.Is_Empty then
               Emit (".cfi_restore_state");
            end if;
         end if;
         Emit_Traps;

         if Debug /= null then
            Put (Dwarf.Label_Name (Local_Prefix, "end", Item) & ":");
            Emit (".cfi_endproc");
         end if;
         Capturing := Landin.IR.No_Item;
         if Shareable (Positive (Item)) then
            Machine.Seal (Streams (Positive (Item)));
         end if;
         Statistics (Positive (Item)) :=
           Machine.Statistics (Streams (Positive (Item)));
         declare
            Counts : Landin.Build_Reports.Routine_Statistics renames
              Statistics (Positive (Item));
         begin
            Counts.Item := Item;
            Counts.Frame_Bytes := Extent (Layout);
            Counts.Spill_Bytes := Spill_Bytes (Layout);
            Counts.Save_Bytes := Save_Bytes (Layout);
            Counts.Register_Count := Allocation.Save_Count (Allocation_Plan)
              + Allocation.SSE_Count (Allocation_Plan);
            Counts.Spill_Count := Allocation_Plan.Spill_Homes;
            Counts.Stack_Bytes := 16 + Extent (Layout) + Deepest_Area;
            Counts.Calls_Panic := Calls_Panic;
         end;
         Put (Character'Val (9) & ELF.Size_To_Here (Symbol (Item)));
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
                               (Atoms_Ranked,
                                Landin.IR.Atom_Of
                                  (Of_Unit, Item, Value)));

                     --  [0370] in a module value, folded here for the
                     --  same reason the shifts are: it needs a target.
                     when Landin.IR.Measurement_Kind =>
                        declare
                           Size : Landin.Targets.Byte_Count;
                           Alignment : Landin.Targets.Byte_Alignment;
                        begin
                           Measurement_Extent
                             (Of_Unit, Item, Value, Facts, Size, Alignment);
                           Held (Natural (Value)) :=
                             (if Op /= Landin.IR.Measure_Align
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
                        | Landin.IR.Code_Address
                        | Landin.IR.Evidence_Address
                        | Landin.IR.Evidence_Function
                        | Landin.IR.Evidence_Self | Landin.IR.Call
                        | Landin.IR.Memory_Access | Landin.IR.Assembly
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
                        | Landin.IR.Choose
                        | Landin.IR.Jump | Landin.IR.Branch
                        | Landin.IR.Fail | Landin.IR.Halt =>
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
         Datum_Layouts : Landin.IR.Shape_Measurement.Layout_Cache;
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
                     Emit (".quad " & Base);
                     Emit
                       (".quad "
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
                 "a malformed recursive array image reached x86-64";
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
                 "a malformed recursive variant image reached x86-64";
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
                         (Of_Unit, Shape, Selected, Payload, Facts,
                          Datum_Layouts);
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
                             (Atoms_Ranked, Landin.IR.Declaration_Id
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
                       "a malformed nested image reached x86-64";
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

         if Is_Exported_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;
         Put (Character'Val (9) & ELF.Object_Type (Symbol (Item)));
         Put
           (Character'Val (9) & ".align "
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
         Put
           (Character'Val (9) & ELF.Size
              (Symbol (Item),
               Trimmed (Landin.Targets.Byte_Count'Image (Size))));
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
         Alignment : Landin.Targets.Byte_Alignment)
      is
         Bytes : constant String :=
           Trimmed (Landin.Targets.Byte_Count'Image (Size));
      begin
         if Is_Exported_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ELF.Object_Type (Symbol (Item)));
         Put (Character'Val (9) & ".align "
              & Trimmed (Landin.Targets.Byte_Alignment'Image (Alignment)));
         Put (Symbol (Item) & ":");
         Emit (".zero " & Bytes);
         Put (Character'Val (9) & ELF.Size (Symbol (Item), Bytes));
      end Emit_Reserved;

      --  [0520]'s array: the element repeated, so its extent is one
      --  multiplication and its alignment is the element's own.  A length
      --  of zero takes no room and aligns to a byte, having no element to
      --  be aligned as.
      --  The extent the zero-image emitters below reserve for `Item`.
      function Reserved_Extent
        (Item : Landin.IR.Item_Id) return Landin.Targets.Byte_Count;

      function Reserved_Extent
        (Item : Landin.IR.Item_Id) return Landin.Targets.Byte_Count is
      begin
         case Landin.IR.Result_Of (Of_Unit, Item) is
            when Landin.Types.Aggregate =>
               declare
                  Placed  : Landin.Targets.Placement;
                  Ignored : Landin.Targets.Byte_Count;
               begin
                  Place_Fields (Item, Placed, 0, Ignored);
                  return Landin.Targets.Size_Of (Placed);
               end;
            when Landin.Types.Fixed_Array =>
               declare
                  Size : Landin.Targets.Byte_Count;
                  Alignment : Landin.Targets.Byte_Alignment;
               begin
                  Landin.Backend.Field_Extent
                    (Of_Unit, Landin.IR.Array_Element_Shape (Of_Unit, Item),
                     Facts, Size, Alignment);
                  return Landin.Targets.Byte_Count
                    (Landin.IR.Array_Length (Of_Unit, Item)) * Size;
               end;
            when others =>
               return Landin.Targets.Byte_Count
                 (Landin.Targets.Bytes
                    (Size_Of (Landin.IR.Result_Of (Of_Unit, Item), Facts)));
         end case;
      end Reserved_Extent;

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
            Bytes : constant String :=
              Trimmed
                (Landin.Targets.Byte_Count'Image
                   (Landin.Targets.Byte_Count (Length)
                    * Landin.Targets.Byte_Count
                        (Landin.Targets.Bytes (Held))));
         begin
            if Is_Exported_Item (Item) then
               Put (Character'Val (9) & ".globl " & Symbol (Item));
            end if;

            Put (Character'Val (9) & ELF.Object_Type (Symbol (Item)));
            Put (Character'Val (9) & ".align "
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

            Put (Character'Val (9) & ELF.Size (Symbol (Item), Bytes));
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
         if Is_Exported_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;
         Put (Character'Val (9) & ELF.Object_Type (Symbol (Item)));
         Put (Character'Val (9) & ".align 8");
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
            Emit (".quad " & Base);
         end;
         Emit
           (".quad "
            & Trimmed
                (Landin.IR.Element_Total'Image
                   (Landin.IR.Slice_Image_Length (Of_Unit, Item))));
         Put (Character'Val (9) & ELF.Size (Symbol (Item), "16"));
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
         Bytes : constant String :=
           Trimmed (Positive'Image (Landin.Targets.Bytes (Held)));
      begin
         if Is_Exported_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ELF.Object_Type (Symbol (Item)));
         Put (Character'Val (9) & ".align "
              & Trimmed
                  (Landin.Targets.Byte_Alignment'Image
                     (Landin.Targets.Alignment_Of (Facts, Held))));
         Put (Symbol (Item) & ":");
         Emit (Directive (Held) & " " & Written);
         Put (Character'Val (9) & ELF.Size (Symbol (Item), Bytes));
      end Emit_Datum;

      Any_Written  : Boolean := False;
      Any_Reserved : Boolean := False;
      Any_Read_Only : Boolean := False;

   begin
      --  Synthetic widths remain an assembly-text layout probe. This
      --  renderer always spells ELF symbols; dispatch never emits that probe
      --  as a program, nor admits another real target through this seam.
      if Landin.Targets.Capabilities.Backend_For (Facts)
        /= Landin.Targets.Capabilities.X86_64_ELF
        and then Facts /= Landin.Targets.Synthetic_32
      then
         raise Compiler_Defect with "x86-64 emission needs x86-64 ELF facts";
      end if;
      Validate_Linkage;
      Allocate_Symbols;
      if Optimized then
         for Index in Shareable'Range loop
            declare
               Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            begin
               Shareable (Index) :=
                 Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
                 and then Item /= Hosted_Entry
                 and then not Is_Exported_Item (Item)
                 and then not Is_Forced (Item);
            end;
         end loop;
         Landin.IR.Visit_Address_Exposures (Of_Unit, Exclude_Exposed'Access);
      end if;
      --  Selection/allocation happen once per body before comparing final
      --  instruction evidence.  The entry symbol is deliberately excluded
      --  from local-label canonicalization; self relocations stay exact.
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then not Landin.IR.Is_External (Of_Unit, Item)
            then
               Out_Text := Unbounded.Null_Unbounded_String;
               if Debug = null then
                  declare
                     Plan : constant Allocation.Plan :=
                       Allocation.Make (Of_Unit, Item, Facts, Options);
                     Layout : constant Frame := Allocation.Frame_For
                       (Of_Unit, Item, Facts, Plan, Options);
                  begin
                     Emit_Routine (Item, Plan, Layout);
                  end;
               else
                  Saved.Plans (Index) := new Allocation.Plan'
                    (Allocation.Make (Of_Unit, Item, Facts, Options));
                  Saved.Frames (Index) := new Frame'
                    (Allocation.Frame_For
                       (Of_Unit, Item, Facts, Saved.Plans (Index).all,
                        Options));
                  Emit_Routine
                    (Item, Saved.Plans (Index).all, Saved.Frames (Index).all);
               end if;
               Bodies (Index) := Out_Text;
            end if;
         end;
      end loop;
      Out_Text := Unbounded.Null_Unbounded_String;
      if Debug /= null then
         Unbounded.Append (Out_Text, Dwarf.Preamble (Debug.all, Local_Prefix));
      end if;
      Put (Character'Val (9) & ".text");

      --  A routine shares with the first earlier routine that can.  Two
      --  optimized bodies can share only when their canonical streams are
      --  equal, two reference bodies only when they instantiate one
      --  template, and either only when their signatures have one ABI, so
      --  each routine is compared with the earlier routines that agree with
      --  it on a digest of those, still in item order: the one found is the
      --  one a comparison with every earlier routine would find.  Nothing
      --  shares under debugging.
      if Debug = null then
         declare
            use type Ada.Containers.Hash_Type;

            package Position_Vectors is new Ada.Containers.Vectors
              (Index_Type => Positive, Element_Type => Positive);

            function Same (Key : Ada.Containers.Hash_Type)
              return Ada.Containers.Hash_Type;

            function Same (Key : Ada.Containers.Hash_Type)
              return Ada.Containers.Hash_Type is (Key);

            package Bucket_Maps is new Ada.Containers.Hashed_Maps
              (Key_Type => Ada.Containers.Hash_Type,
               Element_Type => Position_Vectors.Vector,
               Hash => Same, Equivalent_Keys => "=",
               "=" => Position_Vectors."=");

            Buckets : Bucket_Maps.Map;

            --  What Signatures_Have_One_ABI compares, and nothing it may
            --  let differ: its flags, its counts and each part's carrier
            --  size, convention and escape, and an aggregate or array
            --  part's length, element and nominal identity.  Signatures with
            --  one ABI have one digest.
            function ABI_Digest (Signature : Landin.IR.Signature_Id)
              return Ada.Containers.Hash_Type;

            function ABI_Digest (Signature : Landin.IR.Signature_Id)
              return Ada.Containers.Hash_Type
            is
               Result : Ada.Containers.Hash_Type := 0;

               procedure Mix (Value : Natural);

               procedure Mix (Value : Natural) is
               begin
                  Result := Result * 31 + Ada.Containers.Hash_Type (Value);
               end Mix;

               procedure Mix (Part : Landin.IR.Signature_Part);

               procedure Mix (Part : Landin.IR.Signature_Part) is
               begin
                  Mix (Landin.IR.Parameter_Convention'Pos (Part.Convention));
                  Mix (Boolean'Pos (Part.Escaping));
                  if Part.Kind in Landin.Types.Scalar_Name
                    and then Part.Kind not in Landin.Types.Float_Name
                  then
                     Mix (Landin.Targets.Scalar_Size'Pos
                       (Landin.Types.Storage_Size
                          (Landin.Types.Scalar_Name (Part.Kind), Facts)));
                  else
                     Mix (100 + Landin.Types.Type_Kind'Pos (Part.Kind));
                  end if;
                  if Part.Kind in Landin.Types.Aggregate
                                | Landin.Types.Fixed_Array
                  then
                     Mix (Natural (Part.Length mod 2 ** 30));
                     Mix (Landin.Types.Scalar_Name'Pos (Part.Element));
                     Mix (if Part.Nominal = Landin.IR.No_Nominal_Type then 0
                          else Landin.IR.Nominal_Identities.Position
                            (Of_Unit, Part.Nominal));
                  end if;
               end Mix;
            begin
               if Signature = Landin.IR.No_Signature then
                  return 0;
               end if;
               Mix (Boolean'Pos
                 (Landin.IR.Signature_Uses_C_ABI (Of_Unit, Signature)));
               Mix (Boolean'Pos
                 (Landin.IR.Signature_Has_Erased_Self (Of_Unit, Signature)));
               Mix (Boolean'Pos
                 (Landin.IR.Signature_Never_Returns (Of_Unit, Signature)));
               Mix (Boolean'Pos
                 (Landin.IR.Signature_Is_Variadic (Of_Unit, Signature)));
               Mix (Boolean'Pos (Landin.IR.Signature_Errors
                 (Of_Unit, Signature) = Landin.IR.No_Atom_Set));
               Mix (Landin.IR.Signature_Parameter_Count (Of_Unit, Signature));
               Mix (Landin.IR.Signature_Result_Count (Of_Unit, Signature));
               for Index in 1 .. Landin.IR.Signature_Parameter_Count
                 (Of_Unit, Signature)
               loop
                  Mix (Landin.IR.Nth_Signature_Parameter
                    (Of_Unit, Signature, Index));
               end loop;
               for Index in 1 .. Landin.IR.Signature_Result_Count
                 (Of_Unit, Signature)
               loop
                  Mix (Landin.IR.Nth_Signature_Result
                    (Of_Unit, Signature, Index));
               end loop;
               return Result;
            end ABI_Digest;
         begin
            for Right in 1 .. Landin.IR.Item_Count (Of_Unit) loop
               declare
                  Item : constant Landin.IR.Item_Id :=
                    Landin.IR.Item_Id (Right);
                  Template : constant Landin.IR.Declaration_Id :=
                    Landin.IR.Generic_Template_Of (Of_Unit, Item);
               begin
                  if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
                    and then not Landin.IR.Is_External (Of_Unit, Item)
                    and then (if Optimized then
                                Shareable (Right)
                                and then not Has_Inline_Map_Table (Right)
                              else Template /= Landin.IR.No_Declaration)
                  then
                     declare
                        Key : constant Ada.Containers.Hash_Type :=
                          (if Optimized
                           then Machine.Digest (Streams (Right))
                           else Ada.Containers.Hash_Type (Template))
                          * 31 + ABI_Digest
                            (Landin.IR.Signature_Of (Of_Unit, Item));
                        Found : constant Bucket_Maps.Cursor :=
                          Buckets.Find (Key);
                     begin
                        if Bucket_Maps.Has_Element (Found) then
                           for Left of Buckets.Constant_Reference (Found)
                           loop
                              if Final_Bodies_Can_Share
                                (Landin.IR.Item_Id (Left), Item)
                              then
                                 Shared_With (Right) :=
                                   Landin.IR.Item_Id (Left);
                                 --  Sharing uses streams and signatures,
                                 --  never the discarded assembly text.
                                 Bodies (Right) :=
                                   Unbounded.Null_Unbounded_String;
                                 exit;
                              end if;
                           end loop;
                           Buckets.Reference (Found).Append (Right);
                        else
                           Buckets.Insert
                             (Key, Position_Vectors.To_Vector (Right, 1));
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end;
      end if;

      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine then
               if Landin.IR.Is_External (Of_Unit, Item) then
                  null;
               elsif Shared_With (Index) = Landin.IR.No_Item then
                  Begin_Item_Section
                    (".text.landin_routine_", """ax"",@progbits", Index);
                  --  Speed starts every routine on a cache line, so where
                  --  its loops and branches fall within a line is its own
                  --  code's doing and no longer moves when a routine before
                  --  it grows or shrinks.  Without it, reverse-complement's
                  --  unchanged hot loop came to share instruction cache sets
                  --  with the routines it calls when inlining grew earlier
                  --  ones, ran from the decoder rather than the op cache,
                  --  and took a third longer than with this alignment.
                  if Options.Optimize = Landin.Optimization.Speed then
                     Put (Character'Val (9) & ".p2align 6");
                  end if;
                  Unbounded.Append (Out_Text, Bodies (Index));
                  Bodies (Index) := Unbounded.Null_Unbounded_String;
                  Landin.Build_Reports.Append (Report, Statistics (Index));
               else
                  --  An alias is still this routine's symbol: an exported one
                  --  keeps its visibility and its function type, so a
                  --  linker and a debugger see it as before the fold.
                  if Is_Exported_Item (Item) then
                     Emit (".globl " & Symbol (Item));
                  end if;
                  Emit (ELF.Function_Type (Symbol (Item)));
                  Emit
                    (".set " & Symbol (Item) & ", "
                     & Symbol (Shared_With (Index)));
                  --  An alias adds no instruction or frame storage of its own.
                  --  Its representative's report describes the executed body.
                  Landin.Build_Reports.Append
                    (Report, Landin.Build_Reports.Routine_Statistics'
                       (Item => Item, Shared_With => Shared_With (Index),
                        others => <>));
               end if;
            elsif Landin.IR.Is_Read_Only (Of_Unit, Item) then
               Any_Read_Only := True;
            elsif Is_All_Zero (Item) then
               Any_Reserved := True;
            else
               Any_Written := True;
            end if;
         end;
      end loop;

      for From in Landin.Types.Float_Name loop
         if Float_Decode_Used (From) then
            Emit_Float_Decode (From);
         end if;
      end loop;

      --  D450 and D447.  The switch routine is out of line, one per
      --  program, so that its unwind information is exact at every
      --  instruction rather than threaded through a caller's frame.  It is
      --  called with the address to save through in %rdi and the stack
      --  pointer to resume in %rsi, after the caller has checked the
      --  limit.  It pushes %rbp and the callee-saved registers on the
      --  leaving stack, stores %rsp, loads the resumed one and pops the
      --  same six registers before returning into the resumed context.
      --  Both stacks hold the same 56 bytes at the switch, so one CFA rule,
      --  %rsp plus what remains pushed, is right at every instruction:
      --  stopped before the store, a debugger unwinds into the leaving
      --  fibre's frames, and after the load into the resumed fibre's.
      --  Every caller-saved register is left changed, as by a call.
      --
      --  The start routine is the return address of a prepared stack's
      --  first frame: the switch's pops leave the entry in %r12, its
      --  argument in %r13 and zero in %rbp, so the frame-pointer chain ends
      --  at the entry's first frame, and its unwind information says the
      --  return address is undefined, which ends a debugger's walk there.
      --  A first frame returns past the routine's opening nop, never run,
      --  because a debugger looks up a return address less one and must
      --  find it inside this description and this symbol.  An entry is
      --  `-> noreturn`; if it returns anyway, that is D232's `unreachable`
      --  at site zero, as a firmware entry's return is.
      if Stack_Used then
         declare
            Pushed : constant array (1 .. 6) of String (1 .. 4) :=
              ["%rbp", "%rbx", "%r12", "%r13", "%r14", "%r15"];
         begin
            Put (Character'Val (9)
                 & ".section .text.landin_stack,""ax"",@progbits");
            Put (Character'Val (9) & ".type " & Stack_Switcher
                 & ", @function");
            Put (Stack_Switcher & ":");
            if Debug /= null then
               Emit (".cfi_startproc");
            end if;
            for Index in Pushed'Range loop
               Emit ("pushq " & Pushed (Index));
               if Debug /= null then
                  Emit (".cfi_def_cfa_offset "
                        & Trimmed (Natural'Image (8 + 8 * Index)));
                  Emit (".cfi_offset " & Pushed (Index) & ", -"
                        & Trimmed (Natural'Image (8 + 8 * Index)));
               end if;
            end loop;
            Emit ("movq %rsp, (%rdi)");
            Emit ("movq %rsi, %rsp");
            for Index in reverse Pushed'Range loop
               Emit ("popq " & Pushed (Index));
               if Debug /= null then
                  Emit (".cfi_def_cfa_offset "
                        & Trimmed (Natural'Image (8 * Index)));
                  Emit (".cfi_restore " & Pushed (Index));
               end if;
            end loop;
            Emit ("ret");
            if Debug /= null then
               Emit (".cfi_endproc");
            end if;
            Put (Character'Val (9) & ELF.Size_To_Here (Stack_Switcher));

            Put (Character'Val (9) & ".type " & Stack_Start
                 & ", @function");
            Put (Stack_Start & ":");
            if Debug /= null then
               Emit (".cfi_startproc");
               Emit (".cfi_undefined %rip");
            end if;
            Emit ("nop");
            Put (Stack_Entered & ":");
            Emit ("movq %r13, %rdi");
            Emit ("call *%r12");
            if Panic /= null and then Landin.Panics.Handler (Panic.all)
              /= Landin.IR.No_Item
            then
               Emit ("movl $" & Trimmed (Positive'Image
                 (Landin.Panics.Code
                    (Panic.all, Landin.Panics.Unreachable))) & ", %edi");
               Emit ("xorl %esi, %esi");
               Emit ("call " & Symbol (Landin.Panics.Handler (Panic.all)));
            elsif Panic /= null
              and then Landin.Panics.Reports_Default (Panic.all)
            then
               declare
                  Line : constant String := Landin.Panics.Report
                    (Panic.all, Landin.Provenance.No_Origin,
                     Landin.Panics.Unreachable);
                  Index : constant Positive := Reports.Index_Of (Line);
               begin
                  Emit ("leaq " & Report_Label (Index) & "(%rip), %rdi");
                  Emit ("movl $" & Trimmed (Natural'Image (Line'Length))
                        & ", %esi");
                  Emit ("call " & Reporter);
               end;
            end if;
            Emit ("ud2");
            if Debug /= null then
               Emit (".cfi_endproc");
            end if;
            Put (Character'Val (9) & ELF.Size_To_Here (Stack_Start));
         end;
      end if;

      --  D161: read-only images sit in `.rodata`, so a write through a
      --  reference the checker should have refused faults instead of
      --  silently changing every reader's literal.
      if Any_Read_Only then
         for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Index);
            begin
               if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum
                 and then Landin.IR.Is_Read_Only (Of_Unit, Item)
               then
                  Begin_Item_Section
                    (".rodata.landin_datum_", """a"",@progbits", Index);
                  Emit_Array_Image_Datum (Item);
               end if;
            end;
         end loop;
      end if;

      if Landin.IR.Evidence_Count (Of_Unit) > 0 then
         declare
            Kept : constant Kept_Entries :=
              Kept_Evidence_Entries
                (Of_Unit,
                 (if Panic = null then Landin.IR.No_Item
                  else Landin.Panics.Handler (Panic.all)),
                 Meanings, Names);
         begin
            for Position in 1 .. Landin.IR.Evidence_Count (Of_Unit) loop
               declare
                  Evidence : constant Landin.IR.Evidence_Id :=
                    Landin.IR.Evidence_Id (Position);
                  Alias_Previous : constant Boolean := Position > 1
                    and then Shares_Evidence_Table
                      (Of_Unit, Landin.IR.Evidence_Id (Position - 1),
                       Evidence);
                  Alias_Next : constant Boolean :=
                    Position < Landin.IR.Evidence_Count (Of_Unit)
                      and then Shares_Evidence_Table
                        (Of_Unit, Evidence,
                         Landin.IR.Evidence_Id (Position + 1));
                  Size : Landin.Targets.Byte_Count;
                  Alignment : Landin.Targets.Byte_Alignment;
               begin
                  if not Alias_Previous then
                     Begin_Item_Section
                       (".data.rel.ro.local.landin_evidence_",
                        """aw"",@progbits", Position);
                     Landin.Backend.Field_Extent
                       (Of_Unit, Landin.IR.Evidence_Represented
                          (Of_Unit, Evidence), Facts, Size, Alignment);
                     Emit
                       (".balign "
                        & Trimmed
                            (Landin.Targets.Byte_Alignment'Image
                               (Landin.Targets.Pointer_Alignment (Facts))));
                     Put (Evidence_Symbol (Evidence) & ":");
                     if Alias_Next then
                        Put (Evidence_Symbol
                          (Landin.IR.Evidence_Id (Position + 1)) & ":");
                     end if;
                     Emit
                       (".quad "
                        & Trimmed (Landin.Targets.Byte_Count'Image (Size)));
                     Emit
                       (".quad "
                        & Trimmed
                            (Landin.Targets.Byte_Alignment'Image (Alignment)));
                     for Which in 1 .. Landin.IR.Evidence_Entry_Count
                       (Of_Unit, Evidence)
                     loop
                        --  D374: an entry nothing can project is a zero word.
                        if Is_Kept (Kept, Evidence, Which) then
                           Emit
                             (".quad "
                              & Symbol
                                  (Landin.IR.Evidence_Entry_Target
                                     (Of_Unit, Evidence, Which)));
                        else
                           Emit (".quad 0");
                        end if;
                     end loop;
                  end if;
               end;
            end loop;
         end;
      end if;

      --  Data follows every routine rather than interrupting them.  Written
      --  first and reserved second, in the order the declarations were made
      --  inside each; each object is its own collectable input section.
      if Any_Written then
         for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Index);
            begin
               if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum
                 and then not Landin.IR.Is_Read_Only (Of_Unit, Item)
                 and then not Is_All_Zero (Item)
               then
                  Begin_Item_Section
                    (".data.landin_datum_", """aw"",@progbits", Index);
                  if Landin.IR.Result_Of (Of_Unit, Item)
                     = Landin.Types.Aggregate
                  then
                     Emit_Recursive_Image_Datum (Item);
                  elsif Landin.IR.Has_Slice_Image (Of_Unit, Item) then
                     Emit_Slice_Image_Datum (Item);
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

      --  Reserved data are laid out smallest first (Smallest_First), so
      --  the one object as large as RIP-relative reach admits sits last.
      if Any_Reserved then
         declare
            function Reserved (Index : Positive) return Boolean
            is (Landin.IR.Kind_Of (Of_Unit, Landin.IR.Item_Id (Index))
                  = Landin.IR.Datum
                and then not Landin.IR.Is_Read_Only
                  (Of_Unit, Landin.IR.Item_Id (Index))
                and then Is_All_Zero (Landin.IR.Item_Id (Index)));

            Count : Natural := 0;
         begin
            for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
               if Reserved (Index) then
                  Count := Count + 1;
               end if;
            end loop;
            declare
               Items : Landin.Backend.Item_Array (1 .. Count);
               Extents : Landin.Backend.Extent_Array (1 .. Count);
               Next : Natural := 0;
            begin
               for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
                  if Reserved (Index) then
                     Next := Next + 1;
                     Items (Next) := Landin.IR.Item_Id (Index);
                     Extents (Next) :=
                       Reserved_Extent (Landin.IR.Item_Id (Index));
                  end if;
               end loop;
               for Item of Landin.Backend.Smallest_First (Items, Extents)
               loop
                  Begin_Item_Section
                    (".bss.landin_datum_", """aw"",@nobits",
                     Positive (Item));
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
               end loop;
            end;
         end;
      end if;

      --  D361's writer: standard error is descriptor 2, and the line's
      --  address and length arrive as a C call's first two arguments.
      --  Linux is asked by its system call, which a static image has;
      --  FreeBSD only through its C library, which every FreeBSD image
      --  links, so the stack is aligned for C first.  It does not return:
      --  the terminal instruction follows, as it follows every report.
      if Reports.Count > 0 then
         Put (Character'Val (9)
              & ".section .text.landin_trap_report,""ax"",@progbits");
         Put (Character'Val (9) & ".type " & Reporter & ", @function");
         Put (Reporter & ":");
         if Debug /= null then
            Emit (".cfi_startproc");
         end if;
         if Landin.Targets.Capabilities.Hosted_System_Of (Facts)
           = Landin.Targets.Capabilities.Linux
         then
            Emit ("movq %rsi, %rdx");
            Emit ("movq %rdi, %rsi");
            Emit ("movl $2, %edi");
            Emit ("movl $1, %eax");
            Emit ("syscall");
         else
            Emit ("pushq %rbp");
            if Debug /= null then
               Emit (".cfi_def_cfa_offset 16");
               Emit (".cfi_offset %rbp, -16");
            end if;
            Emit ("movq %rsp, %rbp");
            if Debug /= null then
               Emit (".cfi_def_cfa_register %rbp");
            end if;
            Emit ("andq $-16, %rsp");
            Emit ("movq %rsi, %rdx");
            Emit ("movq %rdi, %rsi");
            Emit ("movl $2, %edi");
            Emit ("call " & Landin.Targets.Capabilities.Link_Symbol
              (Link_Facts, "write"));
         end if;
         Emit ("ud2");
         if Debug /= null then
            Emit (".cfi_endproc");
         end if;
         Put (Character'Val (9) & ELF.Size_To_Here (Reporter));
         --  Each line in a mergeable string section of its own, so the
         --  link keeps only the lines a retained routine reaches.
         for Index in 1 .. Reports.Count loop
            Put (Character'Val (9) & ".section .rodata.str1.1.landin_trap_"
                 & Trimmed (Positive'Image (Index))
                 & ",""aMS"",@progbits,1");
            Put (Report_Label (Index) & ":");
            Emit (".asciz " & Landin.Backend.Trap_Reports.Quoted
              (Reports.Text (Index)));
         end loop;
      end if;

      if Debug /= null then
         Unbounded.Append (Out_Text, Dwarf.Sections
           (Of_Unit, Meanings, Names, Facts, Options, Debug.all,
            Local_Prefix, Symbol'Access, Cached_Plan'Access,
            Cached_Frame'Access, Trapped'Access));
      end if;
      Put (Character'Val (9) & ELF.No_Executable_Stack);
      if Panic /= null and then Landin.Panics.Handler (Panic.all)
        /= Landin.IR.No_Item
      then
         Emit (ELF.Push_Panic_Flag_Section);
         Emit (".balign 4");
         Put (Local_Prefix & "landin_panic_active:");
         Emit (".zero 4");
         Emit (ELF.Pop_Section);
      end if;
      Assembly := Out_Text;
   end Emit;

end Landin.Backend.X86_64;
