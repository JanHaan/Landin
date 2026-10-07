with Ada.Containers.Vectors;
with Landin.Provenance;
with Landin.Layouts;
with Landin.IR.Shape_Measurement;
with Landin.Packed;
with Landin.Memory;
with Landin.Targets.Packed;
with Landin.Backend.Dwarf;
with Ada.Strings.Fixed;
with Landin.Hosted;
with Landin.Targets.Capabilities;
with Landin.Backend.RiscV_ABI;
with Landin.Backend.RiscV_Instructions;
with Landin.Backend.ELF;
with Landin.Backend.Hosted_ABI;
with Landin.Backend.Work_Arrays;
with Landin.Types;

package body Landin.Backend.RiscV is

   package ELF_Spelling renames Landin.Backend.ELF;
   use type Landin.Targets.Capabilities.Backend_Kind;

   package Unbounded renames Ada.Strings.Unbounded;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Scalar_Size;
   use type Landin.IR.Atom_Set_Id;
   use type Landin.IR.Declaration_Id;
   use type Landin.IR.Item_Kind;
   use type Landin.IR.Item_Id;
   use type Landin.IR.Value_Id;
   use type Landin.IR.Opcode;
   use type Landin.IR.Parameter_Convention;
   use type Landin.IR.Signature_Id;
   use type Landin.IR.Slot_Id;
   use type Landin.IR.Element_Total;
   use type Landin.Optimization.Objective;
   use type Landin.IR.Field_Image_Form;
   use type Landin.IR.Field_Shape_Kind;
   use type Landin.Types.Folded;
   use type Landin.Types.Type_Kind;

   use type Landin.Targets.Target_Facts;
   use type Landin.Layouts.Policy;

   LF : constant Character := Character'Val (10);

   --  `Image` leads with a blank for a non-negative number and assembly
   --  is bytes, so the blank is a byte.  Landin.IR.Dump's trim, for the
   --  same reason.
   function Trimmed (Value : String) return String
     is (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

   function Image (Value : Natural) return String
     is (Trimmed (Natural'Image (Value)));

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

   --  Integer callee-save registers declared by assembly, together with
   --  the backend's fixed scratch homes, are preserved across every call.
   type Saved_Set is array (9 .. 27) of Boolean;

   function Declared
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id) return Saved_Set;

   function Declared
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id) return Saved_Set
   is
      Result : Saved_Set := [9 | 18 .. 26 => True, others => False];
   begin
      for Index in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
         declare
            Value : constant Landin.IR.Value_Id := Landin.IR.Value_Id (Index);
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Assembly then
               for Which in 1 .. Landin.IR.Assembly_Operand_Count
                 (Of_Unit, Item, Value)
               loop
                  for Number in Result'Range loop
                     if Number in 9 | 18 .. 27
                       and then Landin.IR.Register_Of
                          (Landin.IR.Nth_Assembly_Operand
                             (Of_Unit, Item, Value, Which))
                        = "x" & Trimmed (Natural'Image (Number))
                     then
                        Result (Number) := True;
                     end if;
                  end loop;
               end loop;
            end if;
         end;
      end loop;
      return Result;
   end Declared;

   function Save_Count (Saves : Saved_Set) return Natural;

   function Save_Count (Saves : Saved_Set) return Natural is
      Count : Natural := 0;
   begin
      for Held of Saves loop
         if Held then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Save_Count;

   type Value_Location is record
      Home : Natural := 0;
      Register : Natural := 0;
      Size : Held_Size := Landin.Targets.Byte_8;
      Address_Required : Boolean := False;
   end record;
   package Location_Vectors is new Ada.Containers.Vectors
     (Positive, Value_Location);
   type Allocation_Plan is record
      Values : Location_Vectors.Vector;
      Homes : Natural := 0;
      Saves : Saved_Set := [others => False];
   end record;

   function Allocate
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Allocation_Plan;

   function Allocate
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Allocation_Plan
   is
      pragma Unreferenced (Options);
      Result : Allocation_Plan;
   begin
      Result.Values := Location_Vectors.To_Vector
        (Value_Location'(others => <>),
         Ada.Containers.Count_Type (Landin.IR.Value_Count (Of_Unit, Item)));
      Result.Saves := Declared (Of_Unit, Item);
      for Index in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
         declare
            Kind : constant Landin.Types.Type_Kind := Landin.IR.Result_Of
              (Of_Unit, Item, Landin.IR.Value_Id (Index));
         begin
            if Kind in Landin.Types.Scalar_Name then
               Result.Homes := Result.Homes + 1;
               Result.Values (Index).Home := Result.Homes;
               Result.Values (Index).Size := Size_Of (Kind, Facts);
            end if;
         end;
      end loop;
      return Result;
   end Allocate;

   function Frame_For
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Plan : Allocation_Plan;
      Maximum : Landin.Targets.Byte_Count) return Frame;

   function Frame_For
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Plan : Allocation_Plan;
      Maximum : Landin.Targets.Byte_Count) return Frame
   is
      Saves : constant Natural := Save_Count (Plan.Saves);
   begin
      if Options.Optimize = Landin.Optimization.None then
         if Saves = 0 then
            return Laid_Out (Of_Unit, Item, Facts, Maximum);
         end if;
         return Laid_Out (Of_Unit, Item, Facts, Maximum, Saves);
      end if;
      declare
         package Mask_Buffers is new Landin.Backend.Work_Arrays
           (Boolean, Home_Mask, True);
         package Value_Buffers is new Landin.Backend.Work_Arrays
           (Natural, Spill_Assignments, 0);
         package Extent_Buffers is new Landin.Backend.Work_Arrays
           (Landin.Targets.Layouts.Field_Extent,
            Landin.Targets.Layouts.Field_Extent_Array, (0, 1));
         Slots_Data : Mask_Buffers.Buffer
           (Landin.IR.Slot_Count (Of_Unit, Item));
         Values_Data : Value_Buffers.Buffer (Natural (Plan.Values.Length));
         Spills_Data : Extent_Buffers.Buffer (Plan.Homes);
         Values : Spill_Assignments renames Values_Data.Data.all;
         Spills : Landin.Targets.Layouts.Field_Extent_Array renames
           Spills_Data.Data.all;
         Save_Homes : constant Landin.Targets.Layouts.Field_Extent_Array
           (1 .. Saves) := [others => (8, 8)];
      begin
         for Index in Values'Range loop
            declare
               Place : Value_Location renames Plan.Values (Index);
            begin
               Values (Index) := Place.Home;
               if Place.Home /= 0 then
                  Spills (Place.Home) :=
                    (Landin.Targets.Byte_Count
                       (Landin.Targets.Bytes (Place.Size)),
                     Landin.Targets.Alignment_Of (Facts, Place.Size));
               end if;
            end;
         end loop;
         return Laid_Out
           (Of_Unit, Item, Facts, Slots_Data.Data.all, Values,
            Spills, Save_Homes, Maximum);
      end;
   end Frame_For;

   --  Preflight, emission and debug output rebuild the same deterministic
   --  value plan; only source slots have debugger locations.
   function Routine_Frame
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Maximum : Landin.Targets.Byte_Count) return Frame;

   function Routine_Frame
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Maximum : Landin.Targets.Byte_Count) return Frame
   is
      Plan : constant Allocation_Plan :=
        Allocate (Of_Unit, Item, Facts, Options);
   begin
      return Frame_For (Of_Unit, Item, Facts, Options, Plan, Maximum);
   end Routine_Frame;

   function Debug_Plan
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Frame;

   function Debug_Plan
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Frame
   is
   begin
      return Routine_Frame (Of_Unit, Item, Facts, Options, 16#7fff_ffff#);
   end Debug_Plan;

   function Debug_Frame
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts; Plan : Frame;
      Options : Landin.Optimization.Options) return Frame;

   function Debug_Frame
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts; Plan : Frame;
      Options : Landin.Optimization.Options) return Frame
   is
      pragma Unreferenced (Of_Unit, Item, Facts, Options);
   begin
      return Plan;
   end Debug_Frame;

   function Debug_Slot
     (Plan : Frame; Layout : Frame; Slot : Landin.IR.Slot_Id;
      Indirect, Address_Only : Boolean) return String;

   function Debug_Slot
     (Plan : Frame; Layout : Frame; Slot : Landin.IR.Slot_Id;
      Indirect, Address_Only : Boolean) return String
   is
      pragma Unreferenced (Plan, Address_Only);
      HT : constant Character := Character'Val (9);
      LF : constant Character := Character'Val (10);
   begin
      return HT & ".byte 0x91" & LF & HT & ".sleb128 -"
        & Trimmed (Landin.Targets.Byte_Count'Image
            (Slot_Offset (Layout, Slot) + 16)) & LF
        & (if Indirect then HT & ".byte 0x06" & LF else "");
   end Debug_Slot;

   type Debug_Frame_Access is access all Frame;
   --  The shared encoder uses RV64's DWARF frame-register number.
   function ELF_Debug_Sections is new Landin.Backend.Dwarf.Sections
     (Frame, Debug_Frame_Access, Debug_Frame_Access,
      Debug_Plan, Debug_Frame, Debug_Slot, 8, False,
      Single_LEB_Operand => True);

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Boolean
   is
      Limit : constant Landin.Targets.Byte_Count := 16#7fff_ffff#;
      Layout : Frame;
   begin
      if Landin.IR.Is_External (Of_Unit, Item) then
         return True;
      end if;
      Layout := Routine_Frame (Of_Unit, Item, Facts, Options, Limit);
      if Extent (Layout) > Limit then
         return False;
      end if;
      if Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
        and then Landin.IR.Signature_Uses_C_ABI
          (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
      then
         if RiscV_ABI.Signature_Plan
           (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts,
            Limit - 16).Stack_Bytes > Limit - 16
         then
            return False;
         end if;
      elsif Landin.Targets.Byte_Count
        (Landin.IR.Parameter_Count (Of_Unit, Item)) > (Limit - 16) / 8
      then
         return False;
      end if;
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
                     declare
                        Plan : constant RiscV_ABI.Plan :=
                          RiscV_ABI.Call_Plan
                            (Of_Unit, Item, Value, Facts, Limit);
                        Bytes : Landin.Targets.Byte_Count := Plan.Stack_Bytes;
                     begin
                        for Part of Plan.Arguments loop
                           if Part.Shape.Indirect then
                              Bytes := Stack_Align
                                (Bytes, Part.Shape.Alignment, Limit);
                              Bytes := Stack_Add
                                (Bytes, Part.Shape.Size, Limit);
                           end if;
                        end loop;
                        if Stack_Align (Bytes, 16, Limit) > Limit then
                           return False;
                        end if;
                     end;
                  elsif Landin.Targets.Byte_Count
                    (Landin.IR.Operand_Count (Of_Unit, Item, Value))
                      > (Limit - 15) / 8
                  then
                     return False;
                  end if;
               end;
            end if;
         end;
      end loop;
      return True;
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
      Panic : access constant Landin.Panics.Plan := null;
      Level : Landin.Targets.Levels.Feature_Level :=
        Landin.Targets.Levels.Default_Level (Landin.Targets.Linux_RV64))
   is
      System : constant Hosted_ABI.Hosted_System :=
        Landin.Targets.Capabilities.Hosted_System_Of (Facts);
      Output : Unbounded.Unbounded_String;
      --  Dense nonzero u32 atom codes, in declaration-identity order; zero
      --  stays available for the successful half of the failing-call
      --  carrier.
      Atoms_Ranked : constant Atom_Codes := Ranked (Of_Unit);
      Serial : Natural := 0;

      procedure Put (Line : String);
      procedure Emit (Instruction : String);
      function Fresh return String;
      procedure Immediate (Register : String; Value : Pattern);
      procedure Add_Offset
        (Register : String; Offset : Landin.Targets.Byte_Count);
      procedure Stack_Address
        (Register : String; Offset : Landin.Targets.Byte_Count);
      procedure Restore_Stack (Bytes : Landin.Targets.Byte_Count);
      procedure Address (Register, Name : String; Imported : Boolean := False);
      procedure Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String);
      procedure Frame_Memory
        (Store : Boolean; Size : Held_Size; Register : String;
         Offset : Landin.Targets.Byte_Count);
      procedure Frame_Address
        (Offset : Landin.Targets.Byte_Count; Register : String := "x9");
      procedure Reserve (Bytes : Landin.Targets.Byte_Count);
      procedure Copy_Bytes (Bytes : Landin.Targets.Byte_Count);
      procedure Zero_Bytes (Bytes : Landin.Targets.Byte_Count);

      procedure Put (Line : String) is
      begin
         Unbounded.Append (Output, Line & LF);
      end Put;

      --  A platform directive, which on some object formats is nothing.
      procedure Platform_Directive (Text : String);

      procedure Platform_Directive (Text : String) is
      begin
         if Text /= "" then
            Put (Character'Val (9) & Text);
         end if;
      end Platform_Directive;

      procedure Emit (Instruction : String) is
         Space : constant Natural :=
           Ada.Strings.Fixed.Index (Instruction, " ");
         Mnemonic : constant String :=
           (if Space = 0 then Instruction
            else Instruction (Instruction'First .. Space - 1));
         Inverse : constant String :=
           (if Mnemonic = "beq" then "bne"
            elsif Mnemonic = "bne" then "beq"
            elsif Mnemonic = "blt" then "bge"
            elsif Mnemonic = "bge" then "blt"
            elsif Mnemonic = "bltu" then "bgeu"
            elsif Mnemonic = "bgeu" then "bltu"
            elsif Mnemonic = "beqz" then "bnez"
            elsif Mnemonic = "bnez" then "beqz"
            elsif Mnemonic = "bltz" then "bgez"
            elsif Mnemonic = "bgez" then "bltz"
            elsif Mnemonic = "blez" then "bgtz"
            elsif Mnemonic = "bgtz" then "blez" else "");
      begin
         if Mnemonic = "j" then
            Put (Character'Val (9) & "lla x26, "
              & Instruction (Space + 1 .. Instruction'Last));
            Put (Character'Val (9) & "jr x26");
         elsif Inverse /= "" then
            --  RISC-V conditional reach is only 4 KiB, and JAL's reach
            --  is only 1 MiB. A private saved scratch carries the full
            --  PC-relative destination without disturbing loop operands,
            --  results or the failure carrier. The opposite condition
            --  always reaches its adjacent continuation.
            declare
               Comma : constant Natural := Ada.Strings.Fixed.Index
                 (Instruction, ",", Ada.Strings.Backward);
               Skip : constant String := Fresh;
            begin
               Put (Character'Val (9) & Inverse
                 & Instruction (Space .. Comma) & " " & Skip);
               Put (Character'Val (9) & "lla x26, "
                 & Trimmed (Instruction (Comma + 1 .. Instruction'Last)));
               Put (Character'Val (9) & "jr x26");
               Put (Skip & ":");
            end;
         else
            Put (Character'Val (9) & Instruction);
         end if;
      end Emit;

      function Reg (Spelling : String) return
        RiscV_Instructions.Register_Number is
        (RiscV_Instructions.Register_Number'Value
          (Spelling (Spelling'First + 1 .. Spelling'Last)));

      procedure Immediate (Register : String; Value : Pattern) is
      begin
         Emit (RiscV_Instructions.Immediate
           (Reg (Register), RiscV_Instructions.Pattern (Value), 64));
      end Immediate;

      procedure Add_Offset
        (Register : String; Offset : Landin.Targets.Byte_Count) is
      begin
         if Offset > 0 then
            if Offset <= 2047 then
               Emit ("addi " & Register & ", " & Register & ", "
                 & Trimmed (Landin.Targets.Byte_Count'Image (Offset)));
            else
               Immediate ("x18", Pattern (Offset));
               Emit ("add " & Register & ", " & Register & ", x18");
            end if;
         end if;
      end Add_Offset;

      procedure Stack_Address
        (Register : String; Offset : Landin.Targets.Byte_Count) is
      begin
         Emit ("mv " & Register & ", sp");
         Add_Offset (Register, Offset);
      end Stack_Address;

      procedure Restore_Stack (Bytes : Landin.Targets.Byte_Count) is
      begin
         Add_Offset ("sp", Bytes);
      end Restore_Stack;

      procedure Address (Register, Name : String; Imported : Boolean := False)
      is
         pragma Unreferenced (Imported);
      begin
         Emit ("la " & Register & ", " & Name);
      end Address;

      procedure Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String) is
      begin
         Emit (RiscV_Instructions.Memory
           (Store, Size, Reg (Register), Reg (Base), 64));
      end Memory;

      procedure Frame_Address
        (Offset : Landin.Targets.Byte_Count; Register : String := "x9") is
      begin
         if Offset <= 2032 then
            Emit ("addi " & Register & ", x8, -"
              & Trimmed (Landin.Targets.Byte_Count'Image (Offset + 16)));
         else
            Immediate (Register, Pattern (Offset + 16));
            Emit ("sub " & Register & ", x8, " & Register);
         end if;
      end Frame_Address;

      procedure Frame_Memory
        (Store : Boolean; Size : Held_Size; Register : String;
         Offset : Landin.Targets.Byte_Count) is
      begin
         if Offset <= 2032 then
            Emit (RiscV_Instructions.Memory
              (Store, Size, Reg (Register), 8, 64, -Integer (Offset + 16)));
         else
            Frame_Address (Offset, (if Register = "x9" then "x18" else "x9"));
            Memory (Store, Size, Register,
                    (if Register = "x9" then "x18" else "x9"));
         end if;
      end Frame_Memory;

      procedure Reserve (Bytes : Landin.Targets.Byte_Count) is
      begin
         if Bytes > 0 then
            if Bytes <= 2048 then
               Emit ("addi sp, sp, -"
                 & Trimmed (Landin.Targets.Byte_Count'Image (Bytes)));
            else
               Immediate ("x5", Pattern (Bytes));
               Emit ("sub sp, sp, x5");
            end if;
         end if;
      end Reserve;

      procedure Copy_Bytes (Bytes : Landin.Targets.Byte_Count) is
         Loop_Label : constant String := Fresh;
      begin
         if Bytes > 0 then
            Immediate ("x7", Pattern (Bytes));
            Put (Loop_Label & ":");
            Emit ("lbu x28, 0(x6)");
            Emit ("sb x28, 0(x5)");
            Emit ("addi x6, x6, 1");
            Emit ("addi x5, x5, 1");
            Emit ("addi x7, x7, -1");
            Emit ("bnez x7, " & Loop_Label);
         end if;
      end Copy_Bytes;

      procedure Zero_Bytes (Bytes : Landin.Targets.Byte_Count) is
         Loop_Label : constant String := Fresh;
      begin
         if Bytes > 0 then
            Immediate ("x7", Pattern (Bytes));
            Put (Loop_Label & ":");
            Emit ("sb zero, 0(x5)");
            Emit ("addi x5, x5, 1");
            Emit ("addi x7, x7, -1");
            Emit ("bnez x7, " & Loop_Label);
         end if;
      end Zero_Bytes;

      Float_Comparison : Boolean := False;

      procedure Compare
        (Left, Right : String; Literal : Boolean := False);
      procedure Compare_Float (Suffix, Left, Right : String);
      procedure Branch (Condition, Target : String);
      procedure Predicate (Destination, Condition : String);
      procedure Add_Sub
        (Destination, Left, Right : String; Subtract : Boolean;
         Literal : Boolean := False);
      procedure Extract
        (Destination, Source : String; First, Bits : Natural;
         Signed : Boolean := False);
      procedure Insert_Bits
        (Destination, Source : String; First, Bits : Natural);

      procedure Compare (Left, Right : String; Literal : Boolean := False) is
      begin
         Float_Comparison := False;
         Emit ("mv x20, " & Left);
         if Literal then
            Emit ("li x21, " & Right);
         else
            Emit ("mv x21, " & Right);
         end if;
      end Compare;

      procedure Compare_Float (Suffix, Left, Right : String) is
      begin
         Float_Comparison := True;
         Emit ("feq." & Suffix & " x20, " & Left & ", " & Right);
         Emit ("flt." & Suffix & " x21, " & Left & ", " & Right);
         Emit ("fle." & Suffix & " x23, " & Left & ", " & Right);
         Emit ("fclass." & Suffix & " x24, " & Left);
         Emit ("fclass." & Suffix & " x25, " & Right);
         Emit ("or x24, x24, x25");
         Emit ("andi x24, x24, 768");
      end Compare_Float;

      procedure Branch (Condition, Target : String) is
         Test : Unbounded.Unbounded_String;
      begin
         if Float_Comparison then
            if Condition = "eq" then
               Test := Unbounded.To_Unbounded_String ("bnez x20, ");
            elsif Condition = "ne" then
               Test := Unbounded.To_Unbounded_String ("beqz x20, ");
            elsif Condition in "mi" | "lt" then
               Test := Unbounded.To_Unbounded_String ("bnez x21, ");
            elsif Condition = "ls" then
               Test := Unbounded.To_Unbounded_String ("bnez x23, ");
            elsif Condition = "ge" then
               Emit ("or x25, x21, x24");
               Test := Unbounded.To_Unbounded_String ("beqz x25, ");
            elsif Condition = "gt" then
               Emit ("or x25, x23, x24");
               Test := Unbounded.To_Unbounded_String ("beqz x25, ");
            elsif Condition = "vs" then
               Test := Unbounded.To_Unbounded_String ("bnez x24, ");
            else
               raise Compiler_Defect with "invalid floating predicate";
            end if;
         else
            Test := Unbounded.To_Unbounded_String
              (if Condition = "eq" then "beq x20, x21, "
               elsif Condition = "ne" then "bne x20, x21, "
               elsif Condition = "lt" then "blt x20, x21, "
               elsif Condition = "ge" then "bge x20, x21, "
               elsif Condition = "le" then "bge x21, x20, "
               elsif Condition = "gt" then "blt x21, x20, "
               elsif Condition = "lo" then "bltu x20, x21, "
               elsif Condition = "hs" then "bgeu x20, x21, "
               elsif Condition = "hi" then "bltu x21, x20, "
               elsif Condition = "ls" then "bgeu x21, x20, "
               elsif Condition = "vs" then "bnez x24, "
               elsif Condition = "cs" then "bnez x23, "
               elsif Condition = "cc" then "beqz x23, "
               else raise Compiler_Defect with "invalid integer predicate");
         end if;
         Emit (Unbounded.To_String (Test) & Target);
      end Branch;

      procedure Predicate (Destination, Condition : String) is
         Yes : constant String := Fresh;
         Done : constant String := Fresh;
      begin
         Branch (Condition, Yes);
         Emit ("li " & Destination & ", 0");
         Emit ("j " & Done);
         Put (Yes & ":");
         Emit ("li " & Destination & ", 1");
         Put (Done & ":");
      end Predicate;

      procedure Add_Sub
        (Destination, Left, Right : String; Subtract : Boolean;
         Literal : Boolean := False) is
      begin
         Compare (Left, Right, Literal);
         Emit ((if Subtract then "sub " else "add ")
           & Destination & ", x20, x21");
         if Subtract then
            Emit ("sltu x23, x20, x21");
            Emit ("xori x23, x23, 1");
            Emit ("xor x24, x20, x21");
            Emit ("xor x25, x20, " & Destination);
         else
            Emit ("sltu x23, " & Destination & ", x20");
            Emit ("xor x24, x20, " & Destination);
            Emit ("xor x25, x21, " & Destination);
         end if;
         Emit ("and x24, x24, x25");
         Emit ("srli x24, x24, 63");
         Emit ("mv x20, " & Destination);
         Emit ("li x21, 0");
      end Add_Sub;

      procedure Extract
        (Destination, Source : String; First, Bits : Natural;
         Signed : Boolean := False) is
      begin
         if First + Bits < 64 then
            Emit ("slli " & Destination & ", " & Source & ", "
              & Image (64 - First - Bits));
         else
            Emit ("mv " & Destination & ", " & Source);
         end if;
         if Bits < 64 then
            Emit ((if Signed then "srai " else "srli ")
              & Destination & ", " & Destination & ", "
              & Image (64 - Bits));
         end if;
      end Extract;

      procedure Insert_Bits
        (Destination, Source : String; First, Bits : Natural) is
         Mask_Value : constant Pattern :=
           (if Bits = 64 then Pattern'Last else (2 ** Bits - 1) * 2 ** First);
      begin
         Immediate ("x18", Mask_Value);
         Emit ("not x19, x18");
         Emit ("and " & Destination & ", " & Destination & ", x19");
         Emit ("slli x19, " & Source & ", " & Image (First));
         Emit ("and x19, x19, x18");
         Emit ("or " & Destination & ", " & Destination & ", x19");
      end Insert_Bits;

      function Symbol (Item : Landin.IR.Item_Id) return String;
      function Evidence_Symbol (Id : Landin.IR.Evidence_Id) return String;
      function Is_Public_Item (Item : Landin.IR.Item_Id) return Boolean;

      Host_Bridge_Needed : Boolean := Hosted_Entry /= Landin.IR.No_Item;
      Allocated_Symbols : array
        (1 .. Positive'Max (1, Landin.IR.Item_Count (Of_Unit))) of
          Unbounded.Unbounded_String;

      function Is_C_Item (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
            and then Landin.IR.Signature_Uses_C_ABI
              (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item)));

      use Landin.Hosted;
      subtype Hosted_Bridge is Host_Helper;
      Not_A_Bridge : constant Hosted_Bridge := No_Host_Helper;
      function Bridge_Of (Spelling : String) return Hosted_Bridge
        renames Helper_Of;

      function Bridge_Symbol (Helper : Host_Helper) return String
        is (Landin.Targets.Capabilities.Link_Symbol
              (Facts, Helper_Name (Helper)));

      function Is_Hosted_Dependency (Spelling : String) return Boolean
        is (Bridge_Of (Spelling) /= Not_A_Bridge
            or else Spelling = "strlen"
            or else Spelling = "malloc"
            or else Spelling = "free"
            or else Spelling = "open"
            or else Spelling = "read"
            or else Spelling = "write"
            or else Spelling = "close"
            or else Spelling = Hosted_ABI.Errno_Function (System));

      function Is_Forced (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Link_Symbol (Of_Unit, Item)
              /= Landin.Source.Names.No_Name
            or else Item = Hosted_Entry
            or else Landin.IR.Is_External (Of_Unit, Item));

      --  Pick a disjoint prefix for generated local labels. External source
      --  identities receive the object format's prefix at the rendering
      --  seam, where an explicit ELF spelling may begin with `.L`.
      function Unused_Local_Prefix return String;

      function Unused_Local_Prefix return String is
         Candidate : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String
             (ELF_Spelling.Local_Prefix);
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

      --  Internal code labels use the collision-checked ELF prefix.
      Step_Prefix : constant String :=
        Local_Prefix;

      function Fresh return String is
      begin
         Serial := Serial + 1;
         return Step_Prefix & "landin_step_"
           & Trimmed (Natural'Image (Serial));
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

      --  This target owns the emitted bridges and sees actual linker
      --  spellings; the target-neutral verifier sees only interned name IDs.
      --  Refuse an override before returning any assembly, in release too.
      --  Source linkage checking must diagnose these earlier, including the
      --  pointer/retention distinctions erased from neutral scalar carriers.
      procedure Validate_Linkage;

      procedure Validate_Linkage is
         function Import_Agrees
           (Item : Landin.IR.Item_Id; Bridge : Hosted_Bridge) return Boolean;

         function Import_Agrees
           (Item : Landin.IR.Item_Id; Bridge : Hosted_Bridge) return Boolean
         is
            package Ty renames Landin.Types;
            Signature : constant Landin.IR.Signature_Id :=
              Landin.IR.Signature_Of (Of_Unit, Item);
            type Kind_Array is array (Positive range <>) of Ty.Type_Kind;

            function Matches
              (Parameters : Kind_Array; Result : Ty.Type_Kind) return Boolean;

            function Matches
              (Parameters : Kind_Array; Result : Ty.Type_Kind) return Boolean
            is
            begin
               if Landin.IR.Signature_Parameter_Count (Of_Unit, Signature)
                    /= Parameters'Length
                 or else Landin.IR.Signature_Result_Count (Of_Unit, Signature)
                    /= (if Result = Ty.No_Value then 0 else 1)
               then
                  return False;
               end if;
               for Index in Parameters'Range loop
                  declare
                     Part : constant Landin.IR.Signature_Part :=
                       Landin.IR.Nth_Signature_Parameter
                         (Of_Unit, Signature, Index);
                  begin
                     if Part.Kind /= Parameters (Index)
                       or else Part.Convention /= Landin.IR.In_Value
                       or else Part.Atoms /= Landin.IR.No_Atom_Set
                     then
                        return False;
                     end if;
                  end;
               end loop;
               return Result = Ty.No_Value
                 or else Landin.IR.Nth_Signature_Result
                   (Of_Unit, Signature, 1).Kind = Result;
            end Matches;
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) /= Landin.IR.Routine
              or else Signature = Landin.IR.No_Signature
              or else not Is_C_Item (Item)
              or else Landin.IR.Signature_Is_Variadic (Of_Unit, Signature)
              or else Landin.IR.Signature_Errors (Of_Unit, Signature)
                /= Landin.IR.No_Atom_Set
            then
               return False;
            end if;
            case Bridge is
               when Initialize_Arguments =>
                  return Matches ([Ty.I32, Ty.Usize], Ty.No_Value);
               when Argument_Count | Argument_Table =>
                  return Matches ([], Ty.Usize);
               when Argument_At | Text_Length =>
                  return Matches ([Ty.Usize], Ty.Usize);
               when Argument_At_From | Heap_Allocate =>
                  return Matches ([Ty.Usize, Ty.Usize], Ty.Usize);
               when Open_Read | Open_Write =>
                  return Matches ([Ty.Usize], Ty.I32);
               when Read_Bytes | Write_Bytes =>
                  return Matches ([Ty.I32, Ty.Usize, Ty.Usize], Ty.Usize);
               when Close_File =>
                  return Matches ([Ty.I32], Ty.I32);
               when Errno_Value =>
                  return Matches ([], Ty.I32);
               when Heap_Release =>
                  return Matches ([Ty.Usize], Ty.No_Value);
               when Not_A_Bridge =>
                  return False;
            end case;
         end Import_Agrees;
      begin
         for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Position);
               Spelling : constant String := Source_Symbol (Item);
               Bridge : constant Hosted_Bridge := Bridge_Of (Spelling);
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
               then
                  raise Landin.Compiler_Defect with
                    "a link symbol overrides the hosted main entry";
               end if;
               if Is_Forced (Item) and then Bridge /= Not_A_Bridge then
                  if not Landin.IR.Is_External (Of_Unit, Item) then
                     raise Landin.Compiler_Defect with
                       "a definition overrides compiler-owned symbol "
                       & Spelling;
                  elsif not Import_Agrees (Item, Bridge) then
                     raise Landin.Compiler_Defect with
                       "an import disagrees with compiler-owned symbol "
                       & Spelling;
                  end if;
               end if;
            end;
         end loop;
      end Validate_Linkage;

      procedure Allocate_Symbols;

      procedure Allocate_Symbols is
         Allocated : Spelling_Counts;
         Sources : Spelling_Counts;

         function Available
           (Candidate : String; Item : Landin.IR.Item_Id) return Boolean;

         function Available
           (Candidate : String; Item : Landin.IR.Item_Id) return Boolean
         is
         begin
            if Host_Bridge_Needed and then Is_Hosted_Dependency (Candidate)
            then
               return False;
            end if;
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
                 Landin.IR.Declares (Of_Unit, Item);
               Spelling : constant String := Source_Symbol (Item);
            begin
               if not Is_Forced (Item) then
                  if not Is_C_Item (Item) and then Available (Spelling, Item)
                  then
                     Allocate
                       (Position, Unbounded.To_Unbounded_String (Spelling));
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
                        Allocate (Position, Candidate);
                     end;
                  end if;
               end if;
            end;
         end loop;
      end Allocate_Symbols;

      --  Apply target link spelling at the rendering seam.
      --  Namespace comparisons retain the source identity.
      function Symbol (Item : Landin.IR.Item_Id) return String is
         Spelling : constant String :=
           Landin.Targets.Capabilities.Link_Symbol
             (Facts, Unbounded.To_String
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

      function Is_Public_Item (Item : Landin.IR.Item_Id) return Boolean
      is
         Declared : constant Landin.IR.Declaration_Id :=
           Landin.IR.Declares (Of_Unit, Item);
      begin
         return Declared /= Landin.IR.No_Declaration
           and then Landin.Resolution.Is_Public (Meanings, Declared);
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

      procedure Emit_Routine (Item : Landin.IR.Item_Id);

      procedure Emit_Routine (Item : Landin.IR.Item_Id) is
         Path_Layouts : Landin.IR.Shape_Measurement.Layout_Cache;
         Plan : constant Allocation_Plan :=
           Allocate (Of_Unit, Item, Facts, Options);
         Layout : constant Frame := Frame_For
           (Of_Unit, Item, Facts, Options, Plan, 16#7fff_ffff#);
         Saves : constant Saved_Set := Plan.Saves;
         Result : constant Landin.Types.Type_Kind :=
           Landin.IR.Result_Of (Of_Unit, Item);
         Hard_Trap : constant String := Label (Item, 1) & "_trap";
         Shared_Exit : constant String := Label (Item, 1) & "_exit";
         Terminal_Count : Natural := 0;
         Current_Value : Landin.IR.Value_Id := Landin.IR.No_Value;
         type Panic_Edge is record
            Reason : Landin.Panics.Kind;
            Site : Landin.Panics.Site_Number;
            Origin : Landin.Provenance.Origin;
            Label : Unbounded.Unbounded_String;
         end record;
         package Edge_Vectors is new Ada.Containers.Vectors
           (Positive, Panic_Edge);
         Edges : Edge_Vectors.Vector;

         function Trap (Reason : Landin.Panics.Kind) return String;
         function Trap return String;

         function Trap (Reason : Landin.Panics.Kind) return String is
         begin
            if Panic = null or else Landin.Panics.Handler (Panic.all)
              = Landin.IR.No_Item
            then
               return Hard_Trap;
            end if;
            declare
               Origin : constant Landin.Provenance.Origin :=
                 (if Current_Value = Landin.IR.No_Value
                  then Landin.IR.Origin_Of (Of_Unit, Item)
                  else Landin.IR.Origin_Of (Of_Unit, Item, Current_Value));
               Site : constant Landin.Panics.Site_Number :=
                 Landin.Panics.Site (Panic.all, Origin, Reason);
               Name : constant String := Fresh;
            begin
               Edges.Append (Panic_Edge'
                 (Reason, Site, Origin, Unbounded.To_Unbounded_String (Name)));
               return Name;
            end;
         end Trap;

         function Trap return String is
           (Trap (Landin.Panics.For_Value
              (Of_Unit, Item, Current_Value)));


         function Kind (Value : Landin.IR.Value_Id)
           return Landin.Types.Scalar_Name
           is (Landin.IR.Result_Of (Of_Unit, Item, Value));
         function Size_Of_Value (Value : Landin.IR.Value_Id) return Held_Size
           is (Size_Of (Kind (Value), Facts));
         procedure Load_Value
           (Value : Landin.IR.Value_Id; Register : String := "x5");
         procedure Store_Value
           (Value : Landin.IR.Value_Id; Register : String := "x5";
            Atom_Validated : Boolean := False);
         procedure Load_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "x5");
         procedure Store_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "x5");
         procedure Extend (Register : String; Scalar : Landin.Types.Type_Kind);
         procedure Check_Fit
           (Register : String; Scalar : Landin.Types.Integer_Name);
         procedure Epilogue;
         procedure Finish_Exit;

         procedure Load_Value
           (Value : Landin.IR.Value_Id; Register : String := "x5") is
         begin
            if Plan.Values (Positive (Value)).Register /= 0 then
               Emit ("mv " & Register & ", x" & Trimmed (Natural'Image
                 (Plan.Values (Positive (Value)).Register)));
            else
               Frame_Memory (False, Size_Of_Value (Value), Register,
                             Value_Offset (Layout, Value));
            end if;
         end Load_Value;

         procedure Store_Value
           (Value : Landin.IR.Value_Id; Register : String := "x5";
            Atom_Validated : Boolean := False)
         is
            Atoms : constant Landin.IR.Atom_Set_Id :=
              Landin.IR.Atom_Set_Of (Of_Unit, Item, Value);
         begin
            if not Atom_Validated
              and then Atoms /= Landin.IR.No_Atom_Set
              and then Landin.IR.Op_Of (Of_Unit, Item, Value) in
                Landin.IR.Load | Landin.IR.Load_Indirect
                | Landin.IR.Load_Datum | Landin.IR.Load_Field
                | Landin.IR.Load_Element | Landin.IR.Load_Variant_Field
            then
               declare
                  Done : constant String := Fresh;
               begin
                  if Landin.IR.Admits_Reserved_Zero
                    (Of_Unit, Item, Value)
                  then
                     Emit ("beqz " & Register & ", " & Done);
                  end if;
                  for Index in 1 .. Landin.IR.Atom_Count (Of_Unit, Atoms) loop
                     Immediate ("x30", Pattern (Atom_Code
                       (Atoms_Ranked,
                        Landin.IR.Nth_Atom (Of_Unit, Atoms, Index))));
                     Compare (Register, "x30");
                     Branch ("eq", Done);
                  end loop;
                  Emit ("j " & Trap (Landin.Panics.Bad_Conversion));
                  Put (Done & ":");
               end;
            end if;
            if Plan.Values (Positive (Value)).Register /= 0 then
               declare
                  Destination : constant String := "x" & Trimmed
                    (Natural'Image (Plan.Values (Positive (Value)).Register));
                  Bits : constant Natural := 8 * Natural
                    (Landin.Targets.Bytes (Size_Of_Value (Value)));
               begin
                  if Bits = 64 then
                     Emit ("mv " & Destination & ", " & Register);
                  else
                     Extract (Destination, Register, 0, Bits);
                  end if;
               end;
            else
               Frame_Memory (True, Size_Of_Value (Value), Register,
                             Value_Offset (Layout, Value));
            end if;
         end Store_Value;

         procedure Load_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "x5") is
         begin
            Frame_Memory (False, Size_Of
              (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts),
              Register, Slot_Offset (Layout, Slot));
         end Load_Slot;

         procedure Store_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "x5") is
         begin
            Frame_Memory (True, Size_Of
              (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts),
              Register, Slot_Offset (Layout, Slot));
         end Store_Slot;

         procedure Extend (Register : String; Scalar : Landin.Types.Type_Kind)
         is
         begin
            if Scalar in Landin.Types.I8 | Landin.Types.I16 | Landin.Types.I32
            then
               Extract (Register, Register, 0,
                 Natural (Landin.Types.Width (Scalar, Facts)), Signed => True);
            end if;
         end Extend;

         procedure Check_Fit
           (Register : String; Scalar : Landin.Types.Integer_Name)
         is
            Bits : constant Natural :=
              Natural (Landin.Types.Width (Scalar, Facts));
         begin
            if Bits < 64 then
               Extract ("x30", Register, 0, Bits,
                 Signed => Landin.Types.Is_Signed (Scalar));
               Compare ("x30", Register);
               Branch ("ne", Trap);
            end if;
         end Check_Fit;

         --  The declared registers' homes, in register order.
         function Save_Home
           (Number : Natural) return Landin.Targets.Byte_Count;

         function Save_Home
           (Number : Natural) return Landin.Targets.Byte_Count
         is
            Index : Natural := 0;
         begin
            for Which in Saves'First .. Number loop
               if Saves (Which) then
                  Index := Index + 1;
               end if;
            end loop;
            return Save_Offset (Layout, Index);
         end Save_Home;

         procedure Restore_Saves;

         procedure Restore_Saves is
         begin
            for Number in Saves'Range loop
               if Saves (Number) then
                  Frame_Address (Save_Home (Number), "x5");
                  Emit ("ld x" & Trimmed (Natural'Image (Number)) & ", 0(x5)");
                  if Debug /= null then
                     Emit (".cfi_restore "
                           & Trimmed (Natural'Image (Number)));
                  end if;
               end if;
            end loop;
         end Restore_Saves;

         procedure Epilogue is
         begin
            if Debug /= null then
               Emit (".cfi_remember_state");
            end if;
            Restore_Saves;
            Emit ("ld ra, -8(x8)");
            Emit ("mv sp, x8");
            Emit ("ld x8, -16(x8)");
            if Debug /= null then
               Emit (".cfi_def_cfa sp, 0");
               Emit (".cfi_restore x8");
               Emit (".cfi_restore x1");
            end if;
            Emit ("ret");
            if Debug /= null then
               Emit (".cfi_restore_state");
            end if;
         end Epilogue;

         procedure Finish_Exit is
         begin
            if Debug /= null then
               --  Location ranges end after result preparation, before
               --  either the branch or the first shared register restore.
               Put (Dwarf.Label_Name (Local_Prefix, "epilogue", Item,
                 Natural (Current_Value)) & ":");
            end if;
            if Terminal_Count > 1 then
               Emit ("j " & Shared_Exit);
            else
               Epilogue;
            end if;
         end Finish_Exit;

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
                  Positive (Which), Positive (Payload_Field), Facts,
                  Path_Layouts);
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
           is (Landin.Backend.Path_Offset
                 (Of_Unit, Shape, Path, Facts, Path_Layouts));

         --  C carriers are independent of the language's bit-pattern calls.
         --  Each chunk retains its actual byte offset, floating class and
         --  register or stack placement from the LP64D transport plan.
         procedure C_Chunk
           (Place : RiscV_ABI.Location; Chunk : Positive; Store : Boolean);
         procedure C_Entry;
         procedure C_Call (Value : Landin.IR.Value_Id);
         procedure C_Result (Value : Landin.IR.Value_Id);
         C_Result_Place : RiscV_ABI.Location;

         procedure C_Chunk
           (Place : RiscV_ABI.Location; Chunk : Positive; Store : Boolean)
         is
            use all type RiscV_ABI.Carrier_Class;
            Part : RiscV_ABI.Carrier renames Place.Shape.Parts (Chunk);
            Home : RiscV_ABI.Carrier_Location renames Place.Parts (Chunk);
            GPR : constant String := "x" & Image (Home.Register + 9);
            FPR : constant String := "f" & Image (Home.Register + 9);
         begin
            if Home.Register = 0 then
               if Store then
                  Stack_Address ("x30", Home.Stack_At);
                  Emit ("ld x19, 0(x30)");
               else
                  Immediate ("x19", 0);
               end if;
            elsif Part.Class = Float_Class then
               if Part.Bytes = 4 then
                  Emit ((if Store then "fmv.x.w x19, " else "")
                    & (if Store then FPR else "li x19, 0"));
               else
                  Emit ((if Store then "fmv.x.d x19, " else "")
                    & (if Store then FPR else "li x19, 0"));
               end if;
            elsif Store then
               Emit ("mv x19, " & GPR);
            else
               Immediate ("x19", 0);
            end if;
            for Byte in 0 .. Part.Bytes - 1 loop
               declare
                  Offset : constant String := Trimmed
                    (Landin.Targets.Byte_Count'Image (Part.Offset + Byte));
                  Shift : constant String := Trimmed
                    (Landin.Targets.Byte_Count'Image (Byte * 8));
               begin
                  if Store then
                     Emit ("srli x18, x19, " & Shift);
                     Emit ("sb x18, " & Offset & "(x29)");
                  else
                     Emit ("lbu x18, " & Offset & "(x29)");
                     Emit ("slli x18, x18, " & Shift);
                     Emit ("or x19, x19, x18");
                  end if;
               end;
            end loop;
            if not Store then
               if Part.Class = Integer_Class
                 and then Part.Scalar in Landin.Types.Integer_Name
               then
                  if Part.Bytes = 4 then
                     --  LP64D extends both signed and unsigned 32-bit
                     --  integers to XLEN with the sign of bit 31.
                     Emit ("sext.w x19, x19");
                  elsif Part.Scalar in Landin.Types.I8 | Landin.Types.I16 then
                     Emit ("slli x19, x19, "
                       & Image (64 - Natural (Part.Bytes) * 8));
                     Emit ("srai x19, x19, "
                       & Image (64 - Natural (Part.Bytes) * 8));
                  end if;
               end if;
               if Home.Register = 0 then
                  Stack_Address ("x30", Home.Stack_At);
                  Emit ("sd x19, 0(x30)");
               elsif Part.Class = Float_Class then
                  Emit ((if Part.Bytes = 4 then "fmv.w.x " else "fmv.d.x ")
                    & FPR & ", x19");
               else
                  Emit ("mv " & GPR & ", x19");
               end if;
            end if;
         end C_Chunk;

         procedure C_Entry is
            Plan : constant RiscV_ABI.Plan := RiscV_ABI.Signature_Plan
              (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts);
            Hidden : constant Natural :=
              (if Plan.Result.Shape.Aggregate then 1 else 0);
         begin
            C_Result_Place := Plan.Result;
            if Hidden > 0 then
               if Plan.Result.Shape.Indirect then
                  Emit ("mv x5, a0");
               else
                  Frame_Address (Slot_Offset (Layout,
                    Landin.IR.Result_Slot (Of_Unit, Item)), "x5");
               end if;
               Store_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1));
            end if;
            for Index in Plan.Arguments'Range loop
               declare
                  Place : RiscV_ABI.Location renames Plan.Arguments (Index);
                  Slot : constant Landin.IR.Slot_Id :=
                    Landin.IR.Nth_Parameter (Of_Unit, Item, Index + Hidden);
               begin
                  if Place.Shape.Indirect then
                     if Place.Parts (1).Register = 0 then
                        Emit ("mv x6, x8");
                        Add_Offset ("x6", Place.Parts (1).Stack_At);
                        Emit ("ld x6, 0(x6)");
                     else
                        Emit ("mv x6, x" & Image
                          (Place.Parts (1).Register + 9));
                     end if;
                     Frame_Address (Slot_Offset (Layout, Slot), "x5");
                     Copy_Bytes (Place.Shape.Size);
                  else
                     Frame_Address (Slot_Offset (Layout, Slot), "x29");
                     for Chunk in 1 .. Place.Shape.Count loop
                        if Place.Parts (Chunk).Register = 0 then
                           Emit ("mv x30, x8");
                           Add_Offset ("x30", Place.Parts (Chunk).Stack_At);
                           Emit ("ld x19, 0(x30)");
                           --  Chunk's stack source is above the CFA,
                           --  whereas outgoing chunks use the current SP.
                           declare
                              Incoming : RiscV_ABI.Location := Place;
                           begin
                              Incoming.Parts (Chunk).Register := 8;
                              Emit ("mv x17, x19");
                              C_Chunk (Incoming, Chunk, True);
                           end;
                        else
                           C_Chunk (Place, Chunk, True);
                        end if;
                     end loop;
                  end if;
               end;
            end loop;
         end C_Entry;

         procedure C_Call (Value : Landin.IR.Value_Id) is
            Indirect : constant Boolean :=
              Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Indirect_Call;
            Plan : constant RiscV_ABI.Plan :=
              RiscV_ABI.Call_Plan (Of_Unit, Item, Value, Facts);
            Hidden : constant Natural :=
              (if Plan.Result.Shape.Aggregate then 1 else 0);
            Offset : constant Natural := (if Indirect then 1 else 0);
            Copies : array (Plan.Arguments'Range) of
              Landin.Targets.Byte_Count := [others => 0];
            Bytes : Landin.Targets.Byte_Count := Plan.Stack_Bytes;
            function Argument (Index : Positive) return Landin.IR.Value_Id
              is (Landin.IR.Nth_Operand
                    (Of_Unit, Item, Value, Index + Offset + Hidden));
         begin
            for Index in Plan.Arguments'Range loop
               if Plan.Arguments (Index).Shape.Indirect then
                  Bytes := Stack_Align
                    (Bytes, Plan.Arguments (Index).Shape.Alignment,
                     16#7fff_ffff#);
                  Copies (Index) := Bytes;
                  Bytes := Stack_Add
                    (Bytes, Plan.Arguments (Index).Shape.Size,
                     16#7fff_ffff#);
               end if;
            end loop;
            Bytes := Stack_Align (Bytes, 16, 16#7fff_ffff#);
            Reserve (Bytes);
            for Index in Plan.Arguments'Range loop
               declare
                  Place : RiscV_ABI.Location renames Plan.Arguments (Index);
               begin
                  if Place.Shape.Indirect then
                     Load_Value (Argument (Index), "x6");
                     Stack_Address ("x5", Copies (Index));
                     Copy_Bytes (Place.Shape.Size);
                     Stack_Address ("x29", Copies (Index));
                     if Place.Parts (1).Register = 0 then
                        Stack_Address ("x5", Place.Parts (1).Stack_At);
                        Emit ("sd x29, 0(x5)");
                     else
                        Emit ("mv x" & Image
                          (Place.Parts (1).Register + 9) & ", x29");
                     end if;
                  else
                     if Place.Shape.Aggregate then
                        Load_Value (Argument (Index), "x29");
                     else
                        Frame_Address
                          (Value_Offset (Layout, Argument (Index)), "x29");
                     end if;
                     for Chunk in 1 .. Place.Shape.Count loop
                        C_Chunk (Place, Chunk, False);
                     end loop;
                  end if;
               end;
            end loop;
            if Plan.Result.Shape.Indirect then
               Load_Value (Landin.IR.Nth_Operand
                 (Of_Unit, Item, Value, Offset + 1), "x10");
            end if;
            if Indirect then
               Load_Value
                 (Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1), "x30");
               Emit ("jalr ra, 0(x30)");
            else
               Emit ("call " & Symbol
                 (Landin.IR.Callee_Of (Of_Unit, Item, Value)));
            end if;
            if not Plan.Result.Shape.Indirect
              and then Plan.Result.Shape.Size > 0
            then
               if Hidden > 0 then
                  Load_Value (Landin.IR.Nth_Operand
                    (Of_Unit, Item, Value, Offset + 1), "x29");
               else
                  Frame_Address (Value_Offset (Layout, Value), "x29");
               end if;
               for Chunk in 1 .. Plan.Result.Shape.Count loop
                  C_Chunk (Plan.Result, Chunk, True);
               end loop;
            end if;
            Restore_Stack (Bytes);
         end C_Call;

         procedure C_Result (Value : Landin.IR.Value_Id) is
            Place : RiscV_ABI.Location renames C_Result_Place;
         begin
            if Place.Shape.Size = 0 then
               return;
            elsif Place.Shape.Indirect then
               Load_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1), "x5");
               Frame_Address (Slot_Offset
                 (Layout, Landin.IR.Result_Slot (Of_Unit, Item)), "x6");
               Copy_Bytes (Place.Shape.Size);
            else
               if Place.Shape.Aggregate then
                  Frame_Address (Slot_Offset
                    (Layout, Landin.IR.Result_Slot (Of_Unit, Item)), "x29");
               else
                  Frame_Address (Value_Offset (Layout,
                    Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1)), "x29");
               end if;
               for Chunk in 1 .. Place.Shape.Count loop
                  C_Chunk (Place, Chunk, False);
               end loop;
            end if;
         end C_Result;

         --  Numeric integer operands use their own address register;
         --  outputs remain live until copied, with f0 as the full-register
         --  escape carrier when every caller scratch register is occupied.
         procedure Assembly_Block (Value : Landin.IR.Value_Id);

         procedure Assembly_Block (Value : Landin.IR.Value_Id) is
            Chosen : constant Landin.Targets.Assembly.Operand_Register_Array
              := Landin.Backend.Assembly_Registers
                   (Of_Unit, Item, Value, Names, Facts);
            Text : constant String := Landin.Backend.Assembly_Text
              (Of_Unit, Item, Value, Names, Facts);
            Inputs : Natural := 0;
            Start : Natural := Text'First;
            Waiting : array (0 .. 31) of Boolean := [others => False];
            Aside : Natural := 0;

            function Operand (Index : Positive)
              return Landin.IR.Assembly_Operand
              is (Landin.IR.Nth_Assembly_Operand
                    (Of_Unit, Item, Value, Index));

            function Register (Index : Positive) return String
              is (Unbounded.To_String (Chosen (Index).Register));

            function Number (Index : Positive) return Natural
              is (Natural'Value
                    (Register (Index) (Register (Index)'First + 1
                       .. Register (Index)'Last)));

            function Free return String;

            function Free return String is
            begin
               for Candidate in reverse 5 .. 31 loop
                  if Candidate in 5 .. 7 | 28 .. 31
                    and then not Waiting (Candidate)
                  then
                     return "x" & Trimmed (Natural'Image (Candidate));
                  end if;
               end loop;
               raise Compiler_Defect with "no scratch register is free";
            end Free;

            procedure Store (Index : Positive; From : String);

            procedure Store (Index : Positive; From : String) is
               Base : constant String := Free;
            begin
               Frame_Address (Slot_Offset (Layout, Operand (Index).Output),
                              Base);
               Memory (True, Size_Of (Operand (Index).Kind, Facts),
                       From, Base);
            end Store;
         begin
            for Index in Chosen'Range loop
               if Operand (Index).Direction
                 in Landin.IR.Input | Landin.IR.Both
               then
                  Inputs := Inputs + 1;
                  Frame_Address
                    (Value_Offset (Layout, Landin.IR.Nth_Operand
                       (Of_Unit, Item, Value, Inputs)), Register (Index));
                  Memory (False, Size_Of (Operand (Index).Kind, Facts),
                          Register (Index), Register (Index));
                  Extend (Register (Index), Operand (Index).Kind);
               end if;
               if Operand (Index).Output /= Landin.IR.No_Slot then
                  Waiting (Number (Index)) := True;
               end if;
            end loop;
            for Index in Text'First .. Text'Last + 1 loop
               if Index > Text'Last or else Text (Index) = LF then
                  declare
                     Line : constant String :=
                       Trimmed (Text (Start .. Index - 1));
                  begin
                     if Line'Length > 0 then
                        Put (Character'Val (9) & Line);
                     end if;
                  end;
                  Start := Index + 1;
               end if;
            end loop;
            if (for all Candidate in 5 .. 31 =>
              (if Candidate in 5 .. 7 | 28 .. 31
               then Waiting (Candidate) else True))
            then
               for Index in Chosen'Range loop
                  if Operand (Index).Output /= Landin.IR.No_Slot
                    and then Number (Index) in 5 .. 7 | 28 .. 31
                  then
                     Aside := Index;
                     Emit ("fmv.d.x f0, " & Register (Index));
                     Waiting (Number (Index)) := False;
                     exit;
                  end if;
               end loop;
            end if;
            for Index in Chosen'Range loop
               if Operand (Index).Output /= Landin.IR.No_Slot
                 and then Index /= Aside
               then
                  Store (Index, Register (Index));
                  Waiting (Number (Index)) := False;
               end if;
            end loop;
            if Aside /= 0 then
               declare
                  Held : constant String := Free;
               begin
                  Waiting (Natural'Value (Held (Held'First + 1 .. Held'Last)))
                    := True;
                  Emit ("fmv.x.d " & Held & ", f0");
                  Store (Aside, Held);
               end;
            end if;
         end Assembly_Block;

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
            function FP (Scalar : Landin.Types.Scalar_Name) return String
              is (if Scalar = Landin.Types.F32 then "s" else "d");
            procedure Packed_Atom
              (Set_Id : Landin.IR.Atom_Set_Id; Encode : Boolean);

            procedure Packed_Atom
              (Set_Id : Landin.IR.Atom_Set_Id; Encode : Boolean)
            is
               Done : constant String := Fresh;
            begin
               if Set_Id = Landin.IR.No_Atom_Set then
                  return;
               end if;
               for Index in 1 .. Landin.IR.Atom_Count (Of_Unit, Set_Id) loop
                  declare
                     Next : constant String := Fresh;
                     Code : constant Pattern := Pattern (Atom_Code
                       (Atoms_Ranked,
                        Landin.IR.Nth_Atom (Of_Unit, Set_Id, Index)));
                     Raw : constant Pattern := Pattern
                       (Landin.IR.Nth_Encoding (Of_Unit, Set_Id, Index));
                  begin
                     Immediate ("x30", (if Encode then Code else Raw));
                     Compare ("x5", "x30");
                     Branch ("ne", Next);
                     Immediate ("x5", (if Encode then Raw else Code));
                     Emit ("j " & Done);
                     Put (Next & ":");
                  end;
               end loop;
               Emit ("j " & Trap (Landin.Panics.Bad_Conversion));
               Put (Done & ":");
            end Packed_Atom;

            procedure FP_Load (Which : Positive; Register : String);
            procedure FP_Save;
            procedure Index_Address
              (Storage : Landin.IR.Storage; Field : Natural;
               Which, Payload : Natural; Nested : Landin.IR.Path_Step_Array;
               Below : Landin.IR.Path_Step_Array := Landin.IR.No_Path_Steps);

            procedure FP_Load (Which : Positive; Register : String) is
            begin
               Load_Value (Operand (Which));
               Emit ((if Kind (Operand (Which)) = Landin.Types.F32
                      then "fmv.w.x " else "fmv.d.x ")
                 & "f" & Register & ", x5");
            end FP_Load;

            procedure FP_Save is
            begin
               Emit ((if Kind (Value) = Landin.Types.F32
                      then "fmv.x.w " else "fmv.x.d ") & "x5, f16");
               Store_Value (Value);
            end FP_Save;

            procedure Index_Address
              (Storage : Landin.IR.Storage; Field : Natural;
               Which, Payload : Natural; Nested : Landin.IR.Path_Step_Array;
               Below : Landin.IR.Path_Step_Array := Landin.IR.No_Path_Steps)
            is
               Length : constant Landin.IR.Element_Total :=
                 Array_Length_Of (Storage, Field, Which, Payload, Nested);
               Stride : constant Landin.Targets.Byte_Count :=
                 Element_Bytes_Of (Storage, Field, Which, Payload, Nested);
               Scale : Landin.Targets.Byte_Count := Stride;
               Shift : Natural := 0;
            begin
               Load_Value (Operand (1), "x29");
               if not Unchecked then
                  Immediate ("x30", Pattern (Length));
                  Compare ("x29", "x30");
                  Branch ("hs", Trap);
               end if;
               while Scale > 1 and then Scale mod 2 = 0 loop
                  Scale := Scale / 2;
                  Shift := Shift + 1;
               end loop;
               if Scale /= 1 then
                  Immediate ("x30", Pattern (Stride));
                  Emit ("mul x29, x29, x30");
               end if;
               Storage_Address (Storage, Field, "x6", Which, Payload, Nested);
               if Scale = 1 and then Shift > 0 then
                  Emit (RiscV_Instructions.Indexed_Address
                    (6, 6, 29, 30, Shift, 64,
                     Landin.Targets.Levels.Has
                       (Level, Landin.Targets.Levels.Zba),
                     Landin.Targets.Levels.Has (Level,
                       Landin.Targets.Levels.Xtheadba)));
               else
                  Emit ("add x6, x6, x29");
               end if;
               if Below'Length > 0 then
                  Add_Offset ("x6", Path_Offset
                    (Element_Shape_Of (Storage, Field, Which, Payload, Nested),
                     Below));
               end if;
            end Index_Address;
         begin
            case Op is
               when Landin.IR.Assembly =>
                  Assembly_Block (Value);
               when Landin.IR.Number =>
                  declare
                     Bits : constant Landin.Targets.Bit_Width :=
                       (if Kind (Value) in Landin.Types.Float_Name
                        then Landin.Types.Float_Width (Kind (Value))
                        else Landin.Types.Width (Kind (Value), Facts));
                     Number : Pattern := Pattern
                       (Landin.IR.Number_Of (Of_Unit, Item, Value));
                  begin
                     if Kind (Value) not in Landin.Types.Float_Name
                       and then Landin.IR.Is_Negated (Of_Unit, Item, Value)
                     then
                        Number := Mask (0 - Number, Bits);
                     end if;
                     Immediate ("x5", Number);
                     Store_Value (Value);
                  end;
               when Landin.IR.Truth =>
                  Immediate ("x5", (if Landin.IR.Truth_Of
                    (Of_Unit, Item, Value) then 1 else 0));
                  Store_Value (Value);
               when Landin.IR.Atom =>
                  Immediate ("x5", Pattern (Atom_Code
                    (Atoms_Ranked, Landin.IR.Atom_Of (Of_Unit, Item, Value))));
                  Store_Value (Value);
               when Landin.IR.Measure_Size | Landin.IR.Measure_Align =>
                  declare
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Measurement_Extent
                       (Of_Unit, Item, Value, Facts, Bytes, Alignment);
                     Immediate ("x5", (if Op = Landin.IR.Measure_Size
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
                        Store_Value (Value, "x6");
                     else
                        Storage_Address (Storage, Field, "x5", Nested =>
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
                     Width : constant String := (if Bytes = 8
                       then "d" else "w");
                     Retry : constant String := Fresh;
                     Done : constant String := Fresh;
                  begin
                     if Landin.Memory.Operands (M) = 0 then
                        if M /= Compiler_Barrier then
                           Emit ("fence iorw, iorw");
                        end if;
                     else
                        Load_Value (Operand (1), "x6");
                        if Bytes > 1 then
                           Emit ("andi x18, x6, " & Image (Bytes - 1));
                           Emit ("bnez x18, " & Trap);
                        end if;
                        if M not in Volatile_Load | Volatile_Store then
                           Emit ("fence iorw, iorw");
                        end if;
                        if M in Atomic_Load | Volatile_Load then
                           Memory (False, Size, "x5", "x6");
                        elsif M in Atomic_Store | Volatile_Store then
                           Load_Value (Operand (2));
                           Memory (True, Size, "x5", "x6");
                        else
                           Load_Value (Operand (2), "x7");
                           if M = Atomic_Compare_Exchange then
                              Load_Value (Operand (3), "x28");
                           end if;
                           if Bytes >= 4
                             and then M /= Atomic_Compare_Exchange
                           then
                              Emit ((if M = Atomic_Add
                                then "amoadd." else "amoswap.")
                                & Width & ".aqrl x5, x7, (x6)");
                              if Bytes = 4 then
                                 Extract ("x5", "x5", 0, 32);
                              end if;
                           else
                              if Bytes < 4 then
                                 --  A naturally aligned subword fits within
                                 --  one aligned word. Preserve every byte
                                 --  outside it across the reservation loop.
                                 Emit ("andi x18, x6, -4");
                                 Emit ("andi x19, x6, 3");
                                 Emit ("slli x19, x19, 3");
                                 Immediate ("x22", 2 ** (Bytes * 8) - 1);
                              else
                                 Emit ("mv x18, x6");
                              end if;
                              Put (Retry & ":");
                              Emit ("lr." & Width & ".aq x20, (x18)");
                              if Bytes < 4 then
                                 Emit ("srl x5, x20, x19");
                                 Emit ("and x5, x5, x22");
                              elsif Bytes = 4 then
                                 Extract ("x5", "x20", 0, 32);
                              else
                                 Emit ("mv x5, x20");
                              end if;
                              if M = Atomic_Compare_Exchange then
                                 --  This forward escape and the retry below
                                 --  are adjacent local branches. Keep the
                                 --  A extension's constrained LR/SC loop
                                 --  within 16 base-I instructions: far-branch
                                 --  relaxation would introduce JALR.
                                 Put (Character'Val (9)
                                   & "bne x5, x7, " & Done);
                                 Emit ("mv x21, x28");
                              elsif M = Atomic_Add then
                                 Emit ("add x21, x5, x7");
                              else
                                 Emit ("mv x21, x7");
                              end if;
                              if Bytes < 4 then
                                 Emit ("and x21, x21, x22");
                                 Emit ("sll x21, x21, x19");
                                 Emit ("sll x24, x22, x19");
                                 Emit ("not x24, x24");
                                 Emit ("and x25, x20, x24");
                                 Emit ("or x21, x25, x21");
                              end if;
                              Emit ("sc." & Width & ".rl x30, x21, (x18)");
                              Put (Character'Val (9) & "bnez x30, " & Retry);
                              Put (Done & ":");
                           end if;
                        end if;
                        if M not in Volatile_Load | Volatile_Store then
                           Emit ("fence iorw, iorw");
                        end if;
                        if Landin.Memory.Returns_Value (M) then
                           Store_Value (Value);
                        end if;
                     end if;
                  end;

               when Landin.IR.Load_Indirect =>
                  Load_Value (Operand (1), "x6");
                  Memory (False, Size_Of_Value (Value), "x5", "x6");
                  Store_Value (Value);
               when Landin.IR.Store_Indirect =>
                  Load_Value (Operand (1), "x6");
                  Load_Value (Operand (2));
                  Memory (True, Size_Of_Value (Operand (2)), "x5", "x6");
               when Landin.IR.Load_Datum | Landin.IR.Store_Datum =>
                  Address ("x6", Symbol
                    (Landin.IR.Datum_Of (Of_Unit, Item, Value)));
                  if Op = Landin.IR.Load_Datum then
                     Memory (False, Size_Of_Value (Value), "x5", "x6");
                     Store_Value (Value);
                  else
                     Load_Value (Operand (1));
                     Memory (True, Size_Of_Value (Operand (1)), "x5", "x6");
                  end if;
               when Landin.IR.Load_Field | Landin.IR.Store_Field =>
                  declare
                     Shape : constant Landin.IR.Field_Shape :=
                       Landin.IR.Shape_At
                       (Of_Unit, Part_Shape_Of
                          (Place, Landin.IR.Field_Of (Of_Unit, Item, Value)),
                        Landin.IR.Path_Of (Of_Unit, Item, Value));
                  begin
                     if Shape.Packing.Bits /= 0 then
                        Part_Address
                          (Place, Landin.IR.Element_Total
                             (Landin.IR.Field_Of (Of_Unit, Item, Value)),
                           "x6", Nested => Landin.IR.Path_Of
                             (Of_Unit, Item, Value));
                        if Op = Landin.IR.Load_Field then
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x5", "x6");
                           Extract ("x5", "x5", Shape.Packing.First,
                             Shape.Packing.Bits);
                           Packed_Atom (Shape.Atoms, Encode => False);
                           Store_Value (Value, Atom_Validated => True);
                        else
                           Load_Value (Operand (1));
                           Packed_Atom (Shape.Atoms, Encode => True);
                           if Shape.Packing.Bits < 64 then
                              Emit ("srli x7, x5, " & Trimmed
                                (Natural'Image (Shape.Packing.Bits)));
                              Emit ("bnez x7, "
                                & Trap (Landin.Panics.Bad_Conversion));
                           end if;
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x7", "x6");
                           Insert_Bits ("x7", "x5", Shape.Packing.First,
                             Shape.Packing.Bits);
                           Memory (True, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x7", "x6");
                        end if;
                        return;
                     end if;
                  end;
                  Part_Address
                    (Place, Landin.IR.Element_Total
                       (Landin.IR.Field_Of (Of_Unit, Item, Value)),
                     "x6", Nested => Landin.IR.Path_Of (Of_Unit, Item,
                       Value));
                  if Op = Landin.IR.Load_Field then
                     Memory (False, Size_Of_Value (Value), "x5", "x6");
                     Store_Value (Value);
                  else
                     Load_Value (Operand (1));
                     Memory (True, Size_Of_Value (Operand (1)), "x5", "x6");
                  end if;
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
                        Load_Value (Operand (1), "x29");
                        Immediate ("x30", Pattern (Shape.Length));
                        Compare ("x29", "x30");
                        Branch ("hs", Trap);
                        Immediate ("x30", Pattern (Shape.Packing.Bits));
                        Emit ("mul x29, x29, x30");
                        Emit ("addi x29, x29, " & Trimmed
                          (Natural'Image (Shape.Packing.First)));
                        Storage_Address
                          (Place, Field, "x6", Nested => Nested);
                        Immediate ("x28", (if Shape.Packing.Bits = 64
                          then Pattern'Last else
                            2 ** Shape.Packing.Bits - 1));
                        if Op = Landin.IR.Load_Element then
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x5", "x6");
                           Emit ("srl x5, x5, x29");
                           Emit ("and x5, x5, x28");
                           Packed_Atom (Landin.IR.Array_Element_Shape
                             (Of_Unit, Shape).Atoms, Encode => False);
                           Store_Value (Value, Atom_Validated => True);
                        else
                           Load_Value (Operand (2));
                           Packed_Atom (Landin.IR.Array_Element_Shape
                             (Of_Unit, Shape).Atoms, Encode => True);
                           Emit ("not x18, " & "x28");
                           Emit ("and x7, x5, x18");
                           Emit ("bnez x7, "
                             & Trap (Landin.Panics.Bad_Conversion));
                           Emit ("sll x5, x5, x29");
                           Emit ("sll x28, x28, x29");
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x7", "x6");
                           Emit ("not x18, " & "x28");
                           Emit ("and x7, x7, x18");
                           Emit ("or x7, x7, x5");
                           Memory (True, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x7", "x6");
                        end if;
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
                     Memory (False, Size_Of_Value (Value), "x5", "x6");
                     Store_Value (Value);
                  else
                     Load_Value (Operand (2));
                     Memory (True, Size_Of_Value (Operand (2)), "x5", "x6");
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
                          "x5",
                        (if Op = Landin.IR.Copy_Array then
                           Landin.IR.Variant_Case_Of (Of_Unit, Item, Value)
                         else 0),
                        (if Op = Landin.IR.Copy_Array then
                           Landin.IR.Variant_Payload_Field_Of
                             (Of_Unit, Item, Value) else 0),
                        Landin.IR.Path_Of (Of_Unit, Item, Value));
                     Storage_Address (Source, Field, "x6", Nested => Nested);
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
                     Offset : Landin.Targets.Byte_Count;
                  begin
                     if Op = Landin.IR.Select_Variant then
                        Variant_Selected_Payload_Extent
                          (Of_Unit, Reached_Shape (Destination, Field, Nested),
                           Positive (Landin.IR.Variant_Case_Of
                             (Of_Unit, Item, Value)), Facts, Offset, Bytes);
                     else
                        Bytes := Whole_Clear_Extent
                          (Destination, Field, Nested);
                     end if;
                     if Bytes > 0 then
                        Storage_Address (Destination, Field, "x5", Nested =>
                          Nested);
                        if Op = Landin.IR.Select_Variant then
                           Add_Offset ("x5", Offset);
                        end if;
                        Zero_Bytes (Bytes);
                     end if;
                     if Op = Landin.IR.Select_Variant then
                        Storage_Address
                          (Destination, Field, "x6", Nested => Nested);
                        Immediate ("x5", Pattern
                          (Landin.IR.Variant_Case_Of (Of_Unit, Item, Value) -
                            1));
                        Memory (True, Size_Of
                          (Reached_Shape (Destination, Field, Nested).Element,
                           Facts), "x5", "x6");
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
                       (Destination, Field, "x6", Which, Payload, Nested);
                     Add_Offset ("x6", Landin.Targets.Byte_Count (First)
                       * Landin.Targets.Byte_Count (Landin.Targets.Bytes
                         (Held)));
                     Load_Value (Operand (1));
                     Immediate ("x7", Pattern (Length - First));
                     Emit ("beqz x7, " & Loop_Label & "_end");
                     Put (Loop_Label & ":");
                     Memory (True, Held, "x5", "x6");
                     Emit ("addi x6, x6, "
                       & Trimmed (Positive'Image (Landin.Targets.Bytes
                         (Held))));
                     Add_Sub ("x7", "x7", "1", Subtract => True,
                       Literal => True);
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
                          "x6",
                        (if Op = Landin.IR.Load_Variant_Tag then 0
                         else Landin.IR.Variant_Case_Of (Of_Unit, Item,
                           Value)),
                        (if Op = Landin.IR.Load_Variant_Tag then 0
                         else Landin.IR.Variant_Payload_Field_Of (Of_Unit,
                           Item, Value)),
                        Landin.IR.Path_Of (Of_Unit, Item, Value));
                     if Writing then
                        Load_Value (Operand (1));
                        Memory (True, Size_Of_Value (Operand (1)), "x5",
                          "x6");
                     else
                        Memory (False, Size_Of_Value (Value), "x5", "x6");
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
                     Load_Value (Operand (4), "x7");
                     Load_Value (Operand (3), "x6");
                     if not Unchecked then
                        Load_Value (Operand (2), "x5");
                        Compare ("x7", "x5");
                        Branch ((if Landin.IR.Slice_Is_Inclusive
                          (Of_Unit, Item, Value) then "hs" else "hi"), Trap);
                        Compare ("x6", "x7");
                        Branch ("hi", Trap);
                     end if;
                     Immediate ("x7", Pattern (Bytes));
                     Load_Value (Operand (1));
                     Emit ("mul x18, x6, x7");
                     Emit ("add x5, x5, x18");
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
                     Immediate ("x5", Pattern (Alignment));
                     Store_Value (Value);
                  end;
               when Landin.IR.Negation | Landin.IR.Complement |
                 Landin.IR.Logical_Not =>
                  Load_Value (Operand (1));
                  if Op = Landin.IR.Logical_Not then
                     Emit ("xori x5, x5, 1");
                  elsif Op = Landin.IR.Complement then
                     Emit ("not x5, x5");
                  elsif Kind (Value) in Landin.Types.Float_Name then
                     Immediate ("x6", (if Kind (Value) = Landin.Types.F32
                       then 2 ** 31 else 2 ** 63));
                     Emit ("xor x5, x5, x6");
                  else
                     Extend ("x5", Kind (Value));
                     Add_Sub ("x5", "zero", "x5", Subtract => True);
                     if not Unchecked then
                        Branch ((if Landin.Types.Is_Signed (Kind (Value))
                          then "vs" else "cc"), Trap);
                        Check_Fit ("x5", Kind (Value));
                     end if;
                  end if;
                  Store_Value (Value);
               when Landin.IR.Add | Landin.IR.Subtract | Landin.IR.Multiply
                  | Landin.IR.Divide | Landin.IR.Remainder
                  | Landin.IR.Wrapping_Add | Landin.IR.Wrapping_Subtract
                  | Landin.IR.Wrapping_Multiply | Landin.IR.Bitwise_And
                  | Landin.IR.Bitwise_Or | Landin.IR.Bitwise_Xor
                  | Landin.IR.Shift_Left | Landin.IR.Shift_Right =>
                  if Kind (Value) in Landin.Types.Float_Name then
                     FP_Load (1, "16");
                     FP_Load (2, "17");
                     Emit ((case Op is
                       when Landin.IR.Add => "fadd.",
                       when Landin.IR.Subtract => "fsub.",
                       when Landin.IR.Multiply => "fmul.",
                       when Landin.IR.Divide => "fdiv.",
                       when others => raise Compiler_Defect with
                         "invalid float operation")
                       & FP (Kind (Value)) & " f16, f16, f17, rne");
                     FP_Save;
                  else
                     declare
                        Signed : constant Boolean := Landin.Types.Is_Signed
                          (Kind (Value));
                        Checked : constant Boolean := not Unchecked and then
                          Op in
                          Landin.IR.Add | Landin.IR.Subtract |
                            Landin.IR.Multiply;
                        Bits : constant Natural := Natural
                          (Landin.Types.Width (Kind (Value), Facts));
                        Done : constant String := Fresh;
                     begin
                        Load_Value (Operand (1));
                        Load_Value (Operand (2), "x6");
                        Extend ("x5", Kind (Value));
                        Extend ("x6", Kind (Value));
                        case Op is
                           when Landin.IR.Add | Landin.IR.Wrapping_Add =>
                              Add_Sub ("x5", "x5", "x6", Subtract => False);
                              if Checked then
                                 Branch ((if Signed then "vs" else "cs"),
                                   Trap);
                              end if;
                           when Landin.IR.Subtract |
                             Landin.IR.Wrapping_Subtract =>
                              Add_Sub ("x5", "x5", "x6", Subtract => True);
                              if Checked then
                                 Branch ((if Signed then "vs" else "cc"),
                                   Trap);
                              end if;
                           when Landin.IR.Multiply |
                             Landin.IR.Wrapping_Multiply =>
                              if Checked then
                                 Emit ((if Signed then "mulh " else "mulhu ")
                                   & "x7, x5, x6");
                              end if;
                              Emit ("mul x5, x5, x6");
                              if Checked then
                                 if Signed then
                                    Emit ("srai x28, x5, 63");
                                    Compare ("x7", "x28");
                                    Branch ("ne", Trap);
                                 else
                                    Emit ("bnez x7, " & Trap);
                                 end if;
                              end if;
                           when Landin.IR.Divide | Landin.IR.Remainder =>
                              Emit ("beqz x6, " & Trap);
                              if Signed and then Op = Landin.IR.Divide then
                                 Immediate ("x7", To_Pattern
                                   (-Landin.Types.Folded (2 ** (Bits - 1)),
                                     64));
                                 Compare ("x5", "x7");
                                 Branch ("ne", Done & "_divide");
                                 Compare ("x6", "-1", Literal => True);
                                 Branch ("eq", Trap);
                                 Put (Done & "_divide:");
                              end if;
                              Emit ((if Signed then "div " else "divu ")
                                & "x7, x5, x6");
                              if Op = Landin.IR.Remainder then
                                 Emit ("mul x18, x7, x6");
                                 Emit ("sub x5, x5, x18");
                              else
                                 Emit ("mv x5, x7");
                              end if;
                           when Landin.IR.Bitwise_And =>
                              Emit ("and x5, x5, x6");
                           when Landin.IR.Bitwise_Or => Emit ("or x5, x5, x6");
                           when Landin.IR.Bitwise_Xor =>
                              Emit ("xor x5, x5, x6");
                           when Landin.IR.Shift_Left | Landin.IR.Shift_Right =>
                              if Signed then
                                 Extract ("x18", "x6", 63, 1);
                                 Emit ("bnez x18, " & Trap);
                              end if;
                              Compare ("x6", Trimmed (Natural'Image
                                (Bits)), Literal => True);
                              Branch ("lo", Done & "_shift");
                              Emit ("li x5, 0");
                              Emit ("j " & Done);
                              Put (Done & "_shift:");
                              Emit ((if Op = Landin.IR.Shift_Left then "sll "
                                elsif Signed then "sra " else "srl ") &
                                  "x5, x5, x6");
                              Put (Done & ":");
                           when others => raise Compiler_Defect with
                             "invalid integer operation";
                        end case;
                        if Checked then
                           Check_Fit ("x5", Kind (Value));
                        end if;
                        Store_Value (Value);
                     end;
                  end if;
               when Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                  | Landin.IR.Less_Than | Landin.IR.Less_Or_Equal
                  | Landin.IR.Greater_Than | Landin.IR.Greater_Or_Equal =>
                  declare
                     Scalar : constant Landin.Types.Scalar_Name := Kind
                       (Operand (1));
                     Float : constant Boolean := Scalar in
                       Landin.Types.Float_Name;
                     Signed : constant Boolean := Scalar in
                       Landin.Types.Integer_Name
                       and then Landin.Types.Is_Signed (Scalar);
                     Condition : constant String :=
                       (case Op is
                          when Landin.IR.Equal_To => "eq",
                          when Landin.IR.Not_Equal_To => "ne",
                          when Landin.IR.Less_Than =>
                            (if Float then "mi" elsif Signed then "lt" else
                              "lo"),
                          when Landin.IR.Less_Or_Equal =>
                            (if Float then "ls" elsif Signed then "le" else
                              "ls"),
                          when Landin.IR.Greater_Than =>
                            (if Float or Signed then "gt" else "hi"),
                          when Landin.IR.Greater_Or_Equal =>
                            (if Float or Signed then "ge" else "hs"),
                          when others => raise Compiler_Defect with
                            "invalid comparison");
                  begin
                     if Float then
                        FP_Load (1, "16");
                        FP_Load (2, "17");
                        Compare_Float (FP (Scalar), "f16", "f17");
                     else
                        Load_Value (Operand (1));
                        Load_Value (Operand (2), "x6");
                        Extend ("x5", Scalar);
                        Extend ("x6", Scalar);
                        Compare ("x5", "x6");
                     end if;
                     Predicate ("x5", Condition);
                     Store_Value (Value);
                  end;
               when Landin.IR.Range_Check =>
                  Load_Value (Operand (1));
                  Extend ("x5", Kind (Value));
                  Immediate ("x6", To_Pattern
                    (Landin.IR.Range_Lower (Of_Unit, Item, Value), 64));
                  Compare ("x5", "x6");
                  Branch ((if Landin.Types.Is_Signed (Kind (Value))
                    then "lt" else "lo"), Trap);
                  Immediate ("x6", To_Pattern
                    (Landin.IR.Range_Upper (Of_Unit, Item, Value), 64));
                  Compare ("x5", "x6");
                  Branch ((if Landin.Types.Is_Signed (Kind (Value))
                    then "gt" else "hi"), Trap);
                  Store_Value (Value);
               when Landin.IR.Conversion | Landin.IR.Pointer_Address =>
                  declare
                     From : constant Landin.Types.Scalar_Name
                       := Kind (Operand (1));
                     Into_Type : constant Landin.Types.Scalar_Name
                       := Kind (Value);
                     From_Float : constant Boolean := From
                       in Landin.Types.Float_Name;
                     Into_Float : constant Boolean := Into_Type
                       in Landin.Types.Float_Name;
                     Done : constant String := Fresh;
                  begin
                     Load_Value (Operand (1));
                     Extend ("x5", From);
                     if From_Float then
                        FP_Load (1, "16");
                     end if;
                     if From_Float and Into_Float then
                        if From /= Into_Type then
                           Emit ("fsflags zero");
                           Emit ("fcvt." & FP (Into_Type) & "." & FP (From)
                             & " f16, f16"
                             & (if Into_Type = Landin.Types.F32
                                then ", rne" else ""));
                           if Into_Type = Landin.Types.F32 then
                              Emit ("frflags x6");
                              Emit ("andi x6, x6, 4");
                              Emit ("bnez x6, " & Trap);
                           end if;
                        end if;
                        FP_Save;
                     elsif Into_Float then
                        Emit ("fcvt." & FP (Into_Type)
                          & (if From in Landin.Types.Integer_Name
                             and then Landin.Types.Is_Signed (From)
                             then ".l" else ".lu") & " f16, x5, rne");
                        FP_Save;
                     elsif Into_Type = Landin.Types.Bool then
                        if From_Float then
                           Emit ((if From = Landin.Types.F32
                                  then "fmv.w.x " else "fmv.d.x ")
                             & "f17, zero");
                           Emit ("feq." & FP (From) & " x6, f16, f17");
                           Emit ("bnez x6, " & Done & "_zero");
                           Immediate ("x6", (if From = Landin.Types.F32
                             then 16#3f80_0000# else 16#3ff0_0000_0000_0000#));
                           Emit ((if From = Landin.Types.F32
                                  then "fmv.w.x " else "fmv.d.x ")
                             & "f17, x6");
                           Emit ("feq." & FP (From) & " x6, f16, f17");
                           Emit ("beqz x6, " & Trap);
                           Emit ("li x5, 1");
                           Emit ("j " & Done);
                           Put (Done & "_zero:");
                           Emit ("li x5, 0");
                           Put (Done & ":");
                        else
                           Compare ("x5", "1", Literal => True);
                           Branch ("hi", Trap);
                        end if;
                        Store_Value (Value);
                     elsif From_Float then
                        declare
                           Signed : constant Boolean
                             := Landin.Types.Is_Signed (Into_Type);
                        begin
                           --  RTZ's invalid flag tests the rounded integer,
                           --  so -0.5 converts to unsigned zero. NaNs and
                           --  either unrepresentable endpoint raise invalid.
                           Emit ("fsflags zero");
                           Emit ("fcvt." & (if Signed then "l." else "lu.")
                             & FP (From) & " x5, f16, rtz");
                           Emit ("frflags x6");
                           Emit ("andi x6, x6, 16");
                           Emit ("bnez x6, " & Trap);
                           Check_Fit ("x5", Into_Type);
                           Store_Value (Value);
                        end;
                     else
                        if not Unchecked and then Into_Type
                          in Landin.Types.Integer_Name
                        then
                           if From in Landin.Types.Integer_Name
                             and then Landin.Types.Is_Signed (From)
                               /= Landin.Types.Is_Signed (Into_Type)
                           then
                              Emit ("bltz x5, " & Trap);
                           end if;
                           Check_Fit ("x5", Into_Type);
                        end if;
                        Store_Value (Value);
                     end if;
                  end;
               when Landin.IR.Function_Address =>
                  declare
                     Callee : constant Landin.IR.Item_Id :=
                       Landin.IR.Callee_Of (Of_Unit, Item, Value);
                  begin
                     Address ("x5", Symbol (Callee), Landin.IR.Is_External
                       (Of_Unit, Callee));
                     Store_Value (Value);
                  end;
               when Landin.IR.Evidence_Address =>
                  Address ("x5", Evidence_Symbol
                    (Landin.IR.Evidence_Of (Of_Unit, Item, Value)));
                  Store_Value (Value);
               when Landin.IR.Evidence_Function =>
                  Load_Value (Operand (1));
                  if Landin.IR.Evidence_Is_Erased
                    (Of_Unit, Landin.IR.Evidence_Of (Of_Unit, Item, Value))
                  then
                     Emit ("ld x5, 8(x5)");
                  end if;
                  Add_Offset ("x5", Landin.Targets.Evidence_Function_Offset
                    (Facts, Landin.IR.Evidence_Entry_Of (Of_Unit, Item,
                      Value)));
                  Emit ("ld x5, 0(x5)");
                  Store_Value (Value);
               when Landin.IR.Evidence_Self =>
                  Load_Value (Landin.IR.Nth_Operand (Of_Unit, Item, Operand
                    (1), 1));
                  Emit ("ld x5, 0(x5)");
                  Store_Value (Value);
               when Landin.IR.Failure_Test =>
                  Load_Value (Operand (1));
                  Compare ("x5", "0", Literal => True);
                  Predicate ("x5", "ne");
                  Store_Value (Value);
               when Landin.IR.Call | Landin.IR.Indirect_Call =>
                  declare
                     Indirect : constant Boolean := Op =
                       Landin.IR.Indirect_Call;
                     Signature : constant Landin.IR.Signature_Id :=
                       (if Indirect then Landin.IR.Call_Signature (Of_Unit,
                         Item, Value)
                        else Landin.IR.Signature_Of (Of_Unit,
                          Landin.IR.Callee_Of (Of_Unit, Item, Value)));
                     Offset : constant Natural := (if Indirect then 1 else 0);
                     Count : constant Natural :=
                       Landin.IR.Operand_Count (Of_Unit, Item, Value) - Offset;
                     Bytes : constant Landin.Targets.Byte_Count :=
                       Stack_Align (Landin.Targets.Byte_Count
                         (Natural'Max (8, Count) - 8) * 8, 16, 16#7fff_ffff#);
                  begin
                     if Landin.IR.Signature_Uses_C_ABI (Of_Unit, Signature)
                     then
                        C_Call (Value);
                        return;
                     end if;
                     Reserve (Bytes);
                     for Index in 1 .. Count loop
                        if Index <= 8 then
                           Load_Value (Operand (Index + Offset), "x"
                             & Trimmed (Natural'Image (Index + 9)));
                        else
                           Load_Value (Operand (Index + Offset));
                           declare
                              Stack_At : constant Landin.Targets.Byte_Count :=
                                Landin.Targets.Byte_Count (Index - 9) * 8;
                           begin
                              if Stack_At <= 2047 then
                                 Emit ("sd x5, " & Trimmed
                                 (Landin.Targets.Byte_Count'Image (Stack_At))
                                 & "(sp)");
                              else
                                 Emit ("mv x6, sp");
                                 Add_Offset ("x6", Stack_At);
                                 Emit ("sd x5, 0(x6)");
                              end if;
                           end;
                        end if;
                     end loop;
                     if Indirect then
                        Load_Value (Operand (1), "x30");
                        Emit ("jalr ra, 0(x30)");
                     else
                        Emit ("call " & Symbol (Landin.IR.Callee_Of (Of_Unit,
                          Item, Value)));
                     end if;
                     if Landin.IR.Failure_Slot_Of (Of_Unit, Item, Value) /=
                       Landin.IR.No_Slot
                     then
                        Store_Slot (Landin.IR.Failure_Slot_Of (Of_Unit, Item,
                          Value), "x31");
                     end if;
                     if Landin.IR.Result_Of (Of_Unit, Item, Value) in
                       Landin.Types.Scalar_Name
                     then
                        Store_Value (Value, "x10");
                     end if;
                     Restore_Stack (Bytes);
                  end;
               when Landin.IR.Jump =>
                  Emit ("j " & Label (Item, Landin.IR.Target_Of (Of_Unit,
                    Item, Value)));
               when Landin.IR.Branch =>
                  Load_Value (Operand (1));
                  Emit ("bnez x5, " & Label (Item, Landin.IR.Target_Of
                    (Of_Unit, Item, Value)));
                  Emit ("j " & Label (Item, Landin.IR.Alternative_Of (Of_Unit,
                    Item, Value)));
               when Landin.IR.Leave =>
                  if Is_C_Item (Item) then
                     C_Result (Value);
                  elsif Result in Landin.Types.Scalar_Name then
                     Load_Value (Operand (1), "x10");
                     if Item = Hosted_Entry then
                        --  The no-argument language entry returns libc's
                        --  C int, whose LP64D carrier is sign-extended to
                        --  XLEN even when the language bit carrier is not.
                        Emit ("sext.w x10, x10");
                     end if;
                  elsif Result in Landin.Types.Aggregate |
                    Landin.Types.Fixed_Array
                  then
                     declare
                        Slot : constant Landin.IR.Slot_Id :=
                          Landin.IR.Result_Slot (Of_Unit, Item);
                     begin
                        Load_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1));
                        Frame_Address (Slot_Offset (Layout, Slot), "x6");
                        Copy_Bytes (Whole_Clear_Extent
                          ((Kind => Landin.IR.Frame_Slot, Slot => Slot), 0,
                            Landin.IR.No_Path_Steps));
                     end;
                  end if;
                  Emit ("li x31, 0");
                  Finish_Exit;
               when Landin.IR.Halt =>
                  if Panic = null or else Landin.Panics.Handler (Panic.all)
                    = Landin.IR.No_Item
                  then
                     Emit ("unimp");
                  else
                     Emit ("j " & Trap (Landin.Panics.Unreachable));
                  end if;

               when Landin.IR.Fail =>
                  Load_Value (Operand (1), "x31");
                  Finish_Exit;
            end case;
         end Instruction;

      begin
         --  One terminal keeps its inline teardown; more than one pays for
         --  branches to a single restore sequence.
         for Index in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
            if Landin.IR.Op_Of (Of_Unit, Item, Landin.IR.Value_Id (Index))
              in Landin.IR.Leave | Landin.IR.Fail
            then
               Terminal_Count := Terminal_Count + 1;
            end if;
         end loop;
         if Is_Public_Item (Item) or else Is_Forced (Item) then
            Emit (".globl " & Symbol (Item));
         end if;
         Emit (".p2align 2");
         Platform_Directive (ELF_Spelling.Function_Type (Symbol (Item)));
         Put (Symbol (Item) & ":");
         if Debug /= null then
            Put (Dwarf.Label_Name (Local_Prefix, "begin", Item) & ":");
            Put (Dwarf.Source_Line
              (Debug.all, Landin.IR.Origin_Of (Of_Unit, Item)));
            Emit (".cfi_startproc");
         end if;
         Emit ("addi sp, sp, -16");
         Emit ("sd x8, 0(sp)");
         Emit ("sd ra, 8(sp)");
         if Debug /= null then
            Emit (".cfi_def_cfa_offset 16");
            Emit (".cfi_offset x8, -16");
            Emit (".cfi_offset x1, -8");
         end if;
         Emit ("addi x8, sp, 16");
         if Debug /= null then
            Emit (".cfi_def_cfa x8, 0");
         end if;
         if Item = Hosted_Entry then
            Emit ("call " & Bridge_Symbol (Initialize_Arguments));
         end if;
         Reserve (Extent (Layout));
         for Number in Saves'Range loop
            if Saves (Number) then
               Frame_Address (Save_Home (Number), "x5");
               Emit ("sd x" & Trimmed (Natural'Image (Number)) & ", 0(x5)");
               if Debug /= null then
                  --  The home sits below the CFA and saved-frame header.
                  Emit (".cfi_offset " & Trimmed (Natural'Image (Number))
                        & ", -" & Trimmed (Landin.Targets.Byte_Count'Image
                          (Save_Home (Number) + 16)));
               end if;
            end if;
         end loop;
         if Panic /= null and then Item = Landin.Panics.Handler (Panic.all)
         then
            declare
               Retry : constant String := Fresh;
               Busy : constant String := Fresh;
               Claimed : constant String := Fresh;
            begin
               Address ("x18", Local_Prefix & "landin_panic_active");
               Put (Retry & ":");
               Emit ("lr.w.aq x19, (x18)");
               --  The five-instruction reservation loop uses only direct
               --  local branches. Its busy escape leaves the loop before
               --  the possibly distant hard-trap jump.
               Put (Character'Val (9) & "bnez x19, " & Busy);
               Emit ("li x19, 1");
               Emit ("sc.w.rl x9, x19, (x18)");
               Put (Character'Val (9) & "bnez x9, " & Retry);
               Emit ("j " & Claimed);
               Put (Busy & ":");
               Emit ("j " & Hard_Trap);
               Put (Claimed & ":");
            end;
         end if;
         if Is_C_Item (Item) then
            C_Entry;
         else
            for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
               declare
                  Slot : constant Landin.IR.Slot_Id := Landin.IR.Nth_Parameter
                    (Of_Unit, Item, Index);
                  Aggregate : constant Boolean := Landin.IR.Is_Aggregate
                    (Of_Unit, Item, Slot)
                    or else Landin.IR.Is_Array (Of_Unit, Item, Slot);
               begin
                  if Index <= 8 then
                     Emit ("mv x6, x" & Trimmed (Natural'Image (Index + 9)));
                  else
                     Emit ("mv x6, x8");
                     Add_Offset ("x6", Landin.Targets.Byte_Count (Index
                       - 9) * 8);
                     Emit ("ld x6, 0(x6)");
                  end if;
                  if Aggregate then
                     declare
                        Zero_Label : constant String := Fresh;
                        Done_Label : constant String := Fresh;
                        Bytes : constant Landin.Targets.Byte_Count :=
                          Whole_Clear_Extent
                            ((Kind => Landin.IR.Frame_Slot, Slot => Slot), 0,
                             Landin.IR.No_Path_Steps);
                     begin
                        Frame_Address (Slot_Offset (Layout, Slot), "x5");
                        Emit ("beqz x6, " & Zero_Label);
                        Copy_Bytes (Bytes);
                        Emit ("j " & Done_Label);
                        Put (Zero_Label & ":");
                        Zero_Bytes (Bytes);
                        Put (Done_Label & ":");
                     end;
                  else
                     Store_Slot (Slot, "x6");
                  end if;
               end;
            end loop;
         end if;
         for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            Put (Label (Item, Landin.IR.Block_Id (Block)) & ":");
            for Position in 1 .. Landin.IR.Length (Of_Unit, Item,
              Landin.IR.Block_Id (Block)) loop
               Current_Value := Landin.IR.Nth_Value (Of_Unit, Item,
                 Landin.IR.Block_Id (Block), Position);
               if Debug /= null then
                  Put (Dwarf.Label_Name (Local_Prefix, "value", Item,
                    Natural (Current_Value)) & ":");
                  Put (Dwarf.Source_Line (Debug.all,
                    Landin.IR.Origin_Of (Of_Unit, Item, Current_Value)));
               end if;
               Instruction (Current_Value);
               if Debug /= null then
                  Put (Dwarf.Label_Name (Local_Prefix, "after", Item,
                    Natural (Current_Value)) & ":");
               end if;
            end loop;
         end loop;
         if Terminal_Count > 1 then
            Put (Shared_Exit & ":");
            Epilogue;
         end if;
         for Edge of Edges loop
            Put (Unbounded.To_String (Edge.Label) & ":");
            if Debug /= null then
               Put (Dwarf.Source_Line (Debug.all, Edge.Origin));
            end if;
            Immediate ("x10", Pattern (Landin.Panics.Code
              (Panic.all, Edge.Reason)));
            Immediate ("x11", Pattern (Edge.Site));
            Emit ("call " & Symbol (Landin.Panics.Handler (Panic.all)));
            Emit ("unimp");
         end loop;
         Put (Hard_Trap & ":");
         Emit ("unimp");
         if Debug /= null then
            Put (Dwarf.Label_Name (Local_Prefix, "end", Item) & ":");
            Emit (".cfi_endproc");
         end if;
         Platform_Directive (ELF_Spelling.Size_To_Here (Symbol (Item)));
         Landin.Build_Reports.Append (Report,
           Landin.Build_Reports.Routine_Statistics'
             (Item => Item, Frame_Bytes => Extent (Layout),
              Spill_Bytes => Spill_Bytes (Layout),
              Save_Bytes => Save_Bytes (Layout),
              Register_Count => Save_Count (Plan.Saves),
              Spill_Count => Plan.Homes, others => <>));
      end Emit_Routine;

      --  The value a datum's block describes.  [1460] says nothing runs
      --  before the entry point, so this walk is a fold and not an
      --  interpreter: it reaches the block's own Leave and answers with
      --  what that carries.
      function Folded (Item : Landin.IR.Item_Id) return Landin.Types.Folded;

      --  Only a cache miss needs the value and slot scratch buffers.
      function Evaluate (Item : Landin.IR.Item_Id)
        return Landin.Types.Folded;

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

      function Evaluate (Item : Landin.IR.Item_Id)
        return Landin.Types.Folded
      is
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
      end Evaluate;

      function Folded (Item : Landin.IR.Item_Id) return Landin.Types.Folded is
      begin
         --  D177 resolves every module bool through the shared static-image
         --  folder.  In particular, a short-circuit Branch is routine CFG
         --  and never reaches the datum-emission walk or its scratch arrays.
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

         return Evaluate (Item);
      end Folded;

      --  How wide a store the assembler is asked for, at each size.
      function Directive (Size : Held_Size) return String
        is (case Size is
               when Landin.Targets.Byte_1 => ".byte",
               when Landin.Targets.Byte_2 => ".short",
               when Landin.Targets.Byte_4 => ".long",
               when Landin.Targets.Byte_8 => ".quad");

      procedure Emit_Datum (Item : Landin.IR.Item_Id);
      procedure End_Object (Item : Landin.IR.Item_Id);

      --  An object's size runs from its label to here.
      procedure End_Object (Item : Landin.IR.Item_Id) is
      begin
         Platform_Directive (ELF_Spelling.Size
           (Symbol (Item), ".-" & Symbol (Item)));
      end End_Object;

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
               if Shape.Length > Landin.IR.Element_Total (Image.Count) then
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
               end if;
            else
               raise Landin.Compiler_Defect with
                 "a malformed recursive array image reached RV64";
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
                 "a malformed recursive variant image reached RV64";
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
                       "a malformed nested image reached RV64";
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
         Platform_Directive (ELF_Spelling.Object_Type (Symbol (Item)));
         Put (Symbol (Item) & ":");
         if not Is_Array
           and then Landin.IR.Layout_Of (Of_Unit, Item) = Landin.Layouts.Packed
         then
            Emit_Packed ((others => <>), (others => <>), Top => True);
            End_Object (Item);
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
         End_Object (Item);
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
      begin
         if Is_Public_Item (Item) then
            Emit (".globl " & Symbol (Item));
         end if;
         --  An empty datum retains its aligned, zero-sized symbol, without
         --  a zero-count space directive that GNU as diagnoses.
         Emit (ELF_Spelling.Zero_Section);
         Emit (".balign "
           & Trimmed (Landin.Targets.Byte_Alignment'Image (Alignment)));
         Emit (ELF_Spelling.Object_Type (Symbol (Item)));
         Put (Symbol (Item) & ":");
         if Size > 0 then
            Emit (".zero "
              & Trimmed (Landin.Targets.Byte_Count'Image (Size)));
         end if;
         Emit (ELF_Spelling.Size
           (Symbol (Item), Trimmed (Landin.Targets.Byte_Count'Image (Size))));
         Emit (ELF_Spelling.Data_Section);
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
            Platform_Directive (ELF_Spelling.Object_Type (Symbol (Item)));
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
                  if Length > Prefix then
                     Emit
                       (".rept "
                        & Trimmed
                            (Landin.IR.Element_Total'Image (Length - Prefix)));
                     Emit
                       (Directive (Held) & " "
                        & Trimmed
                            (Landin.Types.Folded'Image
                               (Landin.IR.Repeated_Image_Value
                                  (Of_Unit, Item))));
                     Emit (".endr");
                  end if;
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
            End_Object (Item);
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
         Platform_Directive (ELF_Spelling.Object_Type (Symbol (Item)));
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
         End_Object (Item);
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
         Platform_Directive (ELF_Spelling.Object_Type (Symbol (Item)));
         Put (Symbol (Item) & ":");
         Emit (Directive (Held) & " " & Written);
         End_Object (Item);
      end Emit_Datum;

      procedure Runtime;

      procedure Runtime is
         Argv : constant String := Local_Prefix & "host_argv";
         Argc : constant String := Local_Prefix & "host_argc";
         Invalid : constant String := Local_Prefix & "host_invalid";
         Open_Frame : Boolean := False;
         Open_Bridge : Host_Helper := No_Host_Helper;
         procedure Close_Bridge;
         procedure Start (Helper : Host_Helper; Framed : Boolean := True);
         procedure Finish;

         procedure Close_Bridge is
         begin
            if Debug /= null and then Open_Frame then
               Emit (".cfi_endproc");
            end if;
            if Open_Bridge /= No_Host_Helper then
               Platform_Directive (ELF_Spelling.Size_To_Here
                 (Bridge_Symbol (Open_Bridge)));
            end if;
         end Close_Bridge;

         procedure Start (Helper : Host_Helper; Framed : Boolean := True) is
         begin
            Close_Bridge;
            Emit (".p2align 2");
            Emit (".globl " & Bridge_Symbol (Helper));
            Emit (ELF_Spelling.Hidden (Bridge_Symbol (Helper)));
            Platform_Directive (ELF_Spelling.Function_Type
              (Bridge_Symbol (Helper)));
            Put (Bridge_Symbol (Helper) & ":");
            Open_Bridge := Helper;
            Open_Frame := True;
            if Debug /= null then
               Emit (".loc 1 0 0 is_stmt 0");
               Emit (".cfi_startproc");
            end if;
            if Framed then
               Emit ("addi sp, sp, -16");
               Emit ("sd x8, 0(sp)");
               Emit ("sd ra, 8(sp)");
               if Debug /= null then
                  Emit (".cfi_def_cfa_offset 16");
                  Emit (".cfi_offset x8, -16");
                  Emit (".cfi_offset x1, -8");
               end if;
               Emit ("addi x8, sp, 16");
               if Debug /= null then
                  Emit (".cfi_def_cfa x8, 0");
               end if;
               Emit ("addi sp, sp, -16");
               Emit ("sd x26, 8(sp)");
               if Debug /= null then
                  Emit (".cfi_offset x26, -24");
               end if;
            end if;
         end Start;

         procedure Finish is
         begin
            if Debug /= null then
               Emit (".cfi_remember_state");
            end if;
            Emit ("ld x26, -24(x8)");
            Emit ("ld ra, -8(x8)");
            Emit ("mv sp, x8");
            Emit ("ld x8, -16(x8)");
            if Debug /= null then
               Emit (".cfi_def_cfa sp, 0");
               Emit (".cfi_restore x8");
               Emit (".cfi_restore x1");
               Emit (".cfi_restore x26");
            end if;
            Emit ("ret");
            if Debug /= null then
               Emit (".cfi_restore_state");
            end if;
         end Finish;

      begin
         Emit (".text");
         Start (Initialize_Arguments);
         Address ("x5", Argv);
         Emit ("ld x6, 0(x5)");
         Emit ("bnez x6, " & Local_Prefix & "host_initialized");
         Emit ("bltz a0, " & Invalid);
         Emit ("beqz a1, " & Invalid);
         Emit ("sd a1, 0(x5)");
         Address ("x5", Argc);
         Emit ("sw a0, 0(x5)");
         Finish;
         Put (Local_Prefix & "host_initialized:");
         Emit ("bne x6, a1, " & Invalid);
         Address ("x5", Argc);
         Emit ("lw x6, 0(x5)");
         Emit ("bne x6, a0, " & Invalid);
         Finish;
         Put (Invalid & ":");
         if Panic /= null and then Landin.Panics.Handler (Panic.all)
           /= Landin.IR.No_Item
         then
            Immediate ("x10", Pattern (Landin.Panics.Code
              (Panic.all, Landin.Panics.Unreachable)));
            Emit ("li a1, 0");
            Emit ("call " & Symbol (Landin.Panics.Handler (Panic.all)));
         end if;
         Emit ("unimp");
         Start (Argument_Count);
         Address ("x5", Argv);
         Emit ("ld x5, 0(x5)");
         Emit ("beqz x5, " & Invalid);
         Address ("x5", Argc);
         Emit ("lw a0, 0(x5)");
         Emit ("addi a0, a0, -1");
         Emit ("bgez a0, " & Local_Prefix & "argc_done");
         Emit ("li a0, 0");
         Put (Local_Prefix & "argc_done:");
         Finish;
         Start (Argument_Table);
         Address ("x5", Argv);
         Emit ("ld a0, 0(x5)");
         Emit ("beqz a0, " & Invalid);
         Emit ("addi a0, a0, 8");
         Finish;
         Start (Argument_At);
         Address ("x5", Argv);
         Emit ("ld x5, 0(x5)");
         Emit ("beqz x5, " & Invalid);
         Address ("x6", Argc);
         Emit ("lw x6, 0(x6)");
         Emit ("addi x6, x6, -1");
         Emit ("blez x6, " & Invalid);
         Emit ("bgeu a0, x6, " & Invalid);
         Emit ("slli x6, a0, 3");
         Emit ("add x5, x5, x6");
         Emit ("ld a0, 8(x5)");
         Emit ("beqz a0, " & Invalid);
         Finish;
         Start (Argument_At_From);
         Emit ("slli x5, a1, 3");
         Emit ("add x5, a0, x5");
         Emit ("ld a0, 0(x5)");
         Finish;
         Start (Text_Length, Framed => False);
         Emit ("tail " & Landin.Targets.Capabilities.Link_Symbol
           (Facts, "strlen"));
         Start (Read_Bytes, Framed => False);
         Emit ("sext.w a0, a0");
         Emit ("tail " & Landin.Targets.Capabilities.Link_Symbol
           (Facts, "read"));
         Start (Write_Bytes, Framed => False);
         Emit ("sext.w a0, a0");
         Emit ("tail " & Landin.Targets.Capabilities.Link_Symbol
           (Facts, "write"));
         Start (Close_File, Framed => False);
         Emit ("sext.w a0, a0");
         Emit ("tail " & Landin.Targets.Capabilities.Link_Symbol
           (Facts, "close"));
         Start (Open_Read, Framed => False);
         Emit ("li a1, 0");
         Emit ("tail " & Landin.Targets.Capabilities.Link_Symbol
           (Facts, "open"));
         Start (Open_Write);
         Emit ("li a1, " & Image (Hosted_ABI.Create_For_Writing (System)));
         Emit ("li a2, " & Image (Hosted_ABI.Created_File_Mode));
         Emit ("call " & Landin.Targets.Capabilities.Link_Symbol
           (Facts, "open"));
         Finish;
         Start (Errno_Value);
         Emit ("call " & Landin.Targets.Capabilities.Link_Symbol
           (Facts, Hosted_ABI.Errno_Function (System)));
         Emit ("lwu a0, 0(a0)");
         Finish;
         Start (Heap_Allocate);
         Emit ("bnez a1, " & Local_Prefix & "heap_alignment");
         Emit ("li a1, 1");
         Put (Local_Prefix & "heap_alignment:");
         Emit ("addi x5, a1, 7");
         Emit ("bltu x5, a1, " & Local_Prefix & "heap_failed");
         Emit ("add x6, a0, x5");
         Emit ("bltu x6, a0, " & Local_Prefix & "heap_failed");
         Emit ("bltz x6, " & Local_Prefix & "heap_failed");
         Emit ("mv a0, x6");
         Emit ("addi sp, sp, -16");
         Emit ("sd a1, 0(sp)");
         Emit ("call " & Landin.Targets.Capabilities.Link_Symbol
           (Facts, "malloc"));
         Emit ("beqz a0, " & Local_Prefix & "heap_failed");
         Emit ("ld a1, 0(sp)");
         Emit ("addi x5, a0, 8");
         Emit ("remu x6, x5, a1");
         Emit ("beqz x6, " & Local_Prefix & "heap_aligned");
         Emit ("sub x7, a1, x6");
         Emit ("add x5, x5, x7");
         Put (Local_Prefix & "heap_aligned:");
         Emit ("sd a0, -8(x5)");
         Emit ("mv a0, x5");
         Finish;
         Put (Local_Prefix & "heap_failed:");
         Emit ("li a0, 0");
         Finish;
         Start (Heap_Release, Framed => False);
         Emit ("ld a0, -8(a0)");
         Emit ("tail " & Landin.Targets.Capabilities.Link_Symbol
           (Facts, "free"));
         Close_Bridge;
         Emit (".data");
         Emit (".balign 8");
         Put (Argv & ":");
         Emit (".quad 0");
         Put (Argc & ":");
         Emit (".long 0");
      end Runtime;


   begin
      if Landin.Targets.Capabilities.Backend_For (Facts)
          /= Landin.Targets.Capabilities.RV64_ELF
        or else not Landin.Targets.Levels.Belongs_To (Level, Facts)
      then
         raise Compiler_Defect with
           "RV64 emission needs an RV64 description";
      end if;
      --  The ELF ISA attribute and toolchain both assume the selected set.
      Emit (".attribute arch, """ & Landin.Targets.Levels.Name (Level) & """");
      Emit (".option norelax");
      Emit (".option pic");
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         if Landin.IR.Is_External (Of_Unit, Landin.IR.Item_Id (Index))
           and then Helper_Of (Source_Symbol (Landin.IR.Item_Id (Index))) /=
             No_Host_Helper
         then
            Host_Bridge_Needed := True;
         end if;
      end loop;
      Validate_Linkage;
      Allocate_Symbols;
      if Panic /= null and then Landin.Panics.Handler (Panic.all)
        /= Landin.IR.No_Item
      then
         Emit (ELF_Spelling.Push_Panic_Flag_Section);
         Emit (".balign 4");
         Put (Local_Prefix & "landin_panic_active:");
         Emit (".zero 4");
         Emit (ELF_Spelling.Pop_Section);
      end if;
      Emit (".text");
      if Debug /= null then
         Unbounded.Append (Output, Dwarf.Preamble
           (Debug.all, Local_Prefix,
            Mach_O => False));
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
                  Emit (ELF_Spelling.Read_Only_Section);
                  Emit_Array_Image_Datum (Item);
               else
                  Emit (".data");
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
         Emit (ELF_Spelling.Relocated_Read_Only_Section);
         for Index in 1 .. Landin.IR.Evidence_Count (Of_Unit) loop
            declare
               Id : constant Landin.IR.Evidence_Id := Landin.IR.Evidence_Id
                 (Index);
               Alias_Previous : constant Boolean := Index > 1
                 and then Shares_Evidence_Table
                   (Of_Unit, Landin.IR.Evidence_Id (Index - 1), Id);
               Alias_Next : constant Boolean :=
                 Index < Landin.IR.Evidence_Count (Of_Unit)
                   and then Shares_Evidence_Table
                     (Of_Unit, Id, Landin.IR.Evidence_Id (Index + 1));
               Bytes : Landin.Targets.Byte_Count;
               Alignment : Landin.Targets.Byte_Alignment;
            begin
               if not Alias_Previous then
                  Field_Extent
                    (Of_Unit, Landin.IR.Evidence_Represented (Of_Unit, Id),
                     Facts, Bytes, Alignment);
                  Emit (".balign 8");
                  Put (Evidence_Symbol (Id) & ":");
                  if Alias_Next then
                     Put (Evidence_Symbol
                       (Landin.IR.Evidence_Id (Index + 1)) & ":");
                  end if;
                  Emit (".quad " & Trimmed (Landin.Targets.Byte_Count'Image
                    (Bytes)));
                  Emit (".quad " & Trimmed
                    (Landin.Targets.Byte_Alignment'Image (Alignment)));
                  for Entry_Index in 1 .. Landin.IR.Evidence_Entry_Count
                    (Of_Unit, Id) loop
                     Emit (".quad " & Symbol
                       (Landin.IR.Evidence_Entry_Target (Of_Unit, Id,
                         Entry_Index)));
                  end loop;
               end if;
            end;
         end loop;
      end if;
      if Host_Bridge_Needed then
         Runtime;
      end if;
      if Debug /= null then
         Unbounded.Append (Output,
           ELF_Debug_Sections
             (Of_Unit, Meanings, Names, Facts, Options, Debug.all,
              Local_Prefix, Symbol'Access));
      end if;
      Emit (ELF_Spelling.No_Executable_Stack);
      Assembly := Output;
   end Emit;

end Landin.Backend.RiscV;
