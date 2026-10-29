with Ada.Containers.Generic_Sort;
with Ada.Containers.Ordered_Maps;
with Ada.Containers.Vectors;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Landin.Provenance;
with Landin.Layouts;
with Landin.Machine;
with Landin.IR.Control_Flow;
with Landin.IR.Liveness;
with Landin.IR.Shape_Measurement;
with Landin.Packed;
with Landin.Memory;
with Landin.Targets.Packed;
with Landin.Backend.Debug_Locations;
with Landin.Backend.Dwarf;
with Ada.Strings.Fixed;
with Landin.Targets.Capabilities;
with Landin.Backend.AAPCS64_ABI;
with Landin.Backend.Arm64.Platform;
with Landin.Backend.Arm64.Selection;
with Landin.Backend.ELF;
with Landin.Backend.Entry_Point;
with Landin.Backend.Trap_Reports;
with Landin.Backend.Work_Arrays;
with Landin.Types;

package body Landin.Backend.Arm64 is

   package ELF_Spelling renames Landin.Backend.ELF;
   use type Landin.Targets.Capabilities.Object_Format;
   use type Landin.Targets.Capabilities.Backend_Kind;
   use type Landin.Targets.Capabilities.Hosted_System;

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
   use type Landin.IR.Block_Id;
   use type Landin.IR.Storage_Kind;
   use type Selection.Word;
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

   --  Register numbers are DWARF's for AArch64: x0-x30 are 0-30, and
   --  v0-v31, whose low halves are d0-d31 and s0-s31, are 64-95.
   subtype Register_Number is Natural range 0 .. 95;
   No_Register : constant Natural := Natural'Last;
   --  x0-x7, which selection writes only to pass a call's arguments and
   --  take its result, to leave, and in a C routine's entry and C
   --  transport: a location may hold one where no call or assembly lies
   --  in its interval, and a parameter only the one it arrives in.
   subtype Argument_Register is Register_Number range 0 .. 7;
   --  x19-x28, which the prologue saves and every epilogue restores.
   subtype Saved_General is Register_Number range 19 .. 28;
   subtype Float_Register is Register_Number range 64 .. 95;
   --  d8-d15, whose low halves AAPCS64 preserves across a call and which
   --  no assembly block may name, saved as x19-x28 are.
   subtype Saved_Float is Float_Register range 72 .. 79;
   --  d18-d31.  Selection's float scratch is d16 and d17 and C transport's
   --  d0-d7, so only a call or assembly changes these.
   subtype Free_Float is Float_Register range 82 .. 95;

   --  No register a location may hold is one selection writes as scratch
   --  inside an operation (Landin.Backend.Arm64.Selection).
   pragma Compile_Time_Error
     (Argument_Register'Last >= Selection.General_Scratch'First
      or else Saved_General'First <= Selection.General_Scratch'Last
      or else Saved_Float'Last - Float_Register'First
        >= Selection.Float_Scratch'First
      or else Free_Float'First - Float_Register'First
        <= Selection.Float_Scratch'Last,
      "an allocatable register is selection's scratch");

   --  The Step'th register of First .. Through in the order a location
   --  is offered them: x0-x7 downward, which leaves the parameters that
   --  arrive in the lowest of them where they are longest, and every
   --  other run upward.
   function Order (First, Through, Step : Register_Number)
     return Register_Number
     is (if First in Argument_Register then Through - Step
         else First + Step);

   --  D450: whether Value is compiler.stack_switch.  Selection emits it as
   --  a call of the program's switch routine, which resumes another stack
   --  and returns with only the callee-saved registers kept, so it is a
   --  call to every location question: x0-x7 and d18-d31 are changed.
   function Is_Switch
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Value : Landin.IR.Value_Id) return Boolean;

   function Is_Switch
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Value : Landin.IR.Value_Id) return Boolean
   is
      use type Landin.Memory.Operation;
   begin
      return Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Memory_Access
        and then Landin.IR.Memory_Operation (Of_Unit, Item, Value)
          = Landin.Memory.Stack_Switch;
   end Is_Switch;

   --  A register as selection spells it at a width: x or w, d or s.
   function Name
     (Number : Register_Number;
      Size : Landin.Targets.Scalar_Size := Landin.Targets.Byte_8)
      return String
     is (if Number in Float_Register
         then (if Size = Landin.Targets.Byte_8 then "d" else "s")
           & Trimmed (Natural'Image (Number - Float_Register'First))
         else (if Size = Landin.Targets.Byte_8 then "x" else "w")
           & Trimmed (Natural'Image (Number)));

   --  [1630]: which of x19-x28 some block of the routine declares.  Each
   --  is saved in a frame home by the prologue and restored by every
   --  epilogue, which is what declaring one means.  The same set names
   --  the callee-saved registers a routine's locations hold, and the
   --  registers a plan uses at all.
   type Saved_Set is array (Register_Number) of Boolean;

   function Declared
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id) return Saved_Set;

   function Declared
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id) return Saved_Set
   is
      Result : Saved_Set := [others => False];
   begin
      for Index in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
         declare
            Value : constant Landin.IR.Value_Id := Landin.IR.Value_Id (Index);
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Assembly then
               for Which in 1 .. Landin.IR.Assembly_Operand_Count
                 (Of_Unit, Item, Value)
               loop
                  for Number in Saved_General loop
                     if Landin.IR.Register_Of
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
      Register : Natural := No_Register;
      Size : Held_Size := Landin.Targets.Byte_8;
      Address_Required : Boolean := False;
   end record;
   package Location_Vectors is new Ada.Containers.Vectors
     (Positive, Value_Location);
   --  A slot held in a register only over its live interval, in the
   --  order the routine's blocks are laid out: from the value From through
   --  the value Through, or from the entry when From is No_Value.  Both
   --  stay No_Value for a slot whose location holds everywhere.
   type Slot_Location is record
      Register : Natural := No_Register;
      From, Through : Landin.IR.Value_Id := Landin.IR.No_Value;
   end record;
   package Slot_Vectors is new Ada.Containers.Vectors
     (Positive, Slot_Location);
   --  Saves are the registers the prologue saves; Held, every register a
   --  location holds, saved or not.
   type Allocation_Plan is record
      Values : Location_Vectors.Vector;
      Slots : Slot_Vectors.Vector;
      Homes : Natural := 0;
      Saves : Saved_Set := [others => False];
      Held : Saved_Set := [others => False];
   end record;

   --  The slots placed in one register for their whole interval, by the
   --  position each interval opens at.
   package Reservations is new Ada.Containers.Ordered_Maps
     (Key_Type => Natural, Element_Type => Positive);

   --  Size and speed give no place to a constant only instruction
   --  selection reads: every use puts it straight into the register that
   --  needs it, or into the instruction itself.  A call, a C routine's
   --  leave and [1630]'s text reach a value through its frame home, so a
   --  constant one of them names is placed like any other value.
   function Lives_Nowhere
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Value : Landin.IR.Value_Id; Address_Required : Boolean) return Boolean
     is (not Address_Required
         and then Landin.IR.Op_Of (Of_Unit, Item, Value)
           in Landin.IR.Number | Landin.IR.Truth | Landin.IR.Atom);

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
      Slot_Count : constant Natural := Landin.IR.Slot_Count (Of_Unit, Item);
      Result : Allocation_Plan;
   begin
      Result.Values := Location_Vectors.To_Vector
        (Value_Location'(others => <>),
         Ada.Containers.Count_Type (Value_Count));
      Result.Slots := Slot_Vectors.To_Vector
        (Slot_Location'(others => <>),
         Ada.Containers.Count_Type (Slot_Count));
      Result.Saves := Declared (Of_Unit, Item);
      if Options.Optimize = Landin.Optimization.None then
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
      declare
         type Counts is array (Positive range <>) of Natural;
         package Count_Buffers is new Landin.Backend.Work_Arrays
           (Natural, Counts, 0);
         package Mask_Buffers is new Landin.Backend.Work_Arrays
           (Boolean, Home_Mask, False);
         Start_Data, Last_Data, Sequence_Data, Next_Release_Data,
           Next_Free_Data, Written_Data, Opening_Data :
             Count_Buffers.Buffer (Value_Count);
         Release_Data, Call_Data : Count_Buffers.Buffer (Value_Count + 1);
         Use_Data, Weight_Data, Interval_Data, Parameter_Data,
           First_Use_Data, Last_Use_Data, First_Block_Data :
             Count_Buffers.Buffer (Slot_Count);
         Eligible_Data, Across_Data : Mask_Buffers.Buffer (Slot_Count);
         Starts : Counts renames Start_Data.Data.all;
         Lasts : Counts renames Last_Data.Data.all;
         Sequence : Counts renames Sequence_Data.Data.all;
         Releases : Counts renames Release_Data.Data.all;
         Next_Release : Counts renames Next_Release_Data.Data.all;
         Next_Free : Counts renames Next_Free_Data.Data.all;
         --  For each load, the position of the next store to its slot in
         --  the same block, if any.
         Written_After : Counts renames Written_Data.Data.all;
         Uses : Counts renames Use_Data.Data.all;
         Weights : Counts renames Weight_Data.Data.all;
         --  The slots placed in a register, by weight and then as a mark:
         --  1 for one placed over its interval, 2 for one given a span in
         --  a single block by the scan.
         Interval_Slots : Counts renames Interval_Data.Data.all;
         Eligible : Home_Mask renames Eligible_Data.Data.all;
         --  Each slot's first and last load or store, by position, the
         --  block of its first, and whether another block has one too;
         --  and the slot, if any, whose store at a position opens a span
         --  of its own.
         First_Use : Counts renames First_Use_Data.Data.all;
         Last_Use : Counts renames Last_Use_Data.Data.all;
         First_Block : Counts renames First_Block_Data.Data.all;
         Across_Blocks : Home_Mask renames Across_Data.Data.all;
         Opening : Counts renames Opening_Data.Data.all;
         --  How many calls and assembly blocks lie before each position.
         Calls_Before : Counts renames Call_Data.Data.all;
         --  Each parameter slot's place among the parameters, else 0.
         Parameter_Of : Counts renames Parameter_Data.Data.all;
         Free_Homes : array (Held_Size) of Natural := [others => 0];
         Busy_Until : array (Register_Number) of Natural := [others => 0];
         Declared_Set : constant Saved_Set := Result.Saves;
         Tick : Natural := 0;
         Traffic : Natural := 0;
         Has_Assembly : Boolean := False;
         --  Whether a callee-saved register pays for its save: below this
         --  much scalar traffic a routine leaves them alone.
         Saving : Boolean := False;
         Speed : constant Boolean :=
           Options.Optimize = Landin.Optimization.Speed;
         C_Entry : constant Boolean :=
           Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
           and then Landin.IR.Signature_Uses_C_ABI
             (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item));
         Graph : constant Landin.IR.Control_Flow.Graph :=
           Landin.IR.Control_Flow.Make (Of_Unit, Item);
         Depth : constant Landin.IR.Liveness.Count_Vectors.Vector :=
           (if Speed then Landin.IR.Liveness.Loop_Depths (Graph)
            else Landin.IR.Liveness.Count_Vectors.Empty_Vector);
         Spans : constant Landin.IR.Liveness.Interval_Vectors.Vector :=
           (if Speed
            then Landin.IR.Liveness.Slot_Intervals (Of_Unit, Item, Graph)
            else Landin.IR.Liveness.Interval_Vectors.Empty_Vector);
         --  Registers x0-x7, x19-x24, d8-d15 and d18-d31 may hold slots,
         --  each over a run of disjoint intervals, and the next interval
         --  each has still to open.
         subtype Slot_General is Saved_General range 19 .. 24;
         Placed : array (Register_Number) of Reservations.Map;
         Upcoming : array (Register_Number) of Reservations.Cursor :=
           [others => Reservations.No_Element];

         procedure Reach
           (Place : Landin.IR.Storage; Value : Landin.IR.Value_Id);
         procedure Count_Use
           (Of_Slot : Landin.IR.Slot_Id; Value : Landin.IR.Value_Id);
         procedure Place_Intervals;
         procedure Open (Position : Natural);
         function Clear (Number, Position, Last : Natural) return Boolean;
         function Read_In_Place (Value : Positive) return Natural;
         function Released_By (Value : Positive; Position : Natural)
            return Natural;
         function Stored_Into (Value : Positive; Position : Natural)
            return Natural;

         --  Whether a call or assembly block lies at some position from
         --  First through Last: either may change x0-x7 and d18-d31.
         function Calls_In (First, Last : Natural) return Boolean is
           (Last >= First
            and then Calls_Before (Last + 1) > Calls_Before (First));

         --  The last position a slot placed in a register holds it.
         function Holds_Through (Slot : Positive) return Natural is
           (if Interval_Slots (Slot) = 2 then Last_Use (Slot)
            else Spans (Slot).Last);

         --  An operation reaching storage needs a frame slot's cell, and
         --  reads only the address an address slot holds.
         procedure Reach
           (Place : Landin.IR.Storage; Value : Landin.IR.Value_Id) is
         begin
            case Place.Kind is
               when Landin.IR.Frame_Slot =>
                  Eligible (Positive (Place.Slot)) := False;
               when Landin.IR.Runtime_Address =>
                  Count_Use (Place.Address, Value);
               when Landin.IR.Module_Datum => null;
            end case;
         end Reach;

         --  One load or store of a slot, or read of the address it holds,
         --  weighted eight times for each loop around it, up to four.
         procedure Count_Use
           (Of_Slot : Landin.IR.Slot_Id; Value : Landin.IR.Value_Id)
         is
            Slot : constant Positive := Positive (Of_Slot);
            At_Position : constant Positive := Starts (Positive (Value));
            Block : constant Positive :=
              Positive (Landin.IR.Block_Of (Of_Unit, Item, Value));
            Step : constant Natural := 8 ** Natural'Min (Depth (Block), 4);
         begin
            if First_Use (Slot) = 0 or else At_Position < First_Use (Slot) then
               First_Use (Slot) := At_Position;
            end if;
            Last_Use (Slot) := Natural'Max (Last_Use (Slot), At_Position);
            if First_Block (Slot) = 0 then
               First_Block (Slot) := Block;
            elsif First_Block (Slot) /= Block then
               Across_Blocks (Slot) := True;
            end if;
            Uses (Slot) := Uses (Slot) + 1;
            Weights (Slot) :=
              (if Weights (Slot) > Natural'Last - Step
               then Natural'Last else Weights (Slot) + Step);
         end Count_Use;

         --  Each eligible slot read or written twice may hold a register
         --  over its whole interval: the heaviest slot first, ties to the
         --  earlier, each to the first register whose intervals so far it
         --  does not meet.  An interval no call or assembly lies in takes
         --  x0-x7 or d18-d31 first, which cost no save, a parameter only
         --  the argument register it arrives in, which its entry then
         --  leaves alone.  Where saving pays, x19-x24 and d8-d15 follow.
         --  The rest of every register is the values'.
         procedure Place_Intervals is
            Count : Natural := 0;

            procedure Mark (Number : Register_Number);
            procedure Mark (Number : Register_Number) is
            begin
               for Cursor in Placed (Number).Iterate loop
                  Interval_Slots (Reservations.Element (Cursor)) := 1;
               end loop;
               Upcoming (Number) := Placed (Number).First;
            end Mark;

            function Before (Left, Right : Positive) return Boolean is
              (Weights (Interval_Slots (Left))
                 > Weights (Interval_Slots (Right))
               or else
                 (Weights (Interval_Slots (Left))
                    = Weights (Interval_Slots (Right))
                  and then Interval_Slots (Left) < Interval_Slots (Right)));

            procedure Swap (Left, Right : Positive);
            procedure Swap (Left, Right : Positive) is
               Held : constant Natural := Interval_Slots (Left);
            begin
               Interval_Slots (Left) := Interval_Slots (Right);
               Interval_Slots (Right) := Held;
            end Swap;

            procedure Sort is new Ada.Containers.Generic_Sort
              (Positive, Before, Swap);

            --  The slot at Position in weight order, given the first
            --  register it may take, or only a parameter's own one.
            procedure Place (Position : Positive; Own_Only : Boolean);
            procedure Place (Position : Positive; Own_Only : Boolean) is
               Index : constant Positive := Interval_Slots (Position);
               Span : constant Landin.IR.Liveness.Interval := Spans (Index);
               Slot : Slot_Location renames Result.Slots (Index);
               Float : constant Boolean := Landin.IR.Type_Of
                 (Of_Unit, Item, Landin.IR.Slot_Id (Index))
                   in Landin.Types.Float_Name;
               Free : constant Boolean := not Has_Assembly
                 and then not Calls_In
                   (Natural'Max (Span.First, 1), Span.Last);

               procedure Try (Number : Register_Number);
               procedure Try (Number : Register_Number) is
                  Below : constant Reservations.Cursor :=
                    Placed (Number).Floor (Span.Last);
               begin
                  if Slot.Register = No_Register
                    and then not Declared_Set (Number)
                    and then
                      (not Reservations.Has_Element (Below)
                       or else Spans (Reservations.Element (Below)).Last
                         < Span.First)
                  then
                     Placed (Number).Insert (Span.First, Index);
                     Slot.Register := Number;
                     Result.Held (Number) := True;
                     if Number in Saved_General | Saved_Float then
                        Result.Saves (Number) := True;
                     end if;
                  end if;
               end Try;
            begin
               if Own_Only then
                  if Free and then not Float
                    and then Parameter_Of (Index) - 1 in Argument_Register
                  then
                     Try (Parameter_Of (Index) - 1);
                  end if;
                  return;
               end if;
               if Float then
                  if Free then
                     for Number in Free_Float loop
                        Try (Number);
                     end loop;
                  end if;
                  if Saving then
                     for Number in Saved_Float loop
                        Try (Number);
                     end loop;
                  end if;
               else
                  if Free and then Parameter_Of (Index) = 0 then
                     for Number in reverse Argument_Register loop
                        Try (Number);
                     end loop;
                  end if;
                  if Saving then
                     for Number in Slot_General loop
                        Try (Number);
                     end loop;
                  end if;
               end if;
               if Slot.Register /= No_Register
                 and then (Span.First > 0 or else Span.Last < Value_Count)
               then
                  Slot.From :=
                    (if Span.First = 0 then Landin.IR.No_Value
                     else Landin.IR.Value_Id (Sequence (Span.First)));
                  Slot.Through := Landin.IR.Value_Id (Sequence (Span.Last));
               end if;
            end Place;
         begin
            for Index in 1 .. Slot_Count loop
               if Eligible (Index) and then Uses (Index) >= 2
                 and then not Landin.IR.Liveness.Is_Empty (Spans (Index))
               then
                  Count := Count + 1;
                  Interval_Slots (Count) := Index;
               end if;
            end loop;
            Sort (1, Count);
            --  A parameter's own argument register first, which no other
            --  slot may then take from it; then every slot by weight.
            for Position in 1 .. Count loop
               Place (Position, Own_Only => True);
            end loop;
            for Position in 1 .. Count loop
               Place (Position, Own_Only => False);
            end loop;
            Interval_Slots := [others => 0];
            for Number in Argument_Register loop
               Mark (Number);
            end loop;
            for Number in Slot_General loop
               Mark (Number);
            end loop;
            for Number in Float_Register loop
               Mark (Number);
            end loop;
         end Place_Intervals;

         --  The placed intervals opening at Position take their registers
         --  through their last position.
         procedure Open (Position : Natural) is
            procedure Open_One (Number : Register_Number);
            procedure Open_One (Number : Register_Number) is
            begin
               if Reservations.Has_Element (Upcoming (Number))
                 and then Reservations.Key (Upcoming (Number)) = Position
               then
                  Busy_Until (Number) := Spans
                    (Reservations.Element (Upcoming (Number))).Last;
                  Reservations.Next (Upcoming (Number));
               end if;
            end Open_One;
         begin
            for Number in Argument_Register loop
               Open_One (Number);
            end loop;
            for Number in Slot_General loop
               Open_One (Number);
            end loop;
            for Number in Saved_Float loop
               Open_One (Number);
            end loop;
            for Number in Free_Float loop
               Open_One (Number);
            end loop;
         end Open;

         --  Whether a value from Position through Last may take register
         --  Number: nothing holds it now, and the next slot interval placed
         --  in it opens after Last.
         function Clear (Number, Position, Last : Natural) return Boolean is
           (not Declared_Set (Number)
            and then Busy_Until (Number) < Position
            and then
              (not Reservations.Has_Element (Upcoming (Number))
               or else Last < Reservations.Key (Upcoming (Number))));

         --  The register of the slot a load reads, when the loaded value
         --  dies before the slot is next stored and while the slot still
         --  holds that register: nothing writes it in between, so the
         --  value may be that register.  Else No_Register.
         function Read_In_Place (Value : Positive) return Natural is
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, Landin.IR.Value_Id (Value))
              /= Landin.IR.Load
            then
               return No_Register;
            end if;
            declare
               Slot : constant Positive := Positive (Landin.IR.Slot_Of
                 (Of_Unit, Item, Landin.IR.Value_Id (Value)));
            begin
               if Interval_Slots (Slot) /= 0
                 and then Lasts (Value) <= Written_After (Value)
                 and then Lasts (Value) <= Holds_Through (Slot)
               then
                  return Result.Slots (Slot).Register;
               end if;
            end;
            return No_Register;
         end Read_In_Place;

         --  The register of the slot a load at Position reads for the last
         --  time, which the loaded value may go on holding while no
         --  other interval placed there opens; else No_Register.
         function Released_By (Value : Positive; Position : Natural)
            return Natural is
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, Landin.IR.Value_Id (Value))
              /= Landin.IR.Load
            then
               return No_Register;
            end if;
            declare
               Slot : constant Positive := Positive (Landin.IR.Slot_Of
                 (Of_Unit, Item, Landin.IR.Value_Id (Value)));
               Number : constant Natural := Result.Slots (Slot).Register;
            begin
               if Interval_Slots (Slot) /= 0
                 and then Holds_Through (Slot) = Position
                 and then Busy_Until (Number) <= Position
                 and then
                   (not Reservations.Has_Element (Upcoming (Number))
                    or else Lasts (Value)
                      < Reservations.Key (Upcoming (Number)))
               then
                  return Number;
               end if;
            end;
            return No_Register;
         end Released_By;

         --  The register of the slot whose placed interval opens at the
         --  store that last uses a value, which the value may hold from
         --  Position on, so that the store moves nothing; else
         --  No_Register.
         function Stored_Into (Value : Positive; Position : Natural)
            return Natural
         is
            User : constant Landin.IR.Value_Id :=
              Landin.IR.Value_Id (Sequence (Lasts (Value)));
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, User) /= Landin.IR.Store then
               return No_Register;
            end if;
            declare
               Slot : constant Positive :=
                 Positive (Landin.IR.Slot_Of (Of_Unit, Item, User));
               Number : constant Natural := Result.Slots (Slot).Register;
            begin
               if Interval_Slots (Slot) /= 0
                 and then Spans (Slot).First = Lasts (Value)
                 and then Busy_Until (Number) < Position
                 and then Reservations.Has_Element (Upcoming (Number))
                 and then Reservations.Key (Upcoming (Number))
                   = Lasts (Value)
                 and then Reservations.Element (Upcoming (Number)) = Slot
               then
                  return Number;
               end if;
            end;
            return No_Register;
         end Stored_Into;

         --  Whether a value from Position through Last may hold register
         --  Number as far as calls go.  A float may hold d18-d31 when no
         --  call lies strictly inside its interval, since one at its last
         --  position reads it first.  An integer may hold x0-x7 only when
         --  no call lies after its definition at all: a call's arguments
         --  overwrite them one by one.  A callee-saved register must pay
         --  for its save.
         function Fits (Number, Position, Last : Natural) return Boolean is
           (if Number in Argument_Register
            then not Has_Assembly and then not Calls_In (Position + 1, Last)
            elsif Number in Free_Float
            then not Has_Assembly
              and then not Calls_In (Position + 1, Last - 1)
            else Saving);

         --  The span the store at Position that opens a slot's gives it,
         --  through the slot's last use: the stored value's own register
         --  when the value dies there or the slot is never read, so the
         --  store moves nothing; else the first clear one that fits.
         procedure Open_Span (Index : Positive; Position : Natural);
         procedure Open_Span (Index : Positive; Position : Natural) is
            Slot : Slot_Location renames Result.Slots (Index);
            Last : constant Natural := Last_Use (Index);
            Stored : constant Natural := Result.Values (Positive
              (Landin.IR.Nth_Operand
                 (Of_Unit, Item, Landin.IR.Value_Id (Sequence (Position)),
                  1))).Register;

            procedure Take (Number : Register_Number);
            procedure Take (Number : Register_Number) is
            begin
               if Slot.Register = No_Register
                 and then Fits (Number, Position, Last)
               then
                  Slot.Register := Number;
                  Busy_Until (Number) :=
                    Natural'Max (Busy_Until (Number), Last);
                  Result.Held (Number) := True;
                  if Number in Saved_General | Saved_Float then
                     Result.Saves (Number) := True;
                  end if;
               end if;
            end Take;

            procedure Take_Clear (First, Through : Register_Number);
            procedure Take_Clear (First, Through : Register_Number) is
            begin
               for Step in 0 .. Through - First loop
                  if Clear (Order (First, Through, Step), Position, Last)
                  then
                     Take (Order (First, Through, Step));
                  end if;
               end loop;
            end Take_Clear;
         begin
            if Stored /= No_Register and then not Declared_Set (Stored)
              and then (Busy_Until (Stored) = Position or else Last = Position)
              and then
                (not Reservations.Has_Element (Upcoming (Stored))
                 or else Last < Reservations.Key (Upcoming (Stored)))
            then
               Take (Stored);
            end if;
            if Landin.IR.Type_Of (Of_Unit, Item, Landin.IR.Slot_Id (Index))
              in Landin.Types.Float_Name
            then
               Take_Clear (Free_Float'First, Free_Float'Last);
               Take_Clear (Saved_Float'First, Saved_Float'Last);
            else
               Take_Clear (Argument_Register'First, Argument_Register'Last);
               Take_Clear (Saved_General'First, Saved_General'Last);
            end if;
            if Slot.Register /= No_Register then
               Interval_Slots (Index) := 2;
               Slot.From := Landin.IR.Value_Id (Sequence (Position));
               Slot.Through := Landin.IR.Value_Id (Sequence (Last));
            end if;
         end Open_Span;
      begin
         for Block_Index in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            declare
               Block : constant Landin.IR.Block_Id :=
                 Landin.IR.Block_Id (Block_Index);
            begin
               for Position in 1 .. Landin.IR.Length
                 (Of_Unit, Item, Block)
               loop
                  declare
                     Index : constant Positive := Positive
                       (Landin.IR.Nth_Value
                          (Of_Unit, Item, Block, Position));
                  begin
                     Tick := Tick + 1;
                     Sequence (Tick) := Index;
                     Starts (Index) := Tick;
                     Lasts (Index) := Tick;
                     Calls_Before (Tick + 1) := Calls_Before (Tick)
                       + (if Landin.IR.Op_Of
                               (Of_Unit, Item, Landin.IR.Value_Id (Index))
                             in Landin.IR.Call | Landin.IR.Indirect_Call
                              | Landin.IR.Assembly
                            or else Is_Switch
                              (Of_Unit, Item, Landin.IR.Value_Id (Index))
                          then 1 else 0);
                  end;
               end loop;
            end;
         end loop;
         for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
            Parameter_Of (Positive
              (Landin.IR.Nth_Parameter (Of_Unit, Item, Index))) := Index;
         end loop;
         --  Speed may hold a scalar slot in a register.  A C entry's
         --  parameters and result slot are reached by address, as is every
         --  slot a frame storage operand names.  A Landin routine's result
         --  slot is read by nothing but the leave's own operand.
         if Speed then
            for Index in 1 .. Slot_Count loop
               declare
                  Slot : constant Landin.IR.Slot_Id :=
                    Landin.IR.Slot_Id (Index);
               begin
                  Eligible (Index) :=
                    not Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                    and then not Landin.IR.Is_Array (Of_Unit, Item, Slot);
               end;
            end loop;
            if C_Entry then
               for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item)
               loop
                  Eligible (Positive
                    (Landin.IR.Nth_Parameter (Of_Unit, Item, Index))) :=
                      False;
               end loop;
               if Landin.IR.Result_Slot (Of_Unit, Item) /= Landin.IR.No_Slot
               then
                  Eligible (Positive
                    (Landin.IR.Result_Slot (Of_Unit, Item))) := False;
               end if;
            end if;
            for Index in 1 .. Landin.IR.Source_Alias_Count (Of_Unit, Item)
            loop
               declare
                  Place : constant Landin.IR.Storage :=
                    Landin.IR.Nth_Source_Alias (Of_Unit, Item, Index).Place;
               begin
                  --  An alias is described through its storage throughout.
                  case Place.Kind is
                     when Landin.IR.Frame_Slot =>
                        Eligible (Positive (Place.Slot)) := False;
                     when Landin.IR.Runtime_Address =>
                        Eligible (Positive (Place.Address)) := False;
                     when Landin.IR.Module_Datum => null;
                  end case;
               end;
            end loop;
         end if;
         for Index in 1 .. Value_Count loop
            declare
               Value : constant Landin.IR.Value_Id := Landin.IR.Value_Id
                 (Index);
               Op : constant Landin.IR.Opcode := Landin.IR.Op_Of
                 (Of_Unit, Item, Value);
               --  Assembly reads its inputs, and C transport its scalar
               --  arguments and result, through their frame homes.  A
               --  native call moves each from wherever it is.
               Addressed : constant Boolean :=
                 Op = Landin.IR.Assembly
                 or else
                   (Op in Landin.IR.Call | Landin.IR.Indirect_Call
                    and then Landin.IR.Signature_Uses_C_ABI
                      (Of_Unit,
                       (if Op = Landin.IR.Indirect_Call
                        then Landin.IR.Call_Signature (Of_Unit, Item, Value)
                        else Landin.IR.Signature_Of
                          (Of_Unit,
                           Landin.IR.Callee_Of (Of_Unit, Item, Value)))));
            begin
               if Landin.IR.Result_Of (Of_Unit, Item, Value) in
                 Landin.Types.Scalar_Name
               then
                  Traffic := Traffic + 1;
               end if;
               for Position in 1 .. Landin.IR.Operand_Count
                 (Of_Unit, Item, Value)
               loop
                  declare
                     Operand : constant Positive := Positive
                       (Landin.IR.Nth_Operand
                          (Of_Unit, Item, Value, Position));
                  begin
                     Lasts (Operand) := Natural'Max
                       (Lasts (Operand), Starts (Index));
                     Traffic := Traffic + 1;
                     if Addressed then
                        Result.Values (Operand).Address_Required := True;
                     end if;
                  end;
               end loop;
               if Op = Landin.IR.Evidence_Self then
                  declare
                     Projection : constant Landin.IR.Value_Id :=
                       Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1);
                     Receiver : constant Positive := Positive
                       (Landin.IR.Nth_Operand
                          (Of_Unit, Item, Projection, 1));
                  begin
                     Lasts (Receiver) := Natural'Max
                       (Lasts (Receiver), Starts (Index));
                  end;
               end if;
               if Addressed then
                  Result.Values (Index).Address_Required := True;
               elsif Op = Landin.IR.Leave
                 and then Landin.IR.Signature_Of (Of_Unit, Item)
                   /= Landin.IR.No_Signature
                 and then Landin.IR.Signature_Uses_C_ABI
                   (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
               then
                  for Position in 1 .. Landin.IR.Operand_Count
                    (Of_Unit, Item, Value)
                  loop
                     Result.Values (Positive (Landin.IR.Nth_Operand
                       (Of_Unit, Item, Value, Position)))
                         .Address_Required := True;
                  end loop;
               end if;
               if Speed then
                  case Op is
                     when Landin.IR.Load | Landin.IR.Store =>
                        Count_Use
                          (Landin.IR.Slot_Of (Of_Unit, Item, Value), Value);
                     when Landin.IR.Load_Field | Landin.IR.Store_Field
                        | Landin.IR.Load_Element
                        | Landin.IR.Store_Element =>
                        if Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value)
                        then
                           Reach
                             ((if Landin.IR.Is_Address
                                 (Of_Unit, Item,
                                  Landin.IR.Slot_Of (Of_Unit, Item, Value))
                               then (Kind => Landin.IR.Runtime_Address,
                                     Address => Landin.IR.Slot_Of
                                       (Of_Unit, Item, Value))
                               else (Kind => Landin.IR.Frame_Slot,
                                     Slot => Landin.IR.Slot_Of
                                       (Of_Unit, Item, Value))),
                              Value);
                        end if;
                     when Landin.IR.Copy_Array | Landin.IR.Copy_Variant =>
                        Reach (Landin.IR.Source_Of (Of_Unit, Item, Value),
                               Value);
                        Reach (Landin.IR.Destination_Of
                                 (Of_Unit, Item, Value), Value);
                     when Landin.IR.Load_Variant_Tag
                        | Landin.IR.Load_Variant_Field =>
                        Reach (Landin.IR.Source_Of (Of_Unit, Item, Value),
                               Value);
                     when Landin.IR.Storage_Address
                        | Landin.IR.Place_Address
                        | Landin.IR.Clear_Array | Landin.IR.Fill_Array
                        | Landin.IR.Select_Variant
                        | Landin.IR.Store_Variant_Field =>
                        Reach (Landin.IR.Destination_Of
                                 (Of_Unit, Item, Value), Value);
                     when Landin.IR.Call | Landin.IR.Indirect_Call =>
                        if Landin.IR.Failure_Slot_Of (Of_Unit, Item, Value)
                          /= Landin.IR.No_Slot
                        then
                           Eligible (Positive (Landin.IR.Failure_Slot_Of
                             (Of_Unit, Item, Value))) := False;
                        end if;
                     when Landin.IR.Assembly =>
                        --  Assembly text may name any register.
                        Has_Assembly := True;
                     when others => null;
                  end case;
               end if;
            end;
         end loop;
         Saving := Speed and then Traffic >= 12;
         if Speed and then not Has_Assembly then
            declare
               Stamp_Data, Next_Data : Count_Buffers.Buffer (Slot_Count);
               Stamp : Counts renames Stamp_Data.Data.all;
               Next_Store : Counts renames Next_Data.Data.all;
            begin
               for Position in reverse 1 .. Value_Count loop
                  declare
                     Value : constant Landin.IR.Value_Id :=
                       Landin.IR.Value_Id (Sequence (Position));
                     Block : constant Positive := Positive
                       (Landin.IR.Block_Of (Of_Unit, Item, Value));
                     Op : constant Landin.IR.Opcode :=
                       Landin.IR.Op_Of (Of_Unit, Item, Value);
                  begin
                     if Op in Landin.IR.Load | Landin.IR.Store then
                        declare
                           Slot : constant Positive := Positive
                             (Landin.IR.Slot_Of (Of_Unit, Item, Value));
                        begin
                           if Op = Landin.IR.Store then
                              Stamp (Slot) := Block;
                              Next_Store (Slot) := Position;
                           else
                              Written_After (Positive (Value)) :=
                                (if Stamp (Slot) = Block
                                 then Next_Store (Slot) else Natural'Last);
                           end if;
                        end;
                     end if;
                  end;
               end loop;
            end;
            --  A parameter is written at entry too, and a Landin routine's
            --  result slot read at its leave.
            for Index in 1 .. Slot_Count loop
               if Parameter_Of (Index) /= 0 then
                  Uses (Index) := Uses (Index) + 1;
               end if;
            end loop;
            if not C_Entry
              and then Landin.IR.Result_Slot (Of_Unit, Item)
                /= Landin.IR.No_Slot
            then
               Uses (Positive (Landin.IR.Result_Slot (Of_Unit, Item))) :=
                 Uses (Positive (Landin.IR.Result_Slot (Of_Unit, Item))) + 1;
            end if;
            Place_Intervals;
            --  A slot loaded and stored in one block only, which stores it
            --  before reading it, and not placed over its interval, is
            --  dead before that store and after its last use there.  Like
            --  a value it needs a register only in between, which the scan
            --  gives it at the store when it can.
            for Index in 1 .. Slot_Count loop
               if Eligible (Index) and then Interval_Slots (Index) = 0
                 and then not Across_Blocks (Index)
                 and then Parameter_Of (Index) = 0
                 and then First_Use (Index) /= 0
                 and then Landin.IR.Op_Of
                   (Of_Unit, Item,
                    Landin.IR.Value_Id (Sequence (First_Use (Index))))
                   = Landin.IR.Store
               then
                  Opening (First_Use (Index)) := Index;
               end if;
            end loop;
         end if;
         Open (0);
         for Position in 1 .. Value_Count loop
            declare
               Index : constant Positive := Positive (Sequence (Position));
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
               Open (Position);
               if Opening (Position) /= 0 then
                  Open_Span (Opening (Position), Position);
               end if;
               if Kind in Landin.Types.Scalar_Name
                 and then not Lives_Nowhere
                   (Of_Unit, Item, Landin.IR.Value_Id (Index),
                    Result.Values (Index).Address_Required)
               then
                  declare
                     Place : Value_Location renames Result.Values (Index);
                     Last : constant Natural := Lasts (Index);

                     --  Place takes register Number from Position through
                     --  Last, if it has none yet and Number fits there.
                     procedure Share (Number : Natural);
                     procedure Share (Number : Natural) is
                     begin
                        if Place.Register = No_Register
                          and then Number /= No_Register
                          and then Fits (Number, Position, Last)
                        then
                           Place.Register := Number;
                           Busy_Until (Number) :=
                             Natural'Max (Busy_Until (Number), Last);
                           Result.Held (Number) := True;
                           if Number in Saved_General | Saved_Float then
                              Result.Saves (Number) := True;
                           end if;
                        end if;
                     end Share;

                     --  The first register of First .. Through, in Order,
                     --  that is clear from Position through Last, if Place
                     --  has none yet.
                     procedure Take (First, Through : Register_Number);
                     procedure Take (First, Through : Register_Number) is
                     begin
                        for Step in 0 .. Through - First loop
                           exit when Place.Register /= No_Register;
                           if Clear (Order (First, Through, Step), Position,
                                     Last)
                           then
                              Share (Order (First, Through, Step));
                           end if;
                        end loop;
                     end Take;
                  begin
                     Place.Size := Size_Of (Kind, Facts);
                     if Speed and then not Place.Address_Required
                       and then Last > Position
                     then
                        Share (Read_In_Place (Index));
                        Share (Released_By (Index, Position));
                        Share (Stored_Into (Index, Position));
                        if Kind in Landin.Types.Float_Name then
                           Take (Free_Float'First, Free_Float'Last);
                           Take (Saved_Float'First, Saved_Float'Last);
                        else
                           Take (Argument_Register'First,
                                 Argument_Register'Last);
                           Take (Saved_General'First, Saved_General'Last);
                        end if;
                     end if;
                     if Place.Register = No_Register then
                        if Free_Homes (Place.Size) /= 0 then
                           Place.Home := Free_Homes (Place.Size);
                           Free_Homes (Place.Size) := Next_Free (Place.Home);
                        else
                           Result.Homes := Result.Homes + 1;
                           Place.Home := Result.Homes;
                        end if;
                        Next_Release (Index) :=
                          Releases (Lasts (Index) + 1);
                        Releases (Lasts (Index) + 1) := Index;
                     end if;
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
         for Index in 1 .. Natural (Plan.Slots.Length) loop
            Slots_Data.Data (Index) :=
              Plan.Slots (Index).Register = No_Register;
         end loop;
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

   function Debug_Frame
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts; Plan : Allocation_Plan;
      Options : Landin.Optimization.Options) return Frame;

   function Debug_Frame
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts; Plan : Allocation_Plan;
      Options : Landin.Optimization.Options) return Frame
   is
   begin
      return Frame_For (Of_Unit, Item, Facts, Options, Plan, 16#7fff_ffff#);
   end Debug_Frame;

   --  A slot in a general register is that register, or the address held
   --  there for an indirect binding; DWARF numbers x0-x30 as 0-30.  A
   --  float slot in a d register is that register, numbered past 31 and
   --  so named with DW_OP_regx.
   function Debug_Slot
     (Plan : Allocation_Plan; Layout : Frame; Slot : Landin.IR.Slot_Id;
      Indirect, Address_Only : Boolean) return String;

   function Debug_Slot
     (Plan : Allocation_Plan; Layout : Frame; Slot : Landin.IR.Slot_Id;
      Indirect, Address_Only : Boolean) return String
   is
      HT : constant Character := Character'Val (9);
      LF : constant Character := Character'Val (10);
      Register : constant Natural := Plan.Slots (Positive (Slot)).Register;
   begin
      if Register in Float_Register then
         return (if Address_Only then ""
                 else HT & ".byte 0x90" & LF & HT & ".uleb128 "
                   & Trimmed (Natural'Image (Register)) & LF);
      elsif Register /= No_Register then
         if Indirect or else not Address_Only then
            return HT & ".byte " & Trimmed (Natural'Image
              ((if Indirect then 16#70# else 16#50#) + Register)) & LF
              & (if Indirect then HT & ".sleb128 0" & LF else "");
         end if;
         return "";
      end if;
      return HT & ".byte 0x91" & LF & HT & ".sleb128 -"
        & Trimmed (Landin.Targets.Byte_Count'Image
            (Slot_Offset (Layout, Slot))) & LF
        & (if Indirect then HT & ".byte 0x06" & LF else "");
   end Debug_Slot;

   --  A slot the plan holds in a register only over an interval of the
   --  routine, in the order its blocks are laid out, is there nowhere
   --  else: the register belongs to other locations before and after.
   --  An interval opening at a store excludes that store's own
   --  instruction, which precedes the write; one open from the entry
   --  includes everything before its last position.  The register still
   --  holds the slot's value after that position, through the rest of its
   --  block, until a value writes it: that value is the Overwriter, and
   --  the encoder describes the slot at its first address too.  A call
   --  writes x0-x7 and d18-d31, which it does not preserve, and a leave
   --  or failure x0-x7.  The next block may be entered from elsewhere,
   --  where the register is already another location's.
   procedure Narrow
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Plan : Allocation_Plan; Slot : Landin.IR.Slot_Id;
      Live : in out Landin.Backend.Debug_Locations.Flags.Vector;
      Overwriter : in out Landin.IR.Value_Id);

   procedure Narrow
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Plan : Allocation_Plan; Slot : Landin.IR.Slot_Id;
      Live : in out Landin.Backend.Debug_Locations.Flags.Vector;
      Overwriter : in out Landin.IR.Value_Id)
   is
      Place : constant Slot_Location := Plan.Slots (Positive (Slot));
      Opened : Boolean := Place.From = Landin.IR.No_Value;
      Closed : Boolean := False;
      --  Whether the interval has closed in this block and nothing has
      --  written the register since.
      Holding : Boolean := False;

      --  Whether Value writes the slot's register: as its own location,
      --  by storing to another slot held there, as assembly, which may
      --  name any register, or as a call or exit.
      function Writes (Value : Landin.IR.Value_Id) return Boolean is
        (Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Assembly
         or else
           (Place.Register in Argument_Register | Free_Float
            and then (Landin.IR.Op_Of (Of_Unit, Item, Value)
                        in Landin.IR.Call | Landin.IR.Indirect_Call
                      or else Is_Switch (Of_Unit, Item, Value)))
         or else
           (Place.Register in Argument_Register
            and then Landin.IR.Op_Of (Of_Unit, Item, Value)
              in Landin.IR.Leave | Landin.IR.Fail)
         or else Plan.Values (Positive (Value)).Register = Place.Register
         or else (Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Store
                  and then Plan.Slots (Positive (Landin.IR.Slot_Of
                    (Of_Unit, Item, Value))).Register = Place.Register));
   begin
      if Place.From = Landin.IR.No_Value
        and then Place.Through = Landin.IR.No_Value
      then
         return;
      end if;
      for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
         Holding := False;
         for Position in 1 .. Landin.IR.Length
           (Of_Unit, Item, Landin.IR.Block_Id (Block))
         loop
            declare
               Value : constant Landin.IR.Value_Id := Landin.IR.Nth_Value
                 (Of_Unit, Item, Landin.IR.Block_Id (Block), Position);
            begin
               if Opened and then not Closed then
                  Closed := Value = Place.Through;
                  Holding := Closed;
               elsif Holding and then not Writes (Value) then
                  null;
               else
                  if Holding and then Live (Positive (Value)) then
                     Overwriter := Value;
                  end if;
                  Holding := False;
                  Live (Positive (Value)) := False;
                  if Value = Place.From then
                     Opened := True;
                     Closed := Place.From = Place.Through;
                     Holding := Closed;
                  end if;
               end if;
            end;
         end loop;
      end loop;
   end Narrow;

   type Debug_Plan_Access is access all Allocation_Plan;
   type Debug_Frame_Access is access all Frame;
   --  One encoder, instantiated once per object format, since the section
   --  names and the compilation unit's addressing are generic constants.
   function Mach_O_Debug_Sections is new Landin.Backend.Dwarf.Sections
     (Allocation_Plan, Debug_Plan_Access, Debug_Frame_Access,
      Allocate, Debug_Frame, Debug_Slot, 29, True, Narrow => Narrow);

   function ELF_Debug_Sections is new Landin.Backend.Dwarf.Sections
     (Allocation_Plan, Debug_Plan_Access, Debug_Frame_Access,
      Allocate, Debug_Frame, Debug_Slot, 29, False, Narrow => Narrow);

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
         if AAPCS64_ABI.Signature_Plan
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
                        Plan : constant AAPCS64_ABI.Plan :=
                          AAPCS64_ABI.Call_Plan
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
        Landin.Targets.Levels.Default_Level (Landin.Targets.Darwin_Arm64))
   is
      --  D255: Armv8.1-A's LSE does a read-modify-write in one instruction
      --  rather than an exclusive-monitor retry loop.
      Has_LSE : constant Boolean :=
        Landin.Targets.Levels.Has (Level, Landin.Targets.Levels.Lse);
      --  Size and speed choose shorter forms the reference profile, whose
      --  output stays as it is, does not.
      Reference_Profile : constant Boolean :=
        Options.Optimize = Landin.Optimization.None;
      --  Instruction selection is one; the object format and the hosted
      --  system decide only the text around it.
      Format : constant Platform.Arm64_Format :=
        Landin.Targets.Capabilities.Object_Format_Of (Facts);
      type Line_Entry is record
         Text : Unbounded.Unbounded_String;
         Offset : Long_Long_Integer;
         Segment : Natural;
      end record;
      package Line_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Line_Entry);
      Lines : Line_Vectors.Vector;
      type Label_Position is record
         Offset : Long_Long_Integer;
         Segment : Natural;
      end record;
      package Label_Maps is new Ada.Containers.Indefinite_Hashed_Maps
        (Key_Type => String, Element_Type => Label_Position,
         Hash => Ada.Strings.Hash, Equivalent_Keys => "=");
      Labels : Label_Maps.Map;
      type Branch_Entry is record
         First : Positive;
         Target : Unbounded.Unbounded_String;
         Direct : Unbounded.Unbounded_String;
         Reach : Long_Long_Integer;
      end record;
      package Branch_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Branch_Entry);
      Branches : Branch_Vectors.Vector;
      Preamble_Text : Unbounded.Unbounded_String;
      Preamble_After : Natural := 0;
      Debug_Text : Unbounded.Unbounded_String;
      Offset : Long_Long_Integer := 0;
      Segment : Natural := 0;
      --  Dense nonzero u32 atom codes, in declaration-identity order; zero
      --  stays available for the successful half of the failing-call
      --  carrier.
      Atoms_Ranked : constant Atom_Codes := Ranked (Of_Unit);
      Serial : Natural := 0;

      procedure Put (Line : String; Known : Boolean := False);
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
        (Offset : Landin.Targets.Byte_Count; Register : String := "x15");
      procedure Base_Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String;
         Offset : Landin.Targets.Byte_Count);
      procedure Reserve (Bytes : Landin.Targets.Byte_Count);
      procedure Copy_Bytes (Bytes : Landin.Targets.Byte_Count);
      procedure Zero_Bytes (Bytes : Landin.Targets.Byte_Count);
      procedure Move_Units
        (Bytes : Landin.Targets.Byte_Count;
         Width : Landin.Targets.Byte_Count;
         Copy  : Boolean);

      procedure Put (Line : String; Known : Boolean := False) is
         Instruction : constant String := Trimmed (Line);
      begin
         Lines.Append (Line_Entry'
           (Text => Unbounded.To_Unbounded_String (Line),
            Offset => Offset, Segment => Segment));
         if Line'Length > 0 and then Line (Line'Last) = ':' then
            Labels.Include
              (Line (Line'First .. Line'Last - 1),
               (Offset => Offset, Segment => Segment));
         elsif Instruction = ".p2align 2" then
            --  Alignment may change after an earlier branch is shortened.
            Offset := Offset + 3;
         elsif Known and then Instruction'Length > 0
           and then Instruction (Instruction'First) /= '.'
         then
            Offset := Offset + 4;
         elsif Instruction'Length = 0
           or else Ada.Strings.Fixed.Index (Instruction, ".cfi_") = 1
           or else Ada.Strings.Fixed.Index (Instruction, ".loc ") = 1
           or else Ada.Strings.Fixed.Index (Instruction, ".file ") = 1
           or else Ada.Strings.Fixed.Index (Instruction, ".globl ") = 1
           or else Ada.Strings.Fixed.Index (Instruction, ".arch ") = 1
         then
            null;
         else
            --  An opaque instruction, a section change, or a directive
            --  whose size is not bounded separates branch-range regions.
            Segment := Segment + 1;
            Offset := 0;
         end if;
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
           (if Mnemonic = "b.eq" then "b.ne"
            elsif Mnemonic = "b.ne" then "b.eq"
            elsif Mnemonic = "b.lo" then "b.hs"
            elsif Mnemonic = "b.hs" then "b.lo"
            elsif Mnemonic = "b.cc" then "b.cs"
            elsif Mnemonic = "b.cs" then "b.cc"
            elsif Mnemonic = "b.hi" then "b.ls"
            elsif Mnemonic = "b.ls" then "b.hi"
            elsif Mnemonic = "b.lt" then "b.ge"
            elsif Mnemonic = "b.ge" then "b.lt"
            elsif Mnemonic = "b.le" then "b.gt"
            elsif Mnemonic = "b.gt" then "b.le"
            elsif Mnemonic = "b.vs" then "b.vc"
            elsif Mnemonic = "b.vc" then "b.vs"
            elsif Mnemonic = "b.mi" then "b.pl"
            elsif Mnemonic = "b.pl" then "b.mi"
            elsif Mnemonic = "cbz" then "cbnz"
            elsif Mnemonic = "cbnz" then "cbz"
            elsif Mnemonic = "tbz" then "tbnz"
            elsif Mnemonic = "tbnz" then "tbz" else "");
      begin
         if Inverse = "" then
            Put (Character'Val (9) & Instruction, Known => True);
         else
            --  Conditional branches have shorter reach than B.  Keep their
            --  immediate target adjacent even in expanded cleanup routines.
            declare
               Skip : constant String := Fresh;
               Last_Space : constant Natural := Ada.Strings.Fixed.Index
                 (Instruction, " ", Ada.Strings.Backward);
            begin
               Branches.Append
                 (Branch_Entry'
                   (First => Positive (Natural (Lines.Length) + 1),
                   Target => Unbounded.To_Unbounded_String
                     (Instruction (Last_Space + 1 .. Instruction'Last)),
                   Direct => Unbounded.To_Unbounded_String
                     (Character'Val (9) & Instruction),
                   Reach => (if Mnemonic in "tbz" | "tbnz"
                             then 32 * 1024 - 4 else 1024 * 1024 - 4)));
               Put (Character'Val (9) & Inverse
                 & Instruction (Space .. Last_Space) & Skip, Known => True);
               Put (Character'Val (9) & "b "
                 & Instruction (Last_Space + 1 .. Instruction'Last),
                 Known => True);
               Put (Skip & ":");
            end;
         end if;
      end Emit;


      --  Each line of Selection's text, which has neither branches nor
      --  labels.
      procedure Emit_Lines (Text : String);

      procedure Emit_Lines (Text : String) is
         First : Positive := Text'First;
      begin
         for Index in Text'Range loop
            if Text (Index) = LF then
               Emit (Text (First .. Index - 1));
               First := Index + 1;
            end if;
         end loop;
         Emit (Text (First .. Text'Last));
      end Emit_Lines;

      procedure Immediate (Register : String; Value : Pattern) is
      begin
         Emit_Lines (Selection.Immediate (Register, Selection.Word (Value)));
      end Immediate;

      procedure Add_Offset
        (Register : String; Offset : Landin.Targets.Byte_Count) is
      begin
         if Offset > 0 then
            if Offset <= 4095 then
               Emit ("add " & Register & ", " & Register & ", #"
                 & Trimmed (Landin.Targets.Byte_Count'Image (Offset)));
            elsif Offset mod 4096 = 0 and then Offset / 4096 <= 4095 then
               Emit ("add " & Register & ", " & Register & ", #"
                 & Trimmed (Landin.Targets.Byte_Count'Image (Offset / 4096))
                 & ", lsl #12");
            else
               Immediate ("x16", Pattern (Offset));
               Emit ("add " & Register & ", " & Register & ", x16");
            end if;
         end if;
      end Add_Offset;

      procedure Stack_Address
        (Register : String; Offset : Landin.Targets.Byte_Count) is
      begin
         if Offset = 0 then
            Emit ("mov " & Register & ", sp");
         elsif Offset <= 4095 then
            Emit ("add " & Register & ", sp, #"
              & Trimmed (Landin.Targets.Byte_Count'Image (Offset)));
         elsif Offset mod 4096 = 0 and then Offset / 4096 <= 4095 then
            Emit ("add " & Register & ", sp, #"
              & Trimmed (Landin.Targets.Byte_Count'Image (Offset / 4096))
              & ", lsl #12");
         else
            Emit ("mov " & Register & ", sp");
            Add_Offset (Register, Offset);
         end if;
      end Stack_Address;

      --  Size and speed restore nothing a call did not reserve.
      procedure Restore_Stack (Bytes : Landin.Targets.Byte_Count) is
      begin
         if Bytes > 0 then
            Add_Offset ("sp", Bytes);
         elsif Reference_Profile then
            Immediate ("x15", 0);
            Emit ("add sp, sp, x15");
         end if;
      end Restore_Stack;

      procedure Address (Register, Name : String; Imported : Boolean := False)
      is
      begin
         Emit ("adrp " & Register & ", "
               & Platform.Page (Format, Name, Imported));
         if Imported then
            Emit ("ldr " & Register & ", [" & Register & ", "
                  & Platform.Page_Offset (Format, Name, Imported) & "]");
         else
            Emit ("add " & Register & ", " & Register & ", "
                  & Platform.Page_Offset (Format, Name, Imported));
         end if;
      end Address;

      --  Register is general, named here at Size's width, or a d or s
      --  register as written; so for Frame_Memory and Base_Memory.
      procedure Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String)
      is
         Reg : constant String :=
           (if Size = Landin.Targets.Byte_8
              or else Register (Register'First) in 'd' | 's'
            then Register
            else "w" & Register (Register'First + 1 .. Register'Last));
      begin
         Emit ((if Store then "str" else "ldr")
               & (case Size is
                    when Landin.Targets.Byte_1 => "b",
                    when Landin.Targets.Byte_2 => "h",
                    when others => "")
               & " " & Reg & ", [" & Base & "]");
      end Memory;

      procedure Frame_Memory
        (Store : Boolean; Size : Held_Size; Register : String;
         Offset : Landin.Targets.Byte_Count)
      is
         Reg : constant String :=
           (if Size = Landin.Targets.Byte_8
              or else Register (Register'First) in 'd' | 's'
            then Register
            else "w" & Register (Register'First + 1 .. Register'Last));
      begin
         if Offset <= 256 then
            --  The signed unscaled byte offset reaches x29 - 256 without
            --  changing the frame pointer or requiring a scratch register.
            Emit ((if Store then "stur" else "ldur")
                  & (case Size is
                       when Landin.Targets.Byte_1 => "b",
                       when Landin.Targets.Byte_2 => "h",
                       when others => "")
                  & " " & Reg & ", [x29, #"
                  & Trimmed (Integer'Image (-Integer (Offset)))
                  & "]");
         else
            Frame_Address (Offset);
            Memory (Store, Size, Register, "x15");
         end if;
      end Frame_Memory;

      --  Size and speed subtract an offset that fits an immediate from
      --  the frame pointer directly rather than placing it first.
      procedure Frame_Address
        (Offset : Landin.Targets.Byte_Count; Register : String := "x15")
      is
         Operand : constant String :=
           (if Reference_Profile then ""
            else Selection.Arithmetic_Immediate (Selection.Word (Offset)));
      begin
         if Operand /= "" then
            Emit ("sub " & Register & ", x29, " & Operand);
         else
            Immediate (Register, Pattern (Offset));
            Emit ("sub " & Register & ", x29, " & Register);
         end if;
      end Frame_Address;

      --  A load or store Offset bytes past the address Base holds: the
      --  scaled unsigned offset when it fits, else the unscaled signed
      --  one, else the address formed in x10 first.
      procedure Base_Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String;
         Offset : Landin.Targets.Byte_Count)
      is
         Bytes : constant Landin.Targets.Byte_Count :=
           Landin.Targets.Byte_Count (Landin.Targets.Bytes (Size));
         Reg : constant String :=
           (if Size = Landin.Targets.Byte_8
              or else Register (Register'First) in 'd' | 's'
            then Register
            else "w" & Register (Register'First + 1 .. Register'Last));
         Suffix : constant String :=
           (case Size is
               when Landin.Targets.Byte_1 => "b",
               when Landin.Targets.Byte_2 => "h",
               when others => "");
         Where : constant String :=
           ", [" & Base & ", #"
           & Trimmed (Landin.Targets.Byte_Count'Image (Offset)) & "]";
      begin
         if Offset = 0 then
            Memory (Store, Size, Register, Base);
         elsif Offset mod Bytes = 0 and then Offset / Bytes <= 4095 then
            Emit ((if Store then "str" else "ldr") & Suffix & " " & Reg
                  & Where);
         elsif Offset <= 255 then
            Emit ((if Store then "stur" else "ldur") & Suffix & " " & Reg
                  & Where);
         else
            if Base /= "x10" then
               Emit ("mov x10, " & Base);
            end if;
            Add_Offset ("x10", Offset);
            Memory (Store, Size, Register, "x10");
         end if;
      end Base_Memory;

      procedure Reserve (Bytes : Landin.Targets.Byte_Count) is
      begin
         if Bytes = 0 then
            return;
         end if;
         --  Touch each intervening page without using the reserved x18.
         if Bytes >= 4096 then
            declare
               Loop_Label : constant String := Fresh;
            begin
               Immediate ("x15", Pattern (Bytes / 4096));
               Emit ("cbz x15, " & Loop_Label & "_tail");
               Put (Loop_Label & ":");
               Emit ("sub sp, sp, #1, lsl #12");
               Emit ("str xzr, [sp]");
               Emit ("subs x15, x15, #1");
               Emit ("b.ne " & Loop_Label);
               Put (Loop_Label & "_tail:");
            end;
         end if;
         if Bytes mod 4096 > 0 then
            Emit ("sub sp, sp, #"
                  & Trimmed (Landin.Targets.Byte_Count'Image
                    (Bytes mod 4096)));
            Emit ("str xzr, [sp]");
         end if;
      end Reserve;

      --  Speed spends code on every fixed extent through Speed_Transfer
      --  bytes, as x86-64 does, wherever a loop would move it: straight
      --  pairs of words and then the narrower tail, each at its own
      --  offset from x9 and x10, which stay where they are.  The hosted
      --  arm64 targets reach normal memory at any alignment, so no test
      --  of one is needed.
      Speed_Transfer : constant Landin.Targets.Byte_Count := 64;

      function Speed_Unrolled
        (Bytes : Landin.Targets.Byte_Count) return Boolean
        is (Options.Optimize = Landin.Optimization.Speed
            and then Bytes in 1 .. Speed_Transfer);

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
               Where : constant String := (if At_Offset = 0 then ""
                 else ", #" & Trimmed
                   (Landin.Targets.Byte_Count'Image (At_Offset)));
            begin
               if Left >= 16 then
                  if Copy then
                     Emit ("ldp x12, x13, [x10" & Where & "]");
                  end if;
                  Emit ((if Copy then "stp x12, x13" else "stp xzr, xzr")
                        & ", [x9" & Where & "]");
                  At_Offset := At_Offset + 16;
               else
                  declare
                     Width : constant Landin.Targets.Byte_Count :=
                       (if Left >= 8 then 8 elsif Left >= 4 then 4
                        elsif Left >= 2 then 2 else 1);
                     Suffix : constant String :=
                       (if Width = 2 then "h" elsif Width = 1 then "b"
                        else "");
                     Register : constant String :=
                       (if not Copy then (if Width = 8 then "xzr" else "wzr")
                        elsif Width = 8 then "x12" else "w12");
                  begin
                     if Copy then
                        Emit ("ldr" & Suffix & " " & Register & ", [x10"
                              & Where & "]");
                     end if;
                     Emit ("str" & Suffix & " " & Register & ", [x9" & Where
                           & "]");
                     At_Offset := At_Offset + Width;
                  end;
               end if;
            end;
         end loop;
      end Move_Unrolled;

      --  x9 destination, x10 source; private scratch leaves argument banks
      --  intact while copying by-value parameters at routine entry.  The
      --  forward direction also preserves the existing exact self-copy.
      procedure Copy_Bytes (Bytes : Landin.Targets.Byte_Count) is
         Loop_Label : constant String := Fresh;
      begin
         if Speed_Unrolled (Bytes) then
            Move_Unrolled (Bytes, Copy => True);
            return;
         end if;
         if Bytes >= 8 then
            --  A selected field or runtime address need not be word-aligned.
            --  Keep its byte path rather than assuming alignment from size.
            Emit ("orr x11, x9, x10");
            Emit ("tst x11, #7");
            Emit ("b.ne " & Loop_Label & "_bytes");
            Immediate ("x11", Pattern (Bytes / 8));
            Put (Loop_Label & "_words:");
            Emit ("ldr x12, [x10], #8");
            Emit ("str x12, [x9], #8");
            Emit ("subs x11, x11, #1");
            Emit ("b.ne " & Loop_Label & "_words");
            Immediate ("x11", Pattern (Bytes mod 8));
            Emit ("b " & Loop_Label & "_tail");
            Put (Loop_Label & "_bytes:");
         end if;
         Immediate ("x11", Pattern (Bytes));
         if Bytes >= 8 then
            Put (Loop_Label & "_tail:");
         end if;
         Emit ("cbz x11, " & Loop_Label & "_end");
         Put (Loop_Label & ":");
         Emit ("ldrb w12, [x10], #1");
         Emit ("strb w12, [x9], #1");
         Emit ("subs x11, x11, #1");
         Emit ("b.ne " & Loop_Label);
         Put (Loop_Label & "_end:");
      end Copy_Bytes;

      --  A by-value parameter's transfer from its carrier at x10, or its
      --  clear, into its fresh slot at x9: both aligned to Width, four or
      --  eight bytes, and advanced, over a whole number of Width units.
      --  Up to eight units move as unrolled pairs; a longer extent moves
      --  one unit per iteration.
      procedure Move_Units
        (Bytes : Landin.Targets.Byte_Count;
         Width : Landin.Targets.Byte_Count;
         Copy  : Boolean)
      is
         Loop_Label : constant String := Fresh;
         R : constant String := (if Width = 8 then "x" else "w");
         Step : constant String :=
           Trimmed (Landin.Targets.Byte_Count'Image (Width));
         Pair_Step : constant String :=
           Trimmed (Landin.Targets.Byte_Count'Image (2 * Width));
         Units : constant Landin.Targets.Byte_Count := Bytes / Width;
      begin
         if Units <= 8 then
            for Pair in 1 .. Units / 2 loop
               if Copy then
                  Emit ("ldp " & R & "12, " & R & "13, [x10], #"
                        & Pair_Step);
                  Emit ("stp " & R & "12, " & R & "13, [x9], #"
                        & Pair_Step);
               else
                  Emit ("stp " & R & "zr, " & R & "zr, [x9], #"
                        & Pair_Step);
               end if;
            end loop;
            if Units mod 2 /= 0 then
               if Copy then
                  Emit ("ldr " & R & "12, [x10], #" & Step);
                  Emit ("str " & R & "12, [x9], #" & Step);
               else
                  Emit ("str " & R & "zr, [x9], #" & Step);
               end if;
            end if;
            return;
         end if;
         Immediate ("x11", Pattern (Units));
         Put (Loop_Label & ":");
         if Copy then
            Emit ("ldr " & R & "12, [x10], #" & Step);
            Emit ("str " & R & "12, [x9], #" & Step);
         else
            Emit ("str " & R & "zr, [x9], #" & Step);
         end if;
         Emit ("subs x11, x11, #1");
         Emit ("b.ne " & Loop_Label);
      end Move_Units;

      procedure Zero_Bytes (Bytes : Landin.Targets.Byte_Count) is
         Loop_Label : constant String := Fresh;
      begin
         if Speed_Unrolled (Bytes) then
            Move_Unrolled (Bytes, Copy => False);
            return;
         end if;
         if Bytes >= 8 then
            Emit ("tst x9, #7");
            Emit ("b.ne " & Loop_Label & "_bytes");
            Immediate ("x11", Pattern (Bytes / 8));
            Put (Loop_Label & "_words:");
            Emit ("str xzr, [x9], #8");
            Emit ("subs x11, x11, #1");
            Emit ("b.ne " & Loop_Label & "_words");
            Immediate ("x11", Pattern (Bytes mod 8));
            Emit ("b " & Loop_Label & "_tail");
            Put (Loop_Label & "_bytes:");
         end if;
         Immediate ("x11", Pattern (Bytes));
         if Bytes >= 8 then
            Put (Loop_Label & "_tail:");
         end if;
         Emit ("cbz x11, " & Loop_Label & "_end");
         Put (Loop_Label & ":");
         Emit ("strb wzr, [x9], #1");
         Emit ("subs x11, x11, #1");
         Emit ("b.ne " & Loop_Label);
         Put (Loop_Label & "_end:");
      end Zero_Bytes;

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

      function Is_Forced (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Link_Symbol (Of_Unit, Item)
              /= Landin.Source.Names.No_Name
            or else Item = Hosted_Entry
            or else Landin.IR.Is_External (Of_Unit, Item));

      --  Pick a disjoint prefix for generated local labels. External source
      --  identities receive the object format's prefix at the rendering
      --  seam: none on ELF, where an explicit spelling may begin with `.L`,
      --  and Darwin's underscore on Mach-O, where none can begin with `L`.
      function Unused_Local_Prefix
        (Seed : String := Platform.Local_Prefix_Seed (Format))
        return String;

      function Unused_Local_Prefix
        (Seed : String := Platform.Local_Prefix_Seed (Format))
        return String
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
      --  that writes a line to standard error and ends the process.  On
      --  Mach-O the routine's name starts an atom of its own, which an `L`
      --  label would not, so dead stripping keeps it with what calls it.
      Reports : Landin.Backend.Trap_Reports.Table;
      Private_Prefix : constant String :=
        (if Format = Landin.Targets.Capabilities.Mach_O
         then "l" & Local_Prefix (Local_Prefix'First + 1 .. Local_Prefix'Last)
         else Local_Prefix);
      Reporter : constant String := Private_Prefix & "landin_trap_report";

      --  D450: a program that prepares or switches a stack carries one
      --  switch routine and one start routine, emitted after its bodies;
      --  the comment at their emission says what each does.  Both are
      --  local function symbols, `landin.stack_switch` and
      --  `landin.stack_start` with the object format's prefix (D469), so
      --  that a debugger names them in a backtrace: a linker-private `l`
      --  name is gone from a linked Mach-O image, and an ELF `.L` label
      --  was never in one.  Each still starts an atom of its own on
      --  Mach-O.  No Landin routine is spelled with the dot, and an
      --  explicit link name that starts so moves the prefix as it moves a
      --  local label's.  A prepared stack's first frame, and every
      --  switched stack's saved one, is Stack_Frame bytes: x19-x28 and
      --  d8-d15 from its bottom, then the stack's limit (D472) and a word
      --  that keeps the frame sixteen-byte aligned, and at its top the
      --  frame record, x29 and x30, as every routine's (D475).
      --  Stack_Limit is D471's cell: the current stack's limit, zero on
      --  the stack the process started on.  A program that prepares a
      --  stack checks it in its routines' prologues; one that uses a
      --  builtin keeps it, and its switch saves and restores it.
      Stack_Used : Boolean := False;
      Prepares : constant Boolean := Landin.Backend.Prepares_Stacks (Of_Unit);
      Unchecked_Bytes : constant Landin.Targets.Byte_Count :=
        Landin.Backend.Unchecked_Stack_Bytes (Facts);
      Limit_Margin : constant Landin.Targets.Byte_Count :=
        Landin.Backend.Stack_Limit_Margin (Facts);
      Stack_Limit : constant String := Local_Prefix & "landin_stack_limit";
      --  D491's stack for the default report's C call, and its bytes.
      Report_Stack : constant String := Local_Prefix & "landin_report_stack";
      Report_Stack_Bytes : constant Landin.Targets.Byte_Count :=
        Landin.Backend.Report_Stack_Bytes (Facts);
      Stack_Limit_Slot : constant := 144;
      Stack_Record_Slot : constant := 160;
      Routine_Prefix : constant String := Unused_Local_Prefix ("landin.");
      Stack_Switcher : constant String :=
        Landin.Targets.Capabilities.Link_Symbol
          (Facts, Routine_Prefix & "stack_switch");
      Stack_Start : constant String :=
        Landin.Targets.Capabilities.Link_Symbol
          (Facts, Routine_Prefix & "stack_start");
      Stack_Frame : constant := 176;
      --  A linker-private `l` name on Mach-O, as Apple's compilers give a
      --  string literal, so the link sees each line as an atom of its own.
      function Report_Label (Index : Positive) return String
        is (Private_Prefix & "landin_trap_line_"
            & Trimmed (Positive'Image (Index)));

      --  Branch-reach steps were always `L` on Mach-O, which no external
      --  name can collide with; on ELF they take the checked local prefix.
      Step_Prefix : constant String :=
        (if Format = Landin.Targets.Capabilities.Mach_O then "L"
         else Local_Prefix);

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

      --  Apply Darwin's external-symbol prefix only at the rendering seam.
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
              (Of_Unit, Meanings, Item, Hosted_Entry, Landin.IR.No_Item));

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
         --  Size and speed fold an indexed address into the one indirect
         --  access using it, Landin.Backend.Fold_Of's: the access then
         --  reads or writes through Folded_Base, and the address slot's
         --  store and load between, if any, are not emitted.
         Optimized : constant Boolean :=
           Options.Optimize /= Landin.Optimization.None;
         package Use_Buffers is new Landin.Backend.Work_Arrays
           (Natural, Use_Counts, 0);
         Use_Data : Use_Buffers.Buffer
           (if Optimized then Landin.IR.Value_Count (Of_Unit, Item) else 0);
         Uses : Use_Counts renames Use_Data.Data.all;
         Reference_Data : Use_Buffers.Buffer
           (if Optimized then Landin.IR.Slot_Count (Of_Unit, Item) else 0);
         References : Use_Counts renames Reference_Data.Data.all;
         Current_Block : Landin.IR.Block_Id := 1;
         Current_Position : Positive := 1;
         --  Under debugging, the line holding the current value's row.
         Row : Positive := 1;
         Folded : Address_Fold;
         Folded_Base : Unbounded.Unbounded_String;
         --  The branch a comparison right before it already took, testing
         --  the comparison's flags rather than a stored verdict.
         Fused_Branch : Landin.IR.Value_Id := Landin.IR.No_Value;
         --  D338's choice whose condition a comparison right before it
         --  left in the flags, and the condition that holds it.
         Fused_Choice : Landin.IR.Value_Id := Landin.IR.No_Value;
         Choice_Condition : Unbounded.Unbounded_String;
         --  An addition that cannot trap whose addend is a choice of one or
         --  zero right before it, which that choice made as one cinc.
         Fused_Increment : Landin.IR.Value_Id := Landin.IR.No_Value;
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
         --  D471: whether a stack limit check branches to this routine's
         --  own stack_exhausted trap, laid out after the others.
         Limit_Trapped : Boolean := False;
         Limit_Trap : constant String := Label (Item, 1) & "_stack_limit";

         --  D471: branch to the limit trap when the stack pointer less
         --  Bytes is below the current stack's limit, before anything is
         --  written there.  x16 and x17 are free wherever a frame or an
         --  area is reserved.
         procedure Check_Limit (Bytes : Landin.Targets.Byte_Count);

         procedure Check_Limit (Bytes : Landin.Targets.Byte_Count) is
         begin
            if Bytes = 0 then
               Emit ("mov x16, sp");
            elsif Bytes < 4096 then
               Emit ("sub x16, sp, #"
                     & Trimmed (Landin.Targets.Byte_Count'Image (Bytes)));
            else
               Immediate ("x16", Pattern (Bytes));
               Emit ("sub x16, sp, x16");
            end if;
            Emit ("adrp x17, " & Platform.Page (Format, Stack_Limit, False));
            Emit ("ldr x17, [x17, "
                  & Platform.Page_Offset (Format, Stack_Limit, False) & "]");
            Emit ("cmp x16, x17");
            Emit ("b.lo " & Limit_Trap);
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

         --  The register a value lives in, or No_Register for a frame
         --  home or nowhere, and whether size and speed read and write it
         --  there as a general register.
         function Held (Value : Landin.IR.Value_Id) return Natural
           is (Plan.Values (Positive (Value)).Register);
         function In_General (Value : Landin.IR.Value_Id) return Boolean
           is (Optimized and then Held (Value) /= No_Register
               and then Held (Value) not in Float_Register);
         --  A float value size and speed hold in a d or s register, and
         --  that register's name.
         function In_Float (Value : Landin.IR.Value_Id) return Boolean
           is (Optimized and then Held (Value) in Float_Register);
         function Float_Name (Value : Landin.IR.Value_Id) return String
           is (Name (Held (Value), Size_Of_Value (Value)));
         --  The same register as its 32-bit view, or the zero register's.
         function Short (Register : String) return String
           is ("w" & Register (Register'First + 1 .. Register'Last));

         --  Whether a value is a constant, and the pattern it stores.
         --  [1770]'s magnitude and [1880]'s minus are carried apart and
         --  meet here, at the value's own width.
         function Is_Constant (Value : Landin.IR.Value_Id) return Boolean
           is (Optimized
               and then Landin.IR.Op_Of (Of_Unit, Item, Value)
                 in Landin.IR.Number | Landin.IR.Truth | Landin.IR.Atom);
         function Constant_Of (Value : Landin.IR.Value_Id) return Pattern;

         function Constant_Of (Value : Landin.IR.Value_Id) return Pattern is
         begin
            case Landin.IR.Op_Of (Of_Unit, Item, Value) is
               when Landin.IR.Truth =>
                  return (if Landin.IR.Truth_Of (Of_Unit, Item, Value)
                          then 1 else 0);
               when Landin.IR.Atom =>
                  return Pattern (Atom_Code
                    (Atoms_Ranked, Landin.IR.Atom_Of (Of_Unit, Item, Value)));
               when others =>
                  declare
                     Bits : constant Landin.Targets.Bit_Width :=
                       (if Kind (Value) in Landin.Types.Float_Name
                        then Landin.Types.Float_Width (Kind (Value))
                        else Landin.Types.Width (Kind (Value), Facts));
                     Number : constant Pattern := Pattern
                       (Landin.IR.Number_Of (Of_Unit, Item, Value));
                  begin
                     if Kind (Value) not in Landin.Types.Float_Name
                       and then Landin.IR.Is_Negated (Of_Unit, Item, Value)
                     then
                        return Mask (0 - Number, Bits);
                     end if;
                     return Number;
                  end;
            end case;
         end Constant_Of;

         --  A constant Lives_Nowhere left without a place: every use puts
         --  it straight into the register it needs, or into the
         --  instruction itself.
         function Is_Rematerialized (Value : Landin.IR.Value_Id)
           return Boolean
           is (Is_Constant (Value) and then Held (Value) = No_Register
               and then Plan.Values (Positive (Value)).Home = 0);

         procedure Load_Value
           (Value : Landin.IR.Value_Id; Register : String := "x9");
         procedure Store_Value
           (Value : Landin.IR.Value_Id; Register : String := "x9";
            Atom_Validated : Boolean := False);
         procedure Validate_Atoms
           (Value : Landin.IR.Value_Id; Register : String);
         procedure Load_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "x9");
         procedure Store_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "x9";
            Extended : Boolean := False);
         procedure Extend (Register : String; Scalar : Landin.Types.Type_Kind);
         procedure Check_Fit
           (Register : String; Scalar : Landin.Types.Integer_Name);
         procedure Epilogue;
         procedure Finish_Exit;

         --  A location held in register Held, of Size, read into or
         --  written from the general Register.  A general register holds
         --  its value zero-extended, as a load from its frame cell would
         --  leave it; a float's bits cross banks with fmov.
         procedure Move_From
           (Held : Register_Number; Register : String; Size : Held_Size);
         procedure Move_Into
           (Held : Register_Number; Register : String; Size : Held_Size);

         procedure Move_From
           (Held : Register_Number; Register : String; Size : Held_Size) is
         begin
            if Held in Float_Register then
               Emit ("fmov " & (if Size = Landin.Targets.Byte_8 then Register
                                else "w" & Register
                                  (Register'First + 1 .. Register'Last))
                     & ", " & Name (Held, Size));
            elsif Name (Held) /= Register then
               Emit ("mov " & Register & ", " & Name (Held));
            end if;
         end Move_From;

         procedure Move_Into
           (Held : Register_Number; Register : String; Size : Held_Size)
         is
            Bits : constant Natural :=
              8 * Natural (Landin.Targets.Bytes (Size));
         begin
            if Held in Float_Register then
               Emit ("fmov " & Name (Held, Size) & ", "
                     & (if Size = Landin.Targets.Byte_8 then Register
                        else "w" & Register
                          (Register'First + 1 .. Register'Last)));
            elsif Bits < 64 then
               Emit ("ubfx " & Name (Held) & ", " & Register
                     & ", #0, #" & Trimmed (Natural'Image (Bits)));
            elsif Name (Held) /= Register then
               Emit ("mov " & Name (Held) & ", " & Register);
            end if;
         end Move_Into;

         --  Size and speed read an operand where a general register
         --  holds it and leave a result in the general register it lives
         --  in: Read names the register holding Value, its own or Scratch
         --  loaded with it, and Target the register an operation should
         --  compute Value into, from which Deliver puts it where it lives.
         --  Extended says the register already holds the value
         --  zero-extended from its own width, as every value in a general
         --  register is held.  A float held in a d register crosses into
         --  Scratch and back.  The reference profile loads each operand
         --  into Scratch, computes in Scratch and stores from there.
         function Read
           (Value : Landin.IR.Value_Id; Scratch : String := "x9")
            return String;
         function Target
           (Value : Landin.IR.Value_Id; Scratch : String := "x9")
            return String
           is (if In_General (Value) then Name (Held (Value)) else Scratch);
         procedure Deliver
           (Value : Landin.IR.Value_Id; Register : String;
            Extended : Boolean := False);
         --  The register a load from memory leaves Value in: a held float
         --  register itself, which needs no Deliver, or Target.
         function Load_Target (Value : Landin.IR.Value_Id) return String
           is (if In_Float (Value) then Float_Name (Value)
               else Target (Value));
         procedure Loaded (Value : Landin.IR.Value_Id; Register : String);
         --  Read, except that a zero constant is the zero register, which
         --  an instruction may read and store but never use as a base.
         function Read_Or_Zero
           (Value : Landin.IR.Value_Id; Scratch : String := "x9")
            return String
           is (if Is_Rematerialized (Value) and then Constant_Of (Value) = 0
               then "xzr" else Read (Value, Scratch));

         --  What a store to memory writes Value from: a held float
         --  register itself, or Read_Or_Zero's.
         function Store_Source
           (Value : Landin.IR.Value_Id; Scratch : String := "x9")
            return String
           is (if In_Float (Value) then Float_Name (Value)
               else Read_Or_Zero (Value, Scratch));

         procedure Loaded (Value : Landin.IR.Value_Id; Register : String) is
         begin
            if not In_Float (Value) then
               Deliver (Value, Register, Extended => True);
            end if;
         end Loaded;

         function Read
           (Value : Landin.IR.Value_Id; Scratch : String := "x9")
            return String is
         begin
            if In_General (Value) then
               return Name (Held (Value));
            end if;
            Load_Value (Value, Scratch);
            return Scratch;
         end Read;

         procedure Deliver
           (Value : Landin.IR.Value_Id; Register : String;
            Extended : Boolean := False)
         is
            Bits : constant Natural := 8 * Natural
              (Landin.Targets.Bytes (Size_Of_Value (Value)));
         begin
            if not In_General (Value) then
               Store_Value (Value, Register);
               return;
            end if;
            Validate_Atoms (Value, Register);
            if Register = Name (Held (Value)) then
               if not Extended and then Bits < 64 then
                  Emit ("ubfx " & Register & ", " & Register & ", #0, #"
                        & Trimmed (Natural'Image (Bits)));
               end if;
            elsif Extended or else Bits = 64 then
               Emit ("mov " & Name (Held (Value)) & ", " & Register);
            else
               Emit ("ubfx " & Name (Held (Value)) & ", " & Register
                     & ", #0, #" & Trimmed (Natural'Image (Bits)));
            end if;
         end Deliver;

         procedure Load_Value
           (Value : Landin.IR.Value_Id; Register : String := "x9") is
         begin
            if Is_Rematerialized (Value) then
               Immediate (Register, Constant_Of (Value));
            elsif Plan.Values (Positive (Value)).Register /= No_Register then
               Move_From (Plan.Values (Positive (Value)).Register, Register,
                          Size_Of_Value (Value));
            else
               Frame_Memory (False, Size_Of_Value (Value), Register,
                             Value_Offset (Layout, Value));
            end if;
         end Load_Value;

         procedure Validate_Atoms
           (Value : Landin.IR.Value_Id; Register : String)
         is
            Atoms : constant Landin.IR.Atom_Set_Id :=
              Landin.IR.Atom_Set_Of (Of_Unit, Item, Value);
         begin
            if Landin.IR.Validates_Atoms (Of_Unit, Item, Value) then
               declare
                  Done : constant String := Fresh;
               begin
                  if Landin.IR.Admits_Reserved_Zero
                    (Of_Unit, Item, Value)
                  then
                     Emit ("cbz " & Register & ", " & Done);
                  end if;
                  for Run of Runs_Of (Of_Unit, Atoms_Ranked, Atoms) loop
                     if Run.Low = Run.High then
                        Immediate ("x14", Pattern (Run.Low));
                        Emit ("cmp " & Register & ", x14");
                        Emit ("b.eq " & Done);
                     else
                        declare
                           Next : constant String := Fresh;
                        begin
                           Immediate ("x14", Pattern (Run.Low));
                           Emit ("cmp " & Register & ", x14");
                           Emit ("b.lo " & Next);
                           Immediate ("x14", Pattern (Run.High));
                           Emit ("cmp " & Register & ", x14");
                           Emit ("b.ls " & Done);
                           Put (Next & ":");
                        end;
                     end if;
                  end loop;
                  Emit ("b " & Trap (Landin.Panics.Bad_Conversion));
                  Put (Done & ":");
               end;
            end if;
         end Validate_Atoms;

         procedure Store_Value
           (Value : Landin.IR.Value_Id; Register : String := "x9";
            Atom_Validated : Boolean := False)
         is
         begin
            if not Atom_Validated then
               Validate_Atoms (Value, Register);
            end if;
            if Plan.Values (Positive (Value)).Register /= No_Register then
               Move_Into (Plan.Values (Positive (Value)).Register, Register,
                          Size_Of_Value (Value));
            else
               Frame_Memory (True, Size_Of_Value (Value), Register,
                             Value_Offset (Layout, Value));
            end if;
         end Store_Value;

         procedure Load_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "x9")
         is
            Held : constant Natural := Plan.Slots (Positive (Slot)).Register;
            Size : constant Held_Size := Size_Of
              (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts);
         begin
            if Held /= No_Register then
               Move_From (Held, Register, Size);
            else
               Frame_Memory
                 (False, Size, Register, Slot_Offset (Layout, Slot));
            end if;
         end Load_Slot;

         --  Extended says Register already holds the stored value
         --  zero-extended from the slot's width, as any value does.
         procedure Store_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "x9";
            Extended : Boolean := False)
         is
            Held : constant Natural := Plan.Slots (Positive (Slot)).Register;
            Size : constant Held_Size := Size_Of
              (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts);
         begin
            if Held = No_Register then
               Frame_Memory (True, Size, Register, Slot_Offset (Layout, Slot));
            elsif Register = Name (Held) then
               null;
            elsif Extended and then Held not in Float_Register then
               Emit ("mov " & Name (Held) & ", " & Register);
            else
               Move_Into (Held, Register, Size);
            end if;
         end Store_Slot;

         procedure Extend (Register : String; Scalar : Landin.Types.Type_Kind)
         is
         begin
            if Scalar in Landin.Types.I8 | Landin.Types.I16 | Landin.Types.I32
            then
               Emit ((case Scalar is
                        when Landin.Types.I8 => "sxtb ",
                        when Landin.Types.I16 => "sxth ",
                        when others => "sxtw ")
                     & Register & ", w"
                     & Register (Register'First + 1 .. Register'Last));
            end if;
         end Extend;

         procedure Check_Fit
           (Register : String; Scalar : Landin.Types.Integer_Name)
         is
            Bits : constant Natural :=
              Natural (Landin.Types.Width (Scalar, Facts));
         begin
            if Bits = 64 then
               return;
            end if;
            Emit ((if Landin.Types.Is_Signed (Scalar)
                   then "sbfx " else "ubfx ")
                  & "x14, " & Register & ", #0, #"
                  & Trimmed (Natural'Image (Bits)));
            Emit ("cmp x14, " & Register);
            Emit ("b.ne " & Trap);
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

         --  A saved register as a frame directive names it: x19-x28 by
         --  their names, d8-d15 by their DWARF numbers.
         function Frame_Name (Number : Register_Number) return String
           is (if Number in Float_Register
               then Trimmed (Natural'Image (Number))
               else "w" & Trimmed (Natural'Image (Number)));

         procedure Restore_Saves;

         --  Store or reload the declared registers in their homes, in
         --  register order.  Size and speed move two registers whose homes
         --  are adjacent with one pair instruction, from the frame pointer
         --  or from the farthest home.
         procedure Move_Saves (Store : Boolean);

         procedure Move_Saves (Store : Boolean) is
            Waiting : Natural := No_Register;
            --  The farthest home from the frame pointer.  When it is past
            --  the unscaled range, size and speed address every home from
            --  x15 set there once, with small positive offsets.
            Deepest : Landin.Targets.Byte_Count := 0;
            Based : Boolean := False;

            procedure Note (Number : Natural);
            procedure Single (Number : Natural);
            --  The operand reaching the home of register Number.
            function Home_Operand (Number : Natural) return String;

            procedure Note (Number : Natural) is
            begin
               if Debug = null then
                  return;
               elsif Store then
                  --  The CFA is x29 + 16 and the home sits below x29.
                  Emit (".cfi_offset " & Frame_Name (Number)
                        & ", -" & Trimmed (Landin.Targets.Byte_Count'Image
                          (Save_Home (Number) + 16)));
               else
                  Emit (".cfi_restore " & Frame_Name (Number));
               end if;
            end Note;

            function Home_Operand (Number : Natural) return String is
              (if Based and then Deepest = Save_Home (Number) then "[x15]"
               elsif Based
               then "[x15, #" & Trimmed (Landin.Targets.Byte_Count'Image
                 (Deepest - Save_Home (Number))) & "]"
               else "[x29, #-" & Trimmed (Landin.Targets.Byte_Count'Image
                 (Save_Home (Number))) & "]");

            procedure Single (Number : Natural) is
            begin
               if Reference_Profile then
                  Frame_Address (Save_Home (Number));
                  Emit ((if Store then "str " else "ldr ") & Name (Number)
                        & ", [x15]");
               else
                  Emit ((if Based then (if Store then "str " else "ldr ")
                         else (if Store then "stur " else "ldur "))
                        & Name (Number) & ", " & Home_Operand (Number));
               end if;
               Note (Number);
            end Single;
         begin
            for Number in Saves'Range loop
               if Saves (Number) then
                  Deepest := Landin.Targets.Byte_Count'Max
                    (Deepest, Save_Home (Number));
               end if;
            end loop;
            if not Reference_Profile and then Deepest > 256 then
               Frame_Address (Deepest);
               Based := True;
            end if;
            for Number in Saves'Range loop
               if Saves (Number) then
                  --  A pair is two registers of one bank.
                  if Waiting /= No_Register and then not Reference_Profile
                    and then (Number in Float_Register)
                      = (Waiting in Float_Register)
                    and then Save_Home (Number) = Save_Home (Waiting) + 8
                    and then Save_Home (Number) mod 8 = 0
                  then
                     Emit ((if Store then "stp " else "ldp ")
                           & Name (Number) & ", " & Name (Waiting) & ", "
                           & Home_Operand (Number));
                     Note (Waiting);
                     Note (Number);
                     Waiting := No_Register;
                  else
                     if Waiting /= No_Register then
                        Single (Waiting);
                     end if;
                     Waiting := Number;
                  end if;
               end if;
            end loop;
            if Waiting /= No_Register then
               Single (Waiting);
            end if;
         end Move_Saves;

         procedure Restore_Saves is
         begin
            Move_Saves (Store => False);
         end Restore_Saves;

         procedure Epilogue is
         begin
            if Debug /= null then
               Emit (".cfi_remember_state");
            end if;
            Restore_Saves;
            Emit ("mov sp, x29");
            Emit ("ldp x29, x30, [sp], #16");
            if Debug /= null then
               Emit (".cfi_def_cfa sp, 0");
               Emit (".cfi_restore w29");
               Emit (".cfi_restore w30");
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
               Emit ("b " & Shared_Exit);
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
         procedure Part_Access
           (Store    : Boolean;
            Size     : Held_Size;
            Register : String;
            Place    : Landin.IR.Storage;
            Field    : Landin.IR.Element_Total;
            Nested   : Landin.IR.Path_Step_Array);
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

         --  How far past the start of its storage a part begins: what
         --  Part_Address adds to the storage's own address.
         function Part_Offset
           (Place         : Landin.IR.Storage;
            Field         : Landin.IR.Element_Total;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.Targets.Byte_Count;

         function Part_Offset
           (Place         : Landin.IR.Storage;
            Field         : Landin.IR.Element_Total;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.Targets.Byte_Count
         is
            Offset : Landin.Targets.Byte_Count := 0;
            function Shape return Landin.IR.Field_Shape is
              (if Field = 0 then Root_Shape_Of (Place, 0)
               else Part_Shape_Of (Place, Landin.IR.Part_Position (Field)));
         begin
            if Field > 0 then
               case Place.Kind is
                  when Landin.IR.Module_Datum =>
                     Offset := Field_Offset
                       (Place.Datum, Landin.IR.Part_Position (Field));
                  when Landin.IR.Frame_Slot =>
                     Offset := Slot_Offset (Layout, Place.Slot)
                       - Landin.Backend.Field_Offset
                         (Of_Unit, Item, Layout, Place.Slot,
                          Landin.IR.Part_Position (Field), Facts);
                  when Landin.IR.Runtime_Address =>
                     Offset := Path_Offset
                       (Landin.IR.Address_Shape
                          (Of_Unit, Item, Place.Address),
                        [1 => (Field => Landin.IR.Part_Position (Field),
                               Case_Index => 0)]);
               end case;
            end if;
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
            return Offset;
         end Part_Offset;

         procedure Part_Address
           (Place         : Landin.IR.Storage;
            Field         : Landin.IR.Element_Total;
            Register      : String;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps)
         is
         begin
            case Place.Kind is
               when Landin.IR.Module_Datum =>
                  Address (Register, Symbol (Place.Datum));
               when Landin.IR.Frame_Slot =>
                  Frame_Address
                    (Slot_Offset (Layout, Place.Slot), Register);
               when Landin.IR.Runtime_Address =>
                  Load_Slot (Place.Address, Register);
            end case;
            Add_Offset
              (Register,
               Part_Offset (Place, Field, Which, Payload_Field, Nested));
         end Part_Address;

         --  A scalar part's load or store under size and speed, reached
         --  from its base with the access's own offset: a frame cell from
         --  the frame pointer, an address slot's part from the register
         --  holding it or else x10 loaded with it, a datum's from x10.
         procedure Part_Access
           (Store    : Boolean;
            Size     : Held_Size;
            Register : String;
            Place    : Landin.IR.Storage;
            Field    : Landin.IR.Element_Total;
            Nested   : Landin.IR.Path_Step_Array)
         is
            Offset : constant Landin.Targets.Byte_Count :=
              Part_Offset (Place, Field, Nested => Nested);
         begin
            case Place.Kind is
               when Landin.IR.Frame_Slot =>
                  Frame_Memory (Store, Size, Register,
                                Slot_Offset (Layout, Place.Slot) - Offset);
               when Landin.IR.Module_Datum =>
                  Address ("x10", Symbol (Place.Datum));
                  Base_Memory (Store, Size, Register, "x10", Offset);
               when Landin.IR.Runtime_Address =>
                  if Plan.Slots (Positive (Place.Address)).Register
                    /= No_Register
                  then
                     Base_Memory
                       (Store, Size, Register,
                        Name (Plan.Slots (Positive (Place.Address)).Register),
                        Offset);
                  else
                     Load_Slot (Place.Address, "x10");
                     Base_Memory (Store, Size, Register, "x10", Offset);
                  end if;
            end case;
         end Part_Access;

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

         --  A Value_Id restarts in each item, just as a Block_Id does.  The
         --  extra `V` keeps a continuation distinct from a block label.
         --  Transfer a classified chunk at x13. Scalars use their storage
         --  width; byte replay bounds aggregate chunks, including short tails.
         procedure C_Chunk
           (Place : AAPCS64_ABI.Location; Chunk : Positive; Store : Boolean);
         procedure C_Entry;
         procedure C_Call (Value : Landin.IR.Value_Id);
         procedure C_Result (Value : Landin.IR.Value_Id);
         C_Result_Place : AAPCS64_ABI.Location;

         procedure C_Chunk
           (Place : AAPCS64_ABI.Location; Chunk : Positive; Store : Boolean)
         is
            Stride : constant Landin.Targets.Byte_Count :=
              (if Place.Shape.Float_Bytes > 0
               then Place.Shape.Float_Bytes else 8);
            Offset : constant Landin.Targets.Byte_Count :=
              Landin.Targets.Byte_Count (Chunk - 1) * Stride;
            Bytes : constant Landin.Targets.Byte_Count :=
              Landin.Targets.Byte_Count'Min (Stride, Place.Shape.Size -
                Offset);
            Reg : constant String :=
              Trimmed (Natural'Image (Place.Registers (Chunk) - 1));
         begin
            if not Place.Shape.Aggregate then
               if Place.Shape.Float_Bytes > 0 then
                  Emit ((if Store then "str " else "ldr ")
                        & (if Place.Shape.Float_Bytes = 4 then "s" else "d")
                        & Reg & ", [x13]");
               else
                  Memory
                    (Store,
                     (case Place.Shape.Size is
                        when 1 => Landin.Targets.Byte_1,
                        when 2 => Landin.Targets.Byte_2,
                        when 4 => Landin.Targets.Byte_4,
                        when 8 => Landin.Targets.Byte_8,
                        when others => raise Compiler_Defect with
                          "unsupported Darwin C scalar width"),
                     "x" & Reg, "x13");
               end if;
               return;
            end if;
            if Store then
               Emit ((if Place.Shape.Float_Bytes > 0
                      then "fmov x14, d" else "mov x14, x") & Reg);
            else
               Emit ("mov x14, #0");
            end if;
            for Byte in 0 .. Bytes - 1 loop
               if Store then
                  Emit ("lsr x17, x14, #"
                        & Trimmed (Landin.Targets.Byte_Count'Image (Byte *
                          8)));
                  Emit ("strb w17, [x13, #"
                        & Trimmed (Landin.Targets.Byte_Count'Image
                          (Offset + Byte)) & "]");
               else
                  Emit ("ldrb w17, [x13, #"
                        & Trimmed (Landin.Targets.Byte_Count'Image
                          (Offset + Byte)) & "]");
                  Emit ("orr x14, x14, x17, lsl #"
                        & Trimmed (Landin.Targets.Byte_Count'Image (Byte *
                          8)));
               end if;
            end loop;
            if not Store then
               Emit ((if Place.Shape.Float_Bytes > 0
                      then "fmov d" else "mov x") & Reg & ", x14");
            end if;
         end C_Chunk;

         procedure C_Entry is
            Plan : constant AAPCS64_ABI.Plan := AAPCS64_ABI.Signature_Plan
              (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts);
            Hidden : constant Natural :=
              (if Plan.Result.Shape.Aggregate then 1 else 0);
         begin
            --  Every leave in this routine has the same C result carrier.
            C_Result_Place := Plan.Result;
            if Hidden > 0 then
               if Plan.Result.Shape.Indirect then
                  Emit ("mov x9, x8");
               else
                  Frame_Address
                    (Slot_Offset (Layout,
                       Landin.IR.Result_Slot (Of_Unit, Item)), "x9");
               end if;
               Store_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1));
            end if;
            for Index in Plan.Arguments'Range loop
               declare
                  Place : AAPCS64_ABI.Location renames Plan.Arguments (Index);
                  Slot : constant Landin.IR.Slot_Id :=
                    Landin.IR.Nth_Parameter (Of_Unit, Item, Index + Hidden);
               begin
                  if Place.On_Stack or else Place.Shape.Indirect then
                     if Place.On_Stack then
                        Emit ("mov x10, x29");
                        Add_Offset ("x10", 16 + Place.Stack_At);
                        if Place.Shape.Indirect then
                           Emit ("ldr x10, [x10]");
                        end if;
                     else
                        Emit ("mov x10, x" & Trimmed
                          (Natural'Image (Place.Registers (1) - 1)));
                     end if;
                     Frame_Address (Slot_Offset (Layout, Slot), "x9");
                     Copy_Bytes (Place.Shape.Size);
                  else
                     Frame_Address (Slot_Offset (Layout, Slot), "x13");
                     for Chunk in 1 .. Place.Shape.Count loop
                        C_Chunk (Place, Chunk, True);
                     end loop;
                  end if;
               end;
            end loop;
         end C_Entry;

         procedure C_Call (Value : Landin.IR.Value_Id) is
            Indirect : constant Boolean :=
              Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Indirect_Call;
            Plan : constant AAPCS64_ABI.Plan :=
              AAPCS64_ABI.Call_Plan (Of_Unit, Item, Value, Facts);
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
            if Prepares and then Bytes > Unchecked_Bytes then
               Check_Limit (Bytes);
            end if;
            Reserve (Bytes);
            Deepest_Area :=
              Landin.Targets.Byte_Count'Max (Deepest_Area, Bytes);
            for Index in Plan.Arguments'Range loop
               declare
                  Place : AAPCS64_ABI.Location renames Plan.Arguments (Index);
               begin
                  if Place.Shape.Indirect then
                     Load_Value (Argument (Index), "x10");
                     Stack_Address ("x9", Copies (Index));
                     Copy_Bytes (Place.Shape.Size);
                     Stack_Address ("x13", Copies (Index));
                     if Place.On_Stack then
                        if Place.Stack_At <= 32760
                          and then Place.Stack_At mod 8 = 0
                        then
                           Emit ("str x13, [sp, #"
                             & Trimmed (Landin.Targets.Byte_Count'Image
                               (Place.Stack_At)) & "]");
                        else
                           Stack_Address ("x9", Place.Stack_At);
                           Emit ("str x13, [x9]");
                        end if;
                     else
                        Emit ("mov x" & Trimmed
                          (Natural'Image (Place.Registers (1) - 1))
                          & ", x13");
                     end if;
                  elsif Place.On_Stack then
                     if Place.Shape.Aggregate then
                        Load_Value (Argument (Index), "x10");
                     else
                        Frame_Address
                          (Value_Offset (Layout, Argument (Index)), "x10");
                     end if;
                     Stack_Address ("x9", Place.Stack_At);
                     Copy_Bytes (Place.Shape.Size);
                  else
                     if Place.Shape.Aggregate then
                        Load_Value (Argument (Index), "x13");
                     else
                        Frame_Address
                          (Value_Offset (Layout, Argument (Index)), "x13");
                     end if;
                     for Chunk in 1 .. Place.Shape.Count loop
                        C_Chunk (Place, Chunk, False);
                     end loop;
                     if not Place.Shape.Aggregate then
                        Extend
                          ("x" & Trimmed
                             (Natural'Image (Place.Registers (1) - 1)),
                           Kind (Argument (Index)));
                     end if;
                  end if;
               end;
            end loop;
            if Plan.Result.Shape.Indirect then
               Load_Value (Landin.IR.Nth_Operand
                 (Of_Unit, Item, Value, Offset + 1), "x8");
            end if;
            if Indirect then
               Load_Value
                 (Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1), "x14");
               Emit ("blr x14");
            else
               Emit ("bl " & Symbol
                 (Landin.IR.Callee_Of (Of_Unit, Item, Value)));
            end if;
            if not Plan.Result.Shape.Indirect
              and then Plan.Result.Shape.Size > 0
            then
               if Hidden > 0 then
                  Load_Value (Landin.IR.Nth_Operand
                    (Of_Unit, Item, Value, Offset + 1), "x13");
               else
                  Frame_Address (Value_Offset (Layout, Value), "x13");
               end if;
               for Chunk in 1 .. Plan.Result.Shape.Count loop
                  C_Chunk (Plan.Result, Chunk, True);
               end loop;
            end if;
            Restore_Stack (Bytes);
         end C_Call;

         procedure C_Result (Value : Landin.IR.Value_Id) is
            Place : AAPCS64_ABI.Location renames C_Result_Place;
         begin
            if Place.Shape.Size = 0 then
               return;
            elsif Place.Shape.Indirect then
               Load_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1), "x9");
               Frame_Address (Slot_Offset
                 (Layout, Landin.IR.Result_Slot (Of_Unit, Item)), "x10");
               Copy_Bytes (Place.Shape.Size);
            else
               if Place.Shape.Aggregate then
                  Frame_Address (Slot_Offset
                    (Layout, Landin.IR.Result_Slot (Of_Unit, Item)), "x13");
               else
                  Frame_Address (Value_Offset (Layout,
                    Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1)), "x13");
               end if;
               for Chunk in 1 .. Place.Shape.Count loop
                  C_Chunk (Place, Chunk, False);
               end loop;
               Extend ("x0", Result);
            end if;
         end C_Result;

         --  [1630] on arm64.  Every value lives in a frame home, so each
         --  input is loaded through its own register -- which addresses its
         --  home first -- and extended to the whole register as its type
         --  says; the text runs as written; and each output is stored
         --  through a register no output still waiting holds.  Only a block
         --  whose outputs hold all of x0-x17 finds none for its first, which
         --  then waits in d16, a register every block overwrites and none
         --  may name, and is stored last.
         procedure Assembly_Block (Value : Landin.IR.Value_Id);

         procedure Assembly_Block (Value : Landin.IR.Value_Id) is
            Chosen : constant Landin.Targets.Assembly.Operand_Register_Array
              := Landin.Backend.Assembly_Registers
                   (Of_Unit, Item, Value, Names, Facts);
            Text : constant String := Landin.Backend.Assembly_Text
              (Of_Unit, Item, Value, Names, Facts);
            Inputs : Natural := 0;
            Start : Natural := Text'First;
            Waiting : array (0 .. 28) of Boolean := [others => False];
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
               for Candidate in reverse 0 .. 17 loop
                  if not Waiting (Candidate) then
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
            if (for all Held of Waiting (0 .. 17) => Held) then
               for Index in Chosen'Range loop
                  if Operand (Index).Output /= Landin.IR.No_Slot then
                     Aside := Index;
                     Emit ("fmov d16, " & Register (Index));
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
                  Emit ("fmov " & Held & ", d16");
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
                     Immediate ("x14", (if Encode then Code else Raw));
                     Emit ("cmp x9, x14");
                     Emit ("b.ne " & Next);
                     Immediate ("x9", (if Encode then Raw else Code));
                     Emit ("b " & Done);
                     Put (Next & ":");
                  end;
               end loop;
               Emit ("b " & Trap (Landin.Panics.Bad_Conversion));
               Put (Done & ":");
            end Packed_Atom;

            procedure FP_Load (Which : Positive; Register : String);
            procedure FP_Save;
            procedure FP_Finish;
            function FP_Operand
              (Which : Positive; Register : String) return String;
            function FP_Target return String;
            --  A float register's load or store at a frame home, and a
            --  float constant put straight into one: fmov's immediate,
            --  a cleared register, or the pattern through x9.
            procedure Float_Frame
              (Store : Boolean; Register : String;
               Offset : Landin.Targets.Byte_Count);
            procedure Float_Constant
              (Register : String; Bits : Pattern; Single : Boolean);
            --  The checked element's address as what goes between an
            --  access's brackets.  Size and speed leave a power-of-two
            --  stride to the access, `[x10, x13, lsl #n]`, when the access
            --  is Width bytes wide and the stride is that or one; any
            --  other address is formed in Into.  Width zero forms it.
            --  Size and speed read the index, and an address slot holding
            --  the whole storage, where their registers are.
            function Index_Operand
              (Storage : Landin.IR.Storage; Field : Natural;
               Which, Payload : Natural; Nested : Landin.IR.Path_Step_Array;
               Below : Landin.IR.Path_Step_Array := Landin.IR.No_Path_Steps;
               Width : Natural := 0;
               Into : String := "x10") return String;

            --  The register holding where a part of Storage begins: under
            --  size and speed the register of an address slot when the
            --  part is all it addresses, else Register formed with it.
            function Base_Of
              (Storage : Landin.IR.Storage; Field : Natural;
               Register : String; Which, Payload : Natural;
               Nested : Landin.IR.Path_Step_Array) return String;

            --  The access an address this instruction computes folds
            --  into, if any, and how many bytes it moves.
            function Folding return Address_Fold;
            function Folded_Size (Fold : Address_Fold) return Natural;

            --  The base an indirect access reads or writes through: the
            --  address folded into it, or else the register holding its
            --  own, x10 when it has to be loaded.
            function Indirect_Base return String;

            --  The instruction after this one in its block, if any, and
            --  the block laid out after this one, which a branch to it
            --  reaches by falling through.
            Next_Instruction : constant Landin.IR.Value_Id :=
              (if Current_Position
                    < Landin.IR.Length (Of_Unit, Item, Current_Block)
               then Landin.IR.Nth_Value
                 (Of_Unit, Item, Current_Block, Current_Position + 1)
               else Landin.IR.No_Value);
            Following : constant Landin.IR.Block_Id := Current_Block + 1;

            --  The condition true exactly when Condition is false, over
            --  the same flags: for fcmp's too, since each comparison's
            --  condition and its inverse split an unordered pair between
            --  them as D162 does.
            function Inverse (Condition : String) return String is
              (if Condition = "eq" then "ne"
               elsif Condition = "ne" then "eq"
               elsif Condition = "lo" then "hs"
               elsif Condition = "hs" then "lo"
               elsif Condition = "ls" then "hi"
               elsif Condition = "hi" then "ls"
               elsif Condition = "lt" then "ge"
               elsif Condition = "ge" then "lt"
               elsif Condition = "le" then "gt"
               elsif Condition = "gt" then "le"
               elsif Condition = "mi" then "pl"
               else "mi");

            --  To Yes when the flags meet Condition and else to No, with
            --  no branch to the block that follows.
            procedure Branch_On
              (Condition : String; Yes, No : Landin.IR.Block_Id);

            --  Size and speed's comparison of the two operands, in the
            --  flags: an operand where its register is, a constant that
            --  fits as cmp's or cmn's immediate.  A signed operand
            --  narrower than 32 bits is sign-extended first.
            procedure Compare_Integer (Scalar : Landin.Types.Scalar_Name);

            --  Size and speed's integer arithmetic, computed into the
            --  result's register from its operands' with immediates where
            --  the encoding allows.  Done is False for a form it leaves
            --  to the general sequence.
            procedure Select_Integer (Done : out Boolean);

            procedure Float_Frame
              (Store : Boolean; Register : String;
               Offset : Landin.Targets.Byte_Count) is
            begin
               if Offset <= 256 then
                  Emit ((if Store then "stur " else "ldur ") & Register
                        & ", [x29, #"
                        & Trimmed (Integer'Image (-Integer (Offset))) & "]");
               else
                  Frame_Address (Offset);
                  Emit ((if Store then "str " else "ldr ") & Register
                        & ", [x15]");
               end if;
            end Float_Frame;

            procedure Float_Constant
              (Register : String; Bits : Pattern; Single : Boolean)
            is
               Encoded : constant String :=
                 Selection.Float_Immediate (Selection.Word (Bits), Single);
            begin
               if Encoded /= "" then
                  Emit ("fmov " & Register & ", " & Encoded);
               elsif Bits = 0 then
                  Emit ("movi d" & Register (Register'First + 1
                        .. Register'Last) & ", #0");
               else
                  Immediate ("x9", Bits);
                  Emit ("fmov " & Register & ", "
                        & (if Single then "w9" else "x9"));
               end if;
            end Float_Constant;

            procedure FP_Load (Which : Positive; Register : String) is
               Source : constant Landin.IR.Value_Id := Operand (Which);
               Single : constant Boolean :=
                 Kind (Source) = Landin.Types.F32;
               Into : constant String := FP (Kind (Source)) & Register;
            begin
               if not Optimized then
                  Load_Value (Source);
                  Emit ("fmov " & Into & ", "
                        & (if Single then "w9" else "x9"));
               elsif Is_Rematerialized (Source) then
                  Float_Constant (Into, Constant_Of (Source), Single);
               elsif Held (Source) /= No_Register then
                  Emit ("fmov " & Into & ", "
                        & Name (Held (Source), Size_Of_Value (Source)));
               else
                  Float_Frame (False, Into, Value_Offset (Layout, Source));
               end if;
            end FP_Load;

            --  A float operand as an instruction names it: the d or s
            --  register it is held in, or else that of Register, which it
            --  is loaded into.
            function FP_Operand
              (Which : Positive; Register : String) return String
            is
               Held : constant Natural :=
                 Plan.Values (Positive (Operand (Which))).Register;
            begin
               if Held in Float_Register then
                  return Name (Held, Size_Of_Value (Operand (Which)));
               end if;
               FP_Load (Which, Register);
               return FP (Kind (Operand (Which))) & Register;
            end FP_Operand;

            --  Where a float result is computed: the register it is held
            --  in, or else d16 or s16, which FP_Finish then stores.
            function FP_Target return String is
              (if Plan.Values (Positive (Value)).Register in Float_Register
               then Name (Plan.Values (Positive (Value)).Register,
                          Size_Of_Value (Value))
               else FP (Kind (Value)) & "16");

            --  The result in d16 or s16 moved to where it is held.
            procedure FP_Save is
               Single : constant Boolean := Kind (Value) = Landin.Types.F32;
            begin
               if not Optimized then
                  Emit ("fmov " & (if Single then "w9, s16" else "x9, d16"));
                  Store_Value (Value);
               elsif Held (Value) /= No_Register then
                  Emit ("fmov " & Name (Held (Value), Size_Of_Value (Value))
                        & ", " & (if Single then "s16" else "d16"));
               else
                  Float_Frame (True, (if Single then "s16" else "d16"),
                               Value_Offset (Layout, Value));
               end if;
            end FP_Save;

            --  The result computed at FP_Target moved to where it is held,
            --  which is nowhere when it is held there.
            procedure FP_Finish is
            begin
               if Plan.Values (Positive (Value)).Register
                 not in Float_Register
               then
                  FP_Save;
               end if;
            end FP_Finish;

            function Base_Of
              (Storage : Landin.IR.Storage; Field : Natural;
               Register : String; Which, Payload : Natural;
               Nested : Landin.IR.Path_Step_Array) return String is
            begin
               if Optimized
                 and then Storage.Kind = Landin.IR.Runtime_Address
                 and then Field = 0 and then Payload = 0
                 and then Nested'Length = 0
                 and then Plan.Slots (Positive (Storage.Address)).Register
                   /= No_Register
               then
                  return Name
                    (Plan.Slots (Positive (Storage.Address)).Register);
               end if;
               Storage_Address
                 (Storage, Field, Register, Which, Payload, Nested);
               return Register;
            end Base_Of;

            function Index_Operand
              (Storage : Landin.IR.Storage; Field : Natural;
               Which, Payload : Natural; Nested : Landin.IR.Path_Step_Array;
               Below : Landin.IR.Path_Step_Array := Landin.IR.No_Path_Steps;
               Width : Natural := 0;
               Into : String := "x10") return String
            is
               Length : constant Landin.IR.Element_Total :=
                 Array_Length_Of (Storage, Field, Which, Payload, Nested);
               Stride : constant Landin.Targets.Byte_Count :=
                 Element_Bytes_Of (Storage, Field, Which, Payload, Nested);
               Scale : Landin.Targets.Byte_Count := Stride;
               Shift : Natural := 0;
               Index : constant String := Read (Operand (1), "x13");
               Bound : constant String :=
                 (if Optimized
                  then Selection.Arithmetic_Immediate
                    (Selection.Word (Length))
                  else "");
               Scaled : Unbounded.Unbounded_String :=
                 Unbounded.To_Unbounded_String (Index);
            begin
               if not Unchecked then
                  if Bound /= "" then
                     Emit ("cmp " & Index & ", " & Bound);
                  else
                     Immediate ("x14", Pattern (Length));
                     Emit ("cmp " & Index & ", x14");
                  end if;
                  Emit ("b.hs " & Trap);
               end if;
               while Scale > 1 and then Scale mod 2 = 0 loop
                  Scale := Scale / 2;
                  Shift := Shift + 1;
               end loop;
               if Scale /= 1 then
                  Immediate ("x14", Pattern (Stride));
                  Emit ("mul x13, " & Index & ", x14");
                  Scaled := Unbounded.To_Unbounded_String ("x13");
               end if;
               declare
                  Base : constant String :=
                    Base_Of (Storage, Field, "x10", Which, Payload, Nested);
                  Offset : constant String := Unbounded.To_String (Scaled);
               begin
                  if Optimized and then Width > 0 and then Below'Length = 0
                    and then Scale = 1
                    and then (Shift = 0 or else 2 ** Shift = Width)
                  then
                     return Base & ", " & Offset
                       & (if Shift > 0
                          then ", lsl #" & Trimmed (Natural'Image (Shift))
                          else "");
                  end if;
                  if Scale = 1 and then Shift > 0 then
                     Emit ("add " & Into & ", " & Base & ", " & Offset
                           & ", lsl #" & Trimmed (Natural'Image (Shift)));
                  else
                     Emit ("add " & Into & ", " & Base & ", " & Offset);
                  end if;
               end;
               if Below'Length > 0 then
                  Add_Offset (Into, Path_Offset
                    (Element_Shape_Of (Storage, Field, Which, Payload, Nested),
                     Below));
               end if;
               return Into;
            end Index_Operand;

            function Folding return Address_Fold is
              (if Optimized
               then Fold_Of (Of_Unit, Item, Current_Block, Current_Position,
                             Uses, References)
               else (others => <>));

            function Folded_Size (Fold : Address_Fold) return Natural is
              (if Fold.Access_Value = Landin.IR.No_Value then 0
               elsif Landin.IR.Op_Of (Of_Unit, Item, Fold.Access_Value)
                 = Landin.IR.Load_Indirect
               then Landin.Targets.Bytes (Size_Of_Value (Fold.Access_Value))
               else Landin.Targets.Bytes (Size_Of_Value
                 (Landin.IR.Nth_Operand
                    (Of_Unit, Item, Fold.Access_Value, 2))));

            function Indirect_Base return String is
            begin
               if Folded.Access_Value = Value then
                  Folded := (others => <>);
                  return Unbounded.To_String (Folded_Base);
               end if;
               return Read (Operand (1), "x10");
            end Indirect_Base;

            procedure Branch_On
              (Condition : String; Yes, No : Landin.IR.Block_Id) is
            begin
               if Yes = No then
                  if Yes /= Following then
                     Emit ("b " & Label (Item, Yes));
                  end if;
               elsif Yes = Following then
                  Emit ("b." & Inverse (Condition) & " " & Label (Item, No));
               else
                  Emit ("b." & Condition & " " & Label (Item, Yes));
                  if No /= Following then
                     Emit ("b " & Label (Item, No));
                  end if;
               end if;
            end Branch_On;

            procedure Compare_Integer (Scalar : Landin.Types.Scalar_Name) is
               Signed : constant Boolean :=
                 Scalar in Landin.Types.Integer_Name
                 and then Landin.Types.Is_Signed (Scalar);
               Bits : constant Natural :=
                 8 * Natural (Landin.Targets.Bytes (Size_Of (Scalar, Facts)));
               --  A signed 32-bit operand compares in its own 32-bit
               --  view; any other in all 64 bits, zero- or sign-extended.
               Narrow : constant Boolean := Signed and then Bits = 32;
               function View (Register : String) return String is
                 (if Narrow then Short (Register) else Register);
               function Operand_Register
                 (Which : Positive; Scratch : String) return String;

               function Operand_Register
                 (Which : Positive; Scratch : String) return String
               is
                  Held_In : constant String := Read (Operand (Which), Scratch);
               begin
                  if Signed and then Bits < 32 then
                     Emit ((if Bits = 8 then "sxtb " else "sxth ") & Scratch
                           & ", " & Short (Held_In));
                     return Scratch;
                  end if;
                  return Held_In;
               end Operand_Register;

               Left : constant String := Operand_Register (1, "x9");
            begin
               if Is_Constant (Operand (2)) then
                  declare
                     Bits_Value : constant Pattern :=
                       Constant_Of (Operand (2));
                     Negative : constant Boolean :=
                       Signed and then Is_Negative
                         (Bits_Value, Landin.Targets.Bit_Width (Bits));
                     Plain : constant String :=
                       (if Negative then ""
                        else Selection.Arithmetic_Immediate
                          (Selection.Word (Bits_Value)));
                     Negated : constant String :=
                       (if Negative
                        then Selection.Arithmetic_Immediate
                          (Selection.Word
                             (Mask (0 - Bits_Value,
                                    Landin.Targets.Bit_Width (Bits))))
                        else "");
                  begin
                     if Plain /= "" then
                        Emit ("cmp " & View (Left) & ", " & Plain);
                        return;
                     elsif Negated /= "" then
                        Emit ("cmn " & View (Left) & ", " & Negated);
                        return;
                     end if;
                  end;
               end if;
               Emit ("cmp " & View (Left) & ", "
                     & View (Operand_Register (2, "x10")));
            end Compare_Integer;

            procedure Select_Integer (Done : out Boolean) is
               Scalar : constant Landin.Types.Integer_Name :=
                 Landin.Types.Integer_Name (Kind (Value));
               Signed : constant Boolean := Landin.Types.Is_Signed (Scalar);
               Bits : constant Natural :=
                 Natural (Landin.Types.Width (Scalar, Facts));
               Checked : constant Boolean := not Unchecked and then Op in
                 Landin.IR.Add | Landin.IR.Subtract | Landin.IR.Multiply;
               Commutes : constant Boolean := Op in
                 Landin.IR.Add | Landin.IR.Wrapping_Add
                 | Landin.IR.Multiply | Landin.IR.Wrapping_Multiply
                 | Landin.IR.Bitwise_And | Landin.IR.Bitwise_Or
                 | Landin.IR.Bitwise_Xor;
               --  A constant left operand of an operation that commutes
               --  is the right one instead, where an immediate can go.
               Swapped : constant Boolean :=
                 Commutes and then Is_Constant (Operand (1))
                 and then not Is_Constant (Operand (2));
               Left_Value : constant Landin.IR.Value_Id :=
                 Operand (if Swapped then 2 else 1);
               Right_Value : constant Landin.IR.Value_Id :=
                 Operand (if Swapped then 1 else 2);
               Known : constant Boolean := Is_Constant (Right_Value);
               Right_Bits : constant Pattern :=
                 (if Known then Constant_Of (Right_Value) else 0);
               --  32-bit and narrower operands compute in their 32-bit
               --  views, which zero-extend what they write.
               Wide : constant Boolean := Bits = 64;
               function View (Register : String) return String is
                 (if Wide then Register else Short (Register));
               Into : constant String := Target (Value);
               Left : Unbounded.Unbounded_String;

               function Right (Immediate_Text : String) return String;

               --  The right operand: Immediate_Text when the constant
               --  fits there, else its register.
               function Right (Immediate_Text : String) return String is
               begin
                  if Known and then Immediate_Text /= "" then
                     return Immediate_Text;
                  end if;
                  return View (Read (Right_Value, "x10"));
               end Right;

               function L return String is (View (Unbounded.To_String (Left)));
            begin
               Done := True;
               case Op is
                  when Landin.IR.Add | Landin.IR.Wrapping_Add
                     | Landin.IR.Subtract | Landin.IR.Wrapping_Subtract =>
                     if Signed and then Bits < 32 then
                        Done := False;
                        return;
                     end if;
                     declare
                        Adds : constant Boolean :=
                          Op in Landin.IR.Add | Landin.IR.Wrapping_Add;
                        --  A negative signed constant is the opposite
                        --  operation on its magnitude, whose overflow is
                        --  the same.
                        Flip : constant Boolean :=
                          Known and then Signed
                          and then Is_Negative
                            (Right_Bits, Landin.Targets.Bit_Width (Bits))
                          and then Mask (0 - Right_Bits,
                                         Landin.Targets.Bit_Width (Bits))
                            /= Right_Bits;
                        Amount : constant String :=
                          (if not Known then ""
                           else Selection.Arithmetic_Immediate
                             (Selection.Word
                                (if Flip
                                 then Mask (0 - Right_Bits,
                                            Landin.Targets.Bit_Width (Bits))
                                 else Right_Bits)));
                        Adding : constant Boolean :=
                          (if Flip and then Amount /= "" then not Adds
                           else Adds);
                        Narrow_Check : constant Boolean :=
                          Checked and then Bits < 32 and then Adding;
                     begin
                        Left := Unbounded.To_Unbounded_String
                          (Read (Left_Value, "x9"));
                        Emit ((if Adding then "add" else "sub")
                              & (if Checked and then not Narrow_Check
                                 then "s" else "")
                              & " " & View (Into) & ", " & L & ", "
                              & Right (Amount));
                        if Narrow_Check then
                           --  An unsigned sum wider than its type has a
                           --  bit set above it.
                           Emit ("tst " & Short (Into) & ", "
                                 & Selection.Hexadecimal
                                     (16#FFFF_FFFF# - (2 ** Bits - 1)));
                           Emit ("b.ne " & Trap);
                        elsif Checked then
                           Emit ((if Signed then "b.vs "
                                  elsif Adding then "b.cs " else "b.cc ")
                                 & Trap);
                        end if;
                        Deliver (Value, Into,
                                 Extended => Checked or else Bits >= 32);
                     end;
                  when Landin.IR.Bitwise_And | Landin.IR.Bitwise_Or
                     | Landin.IR.Bitwise_Xor =>
                     Left := Unbounded.To_Unbounded_String
                       (Read (Left_Value, "x9"));
                     Emit ((case Op is
                              when Landin.IR.Bitwise_And => "and ",
                              when Landin.IR.Bitwise_Or => "orr ",
                              when others => "eor ")
                           & View (Into) & ", " & L & ", "
                           & Right
                               (if Known
                                  and then Selection.Is_Logical_Immediate
                                    (Selection.Word (Right_Bits),
                                     (if Wide then 64 else 32))
                                then Selection.Hexadecimal
                                  (Selection.Word (Right_Bits))
                                else ""));
                     Deliver (Value, Into, Extended => True);
                  when Landin.IR.Multiply | Landin.IR.Wrapping_Multiply =>
                     if Bits < 32 then
                        Done := False;
                        return;
                     end if;
                     Left := Unbounded.To_Unbounded_String
                       (Read (Left_Value, "x9"));
                     declare
                        By : constant String := Right ("");
                     begin
                        if not Checked then
                           Emit ("mul " & View (Into) & ", " & L & ", " & By);
                           Deliver (Value, Into, Extended => True);
                        elsif Wide then
                           Emit ((if Signed then "smulh " else "umulh ")
                                 & "x11, " & L & ", " & By);
                           Emit ("mul " & Into & ", " & L & ", " & By);
                           if Signed then
                              Emit ("cmp x11, " & Into & ", asr #63");
                              Emit ("b.ne " & Trap);
                           else
                              Emit ("cbnz x11, " & Trap);
                           end if;
                           Deliver (Value, Into, Extended => True);
                        else
                           --  The whole 64-bit product of two 32-bit
                           --  operands, which fits when its upper half
                           --  repeats the sign of, or is clear above, its
                           --  lower one.
                           Emit ((if Signed then "smull " else "umull ")
                                 & Into & ", " & L & ", " & By);
                           if Signed then
                              Emit ("cmp " & Into & ", " & Short (Into)
                                    & ", sxtw");
                              Emit ("b.ne " & Trap);
                           else
                              Emit ("tst " & Into & ", "
                                    & Selection.Hexadecimal
                                        (16#FFFF_FFFF_0000_0000#));
                              Emit ("b.ne " & Trap);
                           end if;
                           Deliver (Value, Into, Extended => not Signed);
                        end if;
                     end;
                  when Landin.IR.Shift_Left | Landin.IR.Shift_Right =>
                     if not Known or else Right_Bits >= Pattern (Bits) then
                        Done := False;
                        return;
                     end if;
                     Left := Unbounded.To_Unbounded_String
                       (Read (Left_Value, "x9"));
                     declare
                        Count : constant String :=
                          "#" & Trimmed (Pattern'Image (Right_Bits));
                     begin
                        if Op = Landin.IR.Shift_Left then
                           Emit ("lsl " & View (Into) & ", " & L & ", "
                                 & Count);
                           Deliver (Value, Into, Extended => Bits >= 32);
                        elsif not Signed or else Bits >= 32 then
                           Emit ((if Signed then "asr " else "lsr ")
                                 & View (Into) & ", " & L & ", " & Count);
                           Deliver (Value, Into, Extended => True);
                        else
                           --  The sign-extended bits above the count.
                           Emit ("sbfx " & Into & ", "
                                 & Unbounded.To_String (Left) & ", "
                                 & Count & ", #" & Trimmed (Natural'Image
                                   (Bits - Natural (Right_Bits))));
                           Deliver (Value, Into, Extended => False);
                        end if;
                     end;
                  when Landin.IR.Divide | Landin.IR.Remainder =>
                     declare
                        Fixed : constant Boolean :=
                          Landin.IR.Op_Of (Of_Unit, Item, Operand (2))
                            = Landin.IR.Number;
                        Magnitude : constant Selection.Word :=
                          (if Fixed
                           then Selection.Word (Landin.IR.Number_Of
                             (Of_Unit, Item, Operand (2)))
                           else 0);
                        Negative : constant Boolean :=
                          Fixed and then Landin.IR.Is_Negated
                            (Of_Unit, Item, Operand (2));
                     begin
                        if not Fixed
                          or else not Selection.Divides_By_Constant
                            (Bits, Signed, Magnitude, Negative,
                             Reciprocal => Options.Optimize
                               = Landin.Optimization.Speed)
                        then
                           Done := False;
                           return;
                        end if;
                        declare
                           Lines : Unbounded.Unbounded_String;
                           Extended : Boolean;
                        begin
                           Selection.Divide_By_Constant
                             (Bits, Signed, Op = Landin.IR.Remainder,
                              Magnitude, Negative, Read (Operand (1), "x9"),
                              Into, Lines, Extended);
                           Emit_Lines (Unbounded.To_String (Lines));
                           Deliver (Value, Into, Extended);
                        end;
                     end;
                  when others =>
                     Done := False;
               end case;
            end Select_Integer;

            --  Size and speed's negation, complement and logical not, and
            --  their conversions between integers that keep the value's
            --  pattern or only extend its sign, and from an integer to a
            --  float: each from its operand's register into the result's.
            --  False for a form left to the general sequence.
            function Negate return Boolean;
            function Convert return Boolean;

            function Negate return Boolean is
               Into : constant String := Target (Value);
            begin
               if Op = Landin.IR.Logical_Not then
                  Emit ("eor " & Short (Into) & ", "
                        & Short (Read (Operand (1))) & ", #1");
                  Deliver (Value, Into, Extended => True);
               elsif Op = Landin.IR.Complement then
                  Emit ("mvn " & Into & ", " & Read (Operand (1)));
                  Deliver (Value, Into, Extended => False);
               elsif Kind (Value) in Landin.Types.Float_Name then
                  Emit ("fneg " & FP_Target & ", " & FP_Operand (1, "16"));
                  FP_Finish;
               elsif Landin.Types.Width (Kind (Value), Facts) < 32 then
                  return False;
               else
                  declare
                     Wide : constant Boolean :=
                       Landin.Types.Width (Kind (Value), Facts) = 64;
                     Source : constant String := Read (Operand (1));
                  begin
                     Emit ((if Unchecked then "neg " else "negs ")
                           & (if Wide then Into else Short (Into)) & ", "
                           & (if Wide then Source else Short (Source)));
                     if not Unchecked then
                        Emit ((if Landin.Types.Is_Signed (Kind (Value))
                               then "b.vs " else "b.cc ") & Trap);
                     end if;
                     Deliver (Value, Into, Extended => True);
                  end;
               end if;
               return True;
            end Negate;

            function Convert return Boolean is
               From : constant Landin.Types.Scalar_Name :=
                 Kind (Operand (1));
               Into_Type : constant Landin.Types.Scalar_Name := Kind (Value);
               From_Signed : constant Boolean :=
                 From in Landin.Types.Integer_Name
                 and then Landin.Types.Is_Signed (From);
            begin
               if From not in Landin.Types.Integer_Name then
                  return False;
               end if;
               declare
                  From_Bits : constant Natural :=
                    Natural (Landin.Types.Width (From, Facts));
                  Extension : constant String :=
                    (case From_Bits is
                        when 8 => "sxtb ",
                        when 16 => "sxth ",
                        when others => "sxtw ");
               begin
                  if Into_Type in Landin.Types.Float_Name then
                     declare
                        Source : constant String := Read (Operand (1));
                        Converted : constant String :=
                          (if not From_Signed or else From_Bits = 64
                           then Source
                           elsif From_Bits = 32 then Short (Source)
                           else "x9");
                     begin
                        if From_Signed and then From_Bits < 32 then
                           Emit (Extension & "x9, " & Short (Source));
                        end if;
                        Emit ((if From_Signed then "scvtf " else "ucvtf ")
                              & FP_Target & ", " & Converted);
                        FP_Finish;
                     end;
                     return True;
                  elsif Into_Type not in Landin.Types.Integer_Name then
                     return False;
                  end if;
                  declare
                     Into_Bits : constant Natural :=
                       Natural (Landin.Types.Width (Into_Type, Facts));
                     Into_Signed : constant Boolean :=
                       Landin.Types.Is_Signed (Into_Type);
                  begin
                     if Into_Bits < From_Bits
                       or else (From_Signed and then not Into_Signed)
                       or else (Into_Signed and then not From_Signed
                                and then Into_Bits = From_Bits)
                     then
                        return False;
                     end if;
                     declare
                        Source : constant String := Read (Operand (1));
                        Into : constant String := Target (Value);
                     begin
                        if From_Signed and then Into_Bits > From_Bits then
                           --  The sign extended to the new width, which
                           --  then holds it zero-extended.
                           Emit (Extension
                                 & (if Into_Bits = 64 then Into
                                    else Short (Into))
                                 & ", " & Short (Source));
                           Deliver (Value, Into,
                                    Extended => Into_Bits >= 32);
                        else
                           Deliver (Value, Source, Extended => True);
                        end if;
                     end;
                  end;
               end;
               return True;
            end Convert;
         begin
            if Value = Folded.Store or else Value = Folded.Load
              or else Value = Fused_Branch or else Value = Fused_Increment
            then
               return;
            end if;
            case Op is
               when Landin.IR.Assembly =>
                  Assembly_Block (Value);
               when Landin.IR.Number | Landin.IR.Truth | Landin.IR.Atom
                  | Landin.IR.Measurement_Kind =>
                  --  A constant no frame home needs is put where each use
                  --  wants it instead.
                  if not Is_Rematerialized (Value) then
                     declare
                        Into : constant String := Target (Value);
                        Bytes : Landin.Targets.Byte_Count;
                        Alignment : Landin.Targets.Byte_Alignment;
                     begin
                        if Op in Landin.IR.Measurement_Kind then
                           Measurement_Extent
                             (Of_Unit, Item, Value, Facts, Bytes, Alignment);
                           Immediate (Into, (if Op /= Landin.IR.Measure_Align
                             then Pattern (Bytes) else Pattern (Alignment)));
                        else
                           Immediate (Into, Constant_Of (Value));
                        end if;
                        Deliver (Value, Into, Extended => True);
                     end;
                  end if;
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
                        declare
                           Fold : constant Address_Fold := Folding;
                           Into : constant String := Target (Value, "x10");
                           Base : constant String :=
                             Index_Operand (Storage, Field, 0, 0, Nested,
                                            Width => Folded_Size (Fold),
                                            Into => Into);
                        begin
                           if Base /= Into or else Fold.Access_Value
                             /= Landin.IR.No_Value
                           then
                              Folded := Fold;
                              Folded_Base :=
                                Unbounded.To_Unbounded_String (Base);
                           else
                              Deliver (Value, Into, Extended => True);
                           end if;
                        end;
                     else
                        declare
                           Into : constant String := Target (Value);
                        begin
                           Storage_Address (Storage, Field, Into, Nested =>
                             Nested);
                           Deliver (Value, Into, Extended => True);
                        end;
                     end if;
                  end;
               when Landin.IR.Load =>
                  declare
                     Held_In : constant Natural :=
                       Plan.Values (Positive (Value)).Register;
                     Slot : constant Landin.IR.Slot_Id :=
                       Landin.IR.Slot_Of (Of_Unit, Item, Value);
                     Source : constant Natural :=
                       Plan.Slots (Positive (Slot)).Register;
                     Size : constant Held_Size := Size_Of_Value (Value);
                  begin
                     --  A value that is its slot's register moves nothing,
                     --  unless its atoms are checked as it is loaded; a
                     --  float moves between its d registers, or between
                     --  one and a frame cell, directly.
                     if Held_In /= No_Register and then Held_In = Source
                       and then Landin.IR.Atom_Set_Of (Of_Unit, Item, Value)
                         = Landin.IR.No_Atom_Set
                     then
                        null;
                     elsif Held_In in Float_Register
                       and then Source in Float_Register
                     then
                        Emit ("fmov " & Name (Held_In, Size)
                              & ", " & Name (Source, Size));
                     elsif Optimized and then Held_In in Float_Register
                       and then Source = No_Register
                     then
                        Float_Frame (False, Name (Held_In, Size),
                                     Slot_Offset (Layout, Slot));
                     elsif Optimized and then Source in Float_Register
                       and then Held_In = No_Register
                     then
                        Float_Frame (True, Name (Source, Size),
                                     Value_Offset (Layout, Value));
                     else
                        declare
                           Into : constant String := Target (Value);
                        begin
                           Load_Slot (Slot, Into);
                           Deliver (Value, Into, Extended => True);
                        end;
                     end if;
                  end;
               when Landin.IR.Store =>
                  declare
                     Pair : constant Address_Fold :=
                       (if Optimized
                        then Carried (Of_Unit, Item, Current_Block,
                                      Current_Position, Uses, References)
                        else (others => <>));
                  begin
                     --  An address another use keeps formed reaches its
                     --  access through the temporary carrying it without
                     --  a round trip through that temporary.
                     if Pair.Access_Value /= Landin.IR.No_Value then
                        Folded := Pair;
                        Folded_Base := Unbounded.To_Unbounded_String
                          (Read (Operand (1), "x10"));
                        return;
                     end if;
                  end;
                  declare
                     Held_In : constant Natural := Plan.Values
                       (Positive (Operand (1))).Register;
                     Slot : constant Landin.IR.Slot_Id :=
                       Landin.IR.Slot_Of (Of_Unit, Item, Value);
                     Into : constant Natural :=
                       Plan.Slots (Positive (Slot)).Register;
                     Size : constant Held_Size := Size_Of_Value (Operand (1));
                  begin
                     --  A value held in its slot's register moves nothing;
                     --  a float moves between its d registers, or between
                     --  one and a frame cell, directly; a constant goes
                     --  straight into a slot's register.
                     if Held_In /= No_Register and then Held_In = Into then
                        null;
                     elsif Held_In in Float_Register
                       and then Into in Float_Register
                     then
                        Emit ("fmov " & Name (Into, Size) & ", "
                              & Name (Held_In, Size));
                     elsif Is_Rematerialized (Operand (1))
                       and then Into in Float_Register
                     then
                        Float_Constant
                          (Name (Into, Size), Constant_Of (Operand (1)),
                           Size = Landin.Targets.Byte_4);
                     elsif Is_Rematerialized (Operand (1))
                       and then Into /= No_Register
                     then
                        Immediate (Name (Into), Constant_Of (Operand (1)));
                     elsif Optimized and then Into in Float_Register
                       and then Held_In = No_Register
                     then
                        Float_Frame (False, Name (Into, Size),
                                     Value_Offset (Layout, Operand (1)));
                     elsif Optimized and then Held_In in Float_Register
                       and then Into = No_Register
                     then
                        Float_Frame (True, Name (Held_In, Size),
                                     Slot_Offset (Layout, Slot));
                     else
                        Store_Slot (Slot, Read_Or_Zero (Operand (1)),
                                    Extended => Optimized);
                     end if;
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
                     R9 : constant String :=
                       (if Bytes = 8 then "x9" else "w9");
                     R11 : constant String :=
                       (if Bytes = 8 then "x11" else "w11");
                     R12 : constant String :=
                       (if Bytes = 8 then "x12" else "w12");
                     Suffix : constant String :=
                       (if Bytes = 1 then "b" elsif Bytes = 2 then "h"
                        else "");
                     Loop_Name : constant String := Fresh;
                  begin
                     if M = Stack_Prepare then
                        --  D450: the operands are the stack's base and
                        --  length, the entry and its argument.  The top is
                        --  aligned down to sixteen and the first frame laid
                        --  below it as the switch routine's restore reads
                        --  it: x19 the entry, x20 its argument, then zero
                        --  for x21-x28 and d8-d15, the stack's limit, its
                        --  base and the margin (D472), and the frame
                        --  record, x29 zero and x30 past the start
                        --  routine's nop.  A slice that
                        --  cannot hold those 176 bytes and the margin traps
                        --  stack_exhausted (D451); the difference is
                        --  signed, since aligning a short slice's top may
                        --  take it below the base.
                        Load_Value (Operand (1), "x10");
                        Load_Value (Operand (2), "x11");
                        Emit ("add x11, x10, x11");
                        Emit ("and x11, x11, #0xfffffffffffffff0");
                        Emit ("sub x11, x11, x10");
                        Emit ("cmp x11, #" & Trimmed
                          (Landin.Targets.Byte_Count'Image
                             (Stack_Frame + Limit_Margin)));
                        Emit ("b.lt " & Trap (Landin.Panics.Stack_Exhausted));
                        Emit ("add x10, x10, x11");
                        Emit ("sub x10, x10, #" & Trimmed (Natural'Image
                          (Stack_Frame)));
                        Load_Value (Operand (3), "x12");
                        Load_Value (Operand (4), "x13");
                        Address ("x14", Stack_Start);
                        Emit ("add x14, x14, #4");
                        Emit ("stp xzr, x14, [x10, #"
                              & Trimmed (Natural'Image (Stack_Record_Slot))
                              & "]");
                        Emit ("stp x12, x13, [x10]");
                        for Pair in 1 .. Stack_Record_Slot / 16 - 1 loop
                           Emit ("stp xzr, xzr, [x10, #"
                                 & Trimmed (Natural'Image (16 * Pair))
                                 & "]");
                        end loop;
                        --  The base is the frame's top less the aligned
                        --  length.
                        Emit ("add x14, x10, #" & Trimmed (Natural'Image
                          (Stack_Frame)));
                        Emit ("sub x14, x14, x11");
                        Emit ("add x14, x14, #" & Trimmed
                          (Landin.Targets.Byte_Count'Image (Limit_Margin)));
                        Emit ("str x14, [x10, #" & Trimmed (Natural'Image
                          (Stack_Limit_Slot)) & "]");
                        Stack_Used := True;
                        Store_Value (Value, "x10");
                     elsif M = Stack_Switch then
                        --  D450/D472: the switch is one call of the
                        --  program's switch routine, with the address to
                        --  save through in x9 and the stack pointer to
                        --  resume in x10, which a linker's veneer leaves
                        --  alone; the routine making it checked its frame
                        --  (D471).  Every location question treats it as a
                        --  call (Is_Switch).
                        Load_Value (Operand (1), "x9");
                        Load_Value (Operand (2), "x10");
                        Emit ("bl " & Stack_Switcher);
                        Stack_Used := True;
                     elsif Landin.Memory.Operands (M) = 0 then
                        case M is
                           when Compiler_Barrier => null;
                           when Completion_Barrier => Emit ("dsb sy");
                           when Device_Barrier => Emit ("dmb sy");
                           when others => Emit ("dmb ish");
                        end case;
                     else
                        Load_Value (Operand (1), "x10");
                        if Bytes > 1 then
                           Emit ("tst x10, #"
                             & Trimmed (Natural'Image (Bytes - 1)));
                           Emit ("b.ne " & Trap);
                        end if;
                        if M not in Volatile_Load | Volatile_Store then
                           Emit ("dmb ish");
                        end if;
                        if M in Atomic_Load | Volatile_Load then
                           Memory (False, Size, "x9", "x10");
                        elsif M in Atomic_Store | Volatile_Store then
                           Load_Value (Operand (2));
                           Memory (True, Size, "x9", "x10");
                        elsif Has_LSE then
                           --  The acquire-release forms, inside the same
                           --  full fences the retry loop has: an ordering
                           --  is strengthened exactly as much at both
                           --  levels.  Each returns the value it found in
                           --  memory, which is the operation's result.
                           Load_Value (Operand (2), "x11");
                           if M = Atomic_Compare_Exchange then
                              Load_Value (Operand (3), "x12");
                              Emit ("mov " & R9 & ", " & R11);
                              Emit ("casal" & Suffix & " " & R9 & ", " & R12
                                    & ", [x10]");
                           elsif M = Atomic_Add then
                              Emit ("ldaddal" & Suffix & " " & R11 & ", "
                                    & R9 & ", [x10]");
                           else
                              Emit ("swpal" & Suffix & " " & R11 & ", "
                                    & R9 & ", [x10]");
                           end if;
                        else
                           Load_Value (Operand (2), "x11");
                           if M = Atomic_Compare_Exchange then
                              Load_Value (Operand (3), "x12");
                           end if;
                           Put (Loop_Name & ":");
                           Emit ("ldxr" & Suffix & " " & R9 & ", [x10]");
                           if M = Atomic_Compare_Exchange then
                              Emit ("cmp " & R9 & ", " & R11);
                              Emit ("b.ne " & Loop_Name & "_mismatch");
                           elsif M = Atomic_Add then
                              Emit ("add " & R12 & ", " & R9 & ", " & R11);
                           else
                              Emit ("mov " & R12 & ", " & R11);
                           end if;
                           Emit ("stxr" & Suffix & " w13, " & R12
                                 & ", [x10]");
                           Emit ("cbnz w13, " & Loop_Name);
                           if M = Atomic_Compare_Exchange then
                              Emit ("b " & Loop_Name & "_done");
                              Put (Loop_Name & "_mismatch:");
                              Emit ("clrex");
                              Put (Loop_Name & "_done:");
                           end if;
                        end if;
                        if M not in Volatile_Load | Volatile_Store then
                           Emit ("dmb ish");
                        end if;
                        if Landin.Memory.Returns_Value (M) then
                           Store_Value (Value);
                        end if;
                     end if;
                  end;

               when Landin.IR.Load_Indirect =>
                  declare
                     Into : constant String := Load_Target (Value);
                  begin
                     Memory (False, Size_Of_Value (Value), Into,
                             Indirect_Base);
                     Loaded (Value, Into);
                  end;
               when Landin.IR.Store_Indirect =>
                  declare
                     Base : constant String := Indirect_Base;
                  begin
                     Memory (True, Size_Of_Value (Operand (2)),
                             Store_Source (Operand (2)), Base);
                  end;
               when Landin.IR.Load_Datum | Landin.IR.Store_Datum =>
                  Address ("x10", Symbol
                    (Landin.IR.Datum_Of (Of_Unit, Item, Value)));
                  if Op = Landin.IR.Load_Datum then
                     declare
                        Into : constant String := Load_Target (Value);
                     begin
                        Memory (False, Size_Of_Value (Value), Into, "x10");
                        Loaded (Value, Into);
                     end;
                  else
                     Memory (True, Size_Of_Value (Operand (1)),
                             Store_Source (Operand (1)), "x10");
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
                           "x10", Nested => Landin.IR.Path_Of
                             (Of_Unit, Item, Value));
                        if Op = Landin.IR.Load_Field then
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x9", "x10");
                           Emit ("ubfx x9, x9, #" & Trimmed
                             (Natural'Image (Shape.Packing.First)) & ", #"
                             & Trimmed (Natural'Image (Shape.Packing.Bits)));
                           Packed_Atom (Shape.Atoms, Encode => False);
                           Store_Value (Value, Atom_Validated => True);
                        else
                           Load_Value (Operand (1));
                           Packed_Atom (Shape.Atoms, Encode => True);
                           if Shape.Packing.Bits < 64 then
                              Emit ("lsr x11, x9, #" & Trimmed
                                (Natural'Image (Shape.Packing.Bits)));
                              Emit ("cbnz x11, "
                                & Trap (Landin.Panics.Bad_Conversion));
                           end if;
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x11", "x10");
                           Emit ("bfi x11, x9, #" & Trimmed
                             (Natural'Image (Shape.Packing.First)) & ", #"
                             & Trimmed (Natural'Image (Shape.Packing.Bits)));
                           Memory (True, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x11", "x10");
                        end if;
                        return;
                     end if;
                  end;
                  if Optimized then
                     declare
                        Field : constant Landin.IR.Element_Total :=
                          Landin.IR.Element_Total
                            (Landin.IR.Field_Of (Of_Unit, Item, Value));
                        Nested : constant Landin.IR.Path_Step_Array :=
                          Landin.IR.Path_Of (Of_Unit, Item, Value);
                        Into : constant String :=
                          (if Op = Landin.IR.Load_Field
                           then Load_Target (Value) else "");
                     begin
                        if Op = Landin.IR.Load_Field then
                           Part_Access (False, Size_Of_Value (Value), Into,
                                        Place, Field, Nested);
                           Loaded (Value, Into);
                        else
                           Part_Access
                             (True, Size_Of_Value (Operand (1)),
                              Store_Source (Operand (1)), Place, Field,
                              Nested);
                        end if;
                     end;
                     return;
                  end if;
                  Part_Address
                    (Place, Landin.IR.Element_Total
                       (Landin.IR.Field_Of (Of_Unit, Item, Value)),
                     "x10", Nested => Landin.IR.Path_Of (Of_Unit, Item,
                       Value));
                  if Op = Landin.IR.Load_Field then
                     Memory (False, Size_Of_Value (Value), "x9", "x10");
                     Store_Value (Value);
                  else
                     Load_Value (Operand (1));
                     Memory (True, Size_Of_Value (Operand (1)), "x9", "x10");
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
                        Load_Value (Operand (1), "x13");
                        Immediate ("x14", Pattern (Shape.Length));
                        Emit ("cmp x13, x14");
                        Emit ("b.hs " & Trap);
                        Immediate ("x14", Pattern (Shape.Packing.Bits));
                        Emit ("mul x13, x13, x14");
                        Emit ("add x13, x13, #" & Trimmed
                          (Natural'Image (Shape.Packing.First)));
                        Storage_Address
                          (Place, Field, "x10", Nested => Nested);
                        Immediate ("x12", (if Shape.Packing.Bits = 64
                          then Pattern'Last else
                            2 ** Shape.Packing.Bits - 1));
                        if Op = Landin.IR.Load_Element then
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x9", "x10");
                           Emit ("lsr x9, x9, x13");
                           Emit ("and x9, x9, x12");
                           Packed_Atom (Landin.IR.Array_Element_Shape
                             (Of_Unit, Shape).Atoms, Encode => False);
                           Store_Value (Value, Atom_Validated => True);
                        else
                           Load_Value (Operand (2));
                           Packed_Atom (Landin.IR.Array_Element_Shape
                             (Of_Unit, Shape).Atoms, Encode => True);
                           Emit ("bic x11, x9, x12");
                           Emit ("cbnz x11, "
                                & Trap (Landin.Panics.Bad_Conversion));
                           Emit ("lsl x9, x9, x13");
                           Emit ("lsl x12, x12, x13");
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x11", "x10");
                           Emit ("bic x11, x11, x12");
                           Emit ("orr x11, x11, x9");
                           Memory (True, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x11", "x10");
                        end if;
                        return;
                     end if;
                  end;
                  declare
                     Moved : constant Held_Size :=
                       (if Op = Landin.IR.Load_Element
                        then Size_Of_Value (Value)
                        else Size_Of_Value (Operand (2)));
                     Base : constant String := Index_Operand
                       (Place,
                        Landin.IR.Element_Field_Of (Of_Unit, Item, Value),
                        Landin.IR.Variant_Case_Of (Of_Unit, Item, Value),
                        Landin.IR.Variant_Payload_Field_Of
                          (Of_Unit, Item, Value),
                        Landin.IR.Path_Of (Of_Unit, Item, Value),
                        Landin.IR.Element_Path_Of (Of_Unit, Item, Value),
                        Width => Landin.Targets.Bytes (Moved));
                  begin
                     if Op = Landin.IR.Load_Element then
                        declare
                           Into : constant String := Load_Target (Value);
                        begin
                           Memory (False, Moved, Into, Base);
                           Loaded (Value, Into);
                        end;
                     else
                        Memory (True, Moved, Store_Source (Operand (2)),
                                Base);
                     end if;
                  end;
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
                          "x9",
                        (if Op = Landin.IR.Copy_Array then
                           Landin.IR.Variant_Case_Of (Of_Unit, Item, Value)
                         else 0),
                        (if Op = Landin.IR.Copy_Array then
                           Landin.IR.Variant_Payload_Field_Of
                             (Of_Unit, Item, Value) else 0),
                        Landin.IR.Path_Of (Of_Unit, Item, Value));
                     Storage_Address (Source, Field, "x10", Nested => Nested);
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
                        Storage_Address (Destination, Field, "x9", Nested =>
                          Nested);
                        if Op = Landin.IR.Select_Variant then
                           Add_Offset ("x9", Offset);
                        end if;
                        Zero_Bytes (Bytes);
                     end if;
                     if Op = Landin.IR.Select_Variant then
                        Storage_Address
                          (Destination, Field, "x10", Nested => Nested);
                        Immediate ("x9", Pattern
                          (Landin.IR.Variant_Case_Of (Of_Unit, Item, Value) -
                            1));
                        Memory (True, Size_Of
                          (Reached_Shape (Destination, Field, Nested).Element,
                           Facts), "x9", "x10");
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
                       (Destination, Field, "x10", Which, Payload, Nested);
                     Add_Offset ("x10", Landin.Targets.Byte_Count (First)
                       * Landin.Targets.Byte_Count (Landin.Targets.Bytes
                         (Held)));
                     Load_Value (Operand (1));
                     Immediate ("x11", Pattern (Length - First));
                     Emit ("cbz x11, " & Loop_Label & "_end");
                     Put (Loop_Label & ":");
                     Memory (True, Held, "x9", "x10");
                     Emit ("add x10, x10, #"
                       & Trimmed (Positive'Image (Landin.Targets.Bytes
                         (Held))));
                     Emit ("subs x11, x11, #1");
                     Emit ("b.ne " & Loop_Label);
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
                          "x10",
                        (if Op = Landin.IR.Load_Variant_Tag then 0
                         else Landin.IR.Variant_Case_Of (Of_Unit, Item,
                           Value)),
                        (if Op = Landin.IR.Load_Variant_Tag then 0
                         else Landin.IR.Variant_Payload_Field_Of (Of_Unit,
                           Item, Value)),
                        Landin.IR.Path_Of (Of_Unit, Item, Value));
                     if Writing then
                        Load_Value (Operand (1));
                        Memory (True, Size_Of_Value (Operand (1)), "x9",
                          "x10");
                     else
                        Memory (False, Size_Of_Value (Value), "x9", "x10");
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
                     declare
                        Upper : constant String := Read (Operand (4), "x11");
                        Lower : constant String := Read (Operand (3), "x10");
                        Scaling : constant String :=
                          (case Bytes is
                              when 2 => ", lsl #1",
                              when 4 => ", lsl #2",
                              when 8 => ", lsl #3",
                              when others => "");
                     begin
                        if not Unchecked then
                           Emit ("cmp " & Upper & ", "
                                 & Read (Operand (2), "x9"));
                           Emit ((if Landin.IR.Slice_Is_Inclusive
                             (Of_Unit, Item, Value) then "b.hs " else "b.hi ")
                               & Trap);
                           --  Lower and upper read from one place hold one
                           --  value under size and speed, so the lower
                           --  edge cannot fail: `a[i..i]`, or two values
                           --  in one register.  The upper edge above is
                           --  still checked.
                           if not Optimized
                             or else (Operand (3) /= Operand (4)
                                      and then Lower /= Upper)
                           then
                              Emit ("cmp " & Lower & ", " & Upper);
                              Emit ("b.hi " & Trap);
                           end if;
                        end if;
                        declare
                           Fold : constant Address_Fold := Folding;
                           Moved : constant Natural := Folded_Size (Fold);
                        begin
                           --  A folded access scales the lower bound
                           --  itself when the stride is one or the bytes
                           --  it moves.
                           if Moved > 0 and then Bytes in 1 | 2 | 4 | 8
                             and then (Bytes = 1
                                       or else Natural (Bytes) = Moved)
                           then
                              Folded := Fold;
                              Folded_Base := Unbounded.To_Unbounded_String
                                (Read (Operand (1), "x11") & ", " & Lower
                                 & Scaling);
                              return;
                           end if;
                        end;
                        if Optimized and then Bytes in 1 | 2 | 4 | 8 then
                           declare
                              Into : constant String := Target (Value);
                           begin
                              Emit ("add " & Into & ", "
                                    & Read (Operand (1), "x9") & ", "
                                    & Lower & Scaling);
                              Deliver (Value, Into, Extended => True);
                           end;
                           return;
                        end if;
                        Immediate ("x11", Pattern (Bytes));
                        declare
                           Base : constant String := Read (Operand (1));
                           Into : constant String := Target (Value);
                        begin
                           Emit ("madd " & Into & ", " & Lower & ", x11, "
                                 & Base);
                           Deliver (Value, Into, Extended => True);
                        end;
                     end;
                  end;
               when Landin.IR.Empty_Slice_Base =>
                  declare
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Field_Extent (Of_Unit,
                       Landin.IR.Slice_Element_Shape (Of_Unit, Item, Value),
                       Facts, Bytes, Alignment);
                     Immediate ("x9", Pattern (Alignment));
                     Store_Value (Value);
                  end;
               when Landin.IR.Negation | Landin.IR.Complement |
                 Landin.IR.Logical_Not =>
                  if Optimized and then Negate then
                     return;
                  end if;
                  Load_Value (Operand (1));
                  if Op = Landin.IR.Logical_Not then
                     Emit ("eor x9, x9, #1");
                  elsif Op = Landin.IR.Complement then
                     Emit ("mvn x9, x9");
                  elsif Kind (Value) in Landin.Types.Float_Name then
                     Immediate ("x10", (if Kind (Value) = Landin.Types.F32
                       then 2 ** 31 else 2 ** 63));
                     Emit ("eor x9, x9, x10");
                  else
                     Extend ("x9", Kind (Value));
                     Emit ("negs x9, x9");
                     if not Unchecked then
                        Emit ((if Landin.Types.Is_Signed (Kind (Value))
                          then "b.vs " else "b.cc ") & Trap);
                        Check_Fit ("x9", Kind (Value));
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
                     declare
                        Left : constant String := FP_Operand (1, "16");
                        Right : constant String := FP_Operand (2, "17");
                     begin
                        Emit ((case Op is
                          when Landin.IR.Add => "fadd ",
                          when Landin.IR.Subtract => "fsub ",
                          when Landin.IR.Multiply => "fmul ",
                          when Landin.IR.Divide => "fdiv ",
                          when others => raise Compiler_Defect with
                            "invalid float operation")
                          & FP_Target & ", " & Left & ", " & Right);
                     end;
                     FP_Finish;
                  else
                     if Optimized then
                        declare
                           Selected : Boolean;
                        begin
                           Select_Integer (Selected);
                           if Selected then
                              return;
                           end if;
                        end;
                     end if;
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
                        Load_Value (Operand (2), "x10");
                        Extend ("x9", Kind (Value));
                        Extend ("x10", Kind (Value));
                        case Op is
                           when Landin.IR.Add | Landin.IR.Wrapping_Add =>
                              Emit ("adds x9, x9, x10");
                              if Checked then
                                 Emit ((if Signed then "b.vs " else "b.cs ") &
                                   Trap);
                              end if;
                           when Landin.IR.Subtract |
                             Landin.IR.Wrapping_Subtract =>
                              Emit ("subs x9, x9, x10");
                              if Checked then
                                 Emit ((if Signed then "b.vs " else "b.cc ") &
                                   Trap);
                              end if;
                           when Landin.IR.Multiply |
                             Landin.IR.Wrapping_Multiply =>
                              if Checked then
                                 Emit ((if Signed then "smulh " else "umulh ")
                                   & "x11, x9, x10");
                              end if;
                              Emit ("mul x9, x9, x10");
                              if Checked then
                                 if Signed then
                                    Emit ("asr x12, x9, #63");
                                    Emit ("cmp x11, x12");
                                    Emit ("b.ne " & Trap);
                                 else
                                    Emit ("cbnz x11, " & Trap);
                                 end if;
                              end if;
                           when Landin.IR.Divide | Landin.IR.Remainder =>
                              Emit ("cbz x10, " & Trap);
                              if Signed and then Op = Landin.IR.Divide then
                                 Immediate ("x11", To_Pattern
                                   (-Landin.Types.Folded (2 ** (Bits - 1)),
                                     64));
                                 Emit ("cmp x9, x11");
                                 Emit ("b.ne " & Done & "_divide");
                                 Emit ("cmn x10, #1");
                                 Emit ("b.eq " & Trap);
                                 Put (Done & "_divide:");
                              end if;
                              Emit ((if Signed then "sdiv " else "udiv ")
                                & "x11, x9, x10");
                              if Op = Landin.IR.Remainder then
                                 Emit ("msub x9, x11, x10, x9");
                              else
                                 Emit ("mov x9, x11");
                              end if;
                           when Landin.IR.Bitwise_And => Emit
                             ("and x9, x9, x10");
                           when Landin.IR.Bitwise_Or => Emit
                             ("orr x9, x9, x10");
                           when Landin.IR.Bitwise_Xor => Emit
                             ("eor x9, x9, x10");
                           when Landin.IR.Shift_Left | Landin.IR.Shift_Right =>
                              if Signed then
                                 Emit ("tbnz x10, #63, " & Trap);
                              end if;
                              Emit ("cmp x10, #" & Trimmed (Natural'Image
                                (Bits)));
                              Emit ("b.lo " & Done & "_shift");
                              Emit ("mov x9, #0");
                              Emit ("b " & Done);
                              Put (Done & "_shift:");
                              Emit ((if Op = Landin.IR.Shift_Left then "lsl "
                                elsif Signed then "asr " else "lsr ") &
                                  "x9, x9, x10");
                              Put (Done & ":");
                           when others => raise Compiler_Defect with
                             "invalid integer operation";
                        end case;
                        if Checked then
                           Check_Fit ("x9", Kind (Value));
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
                     --  A comparison whose one use is the branch right
                     --  after it leaves its verdict in the flags, for that
                     --  branch to test.
                     Fuses : constant Boolean :=
                       Optimized and then Uses (Positive (Value)) = 1
                       and then Next_Instruction /= Landin.IR.No_Value
                       and then Landin.IR.Op_Of
                         (Of_Unit, Item, Next_Instruction) = Landin.IR.Branch
                       and then Landin.IR.Nth_Operand
                         (Of_Unit, Item, Next_Instruction, 1) = Value;
                     --  So does one whose one use is the condition of the
                     --  choice after it, which csel and fcsel test.
                     Feeds_Choice : constant Boolean :=
                       Optimized and then Uses (Positive (Value)) = 1
                       and then Next_Instruction /= Landin.IR.No_Value
                       and then Landin.IR.Op_Of
                         (Of_Unit, Item, Next_Instruction) = Landin.IR.Choose
                       and then Landin.IR.Nth_Operand
                         (Of_Unit, Item, Next_Instruction, 1) = Value;
                  begin
                     if Float then
                        declare
                           Left : constant String := FP_Operand (1, "16");
                        begin
                           if Optimized and then Is_Constant (Operand (2))
                             and then Constant_Of (Operand (2)) = 0
                           then
                              Emit ("fcmp " & Left & ", #0.0");
                           else
                              Emit ("fcmp " & Left & ", "
                                    & FP_Operand (2, "17"));
                           end if;
                        end;
                     elsif Optimized then
                        Compare_Integer (Scalar);
                     else
                        Load_Value (Operand (1));
                        Load_Value (Operand (2), "x10");
                        Extend ("x9", Scalar);
                        Extend ("x10", Scalar);
                        Emit ("cmp x9, x10");
                     end if;
                     if Fuses then
                        --  fcmp leaves an unordered pair's flags so that
                        --  each condition here is false for it but `ne`,
                        --  as D162 has it, and Branch_On's inverse keeps
                        --  that.
                        Branch_On
                          (Condition,
                           Landin.IR.Target_Of
                             (Of_Unit, Item, Next_Instruction),
                           Landin.IR.Alternative_Of
                             (Of_Unit, Item, Next_Instruction));
                        Fused_Branch := Next_Instruction;
                     elsif Feeds_Choice then
                        Choice_Condition :=
                          Unbounded.To_Unbounded_String (Condition);
                        Fused_Choice := Next_Instruction;
                     else
                        declare
                           Into : constant String := Target (Value);
                        begin
                           Emit ("cset " & Short (Into) & ", " & Condition);
                           Deliver (Value, Into, Extended => True);
                        end;
                     end if;
                  end;
               when Landin.IR.Choose =>
                  --  D338: csel or fcsel on the flags a comparison right
                  --  before left, or else on the stored bool.  Every
                  --  condition fcmp leaves is already false for an
                  --  unordered pair but `ne`.  A choice between one and
                  --  zero is cset.  Loading an operand moves no flag.
                  declare
                     Fused : constant Boolean := Value = Fused_Choice;

                     function Is_Number
                       (Which : Landin.IR.Value_Id; Of_Value : Pattern)
                        return Boolean
                       is (Is_Constant (Which)
                           and then Kind (Value) in Landin.Types.Integer_Name
                           and then Constant_Of (Which) = Of_Value);

                     Counts_Up : constant Boolean :=
                       Is_Number (Operand (2), 1)
                       and then Is_Number (Operand (3), 0);
                     Counts_Down : constant Boolean :=
                       Is_Number (Operand (2), 0)
                       and then Is_Number (Operand (3), 1);
                     Condition : constant String :=
                       (if Fused then Unbounded.To_String (Choice_Condition)
                        else "ne");
                  begin
                     if not Fused then
                        Emit ("cmp " & Short (Read (Operand (1))) & ", #0");
                     end if;
                     if (Counts_Up or else Counts_Down)
                       and then Optimized and then Uses (Positive (Value)) = 1
                       and then Next_Instruction /= Landin.IR.No_Value
                       and then
                         (Landin.IR.Op_Of (Of_Unit, Item, Next_Instruction)
                            = Landin.IR.Wrapping_Add
                          or else
                            (Landin.IR.Op_Of
                               (Of_Unit, Item, Next_Instruction)
                               = Landin.IR.Add
                             and then Landin.IR.Is_Unchecked
                               (Of_Unit, Item, Next_Instruction)))
                       and then
                         (Landin.IR.Nth_Operand
                            (Of_Unit, Item, Next_Instruction, 1) = Value)
                         /= (Landin.IR.Nth_Operand
                               (Of_Unit, Item, Next_Instruction, 2) = Value)
                     then
                        --  The addition that takes the one or zero, which
                        --  cannot trap, is the other addend incremented on
                        --  the condition; a narrow sum is then masked.
                        declare
                           Sum : constant Landin.IR.Value_Id :=
                             Next_Instruction;
                           Other : constant Landin.IR.Value_Id :=
                             Landin.IR.Nth_Operand
                               (Of_Unit, Item, Sum,
                                (if Landin.IR.Nth_Operand
                                      (Of_Unit, Item, Sum, 1) = Value
                                 then 2 else 1));
                           Source : constant String := Read (Other, "x10");
                           Into : constant String := Target (Sum);
                        begin
                           Emit ("cinc " & Into & ", " & Source & ", "
                                 & (if Counts_Up then Condition
                                    else Inverse (Condition)));
                           Deliver (Sum, Into);
                           Fused_Increment := Sum;
                        end;
                     elsif Counts_Up or else Counts_Down then
                        declare
                           Into : constant String := Target (Value);
                        begin
                           Emit ("cset " & Short (Into) & ", "
                                 & (if Counts_Up then Condition
                                    else Inverse (Condition)));
                           Deliver (Value, Into, Extended => True);
                        end;
                     elsif Kind (Value) in Landin.Types.Float_Name then
                        declare
                           If_True : constant String := FP_Operand (2, "16");
                           If_False : constant String := FP_Operand (3, "17");
                        begin
                           Emit ("fcsel " & FP_Target & ", " & If_True
                                 & ", " & If_False & ", " & Condition);
                           FP_Finish;
                        end;
                     else
                        declare
                           If_True : constant String :=
                             Read_Or_Zero (Operand (2), "x10");
                           If_False : constant String :=
                             Read_Or_Zero (Operand (3), "x11");
                           Into : constant String := Target (Value);
                        begin
                           Emit ("csel " & Into & ", " & If_True & ", "
                                 & If_False & ", " & Condition);
                           Deliver (Value, Into, Extended => True);
                        end;
                     end if;
                  end;
               when Landin.IR.Range_Check =>
                  if Optimized then
                     declare
                        Signed : constant Boolean :=
                          Landin.Types.Is_Signed (Kind (Value));
                        Bits : constant Natural :=
                          Natural (Landin.Types.Width (Kind (Value), Facts));
                        Source : constant String := Read (Operand (1));
                        Tested : constant String :=
                          (if Signed and then Bits < 64 then "x10"
                           else Source);

                        procedure Bound
                          (Edge : Landin.Types.Folded; Failing : String);

                        --  Trap when the operand is beyond Edge; an
                        --  unsigned operand is never below zero.
                        procedure Bound
                          (Edge : Landin.Types.Folded; Failing : String)
                        is
                           Plain : constant String :=
                             (if Edge >= 0
                              then Selection.Arithmetic_Immediate
                                (Selection.Word (To_Pattern (Edge, 64)))
                              else "");
                           Negated : constant String :=
                             (if Edge in -16_773_120 .. -1
                              then Selection.Arithmetic_Immediate
                                (Selection.Word (To_Pattern (-Edge, 64)))
                              else "");
                        begin
                           if not Signed and then Edge = 0
                             and then Failing = "lo"
                           then
                              return;
                           elsif Plain /= "" then
                              Emit ("cmp " & Tested & ", " & Plain);
                           elsif Negated /= "" then
                              Emit ("cmn " & Tested & ", " & Negated);
                           else
                              Immediate ("x11", To_Pattern (Edge, 64));
                              Emit ("cmp " & Tested & ", x11");
                           end if;
                           Emit ("b." & Failing & " " & Trap);
                        end Bound;
                     begin
                        if Tested /= Source then
                           Emit ((case Bits is
                                     when 8 => "sxtb ",
                                     when 16 => "sxth ",
                                     when others => "sxtw ")
                                 & Tested & ", " & Short (Source));
                        end if;
                        --  An edge at the type's own extreme passes every
                        --  value, so it is not tested: `ptr(n)`'s upper
                        --  edge is the largest `usize`.
                        if Landin.IR.Range_Lower (Of_Unit, Item, Value)
                          > Landin.Types.Lowest (Kind (Value), Facts)
                        then
                           Bound (Landin.IR.Range_Lower
                                    (Of_Unit, Item, Value),
                                  (if Signed then "lt" else "lo"));
                        end if;
                        if Landin.IR.Range_Upper (Of_Unit, Item, Value)
                          < Landin.Types.Highest (Kind (Value), Facts)
                        then
                           Bound (Landin.IR.Range_Upper
                                    (Of_Unit, Item, Value),
                                  (if Signed then "gt" else "hi"));
                        end if;
                        Deliver (Value, Source, Extended => True);
                     end;
                     return;
                  end if;
                  Load_Value (Operand (1));
                  Extend ("x9", Kind (Value));
                  if Landin.IR.Range_Lower (Of_Unit, Item, Value)
                    > Landin.Types.Lowest (Kind (Value), Facts)
                  then
                     Immediate ("x10", To_Pattern
                       (Landin.IR.Range_Lower (Of_Unit, Item, Value), 64));
                     Emit ("cmp x9, x10");
                     Emit ((if Landin.Types.Is_Signed (Kind (Value))
                       then "b.lt " else "b.lo ") & Trap);
                  end if;
                  if Landin.IR.Range_Upper (Of_Unit, Item, Value)
                    < Landin.Types.Highest (Kind (Value), Facts)
                  then
                     Immediate ("x10", To_Pattern
                       (Landin.IR.Range_Upper (Of_Unit, Item, Value), 64));
                     Emit ("cmp x9, x10");
                     Emit ((if Landin.Types.Is_Signed (Kind (Value))
                       then "b.gt " else "b.hi ") & Trap);
                  end if;
                  Store_Value (Value);
               when Landin.IR.Conversion | Landin.IR.Pointer_Address
                  | Landin.IR.Code_Address =>
                  declare
                     From : constant Landin.Types.Scalar_Name := Kind (Operand
                       (1));
                     Into_Type : constant Landin.Types.Scalar_Name := Kind
                       (Value);
                     From_Float : constant Boolean := From in
                       Landin.Types.Float_Name;
                     Into_Float : constant Boolean := Into_Type in
                       Landin.Types.Float_Name;
                     Done : constant String := Fresh;
                  begin
                     if Optimized and then Convert then
                        return;
                     end if;
                     Load_Value (Operand (1));
                     Extend ("x9", From);
                     if From_Float then
                        FP_Load (1, "16");
                     end if;
                     if From_Float and Into_Float then
                        if From /= Into_Type then
                           Emit ("fcvt " & FP (Into_Type) & "16, " & FP (From)
                             & "16");
                           if Into_Type = Landin.Types.F32 then
                              Emit ("fmov w9, s16");
                              Immediate ("x10", 16#7f80_0000#);
                              Emit ("and x11, x9, x10");
                              Emit ("cmp x11, x10");
                              Emit ("b.ne " & Done);
                              Load_Value (Operand (1), "x11");
                              Immediate ("x10", 16#7ff0_0000_0000_0000#);
                              Emit ("and x11, x11, x10");
                              Emit ("cmp x11, x10");
                              Emit ("b.ne " & Trap);
                              Put (Done & ":");
                           end if;
                        end if;
                        FP_Save;
                     elsif Into_Float then
                        Emit ((if From in Landin.Types.Integer_Name
                          and then Landin.Types.Is_Signed (From)
                          then "scvtf " else "ucvtf ") & FP (Into_Type) &
                            "16, x9");
                        FP_Save;
                     elsif Into_Type = Landin.Types.Bool then
                        if From_Float then
                           Emit ("fcmp " & FP (From) & "16, #0.0");
                           Emit ("b.eq " & Done & "_zero");
                           Emit ("fmov " & FP (From) & "17, #1.0");
                           Emit ("fcmp " & FP (From) & "16, " & FP (From) &
                             "17");
                           Emit ("b.ne " & Trap);
                           Emit ("mov x9, #1");
                           Emit ("b " & Done);
                           Put (Done & "_zero:");
                           Emit ("mov x9, #0");
                           Put (Done & ":");
                        else
                           Emit ("cmp x9, #1");
                           Emit ("b.hi " & Trap);
                        end if;
                        Store_Value (Value);
                     elsif From_Float then
                        declare
                           Bits : constant Natural := Natural
                             (Landin.Types.Width (Into_Type, Facts));
                           Signed : constant Boolean := Landin.Types.Is_Signed
                             (Into_Type);
                           Power : constant Natural := (if Signed then Bits -
                             1 else Bits);
                           Bias : constant Natural := (if From =
                             Landin.Types.F32 then 127 else 1023);
                           Fraction : constant Natural := (if From =
                             Landin.Types.F32 then 23 else 52);
                           Upper : constant Pattern := Pattern (Bias + Power)
                             * 2 ** Fraction;
                        begin
                           --  Range is checked after truncation; -0.5 may
                           --  therefore convert to unsigned zero. NaNs trap.
                           Emit ("frintz " & FP (From) & "16, " & FP (From) &
                             "16");
                           Immediate ("x10", Upper);
                           Emit ("fmov " & FP (From) & "17, "
                             & (if From = Landin.Types.F32 then "w10" else
                               "x10"));
                           Emit ("fcmp " & FP (From) & "16, " & FP (From) &
                             "17");
                           Emit ("b.vs " & Trap);
                           Emit ("b.ge " & Trap);
                           if Signed then
                              Emit ("fneg " & FP (From) & "17, " & FP (From) &
                                "17");
                              Emit ("fcmp " & FP (From) & "16, " & FP (From) &
                                "17");
                           else
                              Emit ("fcmp " & FP (From) & "16, #0.0");
                           end if;
                           Emit ("b.lt " & Trap);
                           Emit ((if Signed then "fcvtzs " else "fcvtzu ")
                             & "x9, " & FP (From) & "16");
                           Store_Value (Value);
                        end;
                     else
                        if not Unchecked and then Into_Type in
                          Landin.Types.Integer_Name
                        then
                           if From in Landin.Types.Integer_Name then
                              if Landin.Types.Is_Signed (From)
                                and then not Landin.Types.Is_Signed (Into_Type)
                              then
                                 Emit ("tbnz x9, #63, " & Trap);
                              elsif not Landin.Types.Is_Signed (From)
                                and then Landin.Types.Is_Signed (Into_Type)
                              then
                                 Emit ("tbnz x9, #63, " & Trap);
                              end if;
                           end if;
                           Check_Fit ("x9", Into_Type);
                        end if;
                        Store_Value (Value);
                     end if;
                  end;
               when Landin.IR.Function_Address =>
                  declare
                     Callee : constant Landin.IR.Item_Id :=
                       Landin.IR.Callee_Of (Of_Unit, Item, Value);
                     Into : constant String := Target (Value);
                  begin
                     Address (Into, Symbol (Callee), Landin.IR.Is_External
                       (Of_Unit, Callee));
                     Deliver (Value, Into, Extended => True);
                  end;
               when Landin.IR.Evidence_Address =>
                  declare
                     Into : constant String := Target (Value);
                  begin
                     Address (Into, Evidence_Symbol
                       (Landin.IR.Evidence_Of (Of_Unit, Item, Value)));
                     Deliver (Value, Into, Extended => True);
                  end;
               when Landin.IR.Evidence_Function =>
                  Load_Value (Operand (1));
                  if Landin.IR.Evidence_Is_Erased
                    (Of_Unit, Landin.IR.Evidence_Of (Of_Unit, Item, Value))
                  then
                     Emit ("ldr x9, [x9, #8]");
                  end if;
                  Add_Offset ("x9", Landin.Targets.Evidence_Function_Offset
                    (Facts, Landin.IR.Evidence_Entry_Of (Of_Unit, Item,
                      Value)));
                  Emit ("ldr x9, [x9]");
                  Store_Value (Value);
               when Landin.IR.Evidence_Self =>
                  Load_Value (Landin.IR.Nth_Operand (Of_Unit, Item, Operand
                    (1), 1));
                  Emit ("ldr x9, [x9]");
                  Store_Value (Value);
               when Landin.IR.Failure_Test =>
                  Load_Value (Operand (1));
                  Emit ("cmp w9, #0");
                  Emit ("cset w9, ne");
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
                     if Prepares and then Bytes > Unchecked_Bytes then
                        Check_Limit (Bytes);
                     end if;
                     Reserve (Bytes);
                     Deepest_Area :=
                       Landin.Targets.Byte_Count'Max (Deepest_Area, Bytes);
                     for Index in 1 .. Count loop
                        if Index <= 8 then
                           Load_Value (Operand (Index + Offset), "x"
                             & Trimmed (Natural'Image (Index - 1)));
                        else
                           Load_Value (Operand (Index + Offset));
                           declare
                              Stack_At : constant Landin.Targets.Byte_Count :=
                                Landin.Targets.Byte_Count (Index - 9) * 8;
                           begin
                              if Stack_At <= 32760 then
                                 Emit ("str x9, [sp, #"
                                   & Trimmed (Landin.Targets.Byte_Count'Image
                                     (Stack_At)) & "]");
                              else
                                 Emit ("mov x10, sp");
                                 Add_Offset ("x10", Stack_At);
                                 Emit ("str x9, [x10]");
                              end if;
                           end;
                        end if;
                     end loop;
                     if Indirect then
                        Load_Value (Operand (1), "x14");
                        Emit ("blr x14");
                     else
                        Emit ("bl " & Symbol (Landin.IR.Callee_Of (Of_Unit,
                          Item, Value)));
                     end if;
                     if Landin.IR.Failure_Slot_Of (Of_Unit, Item, Value) /=
                       Landin.IR.No_Slot
                     then
                        Store_Slot (Landin.IR.Failure_Slot_Of (Of_Unit, Item,
                          Value), "x8");
                     end if;
                     if Landin.IR.Result_Of (Of_Unit, Item, Value) in
                       Landin.Types.Scalar_Name
                     then
                        Store_Value (Value, "x0");
                     end if;
                     Restore_Stack (Bytes);
                  end;
               when Landin.IR.Jump =>
                  --  Size and speed fall through to the block that follows.
                  if not Optimized
                    or else Landin.IR.Target_Of (Of_Unit, Item, Value)
                      /= Following
                  then
                     Emit ("b " & Label (Item, Landin.IR.Target_Of (Of_Unit,
                       Item, Value)));
                  end if;
               when Landin.IR.Branch =>
                  if Optimized then
                     declare
                        Truth : constant String :=
                          Short (Read (Operand (1)));
                        Yes : constant Landin.IR.Block_Id :=
                          Landin.IR.Target_Of (Of_Unit, Item, Value);
                        No : constant Landin.IR.Block_Id :=
                          Landin.IR.Alternative_Of (Of_Unit, Item, Value);
                     begin
                        if Yes = Following and then No /= Following then
                           Emit ("cbz " & Truth & ", " & Label (Item, No));
                        else
                           Emit ("cbnz " & Truth & ", " & Label (Item, Yes));
                           if No /= Following then
                              Emit ("b " & Label (Item, No));
                           end if;
                        end if;
                     end;
                     return;
                  end if;
                  Load_Value (Operand (1));
                  Emit ("cbnz w9, " & Label (Item, Landin.IR.Target_Of
                    (Of_Unit, Item, Value)));
                  Emit ("b " & Label (Item, Landin.IR.Alternative_Of (Of_Unit,
                    Item, Value)));
               when Landin.IR.Leave =>
                  if Is_C_Item (Item) then
                     C_Result (Value);
                  elsif Result in Landin.Types.Scalar_Name then
                     Load_Value (Operand (1), "x0");
                  elsif Result in Landin.Types.Aggregate |
                    Landin.Types.Fixed_Array
                  then
                     declare
                        Slot : constant Landin.IR.Slot_Id :=
                          Landin.IR.Result_Slot (Of_Unit, Item);
                     begin
                        Load_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1));
                        Frame_Address (Slot_Offset (Layout, Slot), "x10");
                        Copy_Bytes (Whole_Clear_Extent
                          ((Kind => Landin.IR.Frame_Slot, Slot => Slot), 0,
                            Landin.IR.No_Path_Steps));
                     end;
                  end if;
                  Emit ("mov w8, #0");
                  Finish_Exit;
               when Landin.IR.Halt =>
                  if Panic = null
                    or else not Landin.Panics.Calls_Out (Panic.all)
                  then
                     Emit ("brk #1");
                  else
                     Emit ("b " & Trap (Landin.Panics.Unreachable));
                  end if;

               when Landin.IR.Fail =>
                  Load_Value (Operand (1), "x8");
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
         if Is_Exported_Item (Item) then
            Emit (".globl " & Symbol (Item));
         end if;
         Emit (".p2align 2");
         Platform_Directive (Platform.Begin_Function (Format, Symbol (Item)));
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
               Emit (".cfi_undefined x30");
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
            Emit ("brk #1");
            if Debug /= null then
               Put (Dwarf.Label_Name (Local_Prefix, "end", Item) & ":");
               Emit (".cfi_endproc");
            end if;
            Platform_Directive (Platform.End_Function (Format, Symbol (Item)));
            Landin.Build_Reports.Append (Report,
              Landin.Build_Reports.Routine_Statistics'
                (Item => Item, Naked => True, others => <>));
            return;
         end if;
         Emit ("stp x29, x30, [sp, #-16]!");
         if Debug /= null then
            Emit (".cfi_def_cfa_offset 16");
            Emit (".cfi_offset w29, -16");
            Emit (".cfi_offset w30, -8");
         end if;
         Emit ("mov x29, sp");
         if Debug /= null then
            Emit (".cfi_def_cfa_register w29");
         end if;
         --  The library's initializer receives main's incoming argc, argv
         --  and envp in w0, x1 and x2 before the body can clobber them.
         if Item = Hosted_Entry and then Initializer /= Landin.IR.No_Item then
            Emit ("bl " & Symbol (Initializer));
         end if;
         --  D471: the frame is checked against the current stack's limit
         --  before it is reserved, unless the routine calls nothing and
         --  its frame is one the margin pays for.  The selected handler is
         --  not checked: it stores zero in the cell, so that it and what
         --  it calls run on what a failed check left, without a check
         --  that would enter it again.
         if Prepares then
            if Panic /= null and then Item = Landin.Panics.Handler (Panic.all)
            then
               Address ("x16", Stack_Limit);
               Emit ("str xzr, [x16]");
            elsif not Landin.Backend.Call_Free (Of_Unit, Item)
              or else Extent (Layout) > Unchecked_Bytes
            then
               Check_Limit (Extent (Layout));
            end if;
         end if;
         Reserve (Extent (Layout));
         Move_Saves (Store => True);
         if Panic /= null and then Item = Landin.Panics.Handler (Panic.all)
         then
            declare
               Retry : constant String := Fresh;
            begin
               Address ("x16", Local_Prefix & "landin_panic_active");
               Put (Retry & ":");
               Emit ("ldaxr w17, [x16]");
               Emit ("cbnz w17, " & Hard_Trap);
               Emit ("mov w17, #1");
               Emit ("stlxr w15, w17, [x16]");
               Emit ("cbnz w15, " & Retry);
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
                  --  A parameter held in a register moves there straight
                  --  from the one it arrives in, or stays where it is.
                  Direct : constant Boolean := Index <= 8
                    and then not Aggregate
                    and then Plan.Slots (Positive (Slot)).Register
                      /= No_Register;
                  Home : constant Landin.IR.Slot_Id :=
                    Landin.IR.In_Place_Home (Of_Unit, Item, Slot);

                  --  The unit a shaped slot moves by.  The carrier
                  --  addresses storage aligned for this shape (docs/ir.md)
                  --  and the slot is fresh, so an aligned whole-unit
                  --  extent needs no runtime alignment test.
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
                     if Alignment >= 8 and then Bytes mod 8 = 0 then
                        return 8;
                     elsif Alignment >= 4 and then Bytes mod 4 = 0 then
                        return 4;
                     end if;
                     return 1;
                  end Width_Of;
               begin
                  if Direct then
                     null;
                  elsif Index <= 8 then
                     Emit ("mov x10, x" & Trimmed (Natural'Image (Index - 1)));
                  else
                     Emit ("mov x10, x29");
                     Add_Offset ("x10", 16 + Landin.Targets.Byte_Count (Index
                       - 9) * 8);
                     Emit ("ldr x10, [x10]");
                  end if;
                  if Aggregate then
                     declare
                        Zero_Label : constant String := Fresh;
                        Done_Label : constant String := Fresh;
                        Bytes : constant Landin.Targets.Byte_Count :=
                          Whole_Clear_Extent
                            ((Kind => Landin.IR.Frame_Slot, Slot => Slot), 0,
                             Landin.IR.No_Path_Steps);
                        Width : constant Landin.Targets.Byte_Count :=
                          Width_Of (Slot, Bytes);
                     begin
                        Frame_Address (Slot_Offset (Layout, Slot), "x9");
                        Emit ("cbz x10, " & Zero_Label);
                        if Width > 1 then
                           Move_Units (Bytes, Width, Copy => True);
                        else
                           Copy_Bytes (Bytes);
                        end if;
                        Emit ("b " & Done_Label);
                        Put (Zero_Label & ":");
                        if Width > 1 then
                           Move_Units (Bytes, Width, Copy => False);
                        else
                           Zero_Bytes (Bytes);
                        end if;
                        Put (Done_Label & ":");
                     end;
                  elsif Direct then
                     Store_Slot
                       (Slot, "x" & Trimmed (Natural'Image (Index - 1)));
                  else
                     Store_Slot (Slot, "x10");
                  end if;

                  --  Landin.IR.In_Place's parameter is an address slot,
                  --  stored above like a scalar, through which the body
                  --  reads its caller's storage.  D97's zero carrier still
                  --  clears the parameter's own home, which the parameter
                  --  then addresses.  A direct parameter's carrier is still
                  --  in the register it arrived in; x10 holds no carrier.
                  if Home /= Landin.IR.No_Slot then
                     declare
                        Carrier : constant String :=
                          (if Direct
                           then "x" & Trimmed (Natural'Image (Index - 1))
                           else "x10");
                        Done_Label : constant String := Fresh;
                        Bytes : constant Landin.Targets.Byte_Count :=
                          Whole_Clear_Extent
                            ((Kind => Landin.IR.Frame_Slot, Slot => Home), 0,
                             Landin.IR.No_Path_Steps);
                        Width : constant Landin.Targets.Byte_Count :=
                          Width_Of (Home, Bytes);
                     begin
                        Emit ("cbnz " & Carrier & ", " & Done_Label);
                        Frame_Address (Slot_Offset (Layout, Home), "x9");
                        if Width > 1 then
                           Move_Units (Bytes, Width, Copy => False);
                        else
                           Zero_Bytes (Bytes);
                        end if;
                        Frame_Address (Slot_Offset (Layout, Home), "x10");
                        Store_Slot (Slot, "x10");
                        Put (Done_Label & ":");
                     end;
                  end if;
               end;
            end loop;
         end if;
         if Optimized then
            Count_Uses (Of_Unit, Item, Uses, References);
         end if;
         for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            Put (Label (Item, Landin.IR.Block_Id (Block)) & ":");
            for Position in 1 .. Landin.IR.Length (Of_Unit, Item,
              Landin.IR.Block_Id (Block)) loop
               Current_Block := Landin.IR.Block_Id (Block);
               Current_Position := Position;
               Current_Value := Landin.IR.Nth_Value (Of_Unit, Item,
                 Landin.IR.Block_Id (Block), Position);
               if Debug /= null then
                  Put (Dwarf.Label_Name (Local_Prefix, "value", Item,
                    Natural (Current_Value)) & ":");
                  Put (Dwarf.Source_Line (Debug.all,
                    Landin.IR.Origin_Of (Of_Unit, Item, Current_Value)));
                  Row := Lines.Last_Index;
               end if;
               Instruction (Current_Value);
               if Debug /= null then
                  --  A value that emits no instruction, such as a constant
                  --  stored from the zero register where it is used, keeps
                  --  the labels its location lists name but no line row of
                  --  its own: a row covering no instruction is one LLDB's
                  --  prologue and line lookups read as the next line's.
                  declare
                     --  A line without its leading tab or spaces.
                     function Content (Line : String) return String;

                     function Content (Line : String) return String is
                        First : Positive := Line'First;
                     begin
                        while First <= Line'Last
                          and then Line (First) in ' ' | ASCII.HT
                        loop
                           First := First + 1;
                        end loop;
                        return Line (First .. Line'Last);
                     end Content;

                     Emits : Boolean := False;
                  begin
                     for Index in Row + 1 .. Lines.Last_Index loop
                        declare
                           Text : constant String := Content
                             (Unbounded.To_String
                                (Lines.Element (Index).Text));
                        begin
                           if Text'Length > 0
                             and then Text (Text'First) /= '.'
                             and then Text (Text'Last) /= ':'
                           then
                              Emits := True;
                              exit;
                           end if;
                        end;
                     end loop;
                     declare
                        Text : constant String := Content
                          (Unbounded.To_String (Lines.Element (Row).Text));
                     begin
                        if not Emits
                          and then Ada.Strings.Fixed.Index (Text, ".loc ")
                            = Text'First
                        then
                           Lines.Delete (Row);
                        end if;
                     end;
                  end;
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
               Immediate ("x0", Pattern (Landin.Panics.Code
                 (Panic.all, Edge.Reason)));
               Immediate ("x1", Pattern (Edge.Site));
               Emit ("bl " & Symbol (Landin.Panics.Handler (Panic.all)));
            else
               --  D361: the line for this operation, and its length, to
               --  the routine that writes it and ends the process.
               declare
                  Line : constant String := Landin.Panics.Report
                    (Panic.all, Edge.Origin, Edge.Reason);
               begin
                  Address ("x0", Report_Label (Reports.Index_Of (Line)));
                  Immediate ("x1", Pattern (Line'Length));
                  Emit ("bl " & Reporter);
               end;
            end if;
            Emit ("brk #1");
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
            Emit ("mov sp, x29");
            if Panic = null or else not Landin.Panics.Calls_Out (Panic.all)
            then
               null;
            elsif Landin.Panics.Handler (Panic.all) /= Landin.IR.No_Item
            then
               Immediate ("x0", Pattern (Landin.Panics.Code
                 (Panic.all, Landin.Panics.Stack_Exhausted)));
               Immediate ("x1", Pattern (Landin.Panics.Site
                 (Panic.all, Landin.IR.Origin_Of (Of_Unit, Item),
                  Landin.Panics.Stack_Exhausted)));
               Emit ("bl " & Symbol (Landin.Panics.Handler (Panic.all)));
            else
               declare
                  Line : constant String := Landin.Panics.Report
                    (Panic.all, Landin.IR.Origin_Of (Of_Unit, Item),
                     Landin.Panics.Stack_Exhausted);
               begin
                  Address ("x0", Report_Label (Reports.Index_Of (Line)));
                  Immediate ("x1", Pattern (Line'Length));
                  Emit ("bl " & Reporter);
               end;
            end if;
            Emit ("brk #1");
         end if;
         Put (Hard_Trap & ":");
         Emit ("brk #1");
         if Debug /= null then
            Put (Dwarf.Label_Name (Local_Prefix, "end", Item) & ":");
            Emit (".cfi_endproc");
         end if;
         Platform_Directive (Platform.End_Function (Format, Symbol (Item)));
         Landin.Build_Reports.Append (Report,
           Landin.Build_Reports.Routine_Statistics'
             (Item => Item, Frame_Bytes => Extent (Layout),
              Spill_Bytes => Spill_Bytes (Layout),
              Save_Bytes => Save_Bytes (Layout),
              Register_Count => Save_Count (Plan.Saves or Plan.Held),
              Spill_Count => Plan.Homes,
              Stack_Bytes => 16 + Extent (Layout) + Deepest_Area,
              Calls_Panic => not Edges.Is_Empty
                or else (Limit_Trapped and then Panic /= null
                         and then Landin.Panics.Calls_Out (Panic.all)),
              others => <>));
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

      procedure Emit_Datum (Item : Landin.IR.Item_Id);
      procedure End_Object (Item : Landin.IR.Item_Id);

      --  An object's size runs from its label to here.
      procedure End_Object (Item : Landin.IR.Item_Id) is
      begin
         Platform_Directive (Platform.End_Object
           (Format, Symbol (Item), ".-" & Symbol (Item)));
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
                 "a malformed recursive array image reached arm64";
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
                 "a malformed recursive variant image reached arm64";
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
                       "a malformed nested image reached arm64";
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
         Platform_Directive (Platform.Begin_Object (Format, Symbol (Item)));
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
         Power : Natural := 0;
         Remaining : Natural := Natural (Alignment);
      begin
         while Remaining > 1 loop
            Power := Power + 1;
            Remaining := Remaining / 2;
         end loop;
         if Is_Exported_Item (Item) then
            Emit (".globl " & Symbol (Item));
         end if;
         case Format is
            when Landin.Targets.Capabilities.Mach_O =>
               Emit (".zerofill __DATA,__bss," & Symbol (Item) & ","
                 & Trimmed (Landin.Targets.Byte_Count'Image (Size)) & ","
                 & Trimmed (Natural'Image (Power)));
            when Landin.Targets.Capabilities.ELF =>
               --  The whole datum is its own `.bss` input section, pushed
               --  and popped, so the section around it is unchanged.
               Emit (ELF_Spelling.Push_Item_Section
                 ("bss", "datum", Positive (Item)));
               Emit (".balign "
                 & Trimmed (Landin.Targets.Byte_Alignment'Image (Alignment)));
               Emit (ELF_Spelling.Object_Type (Symbol (Item)));
               Put (Symbol (Item) & ":");
               Emit (".zero "
                 & Trimmed (Landin.Targets.Byte_Count'Image (Size)));
               Emit (ELF_Spelling.Size
                 (Symbol (Item),
                  Trimmed (Landin.Targets.Byte_Count'Image (Size))));
               Emit (ELF_Spelling.Pop_Section);
         end case;
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
            if Is_Exported_Item (Item) then
               Put (Character'Val (9) & ".globl " & Symbol (Item));
            end if;

               Put (Character'Val (9) & ".balign "
                 & Trimmed
                     (Landin.Targets.Byte_Alignment'Image
                        (Landin.Targets.Alignment_Of (Facts, Held))));
            Platform_Directive (Platform.Begin_Object (Format, Symbol (Item)));
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
         Platform_Directive (Platform.Begin_Object (Format, Symbol (Item)));
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
         if Is_Exported_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".balign "
              & Trimmed
                  (Landin.Targets.Byte_Alignment'Image
                     (Landin.Targets.Alignment_Of (Facts, Held))));
         Platform_Directive (Platform.Begin_Object (Format, Symbol (Item)));
         Put (Symbol (Item) & ":");
         Emit (Directive (Held) & " " & Written);
         End_Object (Item);
      end Emit_Datum;

   begin
      if Landin.Targets.Capabilities.Backend_For (Facts)
          not in Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
               | Landin.Targets.Capabilities.Arm64_ELF
        or else not Landin.Targets.Levels.Belongs_To (Level, Facts)
      then
         raise Compiler_Defect with
           "arm64 emission needs an arm64 description";
      end if;
      --  Name the architecture even at the default: Apple's implicit
      --  assembler level admits instructions above armv8-a (D255).
      Emit (".arch " & Landin.Targets.Levels.Name (Level));
      Validate_Linkage;
      Allocate_Symbols;
      if Panic /= null and then Landin.Panics.Handler (Panic.all)
        /= Landin.IR.No_Item
      then
         case Format is
            when Landin.Targets.Capabilities.Mach_O =>
               Emit (".zerofill __DATA,__bss," & Local_Prefix
                 & "landin_panic_active,4,2");
            when Landin.Targets.Capabilities.ELF =>
               Emit (ELF_Spelling.Push_Panic_Flag_Section);
               Emit (".balign 4");
               Put (Local_Prefix & "landin_panic_active:");
               Emit (".zero 4");
               Emit (ELF_Spelling.Pop_Section);
         end case;
      end if;
      Emit (".text");
      if Debug /= null then
         Preamble_After := Natural (Lines.Length);
         Unbounded.Append (Preamble_Text, Dwarf.Preamble
           (Debug.all, Local_Prefix,
            Mach_O => Format = Landin.Targets.Capabilities.Mach_O));
      end if;
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then not Landin.IR.Is_External (Of_Unit, Item)
            then
               --  On ELF every routine and datum is its own input
               --  section, so --gc-sections drops what nothing retained
               --  reaches; Mach-O splits at symbols for -dead_strip.
               if Format = Landin.Targets.Capabilities.ELF then
                  Emit (ELF_Spelling.Item_Section ("text", "routine", Index));
               end if;
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
                  Emit (if Format = Landin.Targets.Capabilities.ELF
                        then ELF_Spelling.Item_Section
                          ("rodata", "datum", Index)
                        else Platform.Read_Only_Section (Format));
                  Emit_Array_Image_Datum (Item);
               else
                  Emit (if Format = Landin.Targets.Capabilities.ELF
                        then ELF_Spelling.Item_Section
                          ("data", "datum", Index)
                        else ".data");
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
         declare
            Kept : constant Kept_Entries :=
              Kept_Evidence_Entries
                (Of_Unit,
                 (if Panic = null then Landin.IR.No_Item
                  else Landin.Panics.Handler (Panic.all)),
                 Meanings, Names);
         begin
            Emit (Platform.Relocated_Read_Only_Section (Format));
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
                     if Format = Landin.Targets.Capabilities.ELF then
                        Emit (ELF_Spelling.Item_Section
                          ("data.rel.ro.local", "evidence", Index));
                     end if;
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
                        --  D374: an entry nothing can project is a zero word.
                        if Is_Kept (Kept, Id, Entry_Index) then
                           Emit (".quad " & Symbol
                             (Landin.IR.Evidence_Entry_Target (Of_Unit, Id,
                               Entry_Index)));
                        else
                           Emit (".quad 0");
                        end if;
                     end loop;
                  end if;
               end;
            end loop;
         end;
      end if;
      --  D450 and D447.  The switch routine is out of line, one per
      --  program, so that its unwind information is exact at every
      --  instruction rather than threaded through a caller's frame.  It is
      --  called with the address to save through in x9 and the stack
      --  pointer to resume in x10.  It opens with the frame record every
      --  routine has (D475), stores x19-x28, d8-d15 and the current
      --  stack's limit (D472) below it on the leaving stack, stores sp
      --  through x9, points x29 at the resumed stack's frame record and
      --  then loads its sp, puts the limit it saved back in the cell and
      --  restores the same registers before returning into the resumed
      --  context.  Both stacks hold the same Stack_Frame bytes at the
      --  switch, so one CFA rule, x29 plus the record, is right from the
      --  record's opening to the restore of sp past the saved registers:
      --  stopped before x29 moves, a debugger unwinds into the leaving
      --  fibre's frames, and after it into the resumed fibre's, whether
      --  it reads the unwind information or follows the frame record.
      --  x18 is never named.  Every caller-saved register is left
      --  changed, as by a call.
      --
      --  The start routine is the return address of a prepared stack's
      --  first frame: the restore leaves the entry in x19, its argument in
      --  x20 and zero in x29, so the frame-pointer chain ends at the
      --  entry's first frame, and its unwind information says the return
      --  address is undefined, which ends a debugger's walk there.  A first
      --  frame returns to the instruction after the routine's opening nop,
      --  never run, because a debugger looks up a return address less one
      --  and must find it inside this description; on Mach-O the nop also
      --  keeps that address inside the routine's own atom.  An entry is
      --  `-> noreturn`; if it returns anyway, that is D232's `unreachable`
      --  at site zero, as a firmware entry's return is.
      if Stack_Used then
         declare
            Pairs : constant array (1 .. 9) of String (1 .. 8) :=
              ["x19, x20", "x21, x22", "x23, x24", "x25, x26", "x27, x28",
               "d8, d9  ", "d10, d11", "d12, d13", "d14, d15"];
            Names : constant array (1 .. 9, 1 .. 2) of String (1 .. 3) :=
              [["w19", "w20"], ["w21", "w22"], ["w23", "w24"],
               ["w25", "w26"], ["w27", "w28"], ["d8 ", "d9 "],
               ["d10", "d11"], ["d12", "d13"], ["d14", "d15"]];

            function Image (Number : Integer) return String
              is (Trimmed (Integer'Image (Number)));
         begin
            Emit (if Format = Landin.Targets.Capabilities.ELF
                  then ".section .text.landin_stack,""ax"",@progbits"
                  else ".text");
            Emit (".p2align 2");
            Platform_Directive
              (Platform.Begin_Function (Format, Stack_Switcher));
            Put (Stack_Switcher & ":");
            if Debug /= null then
               Emit (".cfi_startproc");
            end if;
            Emit ("stp x29, x30, [sp, #-16]!");
            if Debug /= null then
               Emit (".cfi_def_cfa_offset 16");
               Emit (".cfi_offset w29, -16");
               Emit (".cfi_offset w30, -8");
            end if;
            Emit ("mov x29, sp");
            if Debug /= null then
               Emit (".cfi_def_cfa_register w29");
            end if;
            Emit ("sub sp, sp, #" & Image (Stack_Record_Slot));
            for Index in Pairs'Range loop
               Emit ("stp " & Trimmed (Pairs (Index)) & ", [sp, #"
                     & Image (16 * (Index - 1)) & "]");
               if Debug /= null then
                  for Half in 1 .. 2 loop
                     Emit (".cfi_offset " & Trimmed (Names (Index, Half))
                           & ", -" & Image
                             (Stack_Frame - 16 * (Index - 1)
                              - 8 * (Half - 1)));
                  end loop;
               end if;
            end loop;
            Emit ("adrp x12, " & Platform.Page (Format, Stack_Limit, False));
            Emit ("add x12, x12, "
                  & Platform.Page_Offset (Format, Stack_Limit, False));
            Emit ("ldr x11, [x12]");
            Emit ("str x11, [sp, #" & Image (Stack_Limit_Slot) & "]");
            Emit ("mov x11, sp");
            Emit ("str x11, [x9]");
            Emit ("add x29, x10, #" & Image (Stack_Record_Slot));
            Emit ("mov sp, x10");
            Emit ("ldr x11, [sp, #" & Image (Stack_Limit_Slot) & "]");
            Emit ("str x11, [x12]");
            for Index in reverse Pairs'Range loop
               Emit ("ldp " & Trimmed (Pairs (Index)) & ", [sp, #"
                     & Image (16 * (Index - 1)) & "]");
               if Debug /= null then
                  for Half in 1 .. 2 loop
                     Emit (".cfi_restore " & Trimmed (Names (Index, Half)));
                  end loop;
               end if;
            end loop;
            Emit ("add sp, sp, #" & Image (Stack_Record_Slot));
            if Debug /= null then
               Emit (".cfi_def_cfa sp, 16");
            end if;
            Emit ("ldp x29, x30, [sp], #16");
            if Debug /= null then
               Emit (".cfi_def_cfa_offset 0");
               Emit (".cfi_restore w29");
               Emit (".cfi_restore w30");
            end if;
            Emit ("ret");
            if Debug /= null then
               Emit (".cfi_endproc");
            end if;
            Platform_Directive
              (Platform.End_Function (Format, Stack_Switcher));

            Emit (".p2align 2");
            Platform_Directive
              (Platform.Begin_Function (Format, Stack_Start));
            Put (Stack_Start & ":");
            if Debug /= null then
               Emit (".cfi_startproc");
               Emit (".cfi_undefined w30");
            end if;
            Emit ("nop");
            Emit ("mov x0, x20");
            Emit ("blr x19");
            if Panic /= null and then Landin.Panics.Handler (Panic.all)
              /= Landin.IR.No_Item
            then
               Immediate ("x0", Pattern (Landin.Panics.Code
                 (Panic.all, Landin.Panics.Unreachable)));
               Emit ("mov x1, #0");
               Emit ("bl " & Symbol (Landin.Panics.Handler (Panic.all)));
            elsif Panic /= null
              and then Landin.Panics.Reports_Default (Panic.all)
            then
               declare
                  Line : constant String := Landin.Panics.Report
                    (Panic.all, Landin.Provenance.No_Origin,
                     Landin.Panics.Unreachable);
               begin
                  Address ("x0", Report_Label (Reports.Index_Of (Line)));
                  Immediate ("x1", Pattern (Line'Length));
                  Emit ("bl " & Reporter);
               end;
            end if;
            Emit ("brk #1");
            if Debug /= null then
               Emit (".cfi_endproc");
            end if;
            Platform_Directive (Platform.End_Function (Format, Stack_Start));
         end;
         --  D471's cell, zero until a switch resumes a prepared stack.
         case Format is
            when Landin.Targets.Capabilities.Mach_O =>
               Emit (".zerofill __DATA,__bss," & Stack_Limit & ",8,3");
            when Landin.Targets.Capabilities.ELF =>
               Emit (".pushsection .bss.landin_stack_limit,""aw"",@nobits");
               Emit (".balign 8");
               Put (Stack_Limit & ":");
               Emit (".zero 8");
               Emit (".popsection");
         end case;
      end if;
      --  D361's writer: standard error is descriptor 2, and the line's
      --  address and length arrive as a C call's first two arguments.
      --  Linux is asked by its system call, which a static image has;
      --  Darwin and FreeBSD only through their C libraries, which every
      --  image of theirs links.  It keeps a frame record, as every routine
      --  here does, and does not return: the terminal instruction follows.
      if Reports.Count > 0 then
         Emit (if Format = Landin.Targets.Capabilities.ELF
               then ".section .text.landin_trap_report,""ax"",@progbits"
               else ".text");
         Emit (".p2align 2");
         Platform_Directive (Platform.Begin_Function (Format, Reporter));
         Put (Reporter & ":");
         if Debug /= null then
            Emit (".cfi_startproc");
         end if;
         Emit ("stp x29, x30, [sp, #-16]!");
         if Debug /= null then
            Emit (".cfi_def_cfa_offset 16");
            Emit (".cfi_offset w29, -16");
            Emit (".cfi_offset w30, -8");
         end if;
         Emit ("mov x29, sp");
         if Debug /= null then
            Emit (".cfi_def_cfa_register w29");
         end if;
         --  D491: off Linux, in a program that prepares a stack, the C
         --  call runs on the report's own stack, whatever stack failed:
         --  the frame record stays where it was, and the frame address
         --  still names it, so a debugger unwinds to the failed check.
         if Prepares and then Report_Stack_Bytes > 0 then
            Emit ("adrp x9, " & Platform.Page (Format, Report_Stack, False));
            Emit ("add x9, x9, "
                  & Platform.Page_Offset (Format, Report_Stack, False));
            Emit ("add x9, x9, #" & Trimmed
              (Landin.Targets.Byte_Count'Image (Report_Stack_Bytes)));
            Emit ("mov sp, x9");
         end if;
         Emit ("mov x2, x1");
         Emit ("mov x1, x0");
         Emit ("mov x0, #2");
         if Landin.Targets.Capabilities.Hosted_System_Of (Facts)
           = Landin.Targets.Capabilities.Linux
         then
            Emit ("mov x8, #64");
            Emit ("svc #0");
         else
            Emit ("bl " & Landin.Targets.Capabilities.Link_Symbol
              (Facts, "write"));
         end if;
         Emit ("brk #1");
         if Debug /= null then
            Emit (".cfi_endproc");
         end if;
         Platform_Directive (Platform.End_Function (Format, Reporter));
         --  Each line a string the link may merge, and on ELF in a section
         --  of its own, so the link keeps only the lines a retained routine
         --  reaches; Mach-O's literal section is split by string already.
         for Index in 1 .. Reports.Count loop
            Emit (if Format = Landin.Targets.Capabilities.ELF
                  then ".section .rodata.str1.1.landin_trap_"
                    & Trimmed (Positive'Image (Index))
                    & ",""aMS"",@progbits,1"
                  else ".section __TEXT,__cstring,cstring_literals");
            Put (Report_Label (Index) & ":");
            Emit (".asciz " & Landin.Backend.Trap_Reports.Quoted
              (Reports.Text (Index)));
         end loop;
         if Prepares and then Report_Stack_Bytes > 0 then
            declare
               Bytes : constant String :=
                 Trimmed (Landin.Targets.Byte_Count'Image
                   (Report_Stack_Bytes));
            begin
               case Format is
                  when Landin.Targets.Capabilities.Mach_O =>
                     Emit (".zerofill __DATA,__bss," & Report_Stack & ","
                           & Bytes & ",4");
                  when Landin.Targets.Capabilities.ELF =>
                     Emit (".pushsection .bss.landin_report_stack,"
                           & """aw"",@nobits");
                     Emit (".balign 16");
                     Put (Report_Stack & ":");
                     Emit (".zero " & Bytes);
                     Emit (".popsection");
               end case;
            end;
         end if;
      end if;
      if Debug /= null then
         Unbounded.Append (Debug_Text,
           (case Format is
               when Landin.Targets.Capabilities.Mach_O =>
                  Mach_O_Debug_Sections
                    (Of_Unit, Meanings, Names, Facts, Options, Debug.all,
                     Local_Prefix, Symbol'Access),
               when Landin.Targets.Capabilities.ELF =>
                  ELF_Debug_Sections
                    (Of_Unit, Meanings, Names, Facts, Options, Debug.all,
                     Local_Prefix, Symbol'Access)));
      end if;
      Emit (Platform.Trailer (Format));
      --  The first pass retains every long form.  Its byte counts are upper
      --  bounds, including the largest possible padding at each alignment.
      --  Removing long forms cannot increase those bounds.  A segment break
      --  leaves the original form intact when inline assembly or a directive
      --  makes the distance unknown.
      declare
         Out_Text : Unbounded.Unbounded_String;
         Next_Branch : Positive := 1;
         Index : Positive := 1;
      begin
         while Index <= Natural (Lines.Length) loop
            if Next_Branch <= Natural (Branches.Length)
              and then Branches (Next_Branch).First = Index
            then
               declare
                  Branch : constant Branch_Entry := Branches (Next_Branch);
                  Name : constant String := Unbounded.To_String
                    (Branch.Target);
               begin
                  if Labels.Contains (Name)
                    and then Labels.Element (Name).Segment =
                      Lines (Index).Segment
                    and then abs (Labels.Element (Name).Offset -
                                  Lines (Index).Offset) <= Branch.Reach
                  then
                     Unbounded.Append
                       (Out_Text, Unbounded.To_String (Branch.Direct) & LF);
                  else
                     for Part in Index .. Index + 2 loop
                        Unbounded.Append
                          (Out_Text,
                           Unbounded.To_String (Lines (Part).Text) & LF);
                     end loop;
                  end if;
                  Index := Index + 3;
                  Next_Branch := Next_Branch + 1;
               end;
            else
               if Index = Natural (Lines.Length) then
                  Unbounded.Append (Out_Text, Debug_Text);
               end if;
               Unbounded.Append
                 (Out_Text, Unbounded.To_String (Lines (Index).Text) & LF);
               if Index = Preamble_After then
                  Unbounded.Append (Out_Text, Preamble_Text);
               end if;
               Index := Index + 1;
            end if;
         end loop;
         Assembly := Out_Text;
      end;
   end Emit;

end Landin.Backend.Arm64;
