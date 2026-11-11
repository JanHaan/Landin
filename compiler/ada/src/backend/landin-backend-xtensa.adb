with Ada.Containers.Vectors;
with Ada.Containers.Hashed_Sets;
with Ada.Finalization;
with Ada.Unchecked_Deallocation;
with Landin.Targets.Firmware;
with Landin.Provenance;
with Landin.Layouts;
with Landin.Machine;
with Landin.IR.Shape_Measurement;
with Landin.Packed;
with Landin.Memory;
with Landin.Targets.Packed;
with Landin.Backend.Firmware;
with Landin.Backend.Dwarf;
with Ada.Strings.Fixed;
with Landin.Targets.Capabilities;
with Landin.Backend.Xtensa_Machine;
with Landin.Backend.RiscV_Instructions;
with Landin.Backend.ELF;
with Landin.Backend.Site_Counts;
with Landin.Backend.Trap_Reports;
with Landin.Backend.Work_Arrays;
with Landin.Types;

package body Landin.Backend.Xtensa is

   package ELF_Spelling renames Landin.Backend.ELF;
   use type Landin.Targets.Capabilities.Backend_Kind;

   package Unbounded renames Ada.Strings.Unbounded;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Byte_Alignment;
   use type Landin.Targets.Scalar_Size;
   use type Landin.IR.Atom_Set_Id;
   use type Landin.IR.Declaration_Id;
   use type Landin.IR.Item_Kind;
   use type Landin.IR.Item_Id;
   use type Landin.IR.Value_Id;
   use type Landin.IR.Opcode;
   use type Landin.IR.Signature_Id;
   use type Landin.IR.Slot_Id;
   use type Landin.IR.Element_Total;
   use type Landin.Optimization.Objective;
   use type Landin.IR.Field_Image_Form;
   use type Landin.IR.Field_Shape_Kind;
   use type Landin.Types.Folded;
   use type Landin.Types.Type_Kind;

   use type Landin.Targets.Target_Facts;
   use type Landin.Machine.Convention;
   use type Landin.Layouts.Policy;

   LF : constant Character := Character'Val (10);

   --  Paired words implement every enabled 64-bit scalar on this target.
   function XLEN (Facts : Landin.Targets.Target_Facts)
     return RiscV_Instructions.Machine_Width;

   function XLEN (Facts : Landin.Targets.Target_Facts)
     return RiscV_Instructions.Machine_Width is
      pragma Unreferenced (Facts);
   begin
      return 32;
   end XLEN;

   --  `Image` leads with a blank for a non-negative number and assembly
   --  is bytes, so the blank is a byte.  Landin.IR.Dump's trim, for the
   --  same reason.
   function Trimmed (Value : String) return String
     is (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

   function Image (Value : Natural) return String
     is (Trimmed (Natural'Image (Value)));
   function Byte_Image (Value : Landin.Targets.Byte_Count) return String
     is (Trimmed (Landin.Targets.Byte_Count'Image (Value)));

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
   --  So are the float ones a block declares, f8, f9 and f18-f27 (D630),
   --  numbered as DWARF numbers them, 32 above their own: 40, 41, 50-59.
   type Saved_Set is array (9 .. 59) of Boolean;

   function Declared
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts) return Saved_Set;

   --  At XLEN 32 x27 is the high word's scratch (D671), saved as the other
   --  fixed scratch homes are.
   function Declared
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts) return Saved_Set
   is
      pragma Unreferenced (Of_Unit, Item, Facts);
      Result : constant Saved_Set := [others => False];
   begin
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
      Value_Count : constant Natural := Landin.IR.Value_Count (Of_Unit, Item);
      Result : Allocation_Plan;
   begin
      Result.Values := Location_Vectors.To_Vector
        (Value_Location'(others => <>),
         Ada.Containers.Count_Type (Value_Count));
      Result.Saves := Declared (Of_Unit, Item, Facts);
      --  D678: firmware's stack is small, so RV32 reuses a dead value's
      --  home at every objective, as Cortex-M0 does.
      if Options.Optimize = Landin.Optimization.None
        and then XLEN (Facts) = 64
      then
         for Index in 1 .. Value_Count loop
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
      end if;
      --  Size and speed reuse a scalar value's home once the value is
      --  dead, as arm64 does: a value lives within its block (the
      --  verifier refuses an operand from another), from the operation
      --  that defines it through its last reader, so a home freed after
      --  that reader may hold a later value of the same width.  A home
      --  is released only after the operation that reads it last, so an
      --  operation never writes its result over an operand it still
      --  reads.  Evidence_Self reads its projection's receiver, which is
      --  therefore live until it.
      declare
         type Counts is array (Positive range <>) of Natural;
         package Count_Buffers is new Landin.Backend.Work_Arrays
           (Natural, Counts, 0);
         Start_Data, Last_Data, Sequence_Data, Next_Release_Data,
           Next_Free_Data : Count_Buffers.Buffer (Value_Count);
         Release_Data : Count_Buffers.Buffer (Value_Count + 1);
         Starts : Counts renames Start_Data.Data.all;
         Lasts : Counts renames Last_Data.Data.all;
         Sequence : Counts renames Sequence_Data.Data.all;
         Releases : Counts renames Release_Data.Data.all;
         Next_Release : Counts renames Next_Release_Data.Data.all;
         Next_Free : Counts renames Next_Free_Data.Data.all;
         Free_Homes : array (Held_Size) of Natural := [others => 0];
         Tick : Natural := 0;
      begin
         for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            for Position in 1 .. Landin.IR.Length
              (Of_Unit, Item, Landin.IR.Block_Id (Block))
            loop
               declare
                  Index : constant Positive := Positive
                    (Landin.IR.Nth_Value
                       (Of_Unit, Item, Landin.IR.Block_Id (Block),
                        Position));
               begin
                  Tick := Tick + 1;
                  Sequence (Tick) := Index;
                  Starts (Index) := Tick;
                  Lasts (Index) := Tick;
               end;
            end loop;
         end loop;
         for Position in 1 .. Tick loop
            declare
               Index : constant Positive := Sequence (Position);
               Value : constant Landin.IR.Value_Id :=
                 Landin.IR.Value_Id (Index);
            begin
               for Which in 1 .. Landin.IR.Operand_Count
                 (Of_Unit, Item, Value)
               loop
                  declare
                     Operand : constant Positive := Positive
                       (Landin.IR.Nth_Operand (Of_Unit, Item, Value, Which));
                  begin
                     Lasts (Operand) :=
                       Natural'Max (Lasts (Operand), Position);
                  end;
               end loop;
               if Landin.IR.Op_Of (Of_Unit, Item, Value)
                 = Landin.IR.Evidence_Self
               then
                  declare
                     Receiver : constant Positive := Positive
                       (Landin.IR.Nth_Operand
                          (Of_Unit, Item,
                           Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1),
                           1));
                  begin
                     Lasts (Receiver) :=
                       Natural'Max (Lasts (Receiver), Position);
                  end;
               end if;
            end;
         end loop;
         for Position in 1 .. Tick loop
            declare
               Index : constant Positive := Sequence (Position);
               Kind : constant Landin.Types.Type_Kind := Landin.IR.Result_Of
                 (Of_Unit, Item, Landin.IR.Value_Id (Index));
               Released : Natural := Releases (Position);
            begin
               while Released /= 0 loop
                  declare
                     Old : Value_Location renames Result.Values (Released);
                  begin
                     Next_Free (Old.Home) := Free_Homes (Old.Size);
                     Free_Homes (Old.Size) := Old.Home;
                     Released := Next_Release (Released);
                  end;
               end loop;
               if Kind in Landin.Types.Scalar_Name then
                  declare
                     Place : Value_Location renames Result.Values (Index);
                  begin
                     Place.Size := Size_Of (Kind, Facts);
                     if Free_Homes (Place.Size) /= 0 then
                        Place.Home := Free_Homes (Place.Size);
                        Free_Homes (Place.Size) := Next_Free (Place.Home);
                     else
                        Result.Homes := Result.Homes + 1;
                        Place.Home := Result.Homes;
                     end if;
                     Next_Release (Index) := Releases (Lasts (Index) + 1);
                     Releases (Lasts (Index) + 1) := Index;
                  end;
               end if;
            end;
         end loop;
      end;
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
      if Options.Optimize = Landin.Optimization.None
        and then XLEN (Facts) = 64
      then
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
         Word : constant Landin.Targets.Byte_Count :=
           Landin.Targets.Byte_Count (XLEN (Facts) / 8);
         Save_Homes : constant Landin.Targets.Layouts.Field_Extent_Array
           (1 .. Saves) := [others => (Word, Landin.Targets.Byte_Alignment
                                                (Word))];
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
   begin
      if Landin.IR.Is_External (Of_Unit, Item) then
         return True;
      end if;
      --  Only emission plans the frame; preflight plans it only when the
      --  reference frame cannot show it addressable.
      if Landin.Backend.Frame_Bound
          (Of_Unit, Item, Facts, Limit, Saved_Set'Length) > Limit
        and then Extent (Routine_Frame (Of_Unit, Item, Facts, Options, Limit))
          > Limit
      then
         return False;
      end if;
      if Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
        and then Landin.IR.Signature_Uses_C_ABI
          (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
      then
         return False;
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
                     return False;
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

   function Frame_Fits_Firmware_Stack
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts) return Boolean
   is
      Stack : constant Landin.Targets.Byte_Count :=
        Landin.IR.Firmware_Profile (Of_Unit).Stack_Size;
   begin
      if Landin.IR.Is_External (Of_Unit, Item)
        or else Landin.IR.Signature_Machine
          (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
            = Landin.Machine.Naked_Routine
      then
         return True;
      end if;
      --  The frame the emitter lays out at the reference options, which
      --  give every value its own home and so bound every other's.
      return Stack >= 256
        and then Extent (Routine_Frame
          (Of_Unit, Item, Facts, Landin.Optimization.Reference_Options,
           16#7fff_ffff#)) <= Stack - 256;
   exception
      when Stack_Limit_Exceeded => return False;
   end Frame_Fits_Firmware_Stack;

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
        Landin.Targets.Levels.Default_Level (Landin.Targets.Xtensa);
      Firmware_Entry : Landin.IR.Item_Id := Landin.IR.No_Item)
   is
      Output : Unbounded.Unbounded_String;
      --  Dense nonzero u32 atom codes, in declaration-identity order; zero
      --  stays available for the successful half of the failing-call
      --  carrier.
      Atoms_Ranked : constant Atom_Codes := Ranked (Of_Unit);
      Serial : Natural := 0;

      --  Each routine's one frame, which emission and debug output both
      --  read; a build without debug output keeps none past its routine.
      --  The table is on the heap: in this frame it grows with the
      --  program until its stack is spent.
      type Frame_Array is array (Positive range <>) of Debug_Frame_Access;
      type Frame_Array_Access is access Frame_Array;
      procedure Free_Frame is new Ada.Unchecked_Deallocation
        (Frame, Debug_Frame_Access);
      procedure Free_Frames is new Ada.Unchecked_Deallocation
        (Frame_Array, Frame_Array_Access);
      type Retained_Frames (Last : Natural) is
        new Ada.Finalization.Limited_Controlled with record
         Frames : Frame_Array_Access;
      end record;
      overriding procedure Initialize (Owned : in out Retained_Frames);
      overriding procedure Finalize (Owned : in out Retained_Frames);
      overriding procedure Initialize (Owned : in out Retained_Frames) is
      begin
         Owned.Frames := new Frame_Array (1 .. Owned.Last);
         --  In a loop, so that no aggregate the table's size is built in
         --  this frame on its way to the heap.
         for Held of Owned.Frames.all loop
            Held := null;
         end loop;
      end Initialize;
      overriding procedure Finalize (Owned : in out Retained_Frames) is
      begin
         if Owned.Frames = null then
            return;
         end if;
         for Index in Owned.Frames'Range loop
            if Owned.Frames (Index) /= null then
               Free_Frame (Owned.Frames (Index));
            end if;
         end loop;
         Free_Frames (Owned.Frames);
      end Finalize;
      Saved : Retained_Frames (Landin.IR.Item_Count (Of_Unit));
      function Cached_Frame (Item : Landin.IR.Item_Id)
        return Debug_Frame_Access is (Saved.Frames (Positive (Item)));

      --  D671: the machine's width, whether an eight-byte value is a
      --  register pair, and the word a pointer, a saved register and a
      --  frame record's half are moved at.
      Width : constant RiscV_Instructions.Machine_Width := XLEN (Facts);
      Pairs : constant Boolean := Width = 32;
      Word : constant Positive := Natural (Width) / 8;
      Load_Word : constant String := (if Pairs then "lw" else "ld");
      Store_Word : constant String := (if Pairs then "sw" else "sd");
      Word_Directive : constant String :=
        (if Pairs then ".long" else ".quad");
      Atomics : constant Boolean :=
        False;
      Native_Frame_Bytes : Landin.Targets.Byte_Count := 0;
      Native_Scratch_Registers : Boolean := False;

      procedure Put (Line : String);
      procedure Emit (Instruction : String);
      function Fresh return String;
      procedure Immediate (Register : String; Value : Pattern);
      procedure Add_Offset
        (Register : String; Offset : Landin.Targets.Byte_Count);
      procedure Restore_Stack (Bytes : Landin.Targets.Byte_Count);
      procedure Address (Register, Name : String; Imported : Boolean := False);
      procedure Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String);
      procedure Byte_Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String);
      procedure Frame_Memory
        (Store : Boolean; Size : Held_Size; Register : String;
         Offset : Landin.Targets.Byte_Count);
      procedure Frame_Address
        (Offset : Landin.Targets.Byte_Count; Register : String := "x9");
      procedure Reserve (Bytes : Landin.Targets.Byte_Count);
      function High (Register : String) return String;
      procedure Copy_Bytes (Bytes : Landin.Targets.Byte_Count);
      procedure Zero_Bytes (Bytes : Landin.Targets.Byte_Count);
      procedure Move_Words
        (Bytes : Landin.Targets.Byte_Count;
         Width : Landin.Targets.Byte_Count;
         Copy  : Boolean);

      --  The line Put wrote last, for Frame_Memory's reload test.
      Last_Line : Unbounded.Unbounded_String;

      procedure Put (Line : String) is
      begin
         Unbounded.Append (Output, Line & LF);
         Last_Line := Unbounded.To_Unbounded_String (Line);
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
      begin
         Landin.Backend.Xtensa_Machine.Select_Word
           (Instruction, Output, Serial, Native_Frame_Bytes,
            Native_Scratch_Registers);
      end Emit;

      function Native_Word_Offset (Word : Natural) return String is
        (Byte_Image (Landin.Backend.Xtensa_Machine.Word_Offset
           (Word, Native_Scratch_Registers)));

      function Reg (Spelling : String) return
        RiscV_Instructions.Register_Number is
        (RiscV_Instructions.Register_Number'Value
          (Spelling (Spelling'First + 1 .. Spelling'Last)));

      procedure Immediate (Register : String; Value : Pattern) is
      begin
         Emit (RiscV_Instructions.Immediate
           (Reg (Register), RiscV_Instructions.Pattern (Value), Width));
      end Immediate;

      --  D671: an eight-byte value's high word at XLEN 32 is x27 beside
      --  the x5 every value passes through, and the next argument
      --  register beside an argument's or a helper's.
      function High (Register : String) return String is
        (if Register = "x5" then "x27"
         elsif Register = "x10" then "x11"
         elsif Register = "x12" then "x13"
         elsif Register = "x14" then "x15"
         elsif Register = "x16" then "x17"
         else raise Compiler_Defect with "no RV32 word pair at " & Register);

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

      --  D1110: the window handlers keep the caller's a0 to a3 in the
      --  sixteen bytes below this routine's SP, wherever SP is when the
      --  caller's window is taken and wherever it is at RETW.  A call's
      --  outgoing area moves SP between the two, so the three words the
      --  selected SP write does not form go with it: down after SP has
      --  moved and up before it moves back, which keeps both copies above
      --  the SP an interrupt's handler stack starts 32 bytes below.  a7
      --  is the frame's SP, the only one an area is reserved from.
      procedure Move_Base_Save (From, To : String);

      procedure Move_Base_Save (From, To : String) is
      begin
         for Offset in 1 .. 4 loop
            --  The a1 word, at -12, is the CFA every SP write stores.
            if Offset /= 2 then
               Put (Character'Val (9) & "l32e a8, " & From & ", -"
                    & Image (20 - Offset * 4));
               Put (Character'Val (9) & "s32e a8, " & To & ", -"
                    & Image (20 - Offset * 4));
            end if;
         end loop;
      end Move_Base_Save;

      procedure Restore_Stack (Bytes : Landin.Targets.Byte_Count) is
      begin
         if Bytes > 0 then
            Move_Base_Save (From => "a1", To => "a7");
         end if;
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
         if Pairs and then Size = Landin.Targets.Byte_8 then
            --  The high word first, so a pair loaded through its own low
            --  register still reads its base.
            Emit (RiscV_Instructions.Memory
              (Store, Landin.Targets.Byte_4, Reg (High (Register)),
               Reg (Base), Width, 4));
            Emit (RiscV_Instructions.Memory
              (Store, Landin.Targets.Byte_4, Reg (Register), Reg (Base),
               Width));
         else
            Emit (RiscV_Instructions.Memory
              (Store, Size, Reg (Register), Reg (Base), Width));
         end if;
      end Memory;

      --  D410: a scalar of a byte-packed C record may sit at any address,
      --  and a misaligned RISC-V access may trap or be emulated, so it is
      --  moved one byte at a time, least significant byte first, with x7
      --  as scratch.  A load zero-extends, as Memory's does.
      procedure Byte_Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String)
      is
         --  Count bytes of one register at At bytes past Base.
         procedure Bytes_Of (Value : String; Count, At_Byte : Natural);

         procedure Bytes_Of (Value : String; Count, At_Byte : Natural) is
         begin
            if Store then
               for Index in 0 .. Count - 1 loop
                  if Index = 0 then
                     Emit ("sb " & Value & ", "
                       & Trimmed (Natural'Image (At_Byte)) & "(" & Base
                       & ")");
                  else
                     Emit ("srli x7, " & Value & ", "
                       & Trimmed (Natural'Image (8 * Index)));
                     Emit ("sb x7, " & Trimmed (Natural'Image
                       (At_Byte + Index)) & "(" & Base & ")");
                  end if;
               end loop;
            else
               Emit ("lbu " & Value & ", "
                 & Trimmed (Natural'Image (At_Byte + Count - 1)) & "("
                 & Base & ")");
               for Index in reverse 0 .. Count - 2 loop
                  Emit ("slli " & Value & ", " & Value & ", 8");
                  Emit ("lbu x7, " & Trimmed (Natural'Image
                    (At_Byte + Index)) & "(" & Base & ")");
                  Emit ("or " & Value & ", " & Value & ", x7");
               end loop;
            end if;
         end Bytes_Of;

         Count : constant Positive := Landin.Targets.Bytes (Size);
      begin
         if Count = 1 then
            Memory (Store, Size, Register, Base);
         elsif Pairs and then Count = 8 then
            --  D671: a pair's words in turn, the high one at four.
            Bytes_Of (High (Register), 4, 4);
            Bytes_Of (Register, 4, 0);
         else
            Bytes_Of (Register, Count, 0);
         end if;
      end Byte_Memory;

      procedure Frame_Address
        (Offset : Landin.Targets.Byte_Count; Register : String := "x9") is
      begin
         if Offset <= 2000 then
            Emit ("addi " & Register & ", x8, -"
              & Trimmed (Landin.Targets.Byte_Count'Image (Offset + 48)));
         else
            Immediate (Register, Pattern (Offset + 48));
            Emit ("sub " & Register & ", x8, " & Register);
         end if;
      end Frame_Address;

      procedure Frame_Memory
        (Store : Boolean; Size : Held_Size; Register : String;
         Offset : Landin.Targets.Byte_Count) is
      begin
         if Offset <= 2000 and then Pairs
           and then Size = Landin.Targets.Byte_8
         then
            Emit (RiscV_Instructions.Memory
              (Store, Landin.Targets.Byte_4, Reg (High (Register)), 8,
               Width, -Integer (Offset + 48) + 4));
            Emit (RiscV_Instructions.Memory
              (Store, Landin.Targets.Byte_4, Reg (Register), 8, Width,
               -Integer (Offset + 48)));
         elsif Offset <= 2000 then
            --  D678: at XLEN 32 a word loaded from the home the line before
            --  stored it to is already in its register; a narrower one may
            --  not be, since a store keeps only its low bytes.
            if Pairs and then not Store and then Size = Landin.Targets.Byte_4
              and then Unbounded.To_String (Last_Line) = Character'Val (9)
                & RiscV_Instructions.Memory
                    (True, Size, Reg (Register), 8, Width,
                     -Integer (Offset + 48))
            then
               return;
            end if;
            Emit (RiscV_Instructions.Memory
              (Store, Size, Reg (Register), 8, Width,
               -Integer (Offset + 48)));
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
            Move_Base_Save (From => "a7", To => "a1");
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

      --  A by-value parameter's transfer from its carrier at x6, or its
      --  clear, into its fresh slot at x5: both aligned to Width, four or
      --  eight bytes, over a whole number of Width units.  Up to four
      --  units move unrolled; a longer extent moves one per iteration.
      procedure Move_Words
        (Bytes : Landin.Targets.Byte_Count;
         Width : Landin.Targets.Byte_Count;
         Copy  : Boolean)
      is
         Load : constant String := (if Width = 8 then "ld" else "lw");
         Store : constant String := (if Width = 8 then "sd" else "sw");
         Loop_Label : constant String := Fresh;
         Units : constant Landin.Targets.Byte_Count := Bytes / Width;
      begin
         if Units <= 4 then
            for Unit in 0 .. Units - 1 loop
               declare
                  Where : constant String := Trimmed
                    (Landin.Targets.Byte_Count'Image (Unit * Width));
               begin
                  if Copy then
                     Emit (Load & " x28, " & Where & "(x6)");
                     Emit (Store & " x28, " & Where & "(x5)");
                  else
                     Emit (Store & " zero, " & Where & "(x5)");
                  end if;
               end;
            end loop;
            return;
         end if;
         Immediate ("x7", Pattern (Units));
         Put (Loop_Label & ":");
         if Copy then
            Emit (Load & " x28, 0(x6)");
            Emit (Store & " x28, 0(x5)");
            Emit ("addi x6, x6, " & Trimmed
              (Landin.Targets.Byte_Count'Image (Width)));
         else
            Emit (Store & " zero, 0(x5)");
         end if;
         Emit ("addi x5, x5, " & Trimmed
           (Landin.Targets.Byte_Count'Image (Width)));
         Emit ("addi x7, x7, -1");
         Emit ("bnez x7, " & Loop_Label);
      end Move_Words;

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
         Emit ("srli x24, x24, " & Image (Natural (Width) - 1));
         Emit ("mv x20, " & Destination);
         Emit ("li x21, 0");
      end Add_Sub;

      procedure Extract
        (Destination, Source : String; First, Bits : Natural;
         Signed : Boolean := False)
      is
         XLEN_Bits : constant Natural := Natural (Width);
      begin
         if First + Bits < XLEN_Bits then
            Emit ("slli " & Destination & ", " & Source & ", "
              & Image (XLEN_Bits - First - Bits));
         else
            Emit ("mv " & Destination & ", " & Source);
         end if;
         if Bits < XLEN_Bits then
            Emit ((if Signed then "srai " else "srli ")
              & Destination & ", " & Destination & ", "
              & Image (XLEN_Bits - Bits));
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
      function Is_Exported_Item (Item : Landin.IR.Item_Id) return Boolean;

      --  On the heap, as every table with an entry for each item is: in
      --  this frame they grow with the program until its stack is spent,
      --  which ends the build as the host exhausted.
      type Symbol_Texts is array (Positive range <>) of
        Unbounded.Unbounded_String;
      package Symbol_Buffers is new Landin.Backend.Work_Arrays
        (Unbounded.Unbounded_String, Symbol_Texts,
         Unbounded.Null_Unbounded_String);
      Symbol_Data : Symbol_Buffers.Buffer
        (Positive'Max (1, Landin.IR.Item_Count (Of_Unit)));
      Allocated_Symbols : Symbol_Texts renames Symbol_Data.Data.all;

      --  D676: firmware's placements.  A later item may retain a section
      --  an earlier item selected.
      package Section_Sets is new Ada.Containers.Hashed_Sets
        (Element_Type        => Landin.Source.Names.Name_Id,
         Hash                => Landin.Source.Names.Hash,
         Equivalent_Elements => Landin.Source.Names."=");
      Retained_Sections : Section_Sets.Set;

      --  An item's input section: on RV64 always its own, and at XLEN 32
      --  the one its placement names, as Cortex-M0's: a region's, which
      --  says what the region does with it, an explicit section, retained
      --  when the item keeps it, or its own, with the placement's
      --  alignment after it.  Kind is RV64's: text, rodata, data or bss.
      function Item_Section
        (Item : Landin.IR.Item_Id; Kind, Name : String;
         Push : Boolean := False) return String;

      function Item_Section
        (Item : Landin.IR.Item_Id; Kind, Name : String;
         Push : Boolean := False) return String
      is
         Attr : constant Landin.Machine.Placement :=
           Landin.IR.Placement_Of (Of_Unit, Item);
      begin
         if not Pairs or else
           (Attr.Region = Landin.Source.Names.No_Name
            and then Attr.Section = Landin.Source.Names.No_Name
            and then not Attr.Keep and then Attr.Alignment = 0)
         then
            return (if Push
                    then ELF_Spelling.Push_Item_Section
                      (Kind, Name, Positive (Item))
                    else ELF_Spelling.Item_Section
                      (Kind, Name, Positive (Item)));
         end if;
         declare
            function Region_Section return String;
            function Region_Section return String is
               Region : constant String :=
                 Landin.Source.Names.Spelling (Names, Attr.Region);
               Profile : constant Landin.Targets.Firmware.Profile :=
                 Landin.IR.Firmware_Profile (Of_Unit);
               Writable : constant Boolean :=
                 Landin.Targets.Firmware.Writable
                   (Profile.Regions (Landin.Targets.Firmware.Region_Named
                      (Profile, Region)).Mode);
            begin
               return ".landin_region." & Region & "."
                 & (if Kind = "bss" then "bss"
                    elsif Writable then "data"
                    else Kind) & ".landin_" & Trimmed (Item'Image);
            end Region_Section;
            Section : constant String :=
              (if Attr.Region /= Landin.Source.Names.No_Name
               then Region_Section
               elsif Attr.Section = Landin.Source.Names.No_Name
               then "." & Kind & ".landin_" & Trimmed (Item'Image)
               else Landin.Source.Names.Spelling (Names, Attr.Section));
            Retained : constant Boolean := Attr.Keep or else
              (Attr.Section /= Landin.Source.Names.No_Name
               and then Retained_Sections.Contains (Attr.Section));
            BSS : constant Boolean :=
              Ada.Strings.Fixed.Index (Section, ".bss.") = Section'First
              or else (Attr.Region /= Landin.Source.Names.No_Name
                and then Ada.Strings.Fixed.Index (Section, ".bss.") /= 0);
            Flags : constant String :=
              (if Kind = "text" then "ax"
               elsif Kind = "rodata" then "a" else "aw");
         begin
            return (if Push then ".pushsection " else ".section ")
              & Section & ",""" & Flags & (if Retained then "R" else "")
              & """,@" & (if BSS then "nobits" else "progbits")
              & (if Attr.Alignment /= 0
                 then LF & Character'Val (9) & ".balign "
                   & Trimmed (Attr.Alignment'Image)
                 else "");
         end;
      end Item_Section;

      function Is_C_Item (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
            and then Landin.IR.Signature_Uses_C_ABI
              (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item)));

      function Is_Forced (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Link_Symbol (Of_Unit, Item)
              /= Landin.Source.Names.No_Name
            or else Item = Hosted_Entry
            or else Item = Firmware_Entry
            or else Landin.IR.Is_External (Of_Unit, Item));

      --  Pick a disjoint prefix for generated local labels. External source
      --  identities receive the object format's prefix at the rendering
      --  seam, where an explicit ELF spelling may begin with `.L`.
      function Unused_Local_Prefix
        (Seed : String := ELF_Spelling.Local_Prefix) return String;

      function Unused_Local_Prefix
        (Seed : String := ELF_Spelling.Local_Prefix) return String
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

      --  D361's report lines, each a read-only string, and the one routine
      --  that writes a line to standard error and ends the process.
      Reports : Landin.Backend.Trap_Reports.Table;
      Reporter : constant String := Local_Prefix & "landin_trap_report";
      function Report_Label (Index : Positive) return String
        is (Local_Prefix & "landin_trap_line_"
            & Trimmed (Positive'Image (Index)));

      --  D450: a program that prepares or switches a stack carries one
      --  switch routine and one start routine, emitted after its bodies;
      --  the comment there says what each does.  The switch routine's frame
      --  holds Stack_Saved registers, the return address first, then the
      --  frame pointer, the integer callee-saved set x9 and x18 to x27 and
      --  the LP64D float callee-saved set f8, f9 and f18 to f27, the Nth at
      --  Stack_Save_Offset (N) above the stack pointer and so at that many
      --  bytes less Stack_Frame_Bytes below the CFA.  A prepared stack's
      --  first frame is the same frame, and returns to Stack_Entered, past
      --  the start routine's opening nop.  Both routines are local
      --  function symbols, `landin.stack_switch` and `landin.stack_start`
      --  (D469), so that a debugger names them in a backtrace.  The word
      --  at the frame's stack pointer, below every saved register, holds
      --  the stack's limit (D472).  Stack_Limit is D471's cell: the
      --  current stack's limit, zero on the stack the process started on.
      --  A program that prepares a stack checks it in its routines'
      --  prologues; one that uses a builtin keeps it, and its switch saves
      --  and restores it.
      Stack_Used : Boolean := False;
      Prepares : constant Boolean := Landin.Backend.Prepares_Stacks (Of_Unit);
      Unchecked_Bytes : constant Landin.Targets.Byte_Count :=
        Landin.Backend.Unchecked_Stack_Bytes (Facts);
      Limit_Margin : constant Landin.Targets.Byte_Count :=
        Landin.Backend.Stack_Limit_Margin (Facts);
      Stack_Limit : constant String := Local_Prefix & "landin_stack_limit";

      --  D497: the cell is the running thread's, a word of ELF thread
      --  storage reached from `tp` in the local-exec model; a target with
      --  no threads keeps one cell in module storage.  Limit_Base forms
      --  the base the cell is at Limit_Offset from.
      Limit_Offset : constant String :=
        (if Landin.Backend.Has_Threads (Facts)
         then "%tprel_lo(" & Stack_Limit & ")" else "0");
      procedure Limit_Base (Register : String);
      procedure Limit_Base (Register : String) is
      begin
         if Landin.Backend.Has_Threads (Facts) then
            Emit ("lui " & Register & ", %tprel_hi(" & Stack_Limit & ")");
            Emit ("add " & Register & ", " & Register & ", tp, %tprel_add("
                  & Stack_Limit & ")");
         else
            Emit ("lla " & Register & ", " & Stack_Limit);
         end if;
      end Limit_Base;

      --  D496: a datum's address.  A thread's instance is at its offset
      --  from `tp`, in the local-exec model's three instructions.
      procedure Datum_Address (Register : String; Datum : Landin.IR.Item_Id);
      procedure Datum_Address (Register : String; Datum : Landin.IR.Item_Id)
      is
      begin
         if Landin.Backend.In_Thread_Storage (Of_Unit, Facts, Datum) then
            Emit ("lui " & Register & ", %tprel_hi(" & Symbol (Datum) & ")");
            Emit ("add " & Register & ", " & Register & ", tp, %tprel_add("
                  & Symbol (Datum) & ")");
            Emit ("addi " & Register & ", " & Register & ", %tprel_lo("
                  & Symbol (Datum) & ")");
         else
            Address (Register, Symbol (Datum));
         end if;
      end Datum_Address;
      Routine_Prefix : constant String := Unused_Local_Prefix ("landin.");
      Stack_Switcher : constant String := Routine_Prefix & "stack_switch";
      Stack_Start : constant String := Routine_Prefix & "stack_start";
      Stack_Entered : constant String :=
        Local_Prefix & "landin_stack_entered";
      --  All 64 physical AR words, architectural state, stack limit,
      --  padding and the window ABI's top 32 spill bytes.
      Stack_Frame_Bytes : constant Landin.Targets.Byte_Count := 336;

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
            --  D672: firmware's own and libgcc's helpers' names are taken.
            if Pairs and then
              (Landin.Targets.Firmware.Is_RV32_Helper (Candidate)
               or else Ada.Strings.Fixed.Index
                 (Candidate, "_landin_firmware_") = Candidate'First)
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

      function Is_Exported_Item (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.Backend.Is_Exported
              (Of_Unit, Meanings, Item, Hosted_Entry, Firmware_Entry));

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

      --  Plan and Layout are the routine's one plan and frame.
      procedure Emit_Routine
        (Item : Landin.IR.Item_Id; Plan : Allocation_Plan; Layout : Frame);

      procedure Emit_Routine
        (Item : Landin.IR.Item_Id; Plan : Allocation_Plan; Layout : Frame)
      is
         Assembly_First : constant Positive := Unbounded.Length (Output) + 1;
         --  D471's checks, unless the routine runs before its thread has
         --  a thread pointer (D504).
         --  An interrupt handler is unchecked: the compiler's trap entry
         --  that calls it keeps zero in the cell while it runs (D675).
         Checks : constant Boolean := Prepares
           and then (Panic = null
             or else Item /= Landin.Panics.Handler (Panic.all))
           and then not Landin.Backend.Runs_Before_Thread_Pointer
             (Facts, Symbol (Item))
           and then Landin.IR.Signature_Machine
             (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
               /= Landin.Machine.Interrupt_Handler;
         Path_Layouts : Landin.IR.Shape_Measurement.Layout_Cache;
         Result : constant Landin.Types.Type_Kind :=
           Landin.IR.Result_Of (Of_Unit, Item);
         Hard_Trap : constant String := Label (Item, 1) & "_trap";
         Shared_Exit : constant String := Label (Item, 1) & "_exit";
         Terminal_Count : Natural := 0;
         Has_Assembly : Boolean := False;
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
         --  D467: the largest area the body reserves below its frame.
         Deepest_Area : Landin.Targets.Byte_Count := 0;
         --  D672: the libgcc helpers the body calls at XLEN 32.
         Helpers_Called : Natural := 0;
         --  D471: whether a stack limit check branches to this routine's
         --  own stack_exhausted trap, laid out after the others.
         Limit_Trapped : Boolean := False;
         Limit_Trap : constant String := Label (Item, 1) & "_stack_limit";

         --  Where this routine's text begins in the output.
         Routine_Start : constant Natural := Unbounded.Length (Output);

         --  Counts, with the sites counted over the routine's final text.
         procedure Append_Statistics
           (Counts : Landin.Build_Reports.Routine_Statistics);
         procedure Append_Statistics
           (Counts : Landin.Build_Reports.Routine_Statistics)
         is
            Counted : Site_Counts.Counter (Site_Counts.Xtensa);
            Filled : Landin.Build_Reports.Routine_Statistics := Counts;
         begin
            Site_Counts.Add_Lines
              (Counted, Unbounded.Slice
                 (Output, Routine_Start + 1, Unbounded.Length (Output)));
            Site_Counts.Fill (Counted, Filled);
            Landin.Build_Reports.Append (Report, Filled);
         end Append_Statistics;

         --  D672: whether the body may call a libgcc helper at XLEN 32,
         --  which runs below the frame as any callee does, so the frame is
         --  checked as a calling one's is.
         function Calls_Helper return Boolean;
         pragma Unreferenced (Calls_Helper);

         function Calls_Helper return Boolean is
         begin
            if not Pairs then
               return False;
            end if;
            for Index in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
               declare
                  Value : constant Landin.IR.Value_Id :=
                    Landin.IR.Value_Id (Index);
                  Op : constant Landin.IR.Opcode :=
                    Landin.IR.Op_Of (Of_Unit, Item, Value);
                  Result_Kind : constant Landin.Types.Type_Kind :=
                    Landin.IR.Result_Of (Of_Unit, Item, Value);
               begin
                  if Op in Landin.IR.Add | Landin.IR.Subtract
                    | Landin.IR.Multiply | Landin.IR.Divide
                    | Landin.IR.Remainder | Landin.IR.Conversion
                    | Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                    | Landin.IR.Less_Than | Landin.IR.Less_Or_Equal
                    | Landin.IR.Greater_Than | Landin.IR.Greater_Or_Equal
                    and then (Result_Kind in Landin.Types.Float_Name
                      or else Landin.IR.Result_Of
                        (Of_Unit, Item,
                         Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1))
                          in Landin.Types.Float_Name
                      or else (Op in Landin.IR.Divide | Landin.IR.Remainder
                               and then Size_Of (Result_Kind, Facts)
                                 = Landin.Targets.Byte_8))
                  then
                     return True;
                  end if;
               end;
            end loop;
            return False;
         end Calls_Helper;

         --  D471: go to the limit trap when the stack pointer less Bytes is
         --  below the current stack's limit, before anything is written
         --  there.  x5 to x7 are free wherever a frame or an area is
         --  reserved.  The far jump goes through x7 rather than through the
         --  private x26 a long branch uses, because a prologue's check
         --  comes before x26 is saved.
         procedure Check_Limit (Bytes : Landin.Targets.Byte_Count);

         procedure Check_Limit (Bytes : Landin.Targets.Byte_Count) is
            Fits : constant String := Fresh;
            Wrapped : constant String := Fresh;
         begin
            if Bytes = 0 then
               Emit ("mv x5, sp");
            elsif Bytes <= 2048 then
               Emit ("addi x5, sp, -"
                     & Trimmed (Landin.Targets.Byte_Count'Image (Bytes)));
            else
               Immediate ("x5", Pattern (Bytes));
               Emit ("sub x5, sp, x5");
            end if;
            Limit_Base ("x6");
            Emit (Load_Word & " x6, " & Limit_Offset & "(x6)");
            --  A frame larger than the stack pointer's own value leaves a
            --  difference that wrapped past zero and is above every limit.
            if Bytes > 0 then
               Emit ("bltu sp, x5, " & Wrapped);
            end if;
            Emit ("bgeu x5, x6, " & Fits);
            if Bytes > 0 then
               Put (Wrapped & ":");
            end if;
            Emit ("lla x7, " & Limit_Trap);
            Emit ("jr x7");
            Put (Fits & ":");
            Limit_Trapped := True;
         end Check_Limit;

         function Trap (Reason : Landin.Panics.Kind) return String;
         function Trap return String;

         function Trap (Reason : Landin.Panics.Kind) return String is
         begin
            if Panic = null or else not Landin.Panics.Calls_Out (Panic.all)
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
              and then Landin.IR.Validates_Atoms (Of_Unit, Item, Value)
            then
               declare
                  Done : constant String := Fresh;
               begin
                  if Landin.IR.Admits_Reserved_Zero
                    (Of_Unit, Item, Value)
                  then
                     Emit ("beqz " & Register & ", " & Done);
                  end if;
                  for Run of Runs_Of (Of_Unit, Atoms_Ranked, Atoms) loop
                     if Run.Low = Run.High then
                        Immediate ("x30", Pattern (Run.Low));
                        Compare (Register, "x30");
                        Branch ("eq", Done);
                     else
                        declare
                           Next : constant String := Fresh;
                        begin
                           Immediate ("x30", Pattern (Run.Low));
                           Compare (Register, "x30");
                           Branch ("lo", Next);
                           Immediate ("x30", Pattern (Run.High));
                           Compare (Register, "x30");
                           Branch ("ls", Done);
                           Put (Next & ":");
                        end;
                     end if;
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
                  if Bits >= Natural (Width) then
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
              and then Landin.Types.Width (Scalar, Facts) < Width
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
            if Bits < Natural (Width) then
               Extract ("x30", Register, 0, Bits,
                 Signed => Landin.Types.Is_Signed (Scalar));
               Compare ("x30", Register);
               Branch ("ne", Trap);
            end if;
         end Check_Fit;

         --  D673: the language convention's carrier of each argument of a
         --  call or parameter of a routine.  In order, each takes the next
         --  of a0-a7, or at XLEN 32 an eight-byte value the next two, low
         --  word first; the first that does not fit, and every one after
         --  it, takes an eight-byte word of the area at the callee's CFA.
         --  At XLEN 64 that is the Nth in a(N-1) and the ninth on at sp.
         type Carrier is record
            --  a0's ordinal from one, or zero for a stack word.
            Register : Natural := 0;
            Stack_At : Landin.Targets.Byte_Count := 0;
            Pair : Boolean := False;
         end record;
         type Carrier_Array is array (Positive range <>) of Carrier;
         type Pair_Flags is array (Positive range <>) of Boolean;

         function Carriers (Wide : Pair_Flags) return Carrier_Array;

         function Carriers (Wide : Pair_Flags) return Carrier_Array is
            Result : Carrier_Array (Wide'Range);
            Next : Natural := 0;
            Spilled : Boolean := False;
            Words : Natural := 0;
         begin
            for Index in Wide'Range loop
               Result (Index).Pair := Wide (Index);
               if Wide (Index) then
                  Next := (Next + 1) / 2 * 2;
               end if;
               if not Spilled
                 and then Next + (if Wide (Index) then 2 else 1) <= 6
               then
                  Result (Index).Register := Next + 1;
                  Next := Next + (if Wide (Index) then 2 else 1);
               else
                  Spilled := True;
                  if Wide (Index) then
                     Words := (Words + 1) / 2 * 2;
                  end if;
                  Result (Index).Stack_At :=
                    Landin.Targets.Byte_Count (Words) * 4;
                  Words := Words + (if Wide (Index) then 2 else 1);
               end if;
            end loop;
            return Result;
         end Carriers;

         --  The area a call's stack carriers take, aligned to sixteen.
         function Carrier_Bytes (Places : Carrier_Array)
           return Landin.Targets.Byte_Count;

         function Carrier_Bytes (Places : Carrier_Array)
           return Landin.Targets.Byte_Count
         is
            Bytes : Landin.Targets.Byte_Count := 0;
         begin
            for Place of Places loop
               if Place.Register = 0 then
                  Bytes := Landin.Targets.Byte_Count'Max
                    (Bytes, Place.Stack_At + (if Place.Pair then 8 else 4));
               end if;
            end loop;
            --  The current window's base save area may already hold
            --  spilled ancestor registers. Keep outgoing arguments below
            --  that 32-byte area when moving SP.
            return (if Bytes = 0 then 0 else
              Stack_Align (Bytes, 16, 16#7fff_ffff#) + 32);
         end Carrier_Bytes;

         function Argument_Register (Ordinal : Positive) return String
           is ("x" & Image (Ordinal + 9));

         --  An eight-byte value's two words into two named registers.
         procedure Load_Pair
           (Value : Landin.IR.Value_Id; Low, High_Word : String);

         procedure Load_Pair
           (Value : Landin.IR.Value_Id; Low, High_Word : String)
         is
            Offset : constant Landin.Targets.Byte_Count :=
              Value_Offset (Layout, Value);
         begin
            Frame_Memory
              (False, Landin.Targets.Byte_4, High_Word, Offset - 4);
            Frame_Memory (False, Landin.Targets.Byte_4, Low, Offset);
         end Load_Pair;

         procedure Epilogue is
         begin
            for Index in 0 .. 3 loop
               Put (Character'Val (9) & "l32i a" & Image (Index + 2)
                    & ", a7, " & Native_Word_Offset (Index + 10));
            end loop;
            Put (Character'Val (9) & "l32i a6, a7, "
                 & Native_Word_Offset (31));
            Put (Character'Val (9) & "mov a1, a7");
            Put (Character'Val (9) & "retw");
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

         --  D410: whether the scalar a field or element operation reaches
         --  lies inside a byte-packed C record, and so may be unaligned.
         function Unaligned_Part
           (Place  : Landin.IR.Storage;
            Field  : Landin.IR.Element_Total;
            Nested : Landin.IR.Path_Step_Array) return Boolean
         is (Landin.IR.Reaches_Byte_Packed
               (Of_Unit, Item, Place, Field, Nested));

         function Unaligned_Element
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural;
            Payload_Field : Natural;
            Nested        : Landin.IR.Path_Step_Array;
            Below         : Landin.IR.Path_Step_Array) return Boolean;

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

         function Unaligned_Element
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural;
            Payload_Field : Natural;
            Nested        : Landin.IR.Path_Step_Array;
            Below         : Landin.IR.Path_Step_Array) return Boolean
         is (Payload_Field = 0
             and then (Unaligned_Part
                         (Place, Landin.IR.Element_Total (Field), Nested)
                       or else Landin.IR.Enters_Byte_Packed
                         (Of_Unit,
                          Element_Shape_Of
                            (Place, Field, Which, Payload_Field, Nested),
                          Below)));

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
                  Datum_Address (Register, Place.Datum);
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
         procedure C_Entry;
         procedure C_Call (Value : Landin.IR.Value_Id);
         procedure C_Result (Value : Landin.IR.Value_Id);
         procedure C_Entry is
         begin
            raise Compiler_Defect with "Xtensa public C transport is disabled";
         end C_Entry;
         procedure C_Call (Value : Landin.IR.Value_Id) is
            pragma Unreferenced (Value);
         begin
            raise Compiler_Defect with "Xtensa public C transport is disabled";
         end C_Call;
         procedure C_Result (Value : Landin.IR.Value_Id) is
            pragma Unreferenced (Value);
         begin
            raise Compiler_Defect with "Xtensa public C transport is disabled";
         end C_Result;

         --  Numeric integer operands use their own address register;
         --  outputs remain live until copied, with a float register no
         --  float output holds, f0 first, as the full-register escape
         --  carrier when every caller scratch register is occupied, and
         --  the stack when every such float register is an output too.
         --  Float inputs are loaded first, through x5 while it is still
         --  free, and float outputs stored through a free scratch register
         --  as integer ones are (D630).
         procedure Assembly_Block (Value : Landin.IR.Value_Id);

         procedure Assembly_Block (Value : Landin.IR.Value_Id) is
            Chosen : constant Landin.Targets.Assembly.Operand_Register_Array
              := Landin.Backend.Assembly_Registers
                   (Of_Unit, Item, Value, Names, Facts);
            Text : constant String := Landin.Backend.Assembly_Text
              (Of_Unit, Item, Value, Names, Facts);
            Input : Natural := 0;
            function Operand (Index : Positive)
              return Landin.IR.Assembly_Operand
              is (Landin.IR.Nth_Assembly_Operand
                    (Of_Unit, Item, Value, Index));
            function Register (Index : Positive) return String
              is (Unbounded.To_String (Chosen (Index).Register));
            function Number (Index : Positive) return Natural
              is (Natural'Value (Register (Index)
                    (Register (Index)'First + 1 .. Register (Index)'Last)));
            procedure Check (Index : Positive);
            procedure Check (Index : Positive) is
            begin
               if Register (Index)'Length < 2
                 or else Register (Index) (Register (Index)'First) /= 'a'
                 or else Number (Index) not in 2 .. 6 | 8 .. 15
                 or else (Operand (Index).Kind in Landin.Types.Scalar_Name
                   and then Size_Of (Operand (Index).Kind, Facts)
                     > Landin.Targets.Byte_4)
               then
                  raise Compiler_Defect with
                    "invalid Xtensa assembly register";
               end if;
            end Check;
         begin
            --  Stage all inputs before assigning physical operands: native
            --  address calculation may use any of a8-a11. Snapshot every
            --  output before computing a destination address for the same
            --  reason. The dedicated bank cannot overlap source homes.
            for Index in Chosen'Range loop
               Check (Index);
               if Operand (Index).Direction
                 in Landin.IR.Input | Landin.IR.Both
               then
                  Input := Input + 1;
                  Load_Value (Landin.IR.Nth_Operand
                    (Of_Unit, Item, Value, Input), "x5");
                  Extend ("x5", Operand (Index).Kind);
                  Put (Character'Val (9) & "l32i a8, a7, 20");
                  Put (Character'Val (9) & "s32i a8, a7, "
                       & Image (128 + Number (Index) * 4));
               end if;
            end loop;
            for Index in Chosen'Range loop
               if Operand (Index).Direction in Landin.IR.Input | Landin.IR.Both
               then
                  Put (Character'Val (9) & "l32i " & Register (Index)
                       & ", a7, " & Image (128 + Number (Index) * 4));
               end if;
            end loop;
            Put (Text);
            for Index in Chosen'Range loop
               if Operand (Index).Output /= Landin.IR.No_Slot then
                  Put (Character'Val (9) & "s32i " & Register (Index)
                       & ", a7, " & Image (128 + Number (Index) * 4));
               end if;
            end loop;
            for Index in Chosen'Range loop
               if Operand (Index).Output /= Landin.IR.No_Slot then
                  Put (Character'Val (9) & "l32i a8, a7, "
                       & Image (128 + Number (Index) * 4));
                  Put (Character'Val (9) & "s32i a8, a7, 20");
                  Store_Slot (Operand (Index).Output, "x5");
               end if;
            end loop;
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

            --  D410: an indirect access whose address slot reaches a
            --  scalar inside a byte-packed C record.
            function Unaligned_Indirect return Boolean
              is (Landin.IR."/="
                    (Landin.IR.Indirect_Address_Slot (Of_Unit, Item, Value),
                     Landin.IR.No_Slot)
                  and then Landin.IR.Is_Unaligned_Address
                    (Of_Unit, Item,
                     Landin.IR.Indirect_Address_Slot (Of_Unit, Item, Value)));
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
                    (6, 6, 29, 30, Shift, Width,
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

            --  D671 and D672: at XLEN 32, every operation on an eight-byte
            --  integer and every float operation; the rest is the shared
            --  selection's.  An eight-byte operand is the pair x10:x11 or
            --  x12:x13, where libgcc's helpers take and return them, and a
            --  float is libgcc's soft float, as the psABI's ilp32 passes it.
            procedure Pair_Instruction (Handled : out Boolean);

            --  x10:x11 shifted by x12, already in 0 .. 63, with x28 and x29
            --  as scratch.  Below 32 the crossing bits move through a shift
            --  by one and then by 31 - n, so a shift by zero moves none.
            procedure Shift_Pair (Left : Boolean; Signed : Boolean := False);

            procedure Shift_Pair (Left : Boolean; Signed : Boolean := False)
            is
               Small : constant String := Fresh;
               Done : constant String := Fresh;
            begin
               Emit ("li x28, 32");
               Emit ("bltu x12, x28, " & Small);
               Emit ("addi x29, x12, -32");
               if Left then
                  Emit ("sll x11, x10, x29");
                  Emit ("li x10, 0");
               else
                  Emit ((if Signed then "sra" else "srl")
                        & " x10, x11, x29");
                  Emit ((if Signed then "srai x11, x11, 31" else "li x11, 0"));
               end if;
               Emit ("j " & Done);
               Put (Small & ":");
               Emit ("li x29, 31");
               Emit ("sub x29, x29, x12");
               if Left then
                  Emit ("srli x28, x10, 1");
                  Emit ("srl x28, x28, x29");
                  Emit ("sll x11, x11, x12");
                  Emit ("or x11, x11, x28");
                  Emit ("sll x10, x10, x12");
               else
                  Emit ("slli x28, x11, 1");
                  Emit ("sll x28, x28, x29");
                  Emit ("srl x10, x10, x12");
                  Emit ("or x10, x10, x28");
                  Emit ((if Signed then "sra" else "srl") & " x11, x11, x12");
               end if;
               Put (Done & ":");
            end Shift_Pair;

            --  At XLEN 32 a narrower packed member of an eight-byte value
            --  type has a zero high word, and one stored has none.
            procedure Clear_High (Which : Landin.IR.Value_Id);
            procedure Clear_High (Which : Landin.IR.Value_Id) is
            begin
               if Pairs and then Size_Of_Value (Which) = Landin.Targets.Byte_8
               then
                  Emit ("li x27, 0");
               end if;
            end Clear_High;

            procedure Narrow_High (Which : Landin.IR.Value_Id);
            procedure Narrow_High (Which : Landin.IR.Value_Id) is
            begin
               if Pairs and then Size_Of_Value (Which) = Landin.Targets.Byte_8
               then
                  Emit ("bnez x27, " & Trap (Landin.Panics.Bad_Conversion));
               end if;
            end Narrow_High;

            --  Packed_Atom for the pair x5:x27, whose encodings may be all
            --  64 bits, comparing through x7 so the member's bit offset in
            --  x30 survives.
            procedure Pair_Atom
              (Set_Id : Landin.IR.Atom_Set_Id; Encode : Boolean);
            procedure Pair_Atom
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
                     Compared : constant Pattern :=
                       (if Encode then Code else Raw);
                     Answer : constant Pattern :=
                       (if Encode then Raw else Code);
                  begin
                     Immediate ("x7", Compared and 16#FFFF_FFFF#);
                     Emit ("bne x5, x7, " & Next);
                     Immediate ("x7", Compared / 2 ** 32);
                     Emit ("bne x27, x7, " & Next);
                     Immediate ("x5", Answer and 16#FFFF_FFFF#);
                     Immediate ("x27", Answer / 2 ** 32);
                     Emit ("j " & Done);
                     Put (Next & ":");
                  end;
               end loop;
               Emit ("j " & Trap (Landin.Panics.Bad_Conversion));
               Put (Done & ":");
            end Pair_Atom;

            --  D671: a packed member of an eight-byte carrier at XLEN 32,
            --  the carrier's address in x6 and the member's first bit in
            --  x30, as the shared selection's single register does it.
            procedure Packed_Pair
              (Bits : Natural; Atoms : Landin.IR.Atom_Set_Id;
               Writing : Boolean);
            procedure Packed_Pair
              (Bits : Natural; Atoms : Landin.IR.Atom_Set_Id;
               Writing : Boolean)
            is
               Ones : constant Pattern :=
                 (if Bits = 64 then Pattern'Last else 2 ** Bits - 1);
               function Input return Landin.IR.Value_Id
                 is (if Op = Landin.IR.Store_Element then Operand (2)
                     else Operand (1));
            begin
               if not Writing then
                  Memory (False, Landin.Targets.Byte_8, "x10", "x6");
                  Emit ("mv x12, x30");
                  Shift_Pair (False);
                  Immediate ("x7", Ones and 16#FFFF_FFFF#);
                  Emit ("and x10, x10, x7");
                  Immediate ("x7", Ones / 2 ** 32);
                  Emit ("and x11, x11, x7");
                  Emit ("mv x5, x10");
                  Emit ("mv x27, x11");
                  Pair_Atom (Atoms, Encode => False);
                  Store_Value (Value, Atom_Validated => True);
                  return;
               end if;
               Load_Value (Input);
               if Size_Of_Value (Input) /= Landin.Targets.Byte_8 then
                  Emit ("li x27, 0");
               end if;
               Pair_Atom (Atoms, Encode => True);
               Emit ("mv x10, x5");
               Emit ("mv x11, x27");
               if Bits < 64 then
                  Immediate ("x7", (not Ones) and 16#FFFF_FFFF#);
                  Emit ("and x7, x10, x7");
                  Immediate ("x14", (not Ones) / 2 ** 32);
                  Emit ("and x14, x11, x14");
                  Emit ("or x7, x7, x14");
                  Emit ("bnez x7, " & Trap (Landin.Panics.Bad_Conversion));
               end if;
               Emit ("mv x16, x10");
               Emit ("mv x17, x11");
               Immediate ("x10", Ones and 16#FFFF_FFFF#);
               Immediate ("x11", Ones / 2 ** 32);
               Emit ("mv x12, x30");
               Shift_Pair (True);
               Emit ("not x14, x10");
               Emit ("not x15, x11");
               Emit ("mv x10, x16");
               Emit ("mv x11, x17");
               Emit ("mv x12, x30");
               Shift_Pair (True);
               Memory (False, Landin.Targets.Byte_8, "x16", "x6");
               Emit ("and x16, x16, x14");
               Emit ("and x17, x17, x15");
               Emit ("or x16, x16, x10");
               Emit ("or x17, x17, x11");
               Memory (True, Landin.Targets.Byte_8, "x16", "x6");
            end Packed_Pair;

            procedure Pair_Instruction (Handled : out Boolean) is
               function Wide (Which : Landin.IR.Value_Id) return Boolean
                 is (Size_Of_Value (Which) = Landin.Targets.Byte_8);
               function Is_Float (Scalar : Landin.Types.Scalar_Name)
                 return Boolean is (Scalar in Landin.Types.Float_Name);
               function Mode (Scalar : Landin.Types.Scalar_Name)
                 return String
                 is (if Scalar = Landin.Types.F32 then "sf" else "df");
               function Signed_Integer (Scalar : Landin.Types.Scalar_Name)
                 return Boolean
                 is (Scalar in Landin.Types.Integer_Name
                     and then Landin.Types.Is_Signed (Scalar));

               procedure Helper (Name : String);
               procedure Helper (Name : String) is
               begin
                  Emit ("call " & Name);
                  Helpers_Called := Helpers_Called + 1;
               end Helper;

               --  Operand Which as the pair Low:High or, narrower, in Low
               --  with its high word its extension.
               procedure Load_Wide (Which : Positive; Low : String);
               procedure Load_Wide (Which : Positive; Low : String) is
                  Scalar : constant Landin.Types.Scalar_Name :=
                    Kind (Operand (Which));
               begin
                  Load_Value (Operand (Which), Low);
                  if not Wide (Operand (Which)) then
                     Extend (Low, Scalar);
                     Emit ((if Signed_Integer (Scalar)
                            then "srai " & High (Low) & ", " & Low & ", 31"
                            else "li " & High (Low) & ", 0"));
                  end if;
               end Load_Wide;

               --  A float's two operands where its helper takes them.
               procedure Load_Floats (Scalar : Landin.Types.Scalar_Name);
               procedure Load_Floats (Scalar : Landin.Types.Scalar_Name) is
               begin
                  Load_Value (Operand (1), "x10");
                  Load_Value
                    (Operand (2), (if Scalar = Landin.Types.F32 then "x11"
                                   else "x12"));
               end Load_Floats;

               --  Whether X < Y for the pairs named, into x5.
               procedure Less
                 (X_Low, X_High, Y_Low, Y_High : String; Signed : Boolean);
               procedure Less
                 (X_Low, X_High, Y_Low, Y_High : String; Signed : Boolean) is
               begin
                  Emit ((if Signed then "slt" else "sltu") & " x6, " & X_High
                        & ", " & Y_High);
                  Emit ("xor x7, " & X_High & ", " & Y_High);
                  Emit ("seqz x7, x7");
                  Emit ("sltu x28, " & X_Low & ", " & Y_Low);
                  Emit ("and x7, x7, x28");
                  Emit ("or x5, x6, x7");
               end Less;

               --  x10:x11 negated, with x6 as scratch.
               procedure Negate;
               procedure Negate is
               begin
                  Emit ("snez x6, x10");
                  Emit ("neg x10, x10");
                  Emit ("neg x11, x11");
                  Emit ("sub x11, x11, x6");
               end Negate;

               --  The pair x14:x15 or x16:x17 made its magnitude.
               procedure Magnitude (Low, High_Word : String);
               procedure Magnitude (Low, High_Word : String) is
                  Done : constant String := Fresh;
               begin
                  Emit ("bgez " & High_Word & ", " & Done);
                  Emit ("snez x6, " & Low);
                  Emit ("neg " & Low & ", " & Low);
                  Emit ("neg " & High_Word & ", " & High_Word);
                  Emit ("sub " & High_Word & ", " & High_Word & ", x6");
                  Put (Done & ":");
               end Magnitude;

               --  The high word of x10's value extended to Into, against
               --  x11; then the low word's own fit.
               procedure Fit_Narrow (Into : Landin.Types.Scalar_Name);
               procedure Fit_Narrow (Into : Landin.Types.Scalar_Name) is
               begin
                  Emit ((if Signed_Integer (Into) then "srai x6, x10, 31"
                         else "li x6, 0"));
                  Emit ("bne x11, x6, " & Trap);
                  Check_Fit ("x10", Into);
               end Fit_Narrow;
            begin
               Handled := True;
               case Op is
                  when Landin.IR.Number =>
                     if not Wide (Value) then
                        Handled := False;
                        return;
                     end if;
                     declare
                        Number : Pattern := Pattern
                          (Landin.IR.Number_Of (Of_Unit, Item, Value));
                     begin
                        if Kind (Value) not in Landin.Types.Float_Name
                          and then Landin.IR.Is_Negated (Of_Unit, Item, Value)
                        then
                           Number := 0 - Number;
                        end if;
                        Immediate ("x5", Number and 16#FFFF_FFFF#);
                        Immediate ("x27", Number / 2 ** 32);
                        Store_Value (Value);
                     end;

                  when Landin.IR.Negation | Landin.IR.Complement =>
                     if not Wide (Value) then
                        Handled := False;
                        return;
                     end if;
                     Load_Value (Operand (1), "x10");
                     if Op = Landin.IR.Complement then
                        Emit ("not x10, x10");
                        Emit ("not x11, x11");
                     elsif Is_Float (Kind (Value)) then
                        Immediate ("x6", 2 ** 31);
                        Emit ("xor x11, x11, x6");
                     else
                        Emit ("mv x14, x11");
                        Emit ("or x7, x10, x11");
                        Negate;
                        if not Unchecked then
                           if Signed_Integer (Kind (Value)) then
                              --  Only the minimum is its own negation.
                              Emit ("and x6, x14, x11");
                              Emit ("bltz x6, " & Trap);
                           else
                              Emit ("bnez x7, " & Trap);
                           end if;
                        end if;
                     end if;
                     Store_Value (Value, "x10");

                  when Landin.IR.Add | Landin.IR.Subtract
                     | Landin.IR.Multiply | Landin.IR.Divide
                     | Landin.IR.Remainder | Landin.IR.Wrapping_Add
                     | Landin.IR.Wrapping_Subtract
                     | Landin.IR.Wrapping_Multiply
                     | Landin.IR.Bitwise_And | Landin.IR.Bitwise_Or
                     | Landin.IR.Bitwise_Xor | Landin.IR.Shift_Left
                     | Landin.IR.Shift_Right =>
                     if Is_Float (Kind (Value)) then
                        Load_Floats (Kind (Value));
                        Helper ("__" & (case Op is
                           when Landin.IR.Add => "add",
                           when Landin.IR.Subtract => "sub",
                           when Landin.IR.Multiply => "mul",
                           when Landin.IR.Divide => "div",
                           when others => raise Compiler_Defect with
                             "invalid float operation")
                           & Mode (Kind (Value)) & "3");
                        Store_Value (Value, "x10");
                        return;
                     elsif not Wide (Value) then
                        Handled := False;
                        return;
                     end if;
                     declare
                        Signed : constant Boolean :=
                          Landin.Types.Is_Signed (Kind (Value));
                        Checked : constant Boolean := not Unchecked
                          and then Op in Landin.IR.Add | Landin.IR.Subtract
                            | Landin.IR.Multiply;
                        Done : constant String := Fresh;
                     begin
                        Load_Value (Operand (1), "x10");
                        Load_Value (Operand (2), "x12");
                        case Op is
                           when Landin.IR.Add | Landin.IR.Wrapping_Add =>
                              Emit ("add x14, x10, x12");
                              Emit ("sltu x6, x14, x10");
                              Emit ("add x15, x11, x13");
                              if Checked and then not Signed then
                                 Emit ("sltu x7, x15, x11");
                              end if;
                              Emit ("add x15, x15, x6");
                              if Checked and then not Signed then
                                 Emit ("sltu x6, x15, x6");
                                 Emit ("or x7, x7, x6");
                                 Emit ("bnez x7, " & Trap);
                              elsif Checked then
                                 Emit ("xor x6, x11, x15");
                                 Emit ("xor x7, x13, x15");
                                 Emit ("and x6, x6, x7");
                                 Emit ("bltz x6, " & Trap);
                              end if;
                           when Landin.IR.Subtract
                              | Landin.IR.Wrapping_Subtract =>
                              Emit ("sub x14, x10, x12");
                              Emit ("sltu x6, x10, x12");
                              if Checked and then not Signed then
                                 Emit ("sltu x7, x11, x13");
                              end if;
                              Emit ("sub x15, x11, x13");
                              if Checked and then not Signed then
                                 Emit ("sltu x16, x15, x6");
                              end if;
                              Emit ("sub x15, x15, x6");
                              if Checked and then not Signed then
                                 Emit ("or x7, x7, x16");
                                 Emit ("bnez x7, " & Trap);
                              elsif Checked then
                                 Emit ("xor x6, x11, x13");
                                 Emit ("xor x7, x11, x15");
                                 Emit ("and x6, x6, x7");
                                 Emit ("bltz x6, " & Trap);
                              end if;
                           when Landin.IR.Bitwise_And | Landin.IR.Bitwise_Or
                              | Landin.IR.Bitwise_Xor =>
                              declare
                                 Name : constant String :=
                                   (if Op = Landin.IR.Bitwise_And then "and"
                                    elsif Op = Landin.IR.Bitwise_Or then "or"
                                    else "xor");
                              begin
                                 Emit (Name & " x14, x10, x12");
                                 Emit (Name & " x15, x11, x13");
                              end;
                           when Landin.IR.Multiply
                              | Landin.IR.Wrapping_Multiply =>
                              if Checked then
                                 --  D672: the magnitudes' whole product has
                                 --  no word above the low 64 bits, then
                                 --  fits the result's sign.
                                 Emit ("mv x14, x10");
                                 Emit ("mv x15, x11");
                                 Emit ("mv x16, x12");
                                 Emit ("mv x17, x13");
                                 if Signed then
                                    Magnitude ("x14", "x15");
                                    Magnitude ("x16", "x17");
                                 end if;
                                 Emit ("snez x6, x15");
                                 Emit ("snez x7, x17");
                                 Emit ("and x6, x6, x7");
                                 Emit ("bnez x6, " & Trap);
                                 Emit ("mulhu x6, x14, x17");
                                 Emit ("bnez x6, " & Trap);
                                 Emit ("mulhu x6, x15, x16");
                                 Emit ("bnez x6, " & Trap);
                                 Emit ("mul x6, x14, x17");
                                 Emit ("mul x7, x15, x16");
                                 Emit ("add x6, x6, x7");
                                 Emit ("mulhu x7, x14, x16");
                                 Emit ("add x28, x7, x6");
                                 Emit ("sltu x6, x28, x6");
                                 Emit ("bnez x6, " & Trap);
                                 if Signed then
                                    Emit ("xor x29, x11, x13");
                                    Emit ("bltz x29, "
                                         & Done & "_negative");
                                    Emit ("bltz x28, " & Trap);
                                    Emit ("j " & Done
                                         & "_fits");
                                    Put (Done & "_negative:");
                                    Immediate ("x30", 2 ** 31);
                                    Emit ("bltu x28, x30, "
                                         & Done & "_fits");
                                    Emit ("bne x28, x30, " & Trap);
                                    Emit ("mul x6, x14, x16");
                                    Emit ("bnez x6, " & Trap);
                                    Put (Done & "_fits:");
                                 end if;
                              end if;
                              --  The low 64 bits of the product, which
                              --  are both signednesses' wrapping result.
                              Emit ("mul x14, x10, x12");
                              Emit ("mulhu x15, x10, x12");
                              Emit ("mul x6, x10, x13");
                              Emit ("add x15, x15, x6");
                              Emit ("mul x6, x11, x12");
                              Emit ("add x15, x15, x6");
                           when Landin.IR.Divide | Landin.IR.Remainder =>
                              Emit ("or x6, x12, x13");
                              Emit ("beqz x6, " & Trap);
                              if Signed and then Op = Landin.IR.Divide then
                                 Emit ("and x6, x12, x13");
                                 Emit ("li x7, -1");
                                 Emit ("bne x6, x7, "
                                      & Done & "_divide");
                                 Immediate ("x7", 2 ** 31);
                                 Emit ("bne x11, x7, "
                                      & Done & "_divide");
                                 Emit ("beqz x10, " & Trap);
                                 Put (Done & "_divide:");
                              end if;
                              Helper ("__" & (if Signed then "" else "u")
                                & (if Op = Landin.IR.Divide then "div"
                                   else "mod") & "di3");
                              Emit ("mv x14, x10");
                              Emit ("mv x15, x11");
                           when Landin.IR.Shift_Left
                              | Landin.IR.Shift_Right =>
                              if Signed then
                                 Emit ("bltz x13, " & Trap);
                              end if;
                              Emit ("bnez x13, " & Done
                                   & "_zero");
                              Emit ("li x6, 64");
                              Emit ("bgeu x12, x6, " & Done
                                   & "_zero");
                              Shift_Pair (Op = Landin.IR.Shift_Left, Signed);
                              Emit ("mv x14, x10");
                              Emit ("mv x15, x11");
                              Emit ("j " & Done);
                              Put (Done & "_zero:");
                              Emit ("li x14, 0");
                              Emit ("li x15, 0");
                           when others =>
                              raise Compiler_Defect with
                                "invalid integer operation";
                        end case;
                        Put (Done & ":");
                        Emit ("mv x10, x14");
                        Emit ("mv x11, x15");
                        Store_Value (Value, "x10");
                     end;

                  when Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                     | Landin.IR.Less_Than | Landin.IR.Less_Or_Equal
                     | Landin.IR.Greater_Than | Landin.IR.Greater_Or_Equal =>
                     declare
                        Scalar : constant Landin.Types.Scalar_Name :=
                          Kind (Operand (1));
                     begin
                        if Is_Float (Scalar) then
                           --  libgcc's comparisons answer an int whose sign
                           --  holds the relation and which every unordered
                           --  pair fails.
                           Load_Floats (Scalar);
                           Helper ("__" & (case Op is
                              when Landin.IR.Equal_To => "eq",
                              when Landin.IR.Not_Equal_To => "ne",
                              when Landin.IR.Less_Than => "lt",
                              when Landin.IR.Less_Or_Equal => "le",
                              when Landin.IR.Greater_Than => "gt",
                              when others => "ge")
                              & Mode (Scalar) & "2");
                           case Op is
                              when Landin.IR.Equal_To =>
                                 Emit ("seqz x5, x10");
                              when Landin.IR.Not_Equal_To =>
                                 Emit ("snez x5, x10");
                              when Landin.IR.Less_Than =>
                                 Emit ("slti x5, x10, 0");
                              when Landin.IR.Less_Or_Equal =>
                                 Emit ("slti x5, x10, 1");
                              when Landin.IR.Greater_Than =>
                                 Emit ("sgtz x5, x10");
                              when others =>
                                 Emit ("slti x5, x10, 0");
                                 Emit ("xori x5, x5, 1");
                           end case;
                        elsif Wide (Operand (1)) then
                           Load_Value (Operand (1), "x10");
                           Load_Value (Operand (2), "x12");
                           case Op is
                              when Landin.IR.Equal_To
                                 | Landin.IR.Not_Equal_To =>
                                 Emit ("xor x6, x10, x12");
                                 Emit ("xor x7, x11, x13");
                                 Emit ("or x6, x6, x7");
                                 Emit ((if Op = Landin.IR.Equal_To
                                        then "seqz" else "snez")
                                       & " x5, x6");
                              when Landin.IR.Less_Than
                                 | Landin.IR.Greater_Or_Equal =>
                                 Less ("x10", "x11", "x12", "x13",
                                       Signed_Integer (Scalar));
                              when others =>
                                 Less ("x12", "x13", "x10", "x11",
                                       Signed_Integer (Scalar));
                           end case;
                           if Op in Landin.IR.Greater_Or_Equal
                             | Landin.IR.Less_Or_Equal
                           then
                              Emit ("xori x5, x5, 1");
                           end if;
                        else
                           Handled := False;
                           return;
                        end if;
                        Store_Value (Value);
                     end;

                  when Landin.IR.Range_Check =>
                     if not Wide (Value) then
                        Handled := False;
                        return;
                     end if;
                     Load_Value (Operand (1), "x10");
                     for Upper in Boolean loop
                        --  An edge at the type's own extreme passes every
                        --  value, so it is not tested.
                        if (if Upper
                            then Landin.IR.Range_Upper (Of_Unit, Item, Value)
                                 < Landin.Types.Highest (Kind (Value), Facts)
                            else Landin.IR.Range_Lower (Of_Unit, Item, Value)
                                 > Landin.Types.Lowest (Kind (Value), Facts))
                        then
                           declare
                              Bound : constant Pattern := To_Pattern
                                ((if Upper
                                  then Landin.IR.Range_Upper
                                    (Of_Unit, Item, Value)
                                  else Landin.IR.Range_Lower
                                    (Of_Unit, Item, Value)), 64);
                              Compare_High : constant String :=
                                (if Landin.Types.Is_Signed (Kind (Value))
                                 then "blt " else "bltu ");
                              Next : constant String := Fresh;
                           begin
                              Immediate ("x12", Bound and 16#FFFF_FFFF#);
                              Immediate ("x13", Bound / 2 ** 32);
                              if Upper then
                                 Emit (Compare_High & "x13, x11, " & Trap);
                                 Emit ("bne x11, x13, "
                                      & Next);
                                 Emit ("bltu x12, x10, " & Trap);
                              else
                                 Emit (Compare_High & "x11, x13, " & Trap);
                                 Emit ("bne x11, x13, "
                                      & Next);
                                 Emit ("bltu x10, x12, " & Trap);
                              end if;
                              Put (Next & ":");
                           end;
                        end if;
                     end loop;
                     Store_Value (Value, "x10");

                  when Landin.IR.Conversion | Landin.IR.Pointer_Address
                     | Landin.IR.Code_Address =>
                     declare
                        From : constant Landin.Types.Scalar_Name :=
                          Kind (Operand (1));
                        Into : constant Landin.Types.Scalar_Name :=
                          Kind (Value);
                        Done : constant String := Fresh;
                     begin
                        if not (Is_Float (From) or else Is_Float (Into)
                                or else Wide (Operand (1))
                                or else Wide (Value))
                        then
                           Handled := False;
                           return;
                        end if;
                        if Is_Float (From) and then Is_Float (Into) then
                           Load_Value (Operand (1), "x10");
                           if From /= Into then
                              Helper (if From = Landin.Types.F32
                                      then "__extendsfdf2"
                                      else "__truncdfsf2");
                              if Into = Landin.Types.F32 then
                                 --  A finite f64 that rounds to an
                                 --  infinity overflowed; a NaN or an
                                 --  infinity converts as itself.
                                 Immediate ("x6", 16#7F80_0000#);
                                 Emit ("and x7, x10, x6");
                                 Emit ("bne x7, x6, "
                                      & Done);
                                 Load_Value (Operand (1), "x12");
                                 Immediate ("x6", 16#7FF0_0000#);
                                 Emit ("and x7, x13, x6");
                                 Emit ("bne x7, x6, " & Trap);
                              end if;
                           end if;
                        elsif Is_Float (Into) then
                           Load_Value (Operand (1), "x10");
                           if not Wide (Operand (1)) then
                              Extend ("x10", From);
                           end if;
                           Helper ("__float"
                             & (if Signed_Integer (From) then "" else "un")
                             & (if Wide (Operand (1)) then "di" else "si")
                             & Mode (Into));
                        elsif Is_Float (From) and then Into = Landin.Types.Bool
                        then
                           --  Both zeros are false, positive one is true,
                           --  and every other value, a NaN among them,
                           --  fails.
                           Load_Value (Operand (1), "x10");
                           if From = Landin.Types.F32 then
                              Emit ("slli x6, x10, 1");
                              Emit ("beqz x6, " & Done
                                   & "_zero");
                              Immediate ("x6", 16#3F80_0000#);
                              Emit ("bne x10, x6, " & Trap);
                           else
                              Emit ("slli x6, x11, 1");
                              Emit ("or x6, x6, x10");
                              Emit ("beqz x6, " & Done
                                   & "_zero");
                              Emit ("bnez x10, " & Trap);
                              Immediate ("x6", 16#3FF0_0000#);
                              Emit ("bne x11, x6, " & Trap);
                           end if;
                           Emit ("li x10, 1");
                           Emit ("j " & Done);
                           Put (Done & "_zero:");
                           Emit ("li x10, 0");
                        elsif Is_Float (From) then
                           --  D672: the significand decoded and truncated
                           --  toward zero in integer words, as Cortex-M0
                           --  does, with no helper's out-of-range answer.
                           declare
                              Fraction : constant Natural :=
                                (if From = Landin.Types.F32 then 23 else 52);
                              Into_Signed : constant Boolean :=
                                Signed_Integer (Into);
                           begin
                              Load_Value (Operand (1), "x10");
                              Emit ("mv x14, " & (if From = Landin.Types.F32
                                                  then "x10" else "x11"));
                              Emit ("srli x6, x14, " & (if From
                                = Landin.Types.F32 then "23" else "20"));
                              Immediate ("x7", (if From = Landin.Types.F32
                                                then 255 else 2047));
                              Emit ("and x6, x6, x7");
                              Emit ("beq x6, x7, " & Trap);
                              Emit ("addi x6, x6, -" & (if From
                                = Landin.Types.F32 then "127" else "1023"));
                              Emit ("bltz x6, " & Done
                                   & "_zero");
                              Emit ("li x7, 64");
                              Emit ("bgeu x6, x7, " & Trap);
                              if From = Landin.Types.F32 then
                                 Immediate ("x7", 16#7F_FFFF#);
                                 Emit ("and x10, x10, x7");
                                 Immediate ("x7", 16#80_0000#);
                                 Emit ("or x10, x10, x7");
                                 Emit ("li x11, 0");
                              else
                                 Immediate ("x7", 16#F_FFFF#);
                                 Emit ("and x11, x11, x7");
                                 Immediate ("x7", 16#10_0000#);
                                 Emit ("or x11, x11, x7");
                              end if;
                              Emit ("li x7, " & Image (Fraction));
                              Emit ("bltu x6, x7, " & Done
                                   & "_right");
                              Emit ("sub x12, x6, x7");
                              Shift_Pair (True);
                              Emit ("j " & Done & "_sign");
                              Put (Done & "_right:");
                              Emit ("sub x12, x7, x6");
                              Shift_Pair (False);
                              Put (Done & "_sign:");
                              Emit ("bgez x14, " & Done
                                   & "_positive");
                              if Into_Signed then
                                 Immediate ("x6", 2 ** 31);
                                 Emit ("bltu x6, x11, " & Trap);
                                 Emit ("bne x11, x6, "
                                      & Done & "_negate");
                                 Emit ("bnez x10, " & Trap);
                                 Put (Done & "_negate:");
                                 Negate;
                              else
                                 Emit ("or x6, x10, x11");
                                 Emit ("bnez x6, " & Trap);
                              end if;
                              Emit ("j " & Done & "_fit");
                              Put (Done & "_positive:");
                              if Into_Signed then
                                 Emit ("bltz x11, " & Trap);
                              end if;
                              Emit ("j " & Done & "_fit");
                              Put (Done & "_zero:");
                              Emit ("li x10, 0");
                              Emit ("li x11, 0");
                              Put (Done & "_fit:");
                              if not Wide (Value) then
                                 Fit_Narrow (Into);
                              end if;
                           end;
                        else
                           Load_Wide (1, "x10");
                           if Into = Landin.Types.Bool then
                              Emit ("bnez x11, " & Trap);
                              Emit ("li x6, 1");
                              Emit ("bltu x6, x10, " & Trap);
                           elsif not Unchecked
                             and then Into in Landin.Types.Integer_Name
                           then
                              if From in Landin.Types.Integer_Name
                                and then Landin.Types.Is_Signed (From)
                                  /= Landin.Types.Is_Signed (Into)
                              then
                                 Emit ("bltz x11, " & Trap);
                              end if;
                              if not Wide (Value) then
                                 Fit_Narrow (Into);
                              end if;
                           end if;
                        end if;
                        Put (Done & ":");
                        Store_Value (Value, "x10");
                     end;

                  when others =>
                     Handled := False;
               end case;
            end Pair_Instruction;
         begin
            if Pairs then
               declare
                  Handled : Boolean;
               begin
                  Pair_Instruction (Handled);
                  if Handled then
                     return;
                  end if;
               end;
            end if;
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
               when Landin.IR.Measurement_Kind =>
                  declare
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Measurement_Extent
                       (Of_Unit, Item, Value, Facts, Bytes, Alignment);
                     Immediate ("x5", (if Op /= Landin.IR.Measure_Align
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
                     use all type Landin.Memory.Ordering;
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
                     --  The success ordering; a compare-exchange's failure
                     --  ordering is never stronger (D227), so the LR the
                     --  success ordering chooses serves both.
                     Order : constant Landin.Memory.Ordering :=
                       Landin.IR.Memory_Order (Of_Unit, Item, Value);
                  begin
                     if M = Stack_Prepare then
                        Load_Value (Operand (1), "x5");
                        Load_Value (Operand (2), "x6");
                        Emit ("add x6, x6, x5");
                        Emit ("andi x6, x6, -16");
                        Emit ("sub x6, x6, x5");
                        Immediate ("x7", Pattern
                          (Stack_Frame_Bytes + Limit_Margin));
                        Emit ("blt x6, x7, " & Trap);
                        Emit ("add x5, x5, x6");
                        Emit ("addi x5, x5, -"
                              & Byte_Image (Stack_Frame_Bytes));
                        Emit ("mv x28, x5");
                        Zero_Bytes (Stack_Frame_Bytes);
                        Emit ("mv x5, x28");
                        Emit ("addi x7, x5, "
                              & Byte_Image (Stack_Frame_Bytes));
                        Emit ("sw x7, 292(x5)"); --  Root backchain.
                        Emit ("addi x7, x7, -32");
                        Emit ("sw x7, 4(x5)"); --  Root ABI spill space.
                        Emit ("addi x7, x7, 32");
                        Emit ("sub x7, x7, x6");
                        Add_Offset ("x7", Limit_Margin);
                        Emit ("sw x7, 288(x5)");
                        Immediate ("x7", 16#40020#); --  PS.WOE and PS.UM.
                        Emit ("sw x7, 256(x5)");
                        Immediate ("x7", 1);
                        Emit ("sw x7, 264(x5)"); --  WINDOWSTART at WB 0.
                        Load_Value (Operand (3), "x7");
                        Emit ("sw x7, 8(x5)"); --  Prepared a2: entry.
                        Load_Value (Operand (4), "x7");
                        Emit ("sw x7, 12(x5)"); --  Prepared a3: argument.
                        Address ("x7", Stack_Start);
                        Emit ("sw x7, 284(x5)");
                        Stack_Used := True;
                        Store_Value (Value, "x5");
                     elsif M = Stack_Switch then
                        --  D450/D472: the switch is one call of the
                        --  program's switch routine; the routine making it
                        --  checked its frame (D471).  Every value here has
                        --  a frame home, so nothing is kept in a register
                        --  across it, as across any call.
                        Load_Value (Operand (1), "x10");
                        Load_Value (Operand (2), "x11");
                        Emit ("call " & Stack_Switcher);
                        Stack_Used := True;
                     elsif Landin.Memory.Operands (M) = 0 then
                        --  D499, the RISC-V memory model's mapping (the
                        --  unprivileged ISA's Table A.6): acquire FENCE
                        --  R,RW, release FENCE RW,W, acq_rel FENCE.TSO and
                        --  seq_cst FENCE RW,RW.  The device and completion
                        --  barriers keep their device-ordering FENCE.
                        case M is
                           when Compiler_Barrier => null;
                           when Thread_Fence =>
                              Emit (case Order is
                                 when Acquire => "fence r, rw",
                                 when Release => "fence rw, w",
                                 when Acq_Rel => "fence.tso",
                                 when others => "fence rw, rw");
                           when others => Emit ("fence iorw, iorw");
                        end case;
                     else
                        --  D690: the checker admits no eight-byte atomic on
                        --  RV32 and no read-modify-write at a level without
                        --  A, so one that reaches here is a defect.  An
                        --  eight-byte volatile access is its two words.
                        if Pairs and then ((Bytes > Word and then M not in
                            Volatile_Load | Volatile_Store)
                          or else (not Atomics and then M not in
                            Atomic_Load | Volatile_Load | Atomic_Store
                              | Volatile_Store))
                        then
                           raise Compiler_Defect with
                             "an atomic RV32 does not admit at this level";
                        end if;
                        Load_Value (Operand (1), "x6");
                        if Bytes > 1 then
                           Emit ("andi x18, x6, " & Image (Bytes - 1));
                           Emit ("bnez x18, " & Trap);
                        end if;
                        --  D499, Table A.6: a load is a plain load, an
                        --  acquire one followed by FENCE R,RW and a seq_cst
                        --  one also preceded by FENCE RW,RW; a store is a
                        --  plain store, a release or seq_cst one preceded by
                        --  FENCE RW,W.  A read-modify-write carries its
                        --  ordering on its AMO, or on the LR and SC of its
                        --  reservation loop: .aq on LR for an acquire, .rl
                        --  on SC for a release, and .aqrl on LR for
                        --  seq_cst.
                        if M = Atomic_Load then
                           if Order = Seq_Cst then
                              Emit ("fence rw, rw");
                           end if;
                           Memory (False, Size, "x5", "x6");
                           if Landin.Memory.Acquires (Order) then
                              Emit ("fence r, rw");
                           end if;
                        elsif M = Volatile_Load then
                           Memory (False, Size, "x5", "x6");
                        elsif M in Atomic_Store | Volatile_Store then
                           Load_Value (Operand (2));
                           if M = Atomic_Store
                             and then Landin.Memory.Releases (Order)
                           then
                              Emit ("fence rw, w");
                           end if;
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
                                & Width
                                & (case Order is
                                     when Relaxed | No_Ordering => "",
                                     when Acquire => ".aq",
                                     when Release => ".rl",
                                     when Acq_Rel | Seq_Cst => ".aqrl")
                                & " x5, x7, (x6)");
                              if Bytes = 4 and then not Pairs then
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
                              Emit ("lr." & Width
                                & (case Order is
                                     when Seq_Cst => ".aqrl",
                                     when Acquire | Acq_Rel => ".aq",
                                     when others => "")
                                & " x20, (x18)");
                              if Bytes < 4 then
                                 Emit ("srl x5, x20, x19");
                                 Emit ("and x5, x5, x22");
                              elsif Bytes = 4 and then not Pairs then
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
                              Emit ("sc." & Width
                                & (if Landin.Memory.Releases (Order)
                                   then ".rl" else "")
                                & " x30, x21, (x18)");
                              Emit ("bnez x30, " & Retry);
                              Put (Done & ":");
                           end if;
                        end if;
                        if Landin.Memory.Returns_Value (M) then
                           Store_Value (Value);
                        end if;
                     end if;
                  end;

               when Landin.IR.Load_Indirect =>
                  Load_Value (Operand (1), "x6");
                  if Unaligned_Indirect then
                     Byte_Memory (False, Size_Of_Value (Value), "x5", "x6");
                  else
                     Memory (False, Size_Of_Value (Value), "x5", "x6");
                  end if;
                  Store_Value (Value);
               when Landin.IR.Store_Indirect =>
                  Load_Value (Operand (1), "x6");
                  Load_Value (Operand (2));
                  if Unaligned_Indirect then
                     Byte_Memory
                       (True, Size_Of_Value (Operand (2)), "x5", "x6");
                  else
                     Memory (True, Size_Of_Value (Operand (2)), "x5", "x6");
                  end if;
               when Landin.IR.Load_Datum | Landin.IR.Store_Datum =>
                  Datum_Address
                    ("x6", Landin.IR.Datum_Of (Of_Unit, Item, Value));
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
                        if Pairs and then Landin.Targets.Packed.Carrier
                          (Shape.Packing.Storage) = Landin.Targets.Byte_8
                        then
                           Emit ("li x30, " & Image (Shape.Packing.First));
                           Packed_Pair
                             (Shape.Packing.Bits, Shape.Atoms,
                              Op = Landin.IR.Store_Field);
                           return;
                        end if;
                        if Op = Landin.IR.Load_Field then
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x5", "x6");
                           Extract ("x5", "x5", Shape.Packing.First,
                             Shape.Packing.Bits);
                           Packed_Atom (Shape.Atoms, Encode => False);
                           Clear_High (Value);
                           Store_Value (Value, Atom_Validated => True);
                        else
                           Load_Value (Operand (1));
                           Packed_Atom (Shape.Atoms, Encode => True);
                           Narrow_High (Operand (1));
                           if Shape.Packing.Bits < Natural (Width) then
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
                  if Unaligned_Part
                    (Place,
                     Landin.IR.Element_Total
                       (Landin.IR.Field_Of (Of_Unit, Item, Value)),
                     Landin.IR.Path_Of (Of_Unit, Item, Value))
                  then
                     if Op = Landin.IR.Load_Field then
                        Byte_Memory
                          (False, Size_Of_Value (Value), "x5", "x6");
                        Store_Value (Value);
                     else
                        Load_Value (Operand (1));
                        Byte_Memory
                          (True, Size_Of_Value (Operand (1)), "x5", "x6");
                     end if;
                  elsif Op = Landin.IR.Load_Field then
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
                        if Pairs and then Landin.Targets.Packed.Carrier
                          (Shape.Packing.Storage) = Landin.Targets.Byte_8
                        then
                           Emit ("mv x30, x29");
                           Packed_Pair
                             (Shape.Packing.Bits,
                              Landin.IR.Array_Element_Shape
                                (Of_Unit, Shape).Atoms,
                              Op = Landin.IR.Store_Element);
                           return;
                        end if;
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
                           Clear_High (Value);
                           Store_Value (Value, Atom_Validated => True);
                        else
                           Load_Value (Operand (2));
                           Packed_Atom (Landin.IR.Array_Element_Shape
                             (Of_Unit, Shape).Atoms, Encode => True);
                           Narrow_High (Operand (2));
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
                  if Unaligned_Element
                    (Place, Landin.IR.Element_Field_Of (Of_Unit, Item, Value),
                     Landin.IR.Variant_Case_Of (Of_Unit, Item, Value),
                     Landin.IR.Variant_Payload_Field_Of
                       (Of_Unit, Item, Value),
                     Landin.IR.Path_Of (Of_Unit, Item, Value),
                     Landin.IR.Element_Path_Of (Of_Unit, Item, Value))
                  then
                     if Op = Landin.IR.Load_Element then
                        Byte_Memory
                          (False, Size_Of_Value (Value), "x5", "x6");
                        Store_Value (Value);
                     else
                        Load_Value (Operand (2));
                        Byte_Memory
                          (True, Size_Of_Value (Operand (2)), "x5", "x6");
                     end if;
                  elsif Op = Landin.IR.Load_Element then
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
                                    Emit ("srai x28, x5, "
                                          & Image (Natural (Width) - 1));
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
                                 Extract ("x18", "x6",
                                          Natural (Width) - 1, 1);
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
               when Landin.IR.Choose =>
                  --  D338.  The backend uses none of Xtensa's conditional
                  --  moves, MOVEQZ, MOVNEZ, MOVLTZ and MOVGEZ: a choice of
                  --  one or zero is the condition's own zero or one, and
                  --  any other keeps a branch around one load.
                  declare
                     use type Landin.Types.Magnitude;

                     function Is_Number
                       (Which : Landin.IR.Value_Id;
                        Of_Value : Landin.Types.Magnitude) return Boolean
                       is (Landin.IR.Op_Of (Of_Unit, Item, Which)
                             = Landin.IR.Number
                           and then Kind (Value) in Landin.Types.Integer_Name
                           and then not (Pairs and then Size_Of_Value (Value)
                                           = Landin.Targets.Byte_8)
                           and then Landin.IR.Number_Of
                             (Of_Unit, Item, Which) = Of_Value
                           and then (Of_Value = 0
                                     or else not Landin.IR.Is_Negated
                                       (Of_Unit, Item, Which)));
                     Done : constant String := Fresh;
                  begin
                     if Is_Number (Operand (2), 1)
                       and then Is_Number (Operand (3), 0)
                     then
                        Load_Value (Operand (1));
                     elsif Is_Number (Operand (2), 0)
                       and then Is_Number (Operand (3), 1)
                     then
                        Load_Value (Operand (1));
                        Emit ("xori x5, x5, 1");
                     else
                        Load_Value (Operand (1), "x7");
                        Load_Value (Operand (2));
                        Emit ("bnez x7, " & Done);
                        Load_Value (Operand (3));
                        Put (Done & ":");
                     end if;
                     Store_Value (Value);
                  end;
               when Landin.IR.Range_Check =>
                  Load_Value (Operand (1));
                  Extend ("x5", Kind (Value));
                  --  An edge at the type's own extreme passes every
                  --  value, so it is not tested: `ptr(n)`'s upper edge is
                  --  the largest `usize`.
                  if Landin.IR.Range_Lower (Of_Unit, Item, Value)
                    > Landin.Types.Lowest (Kind (Value), Facts)
                  then
                     Immediate ("x6", To_Pattern
                       (Landin.IR.Range_Lower (Of_Unit, Item, Value), 64));
                     Compare ("x5", "x6");
                     Branch ((if Landin.Types.Is_Signed (Kind (Value))
                       then "lt" else "lo"), Trap);
                  end if;
                  if Landin.IR.Range_Upper (Of_Unit, Item, Value)
                    < Landin.Types.Highest (Kind (Value), Facts)
                  then
                     Immediate ("x6", To_Pattern
                       (Landin.IR.Range_Upper (Of_Unit, Item, Value), 64));
                     Compare ("x5", "x6");
                     Branch ((if Landin.Types.Is_Signed (Kind (Value))
                       then "gt" else "hi"), Trap);
                  end if;
                  Store_Value (Value);
               when Landin.IR.Conversion | Landin.IR.Pointer_Address
                  | Landin.IR.Code_Address =>
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
                     Emit (Load_Word & " x5, " & Trimmed
                       (Landin.Targets.Byte_Count'Image
                          (Landin.Targets.Any_Table_Offset (Facts)))
                       & "(x5)");
                  end if;
                  Add_Offset ("x5", Landin.Targets.Evidence_Function_Offset
                    (Facts, Landin.IR.Evidence_Entry_Of (Of_Unit, Item,
                      Value)));
                  Emit (Load_Word & " x5, 0(x5)");
                  Store_Value (Value);
               when Landin.IR.Evidence_Self =>
                  Load_Value (Landin.IR.Nth_Operand (Of_Unit, Item, Operand
                    (1), 1));
                  Emit (Load_Word & " x5, 0(x5)");
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
                     Places : constant Carrier_Array := Carriers
                       ([for Index in 1 .. Count =>
                           Pairs and then Size_Of_Value
                             (Operand (Index + Offset))
                               = Landin.Targets.Byte_8]);
                     Bytes : constant Landin.Targets.Byte_Count :=
                       Carrier_Bytes (Places);
                  begin
                     if Landin.IR.Signature_Uses_C_ABI (Of_Unit, Signature)
                     then
                        if Pairs then
                           raise Compiler_Defect with
                             "RV32 checks no C signature (D660)";
                        end if;
                        C_Call (Value);
                        return;
                     end if;
                     if Checks and then Bytes > Unchecked_Bytes then
                        Check_Limit (Bytes);
                     end if;
                     Reserve (Bytes);
                     Deepest_Area :=
                       Landin.Targets.Byte_Count'Max (Deepest_Area, Bytes);
                     for Index in 1 .. Count loop
                        if Places (Index).Pair
                          and then Places (Index).Register /= 0
                        then
                           Load_Pair (Operand (Index + Offset),
                             Argument_Register (Places (Index).Register),
                             Argument_Register
                               (Places (Index).Register + 1));
                        elsif Places (Index).Register /= 0 then
                           Load_Value (Operand (Index + Offset),
                             Argument_Register (Places (Index).Register));
                        else
                           Load_Value (Operand (Index + Offset));
                           declare
                              Stack_At : constant Landin.Targets.Byte_Count :=
                                Places (Index).Stack_At;
                              Base : constant String :=
                                (if Stack_At <= 2040 then "sp" else "x6");
                              Into : constant Landin.Targets.Byte_Count :=
                                (if Stack_At <= 2040 then Stack_At else 0);
                           begin
                              if Stack_At > 2040 then
                                 Emit ("mv x6, sp");
                                 Add_Offset ("x6", Stack_At);
                              end if;
                              Emit (Store_Word & " x5, " & Trimmed
                                (Landin.Targets.Byte_Count'Image (Into))
                                & "(" & Base & ")");
                              if Places (Index).Pair then
                                 Emit ("sw x27, " & Trimmed
                                   (Landin.Targets.Byte_Count'Image
                                      (Into + 4)) & "(" & Base & ")");
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
                     if Item = Hosted_Entry and then not Pairs then
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
                  if Panic = null
                    or else not Landin.Panics.Calls_Out (Panic.all)
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
         Native_Frame_Bytes := 0;
         Native_Scratch_Registers := False;
         --  One terminal keeps its inline teardown; more than one pays for
         --  branches to a single restore sequence.
         for Index in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
            Has_Assembly := Has_Assembly or else
              Landin.IR.Op_Of (Of_Unit, Item, Landin.IR.Value_Id (Index))
                = Landin.IR.Assembly;
            if Landin.IR.Op_Of (Of_Unit, Item, Landin.IR.Value_Id (Index))
              in Landin.IR.Leave | Landin.IR.Fail
            then
               Terminal_Count := Terminal_Count + 1;
            end if;
         end loop;
         if Is_Exported_Item (Item) then
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
         --  A naked routine is its text and nothing else: no frame record
         --  and no saved register.  It is a process's own entry, which no
         --  caller entered, so its return address is undefined; text that
         --  falls off its end traps.
         if Landin.IR.Signature_Machine
           (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
             = Landin.Machine.Naked_Routine
         then
            if Debug /= null then
               Emit (".cfi_undefined ra");
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
                     declare
                        Text : constant String :=
                          Landin.Source.Names.Spelling
                            (Names, Landin.IR.Assembly_Text
                               (Of_Unit, Item, Value));
                        First : Positive := Text'First;
                     begin
                        for Index in Text'Range loop
                           if Text (Index) = LF then
                              if Index > First then
                                 Put (Character'Val (9)
                                      & Text (First .. Index - 1));
                              end if;
                              First := Index + 1;
                           end if;
                        end loop;
                        if First <= Text'Last then
                           Put (Character'Val (9) & Text (First .. Text'Last));
                        end if;
                     end;
                  end if;
                  if Debug /= null then
                     Put (Dwarf.Label_Name
                       (Local_Prefix, "after", Item, Natural (Value)) & ":");
                  end if;
               end;
            end loop;
            Emit ("unimp");
            if Debug /= null then
               Put (Dwarf.Label_Name (Local_Prefix, "end", Item) & ":");
               Emit (".cfi_endproc");
            end if;
            Platform_Directive (ELF_Spelling.Size_To_Here (Symbol (Item)));
            Append_Statistics
              ((Item => Item, Naked => True, others => <>));
            return;
         end if;
         --  The top 32 bytes belong to window spills. Ordinary routines
         --  need only 80 bytes for their twenty logical word homes;
         --  zero, SP, the derived CFA and register-held scratch words
         --  need no home, and unused x26 has no home either.
         --  Source assembly retains all 128 logical bytes plus its
         --  64-byte snapshot bank at 128 + physical register number * 4.
         --  Source homes lie between the banks and the spill area.
         declare
            Total : constant Landin.Targets.Byte_Count :=
              Stack_Align
                (Extent (Layout) + (if Has_Assembly then 240 else 128),
                 16, 16#7fff_ffff#);
         begin
            Native_Frame_Bytes := Total;
            --  Incoming a2-a7 are homed before any selected instruction.
            --  CALL8 preserves the current window's a2-a6; opaque source
            --  assembly keeps the original complete scratch-bank path.
            Native_Scratch_Registers := not Has_Assembly;
            Put (Character'Val (9) & "entry a1, 32");
            if Checks then
               declare
                  Fits : constant String := Fresh;
                  Wrapped : constant String := Fresh;
               begin
                  Put (Character'Val (9) & "movi a8, "
                       & Trimmed (Landin.Targets.Byte_Count'Image
                           (Total - 16)));
                  Put (Character'Val (9) & "sub a8, a1, a8");
                  Put (Character'Val (9) & "movi a9, " & Stack_Limit);
                  Put (Character'Val (9) & "l32i a9, a9, 0");
                  --  A difference that wrapped past zero fits nothing.
                  Put (Character'Val (9) & "bltu a1, a8, " & Wrapped);
                  Put (Character'Val (9) & "bgeu a8, a9, " & Fits);
                  Put (Wrapped & ":");
                  if Panic /= null
                    and then Landin.Panics.Handler (Panic.all)
                      /= Landin.IR.No_Item
                  then
                     Put (Character'Val (9) & "movi a10, " & Trimmed
                       (Positive'Image (Landin.Panics.Code
                         (Panic.all, Landin.Panics.Stack_Exhausted))));
                     Put (Character'Val (9) & "movi a11, " & Trimmed
                       (Natural'Image (Natural (Landin.Panics.Site
                         (Panic.all, Landin.IR.Origin_Of (Of_Unit, Item),
                          Landin.Panics.Stack_Exhausted)))));
                     Put (Character'Val (9) & "call8 "
                          & Symbol (Landin.Panics.Handler (Panic.all)));
                  end if;
                  Put (Character'Val (9) & "ill");
                  Put (Fits & ":");
               end;
            elsif Prepares and then Panic /= null
              and then Item = Landin.Panics.Handler (Panic.all)
            then
               Put (Character'Val (9) & "movi a8, " & Stack_Limit);
               Put (Character'Val (9) & "movi a9, 0");
               Put (Character'Val (9) & "s32i a9, a8, 0");
            end if;
            Put (Character'Val (9) & "movi a8, "
                 & Trimmed (Landin.Targets.Byte_Count'Image (Total - 32)));
            Put (Character'Val (9) & "sub a1, a1, a8");
            Put (Character'Val (9) & "s32i a7, a1, "
                 & Native_Word_Offset (15));
            Put (Character'Val (9) & "mov a7, a1");
            for Index in 0 .. 4 loop
               Put (Character'Val (9) & "s32i a" & Image (Index + 2)
                    & ", a7, " & Native_Word_Offset (Index + 10));
            end loop;
            Put (Character'Val (9) & "movi a8, " & Trimmed (Total'Image));
            Put (Character'Val (9) & "add a8, a7, a8");
            if not Native_Scratch_Registers then
               Put (Character'Val (9) & "s32i a8, a7, "
                    & Native_Word_Offset (8));
            end if;
            Put (Character'Val (9) & "s32e a8, a1, -12");
         end;
         if Panic /= null and then Item = Landin.Panics.Handler (Panic.all)
         then
            declare
               Retry : constant String := Fresh;
               Busy : constant String := Fresh;
               Claimed : constant String := Fresh;
            begin
               Address ("x18", Local_Prefix & "landin_panic_active");
               if Atomics then
                  Put (Retry & ":");
                  Emit ("lr.w.aq x19, (x18)");
                  --  The five-instruction reservation loop uses only
                  --  direct local branches. Its busy escape leaves the
                  --  loop before the possibly distant hard-trap jump.
                  Emit ("bnez x19, " & Busy);
                  Emit ("li x19, 1");
                  Emit ("sc.w.rl x9, x19, (x18)");
                  Emit ("bnez x9, " & Retry);
               else
                  --  D674: a level without A claims the latch as
                  --  Cortex-M0 does, with a load, a test and a store on
                  --  its one hart.
                  Emit ("lw x19, 0(x18)");
                  Emit ("bnez x19, " & Busy);
                  Emit ("li x19, 1");
                  Emit ("sw x19, 0(x18)");
               end if;
               Emit ("j " & Claimed);
               Put (Busy & ":");
               Emit ("j " & Hard_Trap);
               Put (Claimed & ":");
            end;
         end if;
         if Is_C_Item (Item) then
            if Pairs then
               raise Compiler_Defect with "RV32 checks no C signature (D660)";
            end if;
            C_Entry;
         else
            declare
               Parameters : constant Natural :=
                 Landin.IR.Parameter_Count (Of_Unit, Item);

               function Wide (Index : Positive) return Boolean is
                 (Pairs and then
                    (declare
                       Slot : constant Landin.IR.Slot_Id :=
                         Landin.IR.Nth_Parameter (Of_Unit, Item, Index);
                     begin
                       not Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                       and then not Landin.IR.Is_Array (Of_Unit, Item, Slot)
                       and then Size_Of (Landin.IR.Type_Of
                                           (Of_Unit, Item, Slot), Facts)
                         = Landin.Targets.Byte_8));

               Places : constant Carrier_Array := Carriers
                 ([for Index in 1 .. Parameters => Wide (Index)]);
            begin
               for Index in 1 .. Parameters loop
                  declare
                     Slot : constant Landin.IR.Slot_Id :=
                       Landin.IR.Nth_Parameter (Of_Unit, Item, Index);
                     Aggregate : constant Boolean := Landin.IR.Is_Aggregate
                       (Of_Unit, Item, Slot)
                       or else Landin.IR.Is_Array (Of_Unit, Item, Slot);
                     Home : constant Landin.IR.Slot_Id :=
                       Landin.IR.In_Place_Home (Of_Unit, Item, Slot);

                     --  The unit a shaped slot moves by.  The carrier
                     --  addresses storage aligned for this shape (docs/ir.md)
                     --  and the slot is fresh, so an aligned whole-unit
                     --  extent moves by words.
                     function Width_Of
                       (Shaped : Landin.IR.Slot_Id;
                        Bytes : Landin.Targets.Byte_Count)
                        return Landin.Targets.Byte_Count;

                     function Width_Of
                       (Shaped : Landin.IR.Slot_Id;
                        Bytes : Landin.Targets.Byte_Count)
                        return Landin.Targets.Byte_Count
                     is
                        Size : Landin.Targets.Byte_Count;
                        Alignment : Landin.Targets.Byte_Alignment;
                     begin
                        Landin.Backend.Aggregate_Extent
                          (Of_Unit, Item, Shaped, Facts, Size, Alignment);
                        if Alignment >= 8 and then Bytes mod 8 = 0
                          and then not Pairs
                        then
                           return 8;
                        elsif Alignment >= 4 and then Bytes mod 4 = 0 then
                           return 4;
                        end if;
                        return 1;
                     end Width_Of;
                  begin
                     if Places (Index).Pair then
                        if Places (Index).Register /= 0 then
                           Emit ("mv x5, " & Argument_Register
                             (Places (Index).Register));
                           Emit ("mv x27, " & Argument_Register
                             (Places (Index).Register + 1));
                        else
                           Emit ("mv x6, x8");
                           Add_Offset ("x6", Places (Index).Stack_At);
                           Emit ("lw x27, 4(x6)");
                           Emit ("lw x5, 0(x6)");
                        end if;
                        Store_Slot (Slot, "x5");
                        goto Next_Parameter;
                     elsif Places (Index).Register /= 0 then
                        Emit ("mv x6, " & Argument_Register
                          (Places (Index).Register));
                     else
                        Emit ("mv x6, x8");
                        Add_Offset ("x6", Places (Index).Stack_At);
                        Emit (Load_Word & " x6, 0(x6)");
                     end if;
                     if Aggregate then
                        declare
                           Zero_Label : constant String := Fresh;
                           Done_Label : constant String := Fresh;
                           Bytes : constant Landin.Targets.Byte_Count :=
                             Whole_Clear_Extent
                               ((Kind => Landin.IR.Frame_Slot, Slot => Slot),
                                0, Landin.IR.No_Path_Steps);
                           Width : constant Landin.Targets.Byte_Count :=
                             Width_Of (Slot, Bytes);
                        begin
                           Frame_Address (Slot_Offset (Layout, Slot), "x5");
                           Emit ("beqz x6, " & Zero_Label);
                           if Width > 1 then
                              Move_Words (Bytes, Width, Copy => True);
                           else
                              Copy_Bytes (Bytes);
                           end if;
                           Emit ("j " & Done_Label);
                           Put (Zero_Label & ":");
                           if Width > 1 then
                              Move_Words (Bytes, Width, Copy => False);
                           else
                              Zero_Bytes (Bytes);
                           end if;
                           Put (Done_Label & ":");
                        end;
                     else
                        Store_Slot (Slot, "x6");
                     end if;

                     --  Landin.IR.In_Place's parameter is an address slot,
                     --  stored above like a scalar, through which the body
                     --  reads its caller's storage.  D97's zero carrier still
                     --  clears the parameter's own home, which the parameter
                     --  then addresses.
                     if Home /= Landin.IR.No_Slot then
                        declare
                           Done_Label : constant String := Fresh;
                           Bytes : constant Landin.Targets.Byte_Count :=
                             Whole_Clear_Extent
                               ((Kind => Landin.IR.Frame_Slot, Slot => Home),
                                0, Landin.IR.No_Path_Steps);
                           Width : constant Landin.Targets.Byte_Count :=
                             Width_Of (Home, Bytes);
                        begin
                           Emit ("bnez x6, " & Done_Label);
                           Frame_Address (Slot_Offset (Layout, Home), "x5");
                           if Width > 1 then
                              Move_Words (Bytes, Width, Copy => False);
                           else
                              Zero_Bytes (Bytes);
                           end if;
                           Frame_Address (Slot_Offset (Layout, Home), "x6");
                           Store_Slot (Slot, "x6");
                           Put (Done_Label & ":");
                        end;
                     end if;
                     <<Next_Parameter>>
                  end;
               end loop;
            end;
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
            if Landin.Panics.Handler (Panic.all) /= Landin.IR.No_Item then
               Immediate ("x10", Pattern (Landin.Panics.Code
                 (Panic.all, Edge.Reason)));
               Immediate ("x11", Pattern (Edge.Site));
               Emit ("call " & Symbol (Landin.Panics.Handler (Panic.all)));
            else
               --  D361: the line for this operation, and its length, to
               --  the routine that writes it and ends the process.
               declare
                  Line : constant String := Landin.Panics.Report
                    (Panic.all, Edge.Origin, Edge.Reason);
               begin
                  Emit ("lla x10, " & Report_Label (Reports.Index_Of (Line)));
                  Immediate ("x11", Pattern (Line'Length));
                  Emit ("call " & Reporter);
               end;
            end if;
            Emit ("unimp");
         end loop;
         --  D471: a frame or an area that does not fit traps at the
         --  routine's own site, from the frame record: nothing below it
         --  was reserved for what did not fit, or what was is given back.
         if Limit_Trapped then
            Put (Limit_Trap & ":");
            if Debug /= null then
               Put (Dwarf.Source_Line
                 (Debug.all, Landin.IR.Origin_Of (Of_Unit, Item)));
            end if;
            Put (Character'Val (9) & "mov a1, a7");
            if Panic = null or else not Landin.Panics.Calls_Out (Panic.all)
            then
               null;
            elsif Landin.Panics.Handler (Panic.all) /= Landin.IR.No_Item
            then
               Immediate ("x10", Pattern (Landin.Panics.Code
                 (Panic.all, Landin.Panics.Stack_Exhausted)));
               Immediate ("x11", Pattern (Landin.Panics.Site
                 (Panic.all, Landin.IR.Origin_Of (Of_Unit, Item),
                  Landin.Panics.Stack_Exhausted)));
               Emit ("call " & Symbol (Landin.Panics.Handler (Panic.all)));
            else
               declare
                  Line : constant String := Landin.Panics.Report
                    (Panic.all, Landin.IR.Origin_Of (Of_Unit, Item),
                     Landin.Panics.Stack_Exhausted);
               begin
                  Emit ("lla x10, " & Report_Label (Reports.Index_Of (Line)));
                  Immediate ("x11", Pattern (Line'Length));
                  Emit ("call " & Reporter);
               end;
            end if;
            Emit ("unimp");
         end if;
         Put (Hard_Trap & ":");
         Emit ("unimp");
         if Debug /= null then
            Put (Dwarf.Label_Name (Local_Prefix, "end", Item) & ":");
            Emit (".cfi_endproc");
         end if;
         Platform_Directive (ELF_Spelling.Size_To_Here (Symbol (Item)));
         --  Opaque source assembly has no byte-size bound here. Keep all
         --  arbitrary-range jumps when a routine contains any such block.
         if not Has_Assembly then
            Landin.Backend.Xtensa_Machine.Compact_Jumps
              (Output, Assembly_First);
         end if;
         --  Bank homes are part of the native frame at every objective.
         --  No value or slot is held in a register: every one has its
         --  home, and the saved registers are selection's fixed scratch.
         Append_Statistics
           ((Item => Item, Frame_Bytes => Native_Frame_Bytes,
             Spill_Bytes => Spill_Bytes (Layout),
             Save_Bytes => Save_Bytes (Layout),
             Register_Count => 0,
             Spill_Count => Plan.Homes,
             Stack_Bytes => Native_Frame_Bytes + 16 + Deepest_Area,
             Calls_Panic => not Edges.Is_Empty
               or else (Limit_Trapped and then Panic /= null
                        and then Landin.Panics.Calls_Out (Panic.all)),
             Helper_Calls => Helpers_Called,
             others => <>));
         Native_Frame_Bytes := 0;
         Native_Scratch_Registers := False;
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

      type Item_Folds is array (Positive range <>) of Landin.Types.Folded;
      package Item_Fold_Buffers is new Landin.Backend.Work_Arrays
        (Landin.Types.Folded, Item_Folds, 0);
      type Fold_States is array (Positive range <>) of Fold_State;
      package Fold_State_Buffers is new Landin.Backend.Work_Arrays
        (Fold_State, Fold_States, Unseen);
      Fold_Data : Item_Fold_Buffers.Buffer
        (Landin.IR.Item_Count (Of_Unit));
      Fold_State_Data : Fold_State_Buffers.Buffer
        (Landin.IR.Item_Count (Of_Unit));
      Fold_Of : Item_Folds renames Fold_Data.Data.all;
      Fold_At : Fold_States renames Fold_State_Data.Data.all;

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

      --  D536: how many repeated bodies the image being written is inside,
      --  where a short run is written as plain values.
      Repeating : Natural := 0;

      --  D536: Count copies of one scalar, as `.zero` or `.fill` where one
      --  directive writes them and as nested repetitions of the scalar's
      --  own directive where `.fill` cannot carry its eight bytes; inside a
      --  repeated body a short run is plain values.
      procedure Emit_Scalar_Run
        (Count : Landin.IR.Element_Total;
         Held  : Held_Size;
         Value : Landin.Types.Folded);

      procedure Emit_Scalar_Run
        (Count : Landin.IR.Element_Total;
         Held  : Held_Size;
         Value : Landin.Types.Folded)
      is
         procedure Emit_Value;

         procedure Emit_Value is
         begin
            Emit (Directive (Held) & " "
                  & Trimmed (Landin.Types.Folded'Image (Value)));
         end Emit_Value;

         procedure Emit_Copies is new Landin.Backend.Repeat
           (Emit, Emit_Value);
      begin
         if Count = 0 then
            return;
         elsif Landin.Backend.Is_Plain (Count, Held, Repeating > 0) then
            Emit (Landin.Backend.Plain_Run
              (Count, Held, Value, Directive (Held)));
         elsif Landin.Backend.Is_Filled (Held, Value) then
            Emit (Landin.Backend.Scalar_Run (Count, Held, Value));
         else
            Emit_Copies (Count);
         end if;
      end Emit_Scalar_Run;

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
               Emit (Landin.Backend.Zero_Run (Bytes, Repeating > 0));
            end if;
         end Emit_Zero;

         --  D536: Copies of one element after the first, as one directive
         --  when the element is a plain scalar or writes only zeros, and
         --  as nested repetitions of its image otherwise.
         procedure Emit_Run
           (Element : Landin.IR.Field_Shape;
            Child   : Landin.IR.Aggregate_Field_Image;
            Copies  : Landin.IR.Element_Total);

         procedure Emit_Run
           (Element : Landin.IR.Field_Shape;
            Child   : Landin.IR.Aggregate_Field_Image;
            Copies  : Landin.IR.Element_Total)
         is
            procedure Emit_Element;

            procedure Emit_Element is
            begin
               Emit_Field (Element, Child, Child.Value);
            end Emit_Element;

            procedure Emit_Copies is new Landin.Backend.Repeat
              (Emit, Emit_Element);

            Element_Size : Landin.Targets.Byte_Count;
            Element_Alignment : Landin.Targets.Byte_Alignment;
         begin
            if Element.Kind = Landin.IR.Scalar_Field_Shape
              and then Child.Target = Landin.IR.No_Item
              and then Element.Atoms = Landin.IR.No_Atom_Set
            then
               Emit_Scalar_Run
                 (Copies, Size_Of (Element.Element, Facts), Child.Value);
            elsif Element.Kind /= Landin.IR.Scalar_Field_Shape
              and then Landin.Backend.Is_Zero_Image
                (Of_Unit, Item, Element, Child)
            then
               Landin.Backend.Field_Extent
                 (Of_Unit, Element, Facts, Element_Size, Element_Alignment);
               pragma Unreferenced (Element_Alignment);
               Emit_Zero (Landin.Targets.Byte_Count (Copies) * Element_Size);
            else
               Repeating := Repeating + 1;
               Emit_Copies (Copies);
               Repeating := Repeating - 1;
            end if;
         end Emit_Run;

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
                     Emit (Word_Directive & " " & Base);
                     Emit
                       (Word_Directive & " "
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
                     if Copies = 1 then
                        Emit_Field
                          (Landin.IR.Array_Element_Shape (Of_Unit, Shape),
                           Child, Child.Value);
                     elsif Copies > 1 then
                        Emit_Run
                          (Landin.IR.Array_Element_Shape (Of_Unit, Shape),
                           Child, Landin.IR.Element_Total (Copies));
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
               Emit_Scalar_Run
                 (Shape.Length - Landin.IR.Element_Total (Image.Count),
                  Size_Of (Shape.Element, Facts), Image.Value);
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

         if Is_Exported_Item (Item) then
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
         if Is_Exported_Item (Item) then
            Emit (".globl " & Symbol (Item));
         end if;
         --  An empty datum retains its aligned, zero-sized symbol, without
         --  a zero-count space directive that GNU as diagnoses.
         --  D496: a thread's instances are laid out by the system from the
         --  image's TLS segment, every one zeroed.
         Emit (Item_Section
           (Item, (if Landin.Backend.In_Thread_Storage (Of_Unit, Facts, Item)
                   then "tbss" else "bss"), "datum", Push => True));
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
         Emit (ELF_Spelling.Pop_Section);
      end Emit_Reserved;

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
      --  one directive of its own size; a repetition becomes one run
      --  (D536).  Nonzero or mixed images reach `.data`, while
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
            if Is_Exported_Item (Item) then
               Put (Character'Val (9) & ".globl " & Symbol (Item));
            end if;

               Put (Character'Val (9) & ".balign "
                 & Trimmed
                     (Landin.Targets.Byte_Alignment'Image
                        (Landin.Targets.Alignment_Of (Facts, Held))));
            Platform_Directive (ELF_Spelling.Object_Type (Symbol (Item)));
            Put (Symbol (Item) & ":");

            if Landin.IR.Is_Repeated_Image (Of_Unit, Item) then
               --  D38 writes its finite prefix first, then one run of the
               --  suffix value for N - k positions (D536).  Assembly size
               --  depends on the written prefix, never the target-sized
               --  extent.
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
                  Emit_Scalar_Run
                    (Length - Prefix, Held,
                     Landin.IR.Repeated_Image_Value (Of_Unit, Item));
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
         if Is_Exported_Item (Item) then
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
            Emit (Word_Directive & " " & Base);
         end;
         Emit
           (Word_Directive & " "
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
         if Is_Exported_Item (Item) then
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


   begin
      if Landin.Targets.Capabilities.Backend_For (Facts)
          /= Landin.Targets.Capabilities.Xtensa_ELF
        or else not Landin.Targets.Levels.Belongs_To (Level, Facts)
      then
         raise Compiler_Defect with
           "Xtensa emission needs its own target and feature level";
      end if;
      Emit (".text");
      Validate_Linkage;
      Allocate_Symbols;
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Attr : constant Landin.Machine.Placement :=
              Landin.IR.Placement_Of (Of_Unit, Landin.IR.Item_Id (Index));
         begin
            if Attr.Keep and then Attr.Section /= Landin.Source.Names.No_Name
            then
               Retained_Sections.Include (Attr.Section);
            end if;
         end;
      end loop;
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
      --  D680, D686: the firmware image's compiler-owned text.
      if Firmware_Entry /= Landin.IR.No_Item then
         Put (Landin.Backend.Firmware.Xtensa_Image
           (Of_Unit, Names, Symbol (Firmware_Entry), Symbol'Access,
            Limit_Cell => (if Prepares then Stack_Limit else ""),
            Returned =>
              (if Panic = null
                 or else Landin.Panics.Handler (Panic.all)
                   = Landin.IR.No_Item
               then ""
               else "movi a10, " & Trimmed (Positive'Image
                 (Landin.Panics.Code (Panic.all, Landin.Panics.Unreachable)))
                 & LF & "movi a11, 0" & LF & "call8 "
                 & Symbol (Landin.Panics.Handler (Panic.all))),
            Debug => Debug /= null));
      end if;
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then not Landin.IR.Is_External (Of_Unit, Item)
            then
               --  Every routine and datum is its own input section, so
               --  --gc-sections drops what nothing retained reaches.  D653:
               --  a description's stage before reset is the table's reset
               --  word's, wherever the text lies.
               if Pairs
                 and then Landin.IR.Placement_Of (Of_Unit, Item).Boot_Stage
                 and then Landin.Targets.Firmware.Stage_Before_Reset
                   (Landin.IR.Firmware_Profile (Of_Unit).Boot)
               then
                  Emit (".section .text.landin_firmware_reset_stage,""ax"","
                        & "@progbits");
                  Emit (".balign 4");
                  Emit (".globl "
                        & Landin.Targets.Firmware.Reset_Stage_Symbol);
                  Put (Landin.Targets.Firmware.Reset_Stage_Symbol & ":");
               else
                  Emit (Item_Section (Item, "text", "routine"));
               end if;
               declare
                  Plan : constant Allocation_Plan :=
                    Allocate (Of_Unit, Item, Facts, Options);
               begin
                  if Debug = null or else Pairs then
                     Emit_Routine
                       (Item, Plan, Frame_For
                          (Of_Unit, Item, Facts, Options, Plan,
                           16#7fff_ffff#));
                  else
                     Saved.Frames (Index) := new Frame'
                       (Frame_For
                          (Of_Unit, Item, Facts, Options, Plan,
                           16#7fff_ffff#));
                     Emit_Routine (Item, Plan, Saved.Frames (Index).all);
                  end if;
               end;
            end if;
         end;
      end loop;
      --  Data with an image first, in item order; then the reserved data,
      --  smallest first (Smallest_First), so that the one object as large
      --  as auipc's reach admits sits last.
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum then
               if Landin.IR.Is_Read_Only (Of_Unit, Item) then
                  Emit (Item_Section (Item, "rodata", "datum"));
                  Emit_Array_Image_Datum (Item);
               elsif Is_All_Zero (Item) then
                  null;
               else
                  Emit (Item_Section
                    (Item, (if Pairs and then Landin.IR.Is_Immutable
                              (Of_Unit, Item) then "rodata" else "data"),
                     "datum"));
                  if Landin.IR.Result_Of (Of_Unit, Item) =
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
            for Item of Landin.Backend.Smallest_First (Items, Extents) loop
               Emit (ELF_Spelling.Item_Section
                 ("data", "datum", Positive (Item)));
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
            end loop;
         end;
      end;
      if Landin.IR.Evidence_Count (Of_Unit) > 0 then
         declare
            Kept : constant Kept_Entries :=
              Kept_Evidence_Entries
                (Of_Unit,
                 (if Panic = null then Landin.IR.No_Item
                  else Landin.Panics.Handler (Panic.all)),
                 Meanings, Names);
         begin
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
                     Emit (ELF_Spelling.Item_Section
                       ("data.rel.ro.local", "evidence", Index));
                     Field_Extent
                       (Of_Unit, Landin.IR.Evidence_Represented (Of_Unit, Id),
                        Facts, Bytes, Alignment);
                     Emit (".balign " & Image (Word));
                     Put (Evidence_Symbol (Id) & ":");
                     if Alias_Next then
                        Put (Evidence_Symbol
                          (Landin.IR.Evidence_Id (Index + 1)) & ":");
                     end if;
                     Emit (Word_Directive & " " & Trimmed
                       (Landin.Targets.Byte_Count'Image (Bytes)));
                     Emit (Word_Directive & " " & Trimmed
                       (Landin.Targets.Byte_Alignment'Image (Alignment)));
                     for Entry_Index in 1 .. Landin.IR.Evidence_Entry_Count
                       (Of_Unit, Id) loop
                        --  D374: an entry nothing can project is a zero word.
                        if Is_Kept (Kept, Id, Entry_Index) then
                           Emit (Word_Directive & " " & Symbol
                             (Landin.IR.Evidence_Entry_Target (Of_Unit, Id,
                               Entry_Index)));
                        else
                           Emit (Word_Directive & " 0");
                        end if;
                     end loop;
                  end if;
               end;
            end loop;
         end;
      end if;
      if Stack_Used then
         Emit (".section .text.landin_stack,""ax"",@progbits");
         Emit (".balign 4");
         Platform_Directive (ELF_Spelling.Function_Type (Stack_Switcher));
         Put (Stack_Switcher & ":");
         declare
            procedure Native (Line : String);
            procedure Native (Line : String) is
            begin
               Put (Character'Val (9) & Line);
            end Native;
         begin
            Native ("entry a1, " & Byte_Image (Stack_Frame_Bytes));
            --  Preserve a0 before using it as the sole scratch word.
            Native ("s32i a0, a1, 0");
            Native ("s32i a1, a2, 0");
            --  Masked before EXCSAVE1 names this context: an interrupt's
            --  entry and return leave their own context's address there,
            --  and every save below reads the register back.
            Native ("rsil a0, 15");
            Native ("wsr a1, EXCSAVE1");
            Native ("s32i a0, a1, 256");
            Native ("rsr a0, PS");
            Native ("slli a0, a0, 14"); --  Clear PS.WOE.
            Native ("srli a0, a0, 14");
            Native ("wsr a0, PS");
            Native ("rsync");
            for Index in 0 .. 5 loop
               Native ("rsr a0, " & (case Index is
                 when 0 => "WINDOWBASE", when 1 => "WINDOWSTART",
                 when 2 => "SAR", when 3 => "LBEG", when 4 => "LEND",
                 when others => "LCOUNT"));
               Native ("s32i a0, a1, " & Image (260 + Index * 4));
            end loop;
            Native ("movi a0, " & Stack_Entered);
            Native ("s32i a0, a1, 284");
            Native ("movi a0, " & Stack_Limit);
            Native ("l32i a0, a0, 0");
            Native ("s32i a0, a1, 288");
            Native ("l32i a0, a1, 0");
            for Group in 0 .. 3 loop
               Native ("wsr a0, EXCSAVE2");
               Native ("rsr a0, EXCSAVE1");
               for Reg in 1 .. 15 loop
                  Native ("s32i a" & Image (Reg) & ", a0, "
                          & Image (Group * 64 + Reg * 4));
               end loop;
               Native ("rsr a1, EXCSAVE2");
               Native ("s32i a1, a0, " & Image (Group * 64));
               Native ("rotw 4");
            end loop;
            --  The saved a3 carries the resumed context's address.
            Native ("rsr a0, EXCSAVE1");
            Native ("l32i a0, a0, 12");
            Native ("wsr a0, EXCSAVE1");
            Native ("l32i a1, a0, 256");
            Native ("wsr a1, EPS2");
            Native ("l32i a1, a0, 284");
            Native ("wsr a1, EPC2");
            for Index in 0 .. 3 loop
               Native ("l32i a1, a0, " & Image (268 + Index * 4));
               Native ("wsr a1, " & (case Index is
                 when 0 => "SAR", when 1 => "LBEG", when 2 => "LEND",
                 when others => "LCOUNT"));
            end loop;
            Native ("l32i a1, a0, 288");
            Native ("movi a0, " & Stack_Limit);
            Native ("s32i a1, a0, 0");
            Native ("rsr a0, EXCSAVE1");
            Native ("l32i a1, a0, 260");
            Native ("wsr a1, WINDOWBASE");
            Native ("rsync");
            Native ("rsr a0, EXCSAVE1");
            Native ("l32i a1, a0, 264");
            Native ("wsr a1, WINDOWSTART");
            for Group in 0 .. 3 loop
               Native ("rsr a0, EXCSAVE1");
               for Reg in 1 .. 15 loop
                  Native ("l32i a" & Image (Reg) & ", a0, "
                          & Image (Group * 64 + Reg * 4));
               end loop;
               Native ("l32i a0, a0, " & Image (Group * 64));
               Native ("rotw 4");
            end loop;
            Native ("rfi 2");
            Put (Stack_Entered & ":");
            Native ("retw");
            Platform_Directive (ELF_Spelling.Size_To_Here (Stack_Switcher));
            Native (".balign 4");
            Platform_Directive (ELF_Spelling.Function_Type (Stack_Start));
            Put (Stack_Start & ":");
            Native ("mov a10, a3");
            Native ("callx8 a2");
            Native ("ill");
            Platform_Directive (ELF_Spelling.Size_To_Here (Stack_Start));
         end;
         Emit (".pushsection .bss.landin_stack_limit,""aw"",@nobits");
         Emit (".balign 4");
         Put (Stack_Limit & ":");
         Emit (".zero 4");
         Emit (".popsection");
      end if;
      --  D361's writer: Linux's write system call to descriptor 2, with the
      --  line's address and length as a call's first two arguments.  It
      --  keeps a frame record, as every routine here does, and does not
      --  return: the terminal instruction follows.
      if Reports.Count > 0 then
         if Pairs then
            raise Compiler_Defect with "firmware writes no default report";
         end if;
         Emit (".section .text.landin_trap_report,""ax"",@progbits");
         Emit (".p2align 2");
         Emit (".type " & Reporter & ", @function");
         Put (Reporter & ":");
         if Debug /= null then
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
         Emit ("mv x12, x11");
         Emit ("mv x11, x10");
         Emit ("li x10, 2");
         Emit ("li x17, 64");
         Emit ("ecall");
         Emit ("unimp");
         if Debug /= null then
            Emit (".cfi_endproc");
         end if;
         Platform_Directive (ELF_Spelling.Size_To_Here (Reporter));
         for Index in 1 .. Reports.Count loop
            Emit (".section .rodata.str1.1.landin_trap_"
                  & Trimmed (Positive'Image (Index))
                  & ",""aMS"",@progbits,1");
            Put (Report_Label (Index) & ":");
            Emit (".asciz " & Landin.Backend.Trap_Reports.Quoted
              (Reports.Text (Index)));
         end loop;
      end if;
      --  Firmware's debugging is lines, as Cortex-M0's is (D660).
      if Debug /= null and then Pairs then
         Unbounded.Append (Output, Dwarf.Line_Sections
           (Of_Unit, Meanings, Names, Facts, Debug.all,
            Local_Prefix, Symbol'Access));
      elsif Debug /= null then
         Unbounded.Append (Output,
           ELF_Debug_Sections
             (Of_Unit, Meanings, Names, Facts, Options, Debug.all,
              Local_Prefix, Symbol'Access, Cached_Frame'Access,
              Cached_Frame'Access));
      end if;
      Emit (ELF_Spelling.No_Executable_Stack);
      Assembly := Output;
   end Emit;

end Landin.Backend.Xtensa;
