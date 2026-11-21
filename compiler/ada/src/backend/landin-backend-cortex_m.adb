with Ada.Characters.Handling;
with Ada.Containers.Generic_Sort;
with Ada.Containers.Ordered_Maps;
with Ada.Unchecked_Deallocation;
with Landin.IR.Liveness;
with Ada.Containers.Vectors;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Ada.Containers.Hashed_Sets;
with Landin.Backend.Firmware;
with Landin.Backend.Dwarf;
with Landin.Provenance;
with Landin.Machine;
with Landin.Layouts;
with Landin.IR.Shape_Measurement;
with Landin.Packed;
with Landin.Memory;
with Landin.Targets.Packed;
with Landin.Targets.Firmware;
with Ada.Strings.Fixed;
with Landin.Backend.Arm32_ABI;
with Landin.Backend.Site_Counts;
with Landin.Backend.Work_Arrays;
with Landin.Backend.Placement;
with Landin.Types;

package body Landin.Backend.Cortex_M is

   use type Landin.Machine.Convention;

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
   use type Landin.IR.Storage_Kind;
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

   --  All source places stay pinned. Verified scalar temporaries are block
   --  local: an operand's last read precedes reuse, including across calls.
   --  Scratch registers belong to selection. A reused spill home grows to
   --  hold the widest scalar assigned to it.
   --  D1567: a set of the core registers r0-r15, the Nth bit rN.
   type Register_Mask is mod 2 ** 16;
   function Bit (Number : Natural) return Register_Mask
     is (2 ** Number);

   function Held_Count (Held : Register_Mask) return Natural;
   function Held_Count (Held : Register_Mask) return Natural is
      Count : Natural := 0;
   begin
      for Number in 0 .. 15 loop
         if (Held and Bit (Number)) /= 0 then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Held_Count;

   --  D1567: the core registers a routine's text writes at each position
   --  of its layout order (Landin.Backend.Placement), position zero being
   --  the entry's parameter stores.  A call writes every register AAPCS
   --  does not preserve.
   type Write_Masks is array (Natural range <>) of Register_Mask;
   type Write_Masks_Access is access Write_Masks;
   procedure Free_Masks is new Ada.Unchecked_Deallocation
     (Write_Masks, Write_Masks_Access);

   --  r0-r3, r12 and lr, which a call may change.
   Caller_Saved : constant Register_Mask :=
     Bit (0) or Bit (1) or Bit (2) or Bit (3) or Bit (12) or Bit (14);

   --  D1567: the core registers one line of a routine's text writes.  A
   --  label or directive writes none.  An instruction writes its first
   --  operand, except a comparison, a branch, a barrier, a store or a
   --  push, which write none but a store's or push's base; a load or pop
   --  of several writes its list, a long multiply and a doubleword load
   --  their first two; a call writes every register AAPCS does not
   --  preserve.  A VFP instruction writes a core register only as a
   --  transfer's destination.
   function Written_By (Line : String) return Register_Mask;

   --  D1571: whether a label is one of a routine's traps, which never
   --  return: a Thumb-1 branch too far for B reaches one with BL, which
   --  writes only lr, and a routine is no less a leaf for it.
   function Is_Trap (Target : String) return Boolean
     is ((Target'Length > 5
          and then Target (Target'Last - 4 .. Target'Last) = "_trap")
         or else (Target'Length > 12
                  and then Target (Target'Last - 11 .. Target'Last)
                    = "_stack_limit"));

   function Written_By (Line : String) return Register_Mask is
      HT : constant Character := Character'Val (9);

      function Number_Of (Name : String) return Integer;
      function Number_Of (Name : String) return Integer is
         Text : constant String := Trimmed (Name);
      begin
         if Text'Length in 2 .. 3 and then Text (Text'First) = 'r'
           and then (for all C of Text (Text'First + 1 .. Text'Last)
                     => C in '0' .. '9')
         then
            declare
               Number : constant Natural :=
                 Natural'Value (Text (Text'First + 1 .. Text'Last));
            begin
               return (if Number <= 15 then Number else -1);
            end;
         elsif Text = "sp" then
            return 13;
         elsif Text = "lr" then
            return 14;
         elsif Text = "pc" then
            return 15;
         elsif Text = "ip" then
            return 12;
         elsif Text = "fp" then
            return 11;
         elsif Text = "sl" then
            return 10;
         elsif Text = "sb" then
            return 9;
         end if;
         return -1;
      end Number_Of;

      function One (Name : String) return Register_Mask is
        (if Number_Of (Name) >= 0 then Bit (Number_Of (Name)) else 0);

      --  The registers a brace list names, ranges included.
      function List_Of (Text : String) return Register_Mask;
      function List_Of (Text : String) return Register_Mask is
         Open : constant Natural := Ada.Strings.Fixed.Index (Text, "{");
         Close : constant Natural := Ada.Strings.Fixed.Index (Text, "}");
         Result : Register_Mask := 0;
         Start : Natural;
      begin
         if Open = 0 or else Close < Open then
            return 16#FFFF#;
         end if;
         Start := Open + 1;
         for Index in Open + 1 .. Close loop
            if Index = Close or else Text (Index) = ',' then
               declare
                  Item : constant String :=
                    Trimmed (Text (Start .. Index - 1));
                  Dash : constant Natural :=
                    Ada.Strings.Fixed.Index (Item, "-");
               begin
                  if Dash > 0 then
                     declare
                        Low : constant Integer :=
                          Number_Of (Item (Item'First .. Dash - 1));
                        High : constant Integer :=
                          Number_Of (Item (Dash + 1 .. Item'Last));
                     begin
                        if Low >= 0 and then High >= Low then
                           for Number in Low .. High loop
                              Result := Result or Bit (Number);
                           end loop;
                        end if;
                     end;
                  else
                     Result := Result or One (Item);
                  end if;
               end;
               Start := Index + 1;
            end if;
         end loop;
         return Result;
      end List_Of;

      First : Positive;
      Space : Natural;
   begin
      if Line'Length < 2 or else Line (Line'First) /= HT
        or else Line (Line'First + 1) = '.'
      then
         return 0;
      end if;
      First := Line'First + 1;
      Space := Ada.Strings.Fixed.Index (Line (First .. Line'Last), " ");
      declare
         Spelled : constant String :=
           (if Space = 0 then Line (First .. Line'Last)
            else Line (First .. Space - 1));
         Mnemonic : constant String :=
           (if Spelled'Length > 2
              and then Spelled (Spelled'Last - 1 .. Spelled'Last)
                in ".w" | ".n"
            then Spelled (Spelled'First .. Spelled'Last - 2)
            else Spelled);
         Rest : constant String :=
           (if Space = 0 then "" else Line (Space + 1 .. Line'Last));
         Comma : constant Natural := Ada.Strings.Fixed.Index (Rest, ",");
         Target : constant String :=
           (if Comma = 0 then Rest else Rest (Rest'First .. Comma - 1));
         Back : constant Boolean := Ada.Strings.Fixed.Index (Rest, "!") > 0;
         Base : constant String :=
           (if Back then Rest (Rest'First .. Ada.Strings.Fixed.Index
                                 (Rest, "!") - 1)
            else "");
         Conditions : constant array (1 .. 15) of String (1 .. 2) :=
           ["eq", "ne", "cs", "cc", "hs", "lo", "mi", "pl", "vs", "vc",
            "hi", "ls", "ge", "lt", "gt"];
         function Branches return Boolean is
           (Mnemonic in "b" | "bx" | "cbz" | "cbnz" | "ble" | "bal"
            or else (Mnemonic'Length = 3
                     and then Mnemonic (Mnemonic'First) = 'b'
                     and then (for some C of Conditions =>
                                 C = Mnemonic (Mnemonic'First + 1
                                               .. Mnemonic'Last))));
         Second : constant String :=
           (if Comma = 0 then ""
            else Rest (Comma + 1 .. Rest'Last));
         Comma_2 : constant Natural := Ada.Strings.Fixed.Index (Second, ",");
         Second_Name : constant String :=
           (if Comma_2 = 0 then Second
            else Second (Second'First .. Comma_2 - 1));
      begin
         if Mnemonic = "bl" and then Is_Trap (Trimmed (Rest)) then
            return Bit (14);
         elsif Mnemonic in "bl" | "blx" then
            return Caller_Saved;
         elsif Branches
           or else Mnemonic in "cmp" | "cmn" | "tst" | "teq" | "udf" | "nop"
             | "dmb" | "dsb" | "isb" | "cpsid" | "cpsie" | "wfi" | "wfe"
             | "sev" | "bkpt" | "msr" | "it" | "ite" | "itt" | "itee"
             | "itte" | "itet" | "ittt"
         then
            return 0;
         elsif Mnemonic = "push" then
            return Bit (13);
         elsif Mnemonic = "pop" then
            return List_Of (Rest);
         elsif Mnemonic'Length >= 3
           and then Mnemonic (Mnemonic'First .. Mnemonic'First + 1) = "st"
         then
            return (if Back then One (Base) else 0);
         elsif Mnemonic'Length >= 3
           and then Mnemonic (Mnemonic'First .. Mnemonic'First + 2) = "ldm"
         then
            return List_Of (Rest) or (if Back then One (Base) else 0);
         elsif Mnemonic in "umull" | "smull" | "umlal" | "smlal" | "ldrd" then
            return One (Target) or One (Second_Name);
         elsif Mnemonic (Mnemonic'First) = 'v' then
            if Mnemonic in "vmov" | "vmrs" then
               return One (Target)
                 or (if Number_Of (Target) >= 0 then One (Second_Name)
                     else 0);
            end if;
            return 0;
         end if;
         return One (Target);
      end;
   end Written_By;

   --  D1567: a value held in a register holds it from position
   --  Live_From through Live_Through; a slot over its interval, both in
   --  layout order.  Register 0 is none: r0 is never offered.
   type Value_Location is record
      Register : Natural := 0;
      Live_From, Live_Through : Natural := 0;
   end record;
   package Location_Vectors is new Ada.Containers.Vectors
     (Positive, Value_Location);
   type Slot_Location is record
      Register : Natural := 0;
      Live_From, Live_Through : Natural := 0;
   end record;
   package Slot_Vectors is new Ada.Containers.Vectors
     (Positive, Slot_Location);
   type Register_Plan is record
      Values : Location_Vectors.Vector;
      Slots : Slot_Vectors.Vector;
      Held : Register_Mask := 0;
   end record;

   --  The slots placed in one register for their whole interval, by the
   --  position each interval opens at.
   package Reservations is new Ada.Containers.Ordered_Maps
     (Key_Type => Natural, Element_Type => Positive);

   type Register_List is array (Positive range <>) of Natural;

   --  D1767: at size and speed an integer constant of at most a word is
   --  made where an operation reads it, as an immediate operand where the
   --  operation has one, rather than kept in a home or register from its
   --  definition on.  A routine with assembly keeps every constant, as it
   --  keeps every value, in its home.
   function Deferred_Constant
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts; Value : Landin.IR.Value_Id)
      return Boolean
     is (Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Number
         and then Landin.IR.Result_Of (Of_Unit, Item, Value)
           in Landin.Types.Integer_Name
         and then Size_Of (Landin.IR.Result_Of (Of_Unit, Item, Value), Facts)
           /= Landin.Targets.Byte_8
         and then not Landin.IR.Validates_Atoms (Of_Unit, Item, Value));

   --  D1567: size and speed hold slots and values in low registers
   --  wherever the routine's text, emitted with every value in its home,
   --  writes none of them: Writes is what that text writes at each
   --  position.  The placement is RISC-V's (D1503) and arm64's (D1404)
   --  over the shared usage (Landin.Backend.Placement): each eligible slot
   --  used twice over its interval, the heaviest first, then in one scan
   --  each slot stored and read within one block over its span and each
   --  value from its definition through its last reader, sharing a slot's
   --  register where the value is that slot's content.  A location holds
   --  a register only where nothing else writes it, from the first
   --  position it is live at through the last, both included.  An
   --  eight-byte scalar keeps its home, as a float does where the float
   --  unit computes it.  A routine that calls offers r4-r7 first, which
   --  it saves anyway, and r3 and r1, which a call writes; a leaf the
   --  other way round, since each of r4-r7 it names costs it a save.
   function Allocate_Registers
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Writes : Write_Masks; High : Boolean) return Register_Plan;

   function Allocate_Registers
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Writes : Write_Masks; High : Boolean) return Register_Plan
   is
      Value_Count : constant Natural := Landin.IR.Value_Count (Of_Unit, Item);
      Slot_Count : constant Natural := Landin.IR.Slot_Count (Of_Unit, Item);
      subtype Counts is Landin.Backend.Placement.Counts;
      package Count_Buffers renames Landin.Backend.Placement.Count_Buffers;
      use type Landin.Optimization.Objective;
      Speed : constant Boolean :=
        Options.Optimize = Landin.Optimization.Speed;
      Hard : constant Boolean := Arm32_ABI.Uses_VFP (Of_Unit);
      Use_Of : Landin.Backend.Placement.Usage
        (Value_Count, Slot_Count, Value_Count + 1);
      Result : Register_Plan;
   begin
      Landin.Backend.Placement.Measure
        (Of_Unit, Item, Speed, Use_Of, Debugger_Spans => False);
      if Use_Of.Has_Assembly or else Writes'First /= 0
        or else Writes'Last /= Value_Count
      then
         return Result;
      end if;
      Result.Values := Location_Vectors.To_Vector
        (Value_Location'(others => <>),
         Ada.Containers.Count_Type (Value_Count));
      Result.Slots := Slot_Vectors.To_Vector
        (Slot_Location'(others => <>),
         Ada.Containers.Count_Type (Slot_Count));
      declare
         Calls : constant Boolean :=
           Use_Of.Calls_Before.Data (Value_Count + 1) > 0;
         Offered : constant Register_List :=
           (if High then
              (if Calls then [4, 5, 6, 7, 3, 1, 12]
               else [3, 1, 12, 5, 4, 6, 7])
            elsif Calls then [4, 5, 6, 7, 3, 1] else [3, 1, 5, 4, 6, 7]);
         type Prefix_Table is array (Offered'Range) of
           Count_Buffers.Buffer (Value_Count + 2);
         --  For each offered register, how many positions before each
         --  position write it: Prefix (I).Data (P + 1) counts positions
         --  zero through P - 1.
         Prefix : Prefix_Table;
         Opening_Data : Count_Buffers.Buffer (Value_Count);
         Interval_Data : Count_Buffers.Buffer (Slot_Count);
         Sequence : Counts renames Use_Of.Sequence.Data.all;
         Lasts : Counts renames Use_Of.Lasts.Data.all;
         Written_After : Counts renames Use_Of.Written_After.Data.all;
         Uses : Counts renames Use_Of.Uses.Data.all;
         Weights : Counts renames Use_Of.Weights.Data.all;
         Parameter_Of : Counts renames Use_Of.Parameter_Of.Data.all;
         First_Use : Counts renames Use_Of.First_Use.Data.all;
         Last_Use : Counts renames Use_Of.Last_Use.Data.all;
         Across_Blocks : Home_Mask renames Use_Of.Across_Blocks.Data.all;
         Eligible : Home_Mask renames Use_Of.Eligible.Data.all;
         Address_Required : Home_Mask
           renames Use_Of.Address_Required.Data.all;
         Spans : Landin.IR.Liveness.Interval_Vectors.Vector
           renames Use_Of.Spans;
         --  The slots placed in a register, by weight and then as a mark:
         --  1 for one placed over its interval, 2 for one given a span in
         --  a single block by the scan; and the slot, if any, whose store
         --  at a position opens such a span.
         Interval_Slots : Counts renames Interval_Data.Data.all;
         Opening : Counts renames Opening_Data.Data.all;
         Busy_Until : array (0 .. 15) of Natural := [others => 0];
         Placed : array (0 .. 15) of Reservations.Map;
         Upcoming : array (0 .. 15) of Reservations.Cursor :=
           [others => Reservations.No_Element];

         --  Whether a scalar of Kind may be held in a core register.
         function Holdable (Kind : Landin.Types.Type_Kind) return Boolean is
           (Kind in Landin.Types.Scalar_Name
            and then Size_Of (Kind, Facts) /= Landin.Targets.Byte_8
            and then not (Hard and then Kind in Landin.Types.Float_Name));

         --  Whether the text writes register Number at some position from
         --  First through Last.
         function Written (Number, First, Last : Natural) return Boolean;
         function Written (Number, First, Last : Natural) return Boolean is
         begin
            for Index in Offered'Range loop
               if Offered (Index) = Number then
                  return Prefix (Index).Data (Last + 2)
                    > Prefix (Index).Data (First + 1);
               end if;
            end loop;
            return True;
         end Written;

         function Fits (Number, First, Last : Natural) return Boolean is
           (not Written (Number, First, Last));

         function Slot_Holdable (Index : Positive) return Boolean is
           (Holdable (Landin.IR.Type_Of
              (Of_Unit, Item, Landin.IR.Slot_Id (Index))));

         --  The last position a slot placed in a register holds it.
         function Holds_Through (Slot : Positive) return Natural is
           (if Interval_Slots (Slot) = 2 then Last_Use (Slot)
            else Spans (Slot).Last);

         procedure Place_Intervals;
         procedure Open (Position : Natural);
         function Clear (Number, Position, Last : Natural) return Boolean;
         function Read_In_Place (Value : Positive) return Natural;
         function Released_By (Value : Positive; Position : Natural)
            return Natural;
         function Stored_Into (Value : Positive; Position : Natural)
            return Natural;
         procedure Open_Span (Index : Positive; Position : Natural);

         procedure Place_Intervals is
            Count : Natural := 0;

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

            procedure Place (Position : Positive);
            procedure Place (Position : Positive) is
               Index : constant Positive := Interval_Slots (Position);
               Span : constant Landin.IR.Liveness.Interval := Spans (Index);
               Slot : Slot_Location renames Result.Slots (Index);

               --  Whether no interval placed in Number meets Span.
               function Open_In (Number : Natural) return Boolean;
               function Open_In (Number : Natural) return Boolean is
                  Below : constant Reservations.Cursor :=
                    Placed (Number).Floor (Span.Last);
               begin
                  return not Reservations.Has_Element (Below)
                    or else Spans (Reservations.Element (Below)).Last
                      < Span.First;
               end Open_In;
            begin
               for Number of Offered loop
                  exit when Slot.Register /= 0;
                  if Fits (Number, Span.First, Span.Last)
                    and then Open_In (Number)
                  then
                     Placed (Number).Insert (Span.First, Index);
                     Slot.Register := Number;
                     Result.Held := Result.Held or Bit (Number);
                     Slot.Live_From := Span.First;
                     Slot.Live_Through := Span.Last;
                  end if;
               end loop;
            end Place;
         begin
            for Index in 1 .. Slot_Count loop
               if Eligible (Index) and then Uses (Index) >= 2
                 and then Slot_Holdable (Index)
                 and then not Landin.IR.Liveness.Is_Empty (Spans (Index))
               then
                  Count := Count + 1;
                  Interval_Slots (Count) := Index;
               end if;
            end loop;
            Sort (1, Count);
            for Position in 1 .. Count loop
               Place (Position);
            end loop;
            Interval_Slots := [others => 0];
            for Number of Offered loop
               for Cursor in Placed (Number).Iterate loop
                  Interval_Slots (Reservations.Element (Cursor)) := 1;
               end loop;
               Upcoming (Number) := Placed (Number).First;
            end loop;
         end Place_Intervals;

         --  The placed intervals opening at Position take their registers
         --  through their last position.
         procedure Open (Position : Natural) is
         begin
            for Number of Offered loop
               if Reservations.Has_Element (Upcoming (Number))
                 and then Reservations.Key (Upcoming (Number)) = Position
               then
                  Busy_Until (Number) := Spans
                    (Reservations.Element (Upcoming (Number))).Last;
                  Reservations.Next (Upcoming (Number));
               end if;
            end loop;
         end Open;

         --  Whether a value from Position through Last may take register
         --  Number: nothing holds it now, the next slot interval placed in
         --  it opens after Last, and nothing writes it in between.
         function Clear (Number, Position, Last : Natural) return Boolean
           is (Busy_Until (Number) < Position
               and then
                 (not Reservations.Has_Element (Upcoming (Number))
                  or else Last < Reservations.Key (Upcoming (Number)))
               and then Fits (Number, Position, Last));

         --  The register of the slot a load reads, when the loaded value
         --  dies before the slot is next stored and while the slot still
         --  holds that register: the value may be that register.
         function Read_In_Place (Value : Positive) return Natural is
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, Landin.IR.Value_Id (Value))
              /= Landin.IR.Load
            then
               return 0;
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
            return 0;
         end Read_In_Place;

         --  The register of the slot a load at Position reads for the last
         --  time, which the loaded value may go on holding while no other
         --  interval placed there opens.
         function Released_By (Value : Positive; Position : Natural)
            return Natural is
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, Landin.IR.Value_Id (Value))
              /= Landin.IR.Load
            then
               return 0;
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
            return 0;
         end Released_By;

         --  The register of the slot whose placed interval opens at the
         --  store that last uses a value, which the value may hold from
         --  Position on, so that the store moves nothing.
         function Stored_Into (Value : Positive; Position : Natural)
            return Natural
         is
            User : constant Landin.IR.Value_Id :=
              Landin.IR.Value_Id (Sequence (Lasts (Value)));
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, User) /= Landin.IR.Store then
               return 0;
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
            return 0;
         end Stored_Into;

         --  The span the store at Position that opens a slot's gives it,
         --  through the slot's last use: the stored value's own register
         --  when the value dies there or the slot is never read, so the
         --  store moves nothing; else the first clear one.
         procedure Open_Span (Index : Positive; Position : Natural) is
            Slot : Slot_Location renames Result.Slots (Index);
            Last : constant Natural := Last_Use (Index);
            Stored : constant Natural := Result.Values (Positive
              (Landin.IR.Nth_Operand
                 (Of_Unit, Item, Landin.IR.Value_Id (Sequence (Position)),
                  1))).Register;

            procedure Take (Number : Natural);
            procedure Take (Number : Natural) is
            begin
               if Slot.Register = 0 and then Fits (Number, Position, Last)
               then
                  Slot.Register := Number;
                  Slot.Live_From := Position;
                  Slot.Live_Through := Last;
                  Busy_Until (Number) :=
                    Natural'Max (Busy_Until (Number), Last);
                  Result.Held := Result.Held or Bit (Number);
               end if;
            end Take;

            function Free_After (Number : Natural) return Boolean is
              ((Busy_Until (Number) = Position or else Last = Position)
               and then
                 (not Reservations.Has_Element (Upcoming (Number))
                  or else Last < Reservations.Key (Upcoming (Number))));
         begin
            if Stored /= 0 and then Free_After (Stored) then
               Take (Stored);
            end if;
            for Number of Offered loop
               if Clear (Number, Position, Last) then
                  Take (Number);
               end if;
            end loop;
            if Slot.Register /= 0 then
               Interval_Slots (Index) := 2;
            end if;
         end Open_Span;
      begin
         for Index in Offered'Range loop
            for Position in 0 .. Value_Count loop
               Prefix (Index).Data (Position + 2) :=
                 Prefix (Index).Data (Position + 1)
                 + (if (Writes (Position) and Bit (Offered (Index))) /= 0
                    then 1 else 0);
            end loop;
         end loop;
         Place_Intervals;
         --  A slot loaded and stored in one block only, which stores it
         --  before reading it, and not placed over its interval, is dead
         --  before that store and after its last use there.  Like a value
         --  it needs a register only in between, which the scan gives it
         --  at the store when it can.
         for Index in 1 .. Slot_Count loop
            if Eligible (Index) and then Interval_Slots (Index) = 0
              and then Slot_Holdable (Index)
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
         Open (0);
         for Position in 1 .. Value_Count loop
            declare
               Index : constant Positive := Sequence (Position);
               Kind : constant Landin.Types.Type_Kind := Landin.IR.Result_Of
                 (Of_Unit, Item, Landin.IR.Value_Id (Index));
            begin
               Open (Position);
               if Opening (Position) /= 0 then
                  Open_Span (Opening (Position), Position);
               end if;
               if Holdable (Kind)
                 and then not Deferred_Constant
                   (Of_Unit, Item, Facts, Landin.IR.Value_Id (Index))
               then
                  declare
                     Place : Value_Location renames Result.Values (Index);
                     Last : constant Natural := Lasts (Index);

                     --  Place takes register Number from Position through
                     --  Last, if it has none yet and Number fits there.
                     procedure Share (Number : Natural);
                     procedure Share (Number : Natural) is
                     begin
                        if Place.Register = 0 and then Number /= 0
                          and then Fits (Number, Position + 1, Last)
                        then
                           Place.Register := Number;
                           Place.Live_From := Position;
                           Place.Live_Through := Last;
                           Busy_Until (Number) :=
                             Natural'Max (Busy_Until (Number), Last);
                           Result.Held := Result.Held or Bit (Number);
                        end if;
                     end Share;
                  begin
                     if not Address_Required (Index)
                       and then Last > Position
                     then
                        Share (Read_In_Place (Index));
                        Share (Released_By (Index, Position));
                        Share (Stored_Into (Index, Position));
                        for Number of Offered loop
                           exit when Place.Register /= 0;
                           if Clear (Number, Position + 1, Last)
                             and then Busy_Until (Number) < Position
                           then
                              Share (Number);
                           end if;
                        end loop;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end;
      return Result;
   end Allocate_Registers;

   --  Whether no write Writes records meets a register Plan holds over a
   --  position it holds it at.  A value's own operation may write its
   --  register as it computes it there, since selection writes a result
   --  after it has read every operand.
   function Holds (Plan : Register_Plan; Writes : Write_Masks)
     return Boolean;

   function Holds (Plan : Register_Plan; Writes : Write_Masks)
     return Boolean
   is
      package Count_Buffers renames Landin.Backend.Placement.Count_Buffers;
      type Prefix_Table is array (0 .. 15) of
        Count_Buffers.Buffer (Writes'Length + 1);
      Prefix : Prefix_Table;

      function Clear (Register, First, Last : Natural) return Boolean is
        (Register = 0 or else Last < First
         or else Prefix (Register).Data (Last + 2)
           = Prefix (Register).Data (First + 1));
   begin
      if Writes'First /= 0 then
         return False;
      end if;
      for Register in Prefix'Range loop
         if (Plan.Held and Bit (Register)) /= 0 then
            for Position in Writes'Range loop
               Prefix (Register).Data (Position + 2) :=
                 Prefix (Register).Data (Position + 1)
                 + (if (Writes (Position) and Bit (Register)) /= 0
                    then 1 else 0);
            end loop;
         end if;
      end loop;
      return (for all Place of Plan.Values =>
                Clear (Place.Register, Place.Live_From + 1,
                       Place.Live_Through))
        and then (for all Place of Plan.Slots =>
                    Clear (Place.Register, Place.Live_From,
                           Place.Live_Through));
   end Holds;

   --  D1567: a slot or value Registers holds in a register has no home.
   function Allocated_Frame
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count;
      Registers : access constant Register_Plan := null) return Frame;

   function Allocated_Frame
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Maximum : Landin.Targets.Byte_Count;
      Registers : access constant Register_Plan := null) return Frame
   is
      package IR renames Landin.IR;
      package L renames Landin.Targets.Layouts;
      package Masks is new Work_Arrays (Boolean, Home_Mask, False);
      package Numbers is new Work_Arrays (Natural, Spill_Assignments, 0);
      package Extents is new Work_Arrays
        (L.Field_Extent, L.Field_Extent_Array, (0, 1));
      Slots : Masks.Buffer (IR.Slot_Count (Of_Unit, Item));
      Values : Numbers.Buffer (IR.Value_Count (Of_Unit, Item));
      Last : Numbers.Buffer (IR.Value_Count (Of_Unit, Item));
      Release_Data, Next_Release_Data, Heap_Data :
        Numbers.Buffer (IR.Value_Count (Of_Unit, Item));
      Spills : Extents.Buffer (IR.Value_Count (Of_Unit, Item));
      Count : Natural := 0;
      Block_Homes : Natural := 0;
      Heap_Count : Natural := 0;

      --  Keep the lowest available home, as the former linear search did.
      --  A heap bounds selection by the logarithm of the block's peak
      --  liveness; release buckets visit each scalar only once.
      procedure Free_Home (Home : Positive);
      function Take_Home return Positive;

      procedure Free_Home (Home : Positive) is
         Index : Positive;
      begin
         Heap_Count := Heap_Count + 1;
         Index := Heap_Count;
         while Index > 1
           and then Heap_Data.Data (Index / 2) > Home
         loop
            Heap_Data.Data (Index) := Heap_Data.Data (Index / 2);
            Index := Index / 2;
         end loop;
         Heap_Data.Data (Index) := Home;
      end Free_Home;

      function Take_Home return Positive is
         Home : constant Positive := Heap_Data.Data (1);
         Last_Home : constant Positive := Heap_Data.Data (Heap_Count);
         Index : Positive := 1;
         Child : Natural;
      begin
         Heap_Count := Heap_Count - 1;
         while Index <= Heap_Count / 2 loop
            Child := Index * 2;
            if Child < Heap_Count
              and then Heap_Data.Data (Child + 1) < Heap_Data.Data (Child)
            then
               Child := Child + 1;
            end if;
            exit when Last_Home <= Heap_Data.Data (Child);
            Heap_Data.Data (Index) := Heap_Data.Data (Child);
            Index := Child;
         end loop;
         if Heap_Count > 0 then
            Heap_Data.Data (Index) := Last_Home;
         end if;
         return Home;
      end Take_Home;
   begin
      --  Simplification retains slot identities when it removes unreachable
      --  instructions.  Only slots still named by executable IR need homes.
      declare
         procedure Mark (Slot : IR.Slot_Id);
         procedure Mark (Place : IR.Storage);

         procedure Mark (Slot : IR.Slot_Id) is
         begin
            if Slot /= IR.No_Slot
              and then (Registers = null
                        or else Natural (Registers.Slots.Length)
                          < Positive (Slot)
                        or else Registers.Slots (Positive (Slot)).Register
                          = 0)
            then
               Slots.Data (Positive (Slot)) := True;
            end if;
         end Mark;

         procedure Mark (Place : IR.Storage) is
         begin
            case Place.Kind is
               when IR.Module_Datum => null;
               when IR.Frame_Slot => Mark (Place.Slot);
               when IR.Runtime_Address => Mark (Place.Address);
            end case;
         end Mark;
      begin
         for Index in 1 .. IR.Parameter_Count (Of_Unit, Item) loop
            Mark (IR.Nth_Parameter (Of_Unit, Item, Index));
            --  A zero carrier clears an in-place parameter's home.
            Mark (IR.In_Place_Home
              (Of_Unit, Item, IR.Nth_Parameter (Of_Unit, Item, Index)));
         end loop;
         Mark (IR.Result_Slot (Of_Unit, Item));
         for Index in 1 .. IR.Value_Count (Of_Unit, Item) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Index);
               Op : constant IR.Opcode := IR.Op_Of (Of_Unit, Item, Value);
            begin
               case Op is
                  when IR.Load | IR.Store =>
                     Mark (IR.Slot_Of (Of_Unit, Item, Value));
                  when IR.Load_Field | IR.Store_Field
                     | IR.Load_Element | IR.Store_Element =>
                     if IR.Reaches_A_Slot (Of_Unit, Item, Value) then
                        Mark (IR.Slot_Of (Of_Unit, Item, Value));
                     end if;
                  when IR.Storage_Address | IR.Place_Address
                     | IR.Clear_Array | IR.Fill_Array
                     | IR.Select_Variant | IR.Store_Variant_Field =>
                     Mark (IR.Destination_Of (Of_Unit, Item, Value));
                  when IR.Copy_Array | IR.Copy_Variant =>
                     Mark (IR.Source_Of (Of_Unit, Item, Value));
                     Mark (IR.Destination_Of (Of_Unit, Item, Value));
                  when IR.Load_Variant_Tag | IR.Load_Variant_Field =>
                     Mark (IR.Source_Of (Of_Unit, Item, Value));
                  when IR.Load_Indirect | IR.Store_Indirect =>
                     Mark (IR.Indirect_Address_Slot
                       (Of_Unit, Item, Value));
                  when IR.Call | IR.Indirect_Call =>
                     Mark (IR.Failure_Slot_Of (Of_Unit, Item, Value));
                  when IR.Assembly =>
                     for Operand in 1 .. IR.Assembly_Operand_Count
                       (Of_Unit, Item, Value)
                     loop
                        Mark (IR.Nth_Assembly_Operand
                          (Of_Unit, Item, Value, Operand).Output);
                     end loop;
                  when others => null;
               end case;
            end;
         end loop;
      end;
      for Block in 1 .. IR.Block_Count (Of_Unit, Item) loop
         --  All prior homes are available at a block boundary. Start this
         --  block at home 1 instead of clearing the routine's high-water mark.
         Block_Homes := 0;
         Heap_Count := 0;
         for Position in 1 .. IR.Length
           (Of_Unit, Item, IR.Block_Id (Block))
         loop
            Release_Data.Data (Position) := 0;
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
               Home : Positive;
               Released : Natural :=
                 (if Position > 1 then Release_Data.Data (Position - 1)
                  else 0);
            begin
               while Released /= 0 loop
                  Free_Home (Positive (Values.Data (Released)));
                  Released := Next_Release_Data.Data (Released);
               end loop;
               if IR.Result_Of (Of_Unit, Item, Value)
                 in Landin.Types.Scalar_Name
                 and then (Registers = null
                           or else Natural (Registers.Values.Length)
                             < Positive (Value)
                           or else Registers.Values (Positive (Value))
                             .Register = 0)
               then
                  if Heap_Count > 0 then
                     Home := Take_Home;
                  else
                     Block_Homes := Block_Homes + 1;
                     Home := Block_Homes;
                  end if;
                  Count := Natural'Max (Count, Block_Homes);
                  Values.Data (Positive (Value)) := Home;
                  Next_Release_Data.Data (Positive (Value)) :=
                    Release_Data.Data (Last.Data (Positive (Value)));
                  Release_Data.Data (Last.Data (Positive (Value))) :=
                    Positive (Value);
                  declare
                     Held : constant Landin.Targets.Scalar_Size :=
                       Landin.Types.Storage_Size
                         (Landin.Types.Scalar_Name
                            (IR.Result_Of (Of_Unit, Item, Value)), Facts);
                  begin
                     --  D1563: a home is at least a word, which sp's
                     --  Thumb-1 offset form reaches.
                     Spills.Data (Home).Size :=
                       Landin.Targets.Byte_Count'Max
                         (Spills.Data (Home).Size,
                          Landin.Targets.Byte_Count'Max
                            (4, Landin.Targets.Byte_Count
                                  (Landin.Targets.Bytes (Held))));
                     Spills.Data (Home).Alignment :=
                       Landin.Targets.Byte_Alignment'Max
                         (Spills.Data (Home).Alignment,
                          Landin.Targets.Byte_Alignment'Max
                            (4, Landin.Targets.Alignment_Of (Facts, Held)));
                  end;
               end if;
            end;
         end loop;
      end loop;
      return Laid_Out
        (Of_Unit, Item, Facts, Slots.Data.all, Values.Data.all,
         Spills.Data (1 .. Count), L.Field_Extent_Array'(1 .. 0 => <>),
         Maximum);
   end Allocated_Frame;

   --  D617: the call-preserved VFP registers ITEM keeps in its frame,
   --  d(Low) to d(High), none when High is zero.  Selection never names
   --  one; only an assembly block can, declaring each one its text names
   --  (D630), as d8-d15 or as s16-s31, and the frame saves the run of
   --  them its blocks declare, where it once saved all eight (D1570).
   --  A call-free leaf holds no block, and a naked body is its own.
   type VFP_Run is record
      Low, High : Natural := 0;
   end record;

   function Saved_VFP
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id) return VFP_Run;

   function VFP_Bytes (Run : VFP_Run) return Landin.Targets.Byte_Count
     is (if Run.High = 0 then 0
         else Landin.Targets.Byte_Count (Run.High - Run.Low + 1) * 8);

   function VFP_List (Run : VFP_Run) return String
     is ("{d" & Trimmed (Run.Low'Image)
         & (if Run.High > Run.Low then "-d" & Trimmed (Run.High'Image)
            else "") & "}");

   function Saved_VFP
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id) return VFP_Run
   is
      Result : VFP_Run;

      procedure Include (Number : Natural);
      procedure Include (Number : Natural) is
      begin
         if Result.High = 0 then
            Result := (Number, Number);
         else
            Result := (Natural'Min (Result.Low, Number),
                       Natural'Max (Result.High, Number));
         end if;
      end Include;
   begin
      if not Arm32_ABI.Uses_VFP (Of_Unit)
        or else Landin.IR.Signature_Machine
          (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
            = Landin.Machine.Naked_Routine
      then
         return Result;
      end if;
      for Index in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
         declare
            Value : constant Landin.IR.Value_Id := Landin.IR.Value_Id (Index);
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Assembly
            then
               for Operand in 1 .. Landin.IR.Assembly_Operand_Count
                 (Of_Unit, Item, Value)
               loop
                  declare
                     Name : constant String :=
                       Ada.Characters.Handling.To_Lower
                         (Landin.IR.Register_Of
                            (Landin.IR.Nth_Assembly_Operand
                               (Of_Unit, Item, Value, Operand)));
                     Number : Integer := -1;
                  begin
                     if Name'Length in 2 .. 3
                       and then Name (Name'First) in 'd' | 's'
                       and then (for all C of Name (Name'First + 1
                                                    .. Name'Last)
                                 => C in '0' .. '9')
                     then
                        Number := Integer'Value
                          (Name (Name'First + 1 .. Name'Last));
                        if Name (Name'First) = 's' then
                           Number := Number / 2;
                        end if;
                     end if;
                     if Number in 8 .. 15 then
                        Include (Number);
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;
      return Result;
   end Saved_VFP;

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Boolean
   is
      pragma Unreferenced (Options);
      Limit : constant Landin.Targets.Byte_Count := 16#FFFF_FFC0#;
      Bound : Landin.Targets.Byte_Count;

      --  Whether every call's staging fits below a frame of Reserved
      --  bytes.  Physical RAM belongs to the selected image, not this
      --  address bound.
      function Calls_Fit (Reserved : Landin.Targets.Byte_Count) return Boolean;
      function Calls_Fit (Reserved : Landin.Targets.Byte_Count) return Boolean
      is
      begin
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
                          (Of_Unit, Item, Value, Facts, Limit - Reserved);
                        pragma Unreferenced (Call);
                     begin
                        null;
                     end;
                  end if;
               end;
            end loop;
         end loop;
         return True;
      exception
         when Stack_Limit_Exceeded => return False;
      end Calls_Fit;
   begin
      if Facts /= Landin.Targets.Cortex_M then
         return False;
      end if;
      if Landin.IR.Is_External (Of_Unit, Item) then
         return True;
      end if;
      --  Only emission plans the frame; preflight plans it only when the
      --  reference frame cannot show the frame and its calls' staging
      --  addressable.  Include caller staging and the largest transient
      --  selector scratch.
      Bound := Landin.Backend.Frame_Bound (Of_Unit, Item, Facts, Limit, 0);
      if Bound <= Limit and then Calls_Fit (Bound) then
         return True;
      end if;
      declare
         Reserved : constant Landin.Targets.Byte_Count :=
           Extent (Allocated_Frame (Of_Unit, Item, Facts, Limit));
      begin
         return Reserved <= Limit and then Calls_Fit (Reserved);
      end;
   exception
      when Stack_Limit_Exceeded => return False;
   end Frame_Is_Addressable;

   function Frame_Fits_Firmware_Stack
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts) return Boolean is
      Plan : constant Arm32_ABI.Plan := Arm32_ABI.Signature_Plan
        (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts);
      --  Match Emit_Routine: round used incoming register homes to eight
      --  bytes and add the six words pushed for the saved registers.
      Overhead : constant Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count ((Plan.Core_Used + 1) / 2) * 8 + 24
        + VFP_Bytes (Saved_VFP (Of_Unit, Item));
   begin
      if Landin.IR.Is_External (Of_Unit, Item)
        or else Landin.IR.Signature_Machine
          (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
            = Landin.Machine.Naked_Routine
      then
         return True;
      end if;
      return Landin.IR.Firmware_Profile (Of_Unit).Stack_Size >= Overhead
        and then Extent (Allocated_Frame
          (Of_Unit, Item, Facts, 16#FFFF_FFC0#)) <=
            Landin.IR.Firmware_Profile (Of_Unit).Stack_Size - Overhead;
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
      Firmware_Entry : Landin.IR.Item_Id := Landin.IR.No_Item;
      Panic : access constant Landin.Panics.Plan := null;
      Level : Landin.Targets.Levels.Feature_Level :=
        Landin.Targets.Levels.Default_Level (Landin.Targets.Cortex_M))
   is
      use type Landin.Targets.Levels.Feature_Level;

      --  D255: Armv7-M divides 32 bits in one instruction, so a 32-bit
      --  quotient or remainder needs no runtime helper.  The 64-bit ones
      --  still call it, since no M profile divides 64 bits.
      Has_Divide : constant Boolean :=
        Landin.Targets.Levels.Has (Level, Landin.Targets.Levels.Idiv);
      --  D605: Thumb-2 multiplies 32 by 32 bits into 64 in one
      --  instruction, so no product needs `__aeabi_lmul` there.
      Has_Long_Multiply : constant Boolean :=
        Landin.Targets.Levels.Has (Level, Landin.Targets.Levels.Thumb2);
      --  D1563: Thumb-2's 32-bit encodings, which reach a byte or
      --  halfword home from sp and any offset up to 4095.
      Thumb2 : constant Boolean :=
        Landin.Targets.Levels.Has (Level, Landin.Targets.Levels.Thumb2);
      --  D606: Armv8-M loads with acquire and stores with release in one
      --  instruction, so an ordered access needs no DMB beside it.
      Has_Acquire_Release : constant Boolean :=
        Landin.Targets.Levels.Is_Armv8_M (Level);
      --  D616/D617: a description with a float unit computes floats in its
      --  VFP registers and passes them in its bank.
      Hard : constant Boolean := Arm32_ABI.Uses_VFP (Of_Unit);
      Out_Text : Unbounded.Unbounded_String;
      --  Dense nonzero u32 atom codes, in declaration-identity order; zero
      --  stays available for the successful half of the failing-call
      --  carrier.
      Atoms_Ranked : constant Atom_Codes := Ranked (Of_Unit);
      Serial : Natural := 0;
      Leaf_Frame : Boolean := False;
      Leaf_Homes : Landin.Targets.Byte_Count := 0;
      --  How far sp stands below the bottom of a framed routine's homes,
      --  and whether that is known here.  A home is then sp plus a small
      --  constant, which one `add rd, sp, #imm` reaches up to 1020 bytes
      --  away, where r11 minus the offset takes a register move and, past
      --  255 bytes, three more instructions.  Known from the end of the
      --  prologue at every block's start, where nothing has moved sp yet;
      --  Reserve, Release and the paired pushes keep it; an assembly block
      --  that names sp, push or pop forgets it until the next block.
      Sp_Depth : Landin.Targets.Byte_Count := 0;
      Sp_Known : Boolean := False;
      --  D467: the deepest Sp_Depth a routine's body reaches, and how
      --  many runtime helpers it calls.
      Deepest_Below : Landin.Targets.Byte_Count := 0;
      Helpers_Called : Natural := 0;
      type Low_Set is array (4 .. 7) of Boolean;
      type Literal_Entry is record
         Name : Unbounded.Unbounded_String;
         Label : Unbounded.Unbounded_String;
      end record;
      package Literal_Vectors is new Ada.Containers.Vectors
        (Positive, Literal_Entry);
      Literals : Literal_Vectors.Vector;
      Pool_Active : Boolean := False;
      Pool_Flushing : Boolean := False;
      --  Four bytes per instruction is an upper bound on these Thumb
      --  instructions.  Keep well below the M0 literal-load limit of 1020
      --  bytes, including alignment and at most 32 pool words.
      Pool_Distance : Natural := 0;
      Pool_Generation : Natural := 0;
      Emission_Line : Natural := 0;
      --  D1567: while Recording names masks, Put adds what each line
      --  writes to the mask of position Record_At, unless Record_At is
      --  negative, outside every position, or the line is Intended, a
      --  write of a held location's own register.  While Deferring, a
      --  routine's statistics wait in Pending until its emission is kept.
      Recording : Write_Masks_Access;
      Record_At : Integer := -1;
      Intended : Boolean := False;
      Deferring : Boolean := False;
      Pending : Landin.Build_Reports.Routine_Statistics;

      function Fresh return String;
      procedure Put (Line : String);
      procedure Emit (Instruction : String);
      procedure Flush_Literals;
      procedure Immediate (Register : String; Value : Pattern);
      procedure Address (Register, Name : String; Imported : Boolean := False);
      procedure Add_Offset
        (Register : String; Offset : Landin.Targets.Byte_Count);
      procedure Frame_Address
        (Offset : Landin.Targets.Byte_Count; Register : String := "r6");
      procedure Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String);
      procedure Byte_Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String);
      procedure Reserve (Bytes : Landin.Targets.Byte_Count);
      procedure Release (Bytes : Landin.Targets.Byte_Count);
      procedure Copy_Bytes (Bytes : Landin.Targets.Byte_Count);
      procedure Copy_Words (Bytes : Landin.Targets.Byte_Count);
      procedure Zero_Words (Bytes : Landin.Targets.Byte_Count);
      procedure Zero_Bytes
        (Bytes : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment);
      function High (Register : String) return String;
      procedure Frame_Address_Through
        (Offset : Landin.Targets.Byte_Count; Register : String);
      procedure Emit_Verbatim (Text : String);





      procedure Emit (Instruction : String) is
      begin
         if Ada.Strings.Fixed.Index (Instruction, "bl __aeabi_") = 1 then
            Helpers_Called := Helpers_Called + 1;
         end if;
         --  Frame records emit no instructions. In particular, a record
         --  between a return and its trap label must not advance a pool
         --  flush ahead of that label in debug builds.
         if Pool_Active and then not Pool_Flushing
           and then not Literals.Is_Empty
           and then Ada.Strings.Fixed.Index (Instruction, ".cfi_") /= 1
         then
            if Pool_Distance >= 512 then
               Flush_Literals;
            elsif Instruction'Length > 0
              and then Instruction (Instruction'First) = '.'
            then
               if Instruction = ".balign 4"
                 or else Ada.Strings.Fixed.Index (Instruction, ".word ") = 1
               then
                  Pool_Distance := Pool_Distance + 4;
               elsif Ada.Strings.Fixed.Index (Instruction, ".cfi_") /= 1
               then
                  Flush_Literals;
               end if;
            end if;
         end if;
         if Instruction'Length > 0
           and then Instruction (Instruction'First) /= '.'
         then
            if Pool_Active and then not Pool_Flushing
              and then not Literals.Is_Empty
            then
               Pool_Distance := Pool_Distance + 4;
            end if;
         end if;
         Put (Character'Val (9) & Instruction);
      end Emit;

      function High (Register : String) return String is
        (case Register (Register'Last) is
            when '0' => "r1", when '2' => "r3", when '4' => "r5",
            when others => raise Compiler_Defect with "invalid word pair");

      --  A branch keeps literal words out of fallthrough control flow.  The
      --  oldest load is at most 512 bytes back, and 32 words plus alignment
      --  keep even the last entry within the 1020-byte M0 forward reach.
      procedure Flush_Literals is
      begin
         if Literals.Is_Empty then
            return;
         end if;
         declare
            Done : constant String := Fresh;
         begin
            Pool_Flushing := True;
            Pool_Generation := Pool_Generation + 1;
            Emit ("b " & Done);
            Emit (".balign 4");
            for Literal of Literals loop
               Put (Unbounded.To_String (Literal.Label) & ":");
               Emit (".word " & Unbounded.To_String (Literal.Name));
            end loop;
            Put (Done & ":");
            Literals.Clear;
            Pool_Distance := 0;
            Pool_Flushing := False;
         end;
      end Flush_Literals;

      procedure Address (Register, Name : String; Imported : Boolean := False)
      is
         pragma Unreferenced (Imported);
      begin
         if Pool_Active then
            if Pool_Distance >= 512 then
               Flush_Literals;
            end if;
            for Literal of Literals loop
               if Unbounded.To_String (Literal.Name) = Name then
                  Emit ("ldr " & Register & ", "
                    & Unbounded.To_String (Literal.Label));
                  return;
               end if;
            end loop;
            if Natural (Literals.Length) = 32 then
               Flush_Literals;
            end if;
            declare
               Id : constant String := Fresh;
            begin
               Literals.Append
                 (Literal_Entry'
                   (Name => Unbounded.To_Unbounded_String (Name),
                    Label => Unbounded.To_Unbounded_String (Id)));
               Emit ("ldr " & Register & ", " & Id);
            end;
         else
            --  Startup code is emitted by a separate producer; this path
            --  also keeps a load safe if Address is used outside a routine.
            declare
               Id : constant String := Fresh;
            begin
               Emit ("ldr " & Register & ", " & Id);
               Emit ("b " & Id & "_end");
               Emit (".balign 4");
               Put (Id & ":");
               Emit (".word " & Name);
               Put (Id & "_end:");
            end;
         end if;
      end Address;

      procedure Immediate (Register : String; Value : Pattern) is
         --  Thumb-2's modified immediate: a byte rotated into place, or
         --  one repeated in the halfwords or in every byte.
         function Modified return Boolean;
         function Modified return Boolean is
            Byte : constant Pattern := Value and 16#FF#;
         begin
            if Value = Byte * 16#0001_0001#
              or else Value = Byte * 16#0100_0100#
              or else Value = Byte * 16#0101_0101#
            then
               return True;
            end if;
            for Rotation in 8 .. 31 loop
               declare
                  Rotated : constant Pattern :=
                    ((Value * 2 ** Rotation) or (Value / 2 ** (32 - Rotation)))
                    and 16#FFFF_FFFF#;
               begin
                  if Rotated in 16#80# .. 16#FF# then
                     return True;
                  end if;
               end;
            end loop;
            return False;
         end Modified;
      begin
         if Value > 16#FFFF_FFFF# then
            raise Compiler_Defect with "word constant exceeds ARMv6-M";
         elsif Value <= 255 then
            Emit ("movs " & Register & ", #" & Trimmed (Value'Image));
         elsif Thumb2 then
            --  D1564: Thumb-2 makes a constant in one or two instructions
            --  without a literal: MOV.W's modified immediate, MOVW's
            --  halfword, and MOVT for the high one.
            if Modified then
               Emit ("mov.w " & Register & ", #" & Trimmed (Value'Image));
            else
               Emit ("movw " & Register & ", #"
                 & Trimmed (Pattern'Image (Value and 16#FFFF#)));
               if Value > 16#FFFF# then
                  Emit ("movt " & Register & ", #"
                    & Trimmed (Pattern'Image (Value / 2 ** 16)));
               end if;
            end if;
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
         if Leaf_Frame then
            Emit ("mov " & Register & ", sp");
            Add_Offset (Register, Leaf_Homes - Offset);
         elsif Sp_Known and then Offset <= Leaf_Homes
           and then Leaf_Homes - Offset + Sp_Depth <= 1020 + 2 * 255
           and then (Offset > 255
             or else Leaf_Homes - Offset + Sp_Depth <= 1020)
           and then Register'Length = 2
           and then Register (Register'First) = 'r'
           and then Register (Register'Last) in '0' .. '7'
         then
            --  Up to 1020 bytes above sp in one instruction, whose
            --  immediate counts words, and the rest in at most two more
            --  byte additions: never longer than the r11 forms below.
            declare
               Above : constant Landin.Targets.Byte_Count :=
                 Leaf_Homes - Offset + Sp_Depth;
               Base : constant Landin.Targets.Byte_Count :=
                 Landin.Targets.Byte_Count'Min (Above - Above mod 4, 1020);
               Rest : Landin.Targets.Byte_Count := Above - Base;
            begin
               Emit ("add " & Register & ", sp, #"
                 & Trimmed (Landin.Targets.Byte_Count'Image (Base)));
               while Rest > 0 loop
                  declare
                     Step : constant Landin.Targets.Byte_Count :=
                       Landin.Targets.Byte_Count'Min (Rest, 255);
                  begin
                     Emit ("adds " & Register & ", #"
                       & Trimmed (Landin.Targets.Byte_Count'Image (Step)));
                     Rest := Rest - Step;
                  end;
               end loop;
            end;
         elsif Offset <= 255 then
            Emit ("mov " & Register & ", r11");
            Emit ("subs " & Register & ", #" & Trimmed (Offset'Image));
         elsif Offset <= 2 * 255
           and then Register'Length = 2
           and then Register (Register'First) = 'r'
           and then Register (Register'Last) in '0' .. '7'
         then
            Emit ("mov " & Register & ", r11");
            Emit ("subs " & Register & ", #255");
            Emit ("subs " & Register & ", #"
              & Trimmed (Landin.Targets.Byte_Count'Image (Offset - 255)));
         else
            Emit ("mov " & Register & ", r11");
            Immediate ("r7", Pattern (Offset));
            Emit ("subs " & Register & ", " & Register & ", r7");
         end if;
      end Frame_Address;

      --  A frame address formed in Register alone, which assembly needs
      --  when every other low register holds an operand.
      procedure Frame_Address_Through
        (Offset : Landin.Targets.Byte_Count; Register : String) is
      begin
         if Leaf_Frame then
            Emit ("mov " & Register & ", sp");
            Add_Offset (Register, Leaf_Homes - Offset);
         elsif Offset <= 255 then
            Emit ("mov " & Register & ", r11");
            Emit ("subs " & Register & ", #" & Trimmed (Offset'Image));
         else
            Immediate (Register, Pattern (Offset));
            Emit ("rsbs " & Register & ", " & Register & ", #0");
            Emit ("add " & Register & ", r11");
         end if;
      end Frame_Address_Through;

      --  [1630]'s text, one instruction a line as written.
      procedure Emit_Verbatim (Text : String) is
         Start : Natural := Text'First;
      begin
         if Ada.Strings.Fixed.Index (Text, "sp") > 0
           or else Ada.Strings.Fixed.Index (Text, "push") > 0
           or else Ada.Strings.Fixed.Index (Text, "pop") > 0
         then
            Sp_Known := False;
         end if;
         Flush_Literals;
         for Index in Text'First .. Text'Last + 1 loop
            if Index > Text'Last or else Text (Index) = LF then
               declare
                  Line : constant String :=
                    Trimmed (Text (Start .. Index - 1));
               begin
                  if Line'Length > 0 then
                     Emit (Line);
                  end if;
               end;
               Start := Index + 1;
            end if;
         end loop;
      end Emit_Verbatim;

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

      --  D410: ARMv6-M faults on every unaligned halfword or word access,
      --  and a scalar of a byte-packed C record may sit at any address,
      --  so it moves one byte at a time, least significant first, with r4
      --  as scratch.  An eight-byte value is the register pair Memory's.
      procedure Byte_Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String)
      is
         Count : constant Positive := Landin.Targets.Bytes (Size);

         procedure Word (Into : String; First, Bytes : Natural);

         procedure Word (Into : String; First, Bytes : Natural) is
         begin
            if Store then
               Emit ("movs r4, " & Into);
               for Index in 0 .. Bytes - 1 loop
                  Emit ("strb r4, [" & Base & ", #"
                    & Trimmed (Natural'Image (First + Index)) & "]");
                  if Index < Bytes - 1 then
                     Emit ("lsrs r4, r4, #8");
                  end if;
               end loop;
            else
               Emit ("ldrb " & Into & ", [" & Base & ", #"
                 & Trimmed (Natural'Image (First + Bytes - 1)) & "]");
               for Index in reverse 0 .. Bytes - 2 loop
                  Emit ("lsls " & Into & ", " & Into & ", #8");
                  Emit ("ldrb r4, [" & Base & ", #"
                    & Trimmed (Natural'Image (First + Index)) & "]");
                  Emit ("orrs " & Into & ", r4");
               end loop;
            end if;
         end Word;
      begin
         if Count = 1 then
            Memory (Store, Size, Register, Base);
            return;
         end if;
         Word (Register, 0, Natural'Min (Count, 4));
         if Count = 8 then
            Word (High (Register), 4, 4);
         end if;
      end Byte_Memory;

      procedure Reserve (Bytes : Landin.Targets.Byte_Count) is
      begin
         Sp_Depth := Sp_Depth + Bytes;
         Deepest_Below :=
           Landin.Targets.Byte_Count'Max (Deepest_Below, Sp_Depth);
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
         if Bytes > Sp_Depth then
            Sp_Known := False;
         else
            Sp_Depth := Sp_Depth - Bytes;
         end if;
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

      --  A by-value transfer between disjoint, word-aligned ranges whose
      --  extent is a whole number of words: r0 destination, r2 source,
      --  both advanced.  Up to four words move as register pairs; a longer
      --  extent moves one word per iteration.  The ordinary byte loop
      --  retains the forward-copy behavior for aliases.
      procedure Copy_Words (Bytes : Landin.Targets.Byte_Count) is
         Id : constant String := Fresh;
      begin
         if Bytes <= 16 then
            for Pair in 1 .. Bytes / 8 loop
               Emit ("ldmia r2!, {r4, r5}");
               Emit ("stmia r0!, {r4, r5}");
            end loop;
            if Bytes mod 8 /= 0 then
               Emit ("ldmia r2!, {r4}");
               Emit ("stmia r0!, {r4}");
            end if;
            return;
         end if;
         Immediate ("r4", Pattern (Bytes / 4));
         Put (Id & ":");
         Emit ("ldmia r2!, {r5}");
         Emit ("stmia r0!, {r5}");
         Emit ("subs r4, #1");
         Emit ("bne " & Id);
      end Copy_Words;

      --  Zero_Bytes' word form for the same extents, r0 advanced.
      procedure Zero_Words (Bytes : Landin.Targets.Byte_Count) is
         Id : constant String := Fresh;
      begin
         if Bytes = 0 then
            return;
         end if;
         Emit ("movs r5, #0");
         if Bytes <= 16 then
            if Bytes >= 8 then
               Emit ("movs r4, #0");
            end if;
            for Pair in 1 .. Bytes / 8 loop
               Emit ("stmia r0!, {r4, r5}");
            end loop;
            if Bytes mod 8 /= 0 then
               Emit ("stmia r0!, {r5}");
            end if;
            return;
         end if;
         Immediate ("r4", Pattern (Bytes / 4));
         Put (Id & ":");
         Emit ("stmia r0!, {r5}");
         Emit ("subs r4, #1");
         Emit ("bne " & Id);
      end Zero_Words;

      procedure Zero_Bytes
        (Bytes : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment) is
         Id : constant String := Fresh;
      begin
         if Bytes = 0 then
            return;
         end if;
         if Alignment >= 4 and then Bytes >= 4 then
            Immediate ("r4", Pattern (Bytes / 4));
            Emit ("movs r5, #0");
            Put (Id & ":");
            Emit ("str r5, [r0]");
            Emit ("adds r0, #4");
            Emit ("subs r4, #1");
            Emit ("bne " & Id);
            for Tail in 1 .. Bytes mod 4 loop
               Emit ("strb r5, [r0]");
               if Tail < Bytes mod 4 then
                  Emit ("adds r0, #1");
               end if;
            end loop;
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
      --  readable names when free, or else D417's module-qualified name,
      --  `core.arena.reset`, with `.1`, `.2` and so on while another item
      --  holds that.  A candidate must avoid both forced names and other
      --  source names: an explicit C name can hold a qualified spelling too.
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

      package Section_Sets is new Ada.Containers.Hashed_Sets
        (Element_Type        => Landin.Source.Names.Name_Id,
         Hash                => Landin.Source.Names.Hash,
         Equivalent_Elements => Landin.Source.Names."=");
      Retained_Sections : Section_Sets.Set;

      --  A later item may retain a section selected by an earlier item.
      procedure Collect_Retained_Sections;
      procedure Collect_Retained_Sections is
      begin
         for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Attr : constant Landin.Machine.Placement :=
                 Landin.IR.Placement_Of
                   (Of_Unit, Landin.IR.Item_Id (Index));
            begin
               if Attr.Keep
                 and then Attr.Section /= Landin.Source.Names.No_Name
               then
                  Retained_Sections.Include (Attr.Section);
               end if;
            end;
         end loop;
      end Collect_Retained_Sections;

      function Is_Forced (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Link_Symbol (Of_Unit, Item)
              /= Landin.Source.Names.No_Name
            or else Item = Hosted_Entry
            or else Item = Firmware_Entry
            or else Landin.IR.Is_External (Of_Unit, Item));

      --  Pick a disjoint prefix for generated local labels. External source
      --  identities retain their ELF spelling at the rendering seam.
      function Unused_Local_Prefix (First : String := "L") return String;

      function Unused_Local_Prefix (First : String := "L") return String is
         Candidate : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String (First);
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
      --  D1569: a code label is assembler-local, outside the object's
      --  symbol table, so that a listing does not split a routine at it and
      --  an image's identity does not move with the program's item count.
      Label_Prefix : constant String := Unused_Local_Prefix (".L");
      --  ELF debug-only labels must not perturb ld's local-symbol hash table
      --  and consequently the order of generated flash/RAM veneers.
      Debug_Prefix : constant String := Unused_Local_Prefix (".Llandin_");

      --  D450 and D460: a program that prepares or switches a stack
      --  carries one switch routine and one start routine, emitted after
      --  its bodies; the block that emits them says what each does.  A
      --  context's saved frame is Stack_Frame bytes: the CONTROL word, r8
      --  to r11, a scratch word that keeps the frame eight-byte aligned,
      --  the stack's limit (D472), r4 to r7 and the address the switch returns
      --  to.  Stack_Limit is D471's cell: the current stack's limit, zero
      --  on the main stack.  A program that prepares a stack checks it in
      --  its routines' prologues and an interrupt handler keeps zero in it
      --  while it runs on the main stack; one that uses a builtin keeps
      --  it, and its switch saves and restores it.  Both
      --  routines are local function symbols, `landin.stack_switch` and
      --  `landin.stack_start` (D469), the names a debugger shows in a
      --  backtrace; no Landin routine is spelled with the dot, and an
      --  explicit link name that starts so moves the prefix as it moves a
      --  local label's.
      Stack_Used : Boolean := False;
      Routine_Prefix : constant String := Unused_Local_Prefix ("landin.");
      Stack_Switcher : constant String := Routine_Prefix & "stack_switch";
      Stack_Start : constant String := Routine_Prefix & "stack_start";
      --  D620: with a float unit the frame also holds d8-d15, FPSCR and a
      --  word keeping it aligned, between the limit and r8 to r11.
      VFP_Frame : constant Landin.Targets.Byte_Count :=
        (if Hard then Landin.Backend.VFP_Switch_Bytes else 0);
      VFP_Words : constant Natural := Natural (VFP_Frame / 4);
      Stack_Frame : constant Landin.Targets.Byte_Count := 48 + VFP_Frame;
      Prepares : constant Boolean := Landin.Backend.Prepares_Stacks (Of_Unit);
      Unchecked_Bytes : constant Landin.Targets.Byte_Count :=
        Landin.Backend.Unchecked_Stack_Bytes (Facts);
      Limit_Margin : constant Landin.Targets.Byte_Count :=
        Landin.Backend.Stack_Limit_Margin (Facts, Hard);
      Stack_Limit : constant String := Local_Prefix & "landin_stack_limit";

      procedure Put (Line : String) is
      begin
         Unbounded.Append (Out_Text, Line & LF);
         if Recording /= null and then Record_At >= 0
           and then not Intended
         then
            Recording (Record_At) :=
              Recording (Record_At) or Written_By (Line);
         end if;
         --  Debug records cannot change r6 or introduce an executable
         --  entry. Preserve adjacent-home reuse across those records.
         if Line'Length > 0
           and then Ada.Strings.Fixed.Index
             (Line, Character'Val (9) & ".loc ") /= Line'First
           and then Ada.Strings.Fixed.Index
             (Line, Character'Val (9) & ".cfi_") /= Line'First
           and then Ada.Strings.Fixed.Index
             (Line, Debug_Prefix & "debug_") /= Line'First
         then
            Emission_Line := Emission_Line + 1;
         end if;
      end Put;

      function Fresh return String is
      begin
         Serial := Serial + 1;
         return Label_Prefix & "cm_step_" & Trimmed (Serial'Image);
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
            if (Candidate'Length >= 8
                and then Candidate (Candidate'First
                  .. Candidate'First + 7) = "__aeabi_")
              or else Ada.Strings.Fixed.Index
                (Candidate, "_landin_firmware_") = Candidate'First
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

      function Is_Exported_Item (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.Backend.Is_Exported
              (Of_Unit, Meanings, Item, Hosted_Entry, Firmware_Entry));

      --  Labels carry the item, because a Block_Id restarts at 1 in the
      --  next item and two blocks named `.L1` would be one label.
      function Label
        (Item : Landin.IR.Item_Id; Block : Landin.IR.Block_Id)
        return String
        is (Label_Prefix & Trimmed (Landin.IR.Item_Id'Image (Item))
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
         --  D547: a region placement's section names the region and what
         --  the region does with it: run or read in place, or copy from
         --  its load image, or clear, when the region is writable.
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
            Kind : constant String :=
              (if Prefix = ".bss." then "bss"
               elsif Writable then "data"
               elsif Prefix = ".text." then "text"
               else "rodata");
         begin
            return ".landin_region." & Region & "." & Kind & ".landin_"
              & Trimmed (Item'Image);
         end Region_Section;
         Name : constant String :=
           (if Attr.Region /= Landin.Source.Names.No_Name
            then Region_Section
            elsif Attr.Section = Landin.Source.Names.No_Name
            then Prefix & "landin_" & Trimmed (Item'Image)
            else Landin.Source.Names.Spelling (Names, Attr.Section));
         Retained : constant Boolean := Attr.Keep or else
           (Attr.Section /= Landin.Source.Names.No_Name
            and then Retained_Sections.Contains (Attr.Section));
         BSS : constant Boolean :=
           Ada.Strings.Fixed.Index (Name, ".bss.") = Name'First
           or else (Attr.Region /= Landin.Source.Names.No_Name
             and then Ada.Strings.Fixed.Index (Name, ".bss.") /= 0);
      begin
         Emit (".section " & Name & ",""" & Flags
           & (if Retained then "R" else "") & """,%"
           & (if BSS then "nobits" else "progbits"));
         if Attr.Alignment /= 0 then
            Emit (".balign " & Trimmed (Attr.Alignment'Image));
         end if;
      end Select_Section;

      procedure Emit_Vectors;
      procedure Emit_Vectors is
         --  D544: the selected profile's table.  A slot it admits takes its
         --  handler or the unhandled loop, and every other slot is zero.
         Profile : constant Landin.Targets.Firmware.Profile :=
           Landin.IR.Firmware_Profile (Of_Unit);
         Handlers : array (2 .. Landin.Targets.Firmware.Slot_Capacity - 1)
           of Landin.IR.Item_Id := [others => Landin.IR.No_Item];
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
         Emit (".balign " & Trimmed (Landin.Targets.Firmware.Vector_Alignment
           (Profile)'Image));
         Emit (".globl _landin_firmware_vectors");
         Put ("_landin_firmware_vectors:");
         Emit (".word _landin_firmware_stack_top");
         --  D653: a vector-table description's stage runs before reset.
         if Profile.Has_Stage
           and then Landin.Targets.Firmware.Stage_Before_Reset (Profile.Boot)
         then
            Emit (".word " & Landin.Targets.Firmware.Reset_Stage_Symbol);
         else
            Emit (".word _landin_firmware_reset");
         end if;
         for Slot in 2 .. Profile.Vector_Count - 1 loop
            if not Landin.Targets.Firmware.Admits (Profile, Slot) then
               Emit (".word 0");
            elsif Handlers (Slot) /= Landin.IR.No_Item then
               Emit (".word " & Symbol (Handlers (Slot)));
            else
               Emit (".word _landin_firmware_unhandled");
            end if;
         end loop;
         if Landin.Targets.Firmware.Takes_Image_Block (Profile.Boot) then
            --  D637: the IMAGE_DEF block, directly after the table, which
            --  the driver reads back from the object it assembles (D638).
            Emit (".section .embedded_block,""a"",%progbits");
            Emit (".balign 4");
            Emit (".globl _landin_firmware_image_block");
            Emit (".type _landin_firmware_image_block, %object");
            Put ("_landin_firmware_image_block:");
            for Word of Landin.Targets.Firmware.Image_Block loop
               Emit (".word " & Landin.Backend.Firmware.Hex
                 (Landin.Targets.Byte_Count (Word)));
            end loop;
            Emit (".size _landin_firmware_image_block, . - _landin_firmware_"
              & "image_block");
         end if;
      end Emit_Vectors;

      --  Layout is the routine's one planned frame, which the tentative
      --  emission hands the final one.
      procedure Emit_Routine
        (Item : Landin.IR.Item_Id; Layout : Frame; Probe : Boolean := True;
         Leaf : Boolean := False; Saves : Low_Set := [others => True];
         Registers : access constant Register_Plan := null);

      procedure Emit_Routine
        (Item : Landin.IR.Item_Id; Layout : Frame; Probe : Boolean := True;
         Leaf : Boolean := False; Saves : Low_Set := [others => True];
         Registers : access constant Register_Plan := null) is
         Path_Layouts : Landin.IR.Shape_Measurement.Layout_Cache;
         Before_Serial : constant Natural := Serial;
         Before_Line : constant Natural := Emission_Line;
         Before_Generation : constant Natural := Pool_Generation;
         Before_Distance : constant Natural := Pool_Distance;
         Used_Low : Low_Set := [others => False];
         Saving_Low : constant Low_Set := Saves;
         Save_Count : Landin.Targets.Byte_Count := 0;
         Body_Marker : constant String := "@landin_cortex_body@";
         Routine_Start : constant Positive := Unbounded.Length (Out_Text) + 1;
         --  D1768: a site whose Register is named is a comparison with
         --  zero and its conditional branch, which a Thumb-2 level makes
         --  one CBZ or CBNZ where the label is ahead and in its reach.
         type Branch_Site is record
            First, Last : Positive;
            Target, Condition : Unbounded.Unbounded_String;
            Register : Unbounded.Unbounded_String :=
              Unbounded.Null_Unbounded_String;
         end record;
         package Branch_Vectors is new Ada.Containers.Vectors
           (Positive, Branch_Site);
         package Position_Vectors is new Ada.Containers.Vectors
           (Positive, Positive);
         Sites : Branch_Vectors.Vector;
         Assembly_Barriers : Position_Vectors.Vector;
         Result : constant Landin.Types.Type_Kind :=
           Landin.IR.Result_Of (Of_Unit, Item);
         Plan : constant Arm32_ABI.Plan := Arm32_ABI.Signature_Plan
           (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts);
         --  Keep the incoming register words below the laid-out frame.
         --  Round up so calls retain eight-byte SP alignment.
         Home_Bytes : constant Landin.Targets.Byte_Count :=
           Landin.Targets.Byte_Count ((Plan.Core_Used + 1) / 2) * 8;
         --  D617: d8-d15's save, between the laid-out homes and the
         --  incoming staging, so the limit check covers it.
         Saved_Run : constant VFP_Run := Saved_VFP (Of_Unit, Item);
         VFP_Save : constant Landin.Targets.Byte_Count :=
           VFP_Bytes (Saved_Run);
         VFP_Save_Offset : constant Landin.Targets.Byte_Count :=
           Extent (Layout) + VFP_Save;
         Homes : constant Landin.Targets.Byte_Count :=
           Extent (Layout) + VFP_Save + Home_Bytes;
         Hard_Trap : constant String := Label (Item, 1) & "_trap";
         Return_Label : constant String := Label (Item, 1) & "_return";
         Exit_Count : Natural := 0;
         Current_Value : Landin.IR.Value_Id := Landin.IR.No_Value;
         --  D1566: a branch its comparison emitted, and how many operands
         --  read each value.
         Fused : Landin.IR.Value_Id := Landin.IR.No_Value;
         Readers : Landin.Backend.Placement.Count_Buffers.Buffer
           (Landin.IR.Value_Count (Of_Unit, Item));
         Ordinary : constant Boolean := Landin.IR.Signature_Machine
           (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
             = Landin.Machine.Ordinary;
         type Panic_Edge is record
            Reason : Landin.Panics.Kind;
            Site : Landin.Panics.Site_Number;
            Label : Unbounded.Unbounded_String;
            Origin : Landin.Provenance.Origin;
         end record;
         package Edge_Vectors is new Ada.Containers.Vectors
           (Positive, Panic_Edge);
         Edges : Edge_Vectors.Vector;
         Home_Ready : Boolean := False;
         Home_Line : Natural := 0;
         Home_Offset : Landin.Targets.Byte_Count := 0;
         Hard_Trap_Used : Boolean := False;
         --  D471: whether a stack limit check branches to this routine's
         --  own stack_exhausted trap, laid out after the others, and
         --  whether this is an interrupt handler that keeps zero in the
         --  limit's cell while it runs on the main stack.
         Limit_Trapped : Boolean := False;
         Limit_Trap : constant String := Label (Item, 1) & "_stack_limit";
         Keeps_Limit : constant Boolean :=
           Prepares and then not Ordinary
           and then Landin.IR.Signature_Machine
             (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
               /= Landin.Machine.Naked_Routine;
         --  The bytes an interrupt handler pushes below its frame record
         --  for that: the interrupted context's limit and a word that
         --  keeps eight-byte alignment.
         Kept : constant Natural := (if Keeps_Limit then 8 else 0);
         --  D587: the description's second stage, emitted at the start of
         --  the boot kind's slot.
         Marked_Stage : constant Boolean :=
           Landin.IR.Placement_Of (Of_Unit, Item).Boot_Stage;
         --  D653: on a vector-table image the stage runs from the reset
         --  vector, before compiler-owned reset, wherever the text lies.
         Reset_Stage : constant Boolean := Marked_Stage
           and then Landin.Targets.Firmware.Stage_Before_Reset
             (Landin.IR.Firmware_Profile (Of_Unit).Boot);
         Boot_Stage : constant Boolean :=
           Marked_Stage and then not Reset_Stage;

         procedure Mark_Low (Assembly : String);
         function Call_Free (Assembly : String) return Boolean;
         function Low_List return String;

         function Assembly_Space (C : Character) return Boolean is
           (C in ' ' | Character'Val (9) | Character'Val (11)
             | Character'Val (12) | Character'Val (13));

         procedure Mark_Low (Assembly : String) is
            Start : Positive := Assembly'First;
            function Name_Character (C : Character) return Boolean is
              (C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_');
         begin
            for Last in Assembly'Range loop
               if Assembly (Last) = LF then
                  if Assembly (Start) = Character'Val (9) then
                     declare
                        Line : constant String :=
                          Ada.Characters.Handling.To_Lower
                            (Assembly (Start + 1 .. Last - 1));
                        First : Natural := Line'First;
                        Space : Natural;
                        Operand_First : Natural;
                     begin
                        while First <= Line'Last and then
                          Assembly_Space (Line (First))
                        loop
                           First := First + 1;
                        end loop;
                        Space := First;
                        while Space <= Line'Last and then
                          not Assembly_Space (Line (Space))
                        loop
                           Space := Space + 1;
                        end loop;
                        Operand_First := Space;
                        while Operand_First <= Line'Last and then
                          Assembly_Space (Line (Operand_First))
                        loop
                           Operand_First := Operand_First + 1;
                        end loop;
                        if First <= Line'Last and then
                          Line (First) /= '.' and then
                          Operand_First <= Line'Last
                        then
                           declare
                              Op : constant String :=
                                Line (First .. Space - 1);
                              Limit : Natural := Line'Last;
                           begin
                              --  Branch operands and bare literal names are
                              --  symbols, even when one is spelled "r5".
                              if Op not in "b" | "bl" | "beq" | "bne"
                                | "bcc" | "bcs" | "bmi" | "bpl" | "bvs"
                                | "bvc" | "bhi" | "bls" | "bge" | "blt"
                                | "bgt" | "ble" | "bal"
                              then
                                 if Op in "ldr" | "ldrb" | "ldrh"
                                   | "ldrsb" | "ldrsh" | "adr"
                                 then
                                    declare
                                       Comma : constant Natural :=
                                         Ada.Strings.Fixed.Index (Line, ",");
                                    begin
                                       if Comma > 0 and then
                                         Ada.Strings.Fixed.Index
                                           (Line (Comma + 1 .. Line'Last),
                                            "[") = 0
                                       then
                                          Limit := Comma - 1;
                                       end if;
                                    end;
                                 end if;
                                 for Index in Operand_First .. Limit - 1 loop
                                    if Line (Index) = 'r' and then
                                      Line (Index + 1) in '4' .. '7'
                                      and then (Index = Operand_First or else
                                        not Name_Character (Line (Index - 1)))
                                      and then (Index + 1 = Limit or else
                                        not Name_Character (Line (Index + 2)))
                                    then
                                       Used_Low
                                         (Character'Pos (Line (Index + 1))
                                          - Character'Pos ('0')) := True;
                                    end if;
                                 end loop;
                              end if;
                           end;
                        end if;
                     end;
                  end if;
                  Start := Last + 1;
               end if;
            end loop;
         end Mark_Low;

         function Call_Free (Assembly : String) return Boolean is
            Start : Positive := Assembly'First;
            Begun : Boolean := False;
         begin
            for Last in Assembly'Range loop
               if Assembly (Last) = LF then
                  declare
                     Line : constant String := Assembly (Start .. Last - 1);
                  begin
                     if Line = Body_Marker then
                        Begun := True;
                     elsif Begun and then Line'Length > 0 and then
                       Line (Line'First) = Character'Val (9)
                     then
                        declare
                           Text : constant String :=
                             Ada.Characters.Handling.To_Lower
                               (Line (Line'First + 1 .. Line'Last));
                           First : Natural := Text'First;
                           Space : Natural;
                           Operand_First : Natural;
                        begin
                           while First <= Text'Last and then
                             Assembly_Space (Text (First))
                           loop
                              First := First + 1;
                           end loop;
                           Space := First;
                           while Space <= Text'Last and then
                             not Assembly_Space (Text (Space))
                           loop
                              Space := Space + 1;
                           end loop;
                           Operand_First := Space;
                           while Operand_First <= Text'Last and then
                             Assembly_Space (Text (Operand_First))
                           loop
                              Operand_First := Operand_First + 1;
                           end loop;
                           if First <= Text'Last and then
                             Operand_First <= Text'Last
                           then
                              declare
                                 Op : constant String :=
                                   Text (First .. Space - 1);
                              begin
                                 if (Op in "bl" | "blx" | "push" | "pop"
                                     and then not (Op = "bl"
                                       and then Is_Trap (Trimmed (Text
                                         (Operand_First .. Text'Last)))))
                                   or else (Op in "sub" | "add" | "mov"
                                     and then Operand_First + 1 <= Text'Last
                                     and then Text (Operand_First
                                       .. Operand_First + 1) = "sp")
                                 then
                                    return False;
                                 end if;
                              end;
                           end if;
                        end;
                     end if;
                  end;
                  Start := Last + 1;
               end if;
            end loop;
            return True;
         end Call_Free;

         function Low_List return String is
            List : Unbounded.Unbounded_String;
         begin
            for Reg in Saving_Low'Range loop
               if Saving_Low (Reg) then
                  if Unbounded.Length (List) > 0 then
                     Unbounded.Append (List, ", ");
                  end if;
                  Unbounded.Append (List, "r" & Trimmed (Reg'Image));
               end if;
            end loop;
            return Unbounded.To_String (List);
         end Low_List;

         function Trap (Reason : Landin.Panics.Kind) return String;
         function Trap return String;

         function Trap (Reason : Landin.Panics.Kind) return String is
         begin
            if Panic = null or else Landin.Panics.Handler (Panic.all)
              = Landin.IR.No_Item
            then
               Hard_Trap_Used := True;
               return Hard_Trap;
            end if;
            declare
               Site : constant Landin.Panics.Site_Number := Landin.Panics.Site
                 (Panic.all, (if Current_Value = Landin.IR.No_Value
                  then Landin.IR.Origin_Of (Of_Unit, Item)
                  else Landin.IR.Origin_Of (Of_Unit, Item, Current_Value)),
                  Reason);
               Name : constant String := Fresh & "_trap";
            begin
               Edges.Append (Panic_Edge'
                 (Reason, Site, Unbounded.To_Unbounded_String (Name),
                  (if Current_Value = Landin.IR.No_Value
                   then Landin.IR.Origin_Of (Of_Unit, Item)
                   else Landin.IR.Origin_Of
                     (Of_Unit, Item, Current_Value))));
               return Name;
            end;
         end Trap;

         function Trap return String is
           (Trap (Landin.Panics.For_Value
              (Of_Unit, Item, Current_Value)));

         function Kind (Value : Landin.IR.Value_Id)
           return Landin.Types.Scalar_Name
           is (Landin.IR.Result_Of (Of_Unit, Item, Value));

         --  D1567: the register Registers holds a value or slot in, else
         --  0, and a register's name.
         function Value_Register (Value : Landin.IR.Value_Id) return Natural
           is (if Registers = null then 0
               else Registers.Values (Positive (Value)).Register);
         function Slot_Register (Slot : Landin.IR.Slot_Id) return Natural
           is (if Registers = null then 0
               else Registers.Slots (Positive (Slot)).Register);
         function Name (Register : Natural) return String
           is ("r" & Trimmed (Natural'Image (Register)));

         --  D1767: whether a constant is made where it is read, and its
         --  pattern, zero-extended from its size as a home holds it.
         function Deferred (Value : Landin.IR.Value_Id) return Boolean
           is ((Recording /= null or else Registers /= null)
               and then Deferred_Constant (Of_Unit, Item, Facts, Value));
         function Constant_Of (Value : Landin.IR.Value_Id) return Pattern;
         function Constant_Of (Value : Landin.IR.Value_Id) return Pattern is
            Number : Pattern := Pattern
              (Landin.IR.Number_Of (Of_Unit, Item, Value));
            Bytes : constant Positive := Landin.Targets.Bytes
              (Size_Of (Landin.IR.Result_Of (Of_Unit, Item, Value), Facts));
         begin
            if Landin.IR.Is_Negated (Of_Unit, Item, Value) then
               Number := 0 - Number;
            end if;
            return Number and (2 ** (8 * Bytes) - 1);
         end Constant_Of;

         --  D1767: "#N" for a deferred constant an eight-bit immediate
         --  form takes, N at most Limit and not negative as its own type
         --  reads it, else "".
         function Immediate_Operand
           (Value : Landin.IR.Value_Id; Limit : Pattern := 255)
            return String;
         function Immediate_Operand
           (Value : Landin.IR.Value_Id; Limit : Pattern := 255)
            return String is
         begin
            if not Deferred (Value) then
               return "";
            end if;
            declare
               Number : constant Pattern := Constant_Of (Value);
               Scalar : constant Landin.Types.Type_Kind :=
                 Landin.IR.Result_Of (Of_Unit, Item, Value);
               Bits : constant Natural :=
                 8 * Landin.Targets.Bytes (Size_Of (Scalar, Facts));
            begin
               if Number <= Limit
                 and then (not Landin.Types.Is_Signed (Scalar)
                           or else Number < 2 ** (Bits - 1))
               then
                  return "#" & Trimmed (Pattern'Image (Number));
               end if;
               return "";
            end;
         end Immediate_Operand;

         --  D1567: a held scalar narrower than a word is held
         --  zero-extended, as a load from its home leaves it.
         procedure Hold
           (Register : Natural; From : String; Size : Held_Size);
         procedure Hold
           (Register : Natural; From : String; Size : Held_Size) is
         begin
            Intended := True;
            if Size = Landin.Targets.Byte_1 then
               Emit ("uxtb " & Name (Register) & ", " & From);
            elsif Size = Landin.Targets.Byte_2 then
               Emit ("uxth " & Name (Register) & ", " & From);
            elsif From /= Name (Register) then
               Emit ("mov " & Name (Register) & ", " & From);
            end if;
            Intended := False;
         end Hold;
         function Size_Of_Value (Value : Landin.IR.Value_Id) return Held_Size
           is (Size_Of (Kind (Value), Facts));
         procedure Load_Value
           (Value : Landin.IR.Value_Id; Register : String := "r0");
         procedure Store_Value
           (Value : Landin.IR.Value_Id; Register : String := "r0";
            Extended : Boolean := False);
         procedure Load_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "r0");
         procedure Store_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "r0");
         procedure Scalar_Memory
           (Store : Boolean; Size : Held_Size;
            Offset : Landin.Targets.Byte_Count; Register : String;
            Widened : Boolean := False; Extended : Boolean := False);
         procedure Branch (Condition, Target : String);
         procedure Jump (Target : String);
         procedure Long_Jump (Target : String);
         procedure Shorten_Local_Branches;
         procedure Extend (Register : String; Scalar : Landin.Types.Type_Kind);
         procedure Epilogue;
         procedure Restore_And_Return;
         procedure Return_From_Routine;

         procedure Long_Jump (Target : String) is
            Id : constant String := Fresh;
         begin
            if Is_Trap (Target) then
               Emit ("bl " & Target);
               return;
            end if;
            --  Keep the adjacent address word attached to its label. A
            --  pool inserted after that label makes the load read pool
            --  instructions as a destination. These four emitted lines
            --  account for at most sixteen bytes in the pool bound.
            if Pool_Distance + 16 >= 512 then
               Flush_Literals;
            end if;
            Emit ("ldr r7, " & Id);
            Emit ("bx r7");
            Emit (".balign 4");
            Put (Id & ":");
            Emit (".word " & Target & " + 1");
         end Long_Jump;

         procedure Jump (Target : String) is
            First : constant Positive := Unbounded.Length (Out_Text) + 1;
            Generation : constant Natural := Pool_Generation;
         begin
            --  D1564: Thumb-2's B reaches 16 MiB, and the assembler
            --  chooses its narrow or wide encoding.
            if Thumb2 then
               Emit ("b " & Target);
               return;
            end if;
            Long_Jump (Target);
            --  A distance-triggered pool may have been inserted in this
            --  sequence. Its literals serve earlier loads, so retain the
            --  complete sequence when shortening would also erase them.
            if Generation = Pool_Generation then
               Sites.Append
                 (Branch_Site'(First, Unbounded.Length (Out_Text),
                   Unbounded.To_Unbounded_String (Target),
                   Unbounded.Null_Unbounded_String,
                   Unbounded.Null_Unbounded_String));
            end if;
         end Jump;

         function Inverse_Of (Condition : String) return String is
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
            elsif Condition = "mi" then "pl"
            elsif Condition = "pl" then "mi"
            else raise Compiler_Defect with "invalid ARM condition");

         --  D1566: the block emitted now, and the value after the one
         --  emitted now in it.
         Current_Block : Natural := 0;
         Next_Value : Landin.IR.Value_Id := Landin.IR.No_Value;
         --  D1567: the layout position of the value emitted now.
         Tick : Natural := 0;

         --  D1566: a jump to the block laid out next is no instruction.
         procedure Jump_To_Block (Block : Landin.IR.Block_Id);
         procedure Jump_To_Block (Block : Landin.IR.Block_Id) is
         begin
            if Natural (Block) /= Current_Block + 1 then
               Jump (Label (Item, Block));
            end if;
         end Jump_To_Block;

         --  D1566: to Target when Condition holds, else to Alternative,
         --  falling through to whichever is laid out next.
         procedure Transfer
           (Condition : String; Target, Alternative : Landin.IR.Block_Id);
         procedure Transfer
           (Condition : String; Target, Alternative : Landin.IR.Block_Id) is
            use type Landin.IR.Block_Id;
         begin
            if Natural (Target) = Current_Block + 1
              and then Target /= Alternative
            then
               Branch (Inverse_Of (Condition), Label (Item, Alternative));
            else
               Branch (Condition, Label (Item, Target));
               Jump_To_Block (Alternative);
            end if;
         end Transfer;

         --  D1768: Register compared with zero, then Transfer's branches.
         procedure Zero_Transfer
           (Register, Condition : String;
            Target, Alternative : Landin.IR.Block_Id);
         procedure Zero_Transfer
           (Register, Condition : String;
            Target, Alternative : Landin.IR.Block_Id)
         is
            use type Landin.IR.Block_Id;
            First : constant Positive := Unbounded.Length (Out_Text) + 1;
            Generation : constant Natural := Pool_Generation;
            Ahead : constant Boolean :=
              Natural (Target) = Current_Block + 1
              and then Target /= Alternative;
            Taken : constant String :=
              (if Ahead then Inverse_Of (Condition) else Condition);
            Destination : constant String :=
              Label (Item, (if Ahead then Alternative else Target));
         begin
            Emit ("cmp " & Register & ", #0");
            Branch (Taken, Destination);
            if Thumb2 and then Generation = Pool_Generation
              and then Register'Length = 2
              and then Register (Register'Last) in '0' .. '7'
              and then Taken in "eq" | "ne"
            then
               Sites.Append
                 (Branch_Site'(First, Unbounded.Length (Out_Text),
                   Unbounded.To_Unbounded_String (Destination),
                   Unbounded.To_Unbounded_String (Taken),
                   Unbounded.To_Unbounded_String (Register)));
            end if;
            if not Ahead then
               Jump_To_Block (Alternative);
            end if;
         end Zero_Transfer;

         procedure Branch (Condition, Target : String) is
            First : constant Positive := Unbounded.Length (Out_Text) + 1;
            Generation : constant Natural := Pool_Generation;
            Skip : constant String := Fresh;
            Inverse : constant String := Inverse_Of (Condition);
         begin
            --  D1564: Thumb-2's conditional B reaches 1 MiB, and the
            --  assembler chooses its narrow or wide encoding.
            if Thumb2 then
               Emit ("b" & Condition & " " & Target);
               return;
            end if;
            Emit ("b" & Inverse & " " & Skip);
            Long_Jump (Target);
            Put (Skip & ":");
            if Generation = Pool_Generation then
               Sites.Append
                 (Branch_Site'(First, Unbounded.Length (Out_Text),
                   Unbounded.To_Unbounded_String (Target),
                   Unbounded.To_Unbounded_String (Condition),
                   Unbounded.Null_Unbounded_String));
            end if;
         end Branch;

         --  Each ordinary Thumb instruction occupies at most four bytes;
         --  the compiler's in-routine data and alignment lines also occupy
         --  at most four. Four bytes per source line, plus room for both
         --  endpoints, bounds the span before branches are shortened. Do not
         --  cross an inline-assembly or literal-pool boundary, whose size is
         --  not known here. The assembler remains the final range check.
         procedure Shorten_Local_Branches is
            --  Index this routine once. Branch spans then use prefix line
            --  counts and ordered barriers rather than rescanning the text.
            Text : constant String := Unbounded.Slice
              (Out_Text, Routine_Start, Unbounded.Length (Out_Text));
            package Label_Maps is new Ada.Containers.Indefinite_Hashed_Maps
              (String, Positive, Ada.Strings.Hash, "=");
            Labels : Label_Maps.Map;
            Lines, Pools : Position_Vectors.Vector;
            Rewritten : Unbounded.Unbounded_String;
            Cursor : Positive := Text'First;
            Line_First : Positive := Text'First;

            --  Number of indexed positions strictly before Position.
            function Before
              (Points : Position_Vectors.Vector; Position : Positive)
               return Natural;

            function Before
              (Points : Position_Vectors.Vector; Position : Positive)
               return Natural
            is
               Low : Positive := 1;
               High : Natural := Natural (Points.Length);
            begin
               while Low <= High loop
                  declare
                     Middle : constant Positive := Low + (High - Low) / 2;
                  begin
                     if Points (Middle) < Position then
                        Low := Middle + 1;
                     else
                        High := Middle - 1;
                     end if;
                  end;
               end loop;
               return High;
            end Before;

            function Crosses
              (Points : Position_Vectors.Vector; Low, High : Positive)
               return Boolean
              is (Before (Points, High + 1) /= Before (Points, Low));
         begin
            if Sites.Is_Empty then
               return;
            end if;
            for Index in Text'Range loop
               if Text (Index) = LF then
                  declare
                     Line : constant String :=
                       Text (Line_First .. Index - 1);
                     HT : constant Character := Character'Val (9);
                  begin
                     --  Debug directives and labels occupy no code bytes.
                     --  Unknown source sites also emit an empty debug line.
                     --  Their presence must not change branch selection.
                     if Line'Length /= 0
                       and then Ada.Strings.Fixed.Index
                         (Line, HT & ".loc ") /= Line'First
                       and then Ada.Strings.Fixed.Index
                         (Line, HT & ".cfi_") /= Line'First
                       and then Ada.Strings.Fixed.Index
                         (Line, Debug_Prefix & "debug_") /= Line'First
                     then
                        Lines.Append (Index);
                     end if;
                  end;
                  if Index > Line_First
                    and then Text (Index - 1) = ':'
                    and then Line_First > Text'First
                  then
                     declare
                        Name : constant String :=
                          Text (Line_First .. Index - 2);
                     begin
                        if not Labels.Contains (Name) then
                           --  The old search names the LF before the label.
                           Labels.Insert (Name, Line_First - 1);
                        end if;
                     end;
                  end if;
                  declare
                     Pool : constant Natural := Ada.Strings.Fixed.Index
                       (Text (Line_First .. Index - 1), ".ltorg");
                  begin
                     if Pool /= 0 then
                        Pools.Append (Pool);
                     end if;
                  end;
                  Line_First := Index + 1;
               end if;
            end loop;
            for Site of Sites loop
               declare
                  Name : constant String := Unbounded.To_String (Site.Target);
                  Found : constant Label_Maps.Cursor := Labels.Find (Name);
                  First : constant Positive :=
                    Site.First - Routine_Start + Text'First;
               begin
                  if Label_Maps.Has_Element (Found)
                    and then Unbounded.Length (Site.Register) > 0
                  then
                     --  D1768: CBZ and CBNZ reach 126 bytes forward from
                     --  the instruction after them.
                     declare
                        Destination : constant Positive :=
                          Label_Maps.Element (Found);
                        Bound : constant Integer :=
                          4 * (Before (Lines, Destination + 1)
                               - Before (Lines, First)) + 4;
                     begin
                        if Destination > First
                          and then not Crosses
                            (Assembly_Barriers,
                             First - Text'First + Routine_Start,
                             Destination - Text'First + Routine_Start)
                          and then not Crosses (Pools, First, Destination)
                          and then Bound <= 126
                        then
                           Unbounded.Append
                             (Rewritten, Text (Cursor .. First - 1));
                           Unbounded.Append
                             (Rewritten, Character'Val (9)
                              & (if Unbounded.To_String (Site.Condition)
                                   = "eq" then "cbz " else "cbnz ")
                              & Unbounded.To_String (Site.Register)
                              & ", " & Name & LF);
                           Cursor := Site.Last - Routine_Start
                             + Text'First + 1;
                        end if;
                     end;
                  elsif Label_Maps.Has_Element (Found) then
                     declare
                        Destination : constant Positive :=
                          Label_Maps.Element (Found);
                        Low : constant Positive :=
                          Positive'Min (First, Destination);
                        High : constant Positive :=
                          Positive'Max (First, Destination);
                        Bound : constant Natural :=
                          4 * (Before (Lines, High + 1)
                               - Before (Lines, Low)) + 8;
                     begin
                        if not Crosses
                          (Assembly_Barriers,
                           Low - Text'First + Routine_Start,
                           High - Text'First + Routine_Start)
                          and then not Crosses (Pools, Low, High)
                          and then Bound <
                            (if Unbounded.Length (Site.Condition) = 0
                             then 2_000 else 240)
                        then
                           Unbounded.Append
                             (Rewritten, Text (Cursor .. First - 1));
                           Unbounded.Append
                             (Rewritten, Character'Val (9) & "b"
                              & Unbounded.To_String (Site.Condition)
                              & " " & Name & LF);
                           Cursor := Site.Last - Routine_Start
                             + Text'First + 1;
                        end if;
                     end;
                  end if;
               end;
            end loop;
            if Cursor /= Text'First then
               Unbounded.Append (Rewritten, Text (Cursor .. Text'Last));
               Unbounded.Delete
                 (Out_Text, Routine_Start, Unbounded.Length (Out_Text));
               Unbounded.Append (Out_Text, Rewritten);
            end if;
         end Shorten_Local_Branches;
         --  r6 is available across adjacent scalar accesses.  Any emitted
         --  line between them may change it or introduce another entry path,
         --  so only reuse the address when the previous access ended the
         --  output.  A nearby home needs at most one immediate adjustment.
         --  D1563: how far above sp the home Offset names starts, when
         --  that is known here, else -1: a leaf's sp stays at the bottom
         --  of its homes from its prologue's reservation on, and a framed
         --  routine knows its depth from each block's start until an
         --  assembly block names sp.
         function Sp_Above (Offset : Landin.Targets.Byte_Count)
           return Integer
           is (if Offset > Leaf_Homes then -1
               elsif Leaf_Frame then Integer (Leaf_Homes - Offset)
               elsif Sp_Known then Integer (Leaf_Homes - Offset + Sp_Depth)
               else -1);

         --  D1563: a home is read and written through sp's own offset
         --  form where one reaches it: Thumb-1's word form up to 1020
         --  bytes, and at the Thumb-2 levels the byte, halfword and word
         --  forms up to 4095; else through its address formed in r6.  A
         --  value's home narrower than a word is a word (Allocated_Frame)
         --  and Widened: it is written zero-extended, through r7, so a
         --  word read from it is what a narrower one would read.
         procedure Scalar_Memory
           (Store : Boolean; Size : Held_Size;
            Offset : Landin.Targets.Byte_Count; Register : String;
            Widened : Boolean := False; Extended : Boolean := False)
         is
            Above : constant Integer := Sp_Above (Offset);
            --  A register already zero-extended is stored as a word.
            Narrow : constant Boolean :=
              Size in Landin.Targets.Byte_1 | Landin.Targets.Byte_2
              and then not (Store and then Extended);
            Moved : constant Held_Size :=
              (if Widened
                 and then Size in Landin.Targets.Byte_1
                   | Landin.Targets.Byte_2
               then Landin.Targets.Byte_4 else Size);
            From : constant String :=
              (if Widened and then Narrow and then Store then "r7"
               else Register);
            Last : constant Integer :=
              Above + (if Moved = Landin.Targets.Byte_8 then 4 else 0);
         begin
            if Above >= 0 and then Register /= "r6"
              and then
                ((Moved in Landin.Targets.Byte_4 | Landin.Targets.Byte_8
                  and then Above mod 4 = 0 and then Last <= 1020)
                 or else (Thumb2 and then Last <= 4095))
            then
               if Widened and then Narrow and then Store then
                  Emit ((if Size = Landin.Targets.Byte_1 then "uxtb r7, "
                         else "uxth r7, ") & Register);
               end if;
               declare
                  Op : constant String :=
                    (if Store then "str" else "ldr")
                    & (case Moved is
                         when Landin.Targets.Byte_1 => "b",
                         when Landin.Targets.Byte_2 => "h",
                         when others => "");
               begin
                  Emit (Op & " " & From & ", [sp, #"
                    & Trimmed (Integer'Image (Above)) & "]");
                  if Moved = Landin.Targets.Byte_8 then
                     Emit (Op & " " & High (From) & ", [sp, #"
                       & Trimmed (Integer'Image (Above + 4)) & "]");
                  end if;
               end;
               return;
            end if;
            if Home_Ready and then Home_Line = Emission_Line
              and then Register /= "r6"
              and then Offset = Home_Offset
            then
               null;
            elsif Home_Ready and then Home_Line = Emission_Line
              and then Register /= "r6"
              and then Offset > Home_Offset
              and then Offset - Home_Offset <= 255
            then
               Emit ("subs r6, #" & Trimmed
                 (Landin.Targets.Byte_Count'Image (Offset - Home_Offset)));
            elsif Home_Ready and then Home_Line = Emission_Line
              and then Register /= "r6"
              and then Home_Offset > Offset
              and then Home_Offset - Offset <= 255
            then
               Emit ("adds r6, #" & Trimmed
                 (Landin.Targets.Byte_Count'Image (Home_Offset - Offset)));
            else
               Frame_Address (Offset);
            end if;
            if Widened and then Narrow and then Store then
               --  Frame_Address may have formed a long offset in r7.
               Emit ((if Size = Landin.Targets.Byte_1 then "uxtb r7, "
                      else "uxth r7, ") & Register);
            end if;
            Memory (Store, Moved, From, "r6");
            Home_Ready := Register /= "r6";
            Home_Line := Emission_Line;
            Home_Offset := Offset;
         end Scalar_Memory;

         procedure Load_Value
           (Value : Landin.IR.Value_Id; Register : String := "r0") is
         begin
            if Deferred (Value) then
               Immediate (Register, Constant_Of (Value));
               return;
            end if;
            if Value_Register (Value) /= 0 then
               if Register /= Name (Value_Register (Value)) then
                  Emit ("mov " & Register & ", "
                    & Name (Value_Register (Value)));
               end if;
               return;
            end if;
            Scalar_Memory (False, Size_Of_Value (Value),
              Value_Offset (Layout, Value), Register, Widened => True);
         end Load_Value;

         --  Extended says that Register already holds the value
         --  zero-extended, as a load or a comparison leaves it.
         procedure Store_Value
           (Value : Landin.IR.Value_Id; Register : String := "r0";
            Extended : Boolean := False) is
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
                     Emit ("cmp " & Register & ", #0");
                     Branch ("eq", Done);
                  end if;
                  for Run of Runs_Of (Of_Unit, Atoms_Ranked, Atoms) loop
                     if Run.Low = Run.High then
                        Immediate ("r4", Pattern (Run.Low));
                        Emit ("cmp " & Register & ", r4");
                        Branch ("eq", Done);
                     else
                        declare
                           Next : constant String := Fresh;
                        begin
                           Immediate ("r4", Pattern (Run.Low));
                           Emit ("cmp " & Register & ", r4");
                           Branch ("cc", Next);
                           Immediate ("r4", Pattern (Run.High));
                           Emit ("cmp " & Register & ", r4");
                           Branch ("ls", Done);
                           Put (Next & ":");
                        end;
                     end if;
                  end loop;
                  Jump (Trap (Landin.Panics.Bad_Conversion));
                  Put (Done & ":");
               end;
            end if;
            if Value_Register (Value) /= 0 then
               Hold (Value_Register (Value), Register,
                     (if Extended then Landin.Targets.Byte_4
                      else Size_Of_Value (Value)));
               return;
            end if;
            Scalar_Memory (True, Size_Of_Value (Value),
              Value_Offset (Layout, Value), Register, Widened => True,
              Extended => Extended);
         end Store_Value;

         procedure Load_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "r0") is
         begin
            if Slot_Register (Slot) /= 0 then
               if Register /= Name (Slot_Register (Slot)) then
                  Emit ("mov " & Register & ", "
                    & Name (Slot_Register (Slot)));
               end if;
               return;
            end if;
            Scalar_Memory (False, Size_Of
              (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts),
              Slot_Offset (Layout, Slot), Register);
         end Load_Slot;

         procedure Store_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "r0") is
         begin
            if Slot_Register (Slot) /= 0 then
               Hold (Slot_Register (Slot), Register, Size_Of
                 (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts));
               return;
            end if;
            Scalar_Memory (True, Size_Of
              (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts),
              Slot_Offset (Layout, Slot), Register);
         end Store_Slot;

         procedure Extend (Register : String; Scalar : Landin.Types.Type_Kind)
         is
         begin
            if Scalar in Landin.Types.I8 | Landin.Types.I16 then
               Emit ((if Scalar = Landin.Types.I8 then "sxtb " else "sxth ")
                 & Register & ", " & Register);
            end if;
         end Extend;

         --  D1567: the register an operation reads a value from: the
         --  value's own when it is held, else Default after loading it
         --  there.  Extended as Scalar asks, which a held value, kept
         --  zero-extended, needs only for a narrow signed scalar; that one
         --  is loaded to Default and extended there.  A use writes nothing
         --  through it.
         function Operand_In
           (Value : Landin.IR.Value_Id; Default : String;
            Scalar : Landin.Types.Type_Kind := Landin.Types.U32)
            return String;
         function Operand_In
           (Value : Landin.IR.Value_Id; Default : String;
            Scalar : Landin.Types.Type_Kind := Landin.Types.U32)
            return String is
         begin
            if Value_Register (Value) /= 0
              and then Scalar not in Landin.Types.I8 | Landin.Types.I16
            then
               return Name (Value_Register (Value));
            end if;
            Load_Value (Value, Default);
            Extend (Default, Scalar);
            return Default;
         end Operand_In;

         --  The register an operation writes Value's result to: its own
         --  when held, else Default.  Store_Value (Value, Result_In ...)
         --  then completes it.
         function Result_In
           (Value : Landin.IR.Value_Id; Default : String := "r0")
            return String
           is (if Value_Register (Value) /= 0
                 and then not Landin.IR.Validates_Atoms (Of_Unit, Item, Value)
               then Name (Value_Register (Value)) else Default);

         --  D1567: the restores follow every read of the exit that runs
         --  them, after which nothing is live, so they are not recorded.
         procedure Epilogue is
            Recorded_At : constant Integer := Record_At;
            procedure Restore_Saves;
            procedure Restore_Saves is
            begin
               Record_At := -1;
               Restore_And_Return;
               Record_At := Recorded_At;
            end Restore_Saves;
         begin
            Restore_Saves;
         end Epilogue;

         procedure Restore_And_Return is
         begin
            if Probe then
               return;
            end if;
            if Leaf then
               if Debug /= null then
                  Emit (".cfi_remember_state");
               end if;
               if Homes in 1 .. 508 then
                  Emit ("add sp, #" & Trimmed (Homes'Image));
               elsif Homes > 0 then
                  Immediate ("r2", Pattern (Homes));
                  Emit ("add sp, r2");
               end if;
               if Debug /= null then
                  Emit (".cfi_def_cfa_offset " & Trimmed (Save_Count'Image));
               end if;
               if Save_Count > 0 then
                  Emit ("pop {" & Low_List & "}");
               end if;
               if Debug /= null then
                  Emit (".cfi_def_cfa_offset 0");
                  for Reg in Saving_Low'Range loop
                     if Saving_Low (Reg) then
                        Emit (".cfi_restore r" & Trimmed (Reg'Image));
                     end if;
                  end loop;
               end if;
               Emit ("bx lr");
               if Debug /= null then
                  Emit (".cfi_restore_state");
               end if;
               return;
            end if;
            if Debug /= null then
               Emit (".cfi_remember_state");
            end if;
            if VFP_Save > 0 then
               Frame_Address_Through (VFP_Save_Offset, "r6");
               Emit ("vldmia r6, " & VFP_List (Saved_Run));
               if Debug /= null then
                  for Reg in Saved_Run.Low .. Saved_Run.High loop
                     Emit (".cfi_restore d" & Trimmed (Reg'Image));
                  end loop;
               end if;
            end if;
            Emit ("mov r6, r11");
            Emit ("mov sp, r6");
            if Debug /= null then
               Emit (".cfi_def_cfa sp, " & Trimmed (Integer'Image
                 (24 + Kept)));
            end if;
            Emit ("ldr r7, [r6, #4]");
            Emit ("ldr r6, [r6]");
            Emit ("mov lr, r7");
            if Debug /= null and then Ordinary then
               Emit (".cfi_restore lr");
            end if;
            Emit ("mov r11, r6");
            if Debug /= null then
               Emit (".cfi_restore r11");
            end if;
            Emit ("add sp, #8");
            if Debug /= null then
               Emit (".cfi_def_cfa_offset " & Trimmed (Integer'Image
                 (16 + Kept)));
            end if;
            Emit ("pop {r4, r5, r6, r7}");
            if Debug /= null then
               Emit (".cfi_def_cfa_offset " & Trimmed (Kept'Image));
               for Reg in 4 .. 7 loop
                  Emit (".cfi_restore r" & Trimmed (Reg'Image));
               end loop;
            end if;
            --  D471: the interrupted context's limit back in the cell.
            if Keeps_Limit then
               Emit ("pop {r0, r1}");
               if Debug /= null then
                  Emit (".cfi_def_cfa_offset 0");
               end if;
               Address ("r1", Stack_Limit);
               Emit ("str r0, [r1]");
            end if;
            Emit ("bx lr");
            if Debug /= null then
               Emit (".cfi_restore_state");
            end if;
         end Restore_And_Return;

         procedure Return_From_Routine is
         begin
            if Exit_Count > 1 then
               --  The literal follows bx, so its PC-relative load is always
               --  in range, even across large or opaque assembly blocks.
               --  r7 is restored by the shared epilogue before returning.
               Jump (Return_Label);
            else
               Epilogue;
            end if;
         end Return_From_Routine;

         --  D471: go to the limit trap when the stack pointer less Bytes
         --  is below the current stack's limit, before anything is written
         --  there.  r6 and r7 are free after a framed prologue's pushes and
         --  wherever a call's area is reserved.
         procedure Check_Limit (Bytes : Landin.Targets.Byte_Count);

         procedure Check_Limit (Bytes : Landin.Targets.Byte_Count) is
            Wrapped : constant String := Fresh;
            Fits : constant String := Fresh;
         begin
            Emit ("mov r6, sp");
            if Bytes in 1 .. 255 then
               Emit ("subs r6, #" & Trimmed (Bytes'Image));
            elsif Bytes > 0 then
               Immediate ("r7", Pattern (Bytes));
               Emit ("subs r6, r6, r7");
            end if;
            if Bytes = 0 then
               Address ("r7", Stack_Limit);
               Emit ("ldr r7, [r7]");
               Emit ("cmp r6, r7");
               Branch ("cc", Limit_Trap);
            else
               --  D1111: a frame larger than the stack pointer's own value
               --  borrows, and the difference it leaves is above every
               --  limit.  The borrow joins the comparison's own jump to
               --  the trap, one short branch more: at most a literal pool
               --  and four instructions lie between it and its label.
               Emit ("bcc " & Wrapped);
               Address ("r7", Stack_Limit);
               Emit ("ldr r7, [r7]");
               Emit ("cmp r6, r7");
               Emit ("bcs " & Fits);
               Put (Wrapped & ":");
               Long_Jump (Limit_Trap);
               Put (Fits & ":");
            end if;
            Limit_Trapped := True;
         end Check_Limit;
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
         function Root_Word_Aligned
           (Place : Landin.IR.Storage) return Boolean;
         function Same_Root
           (Left, Right : Landin.IR.Storage) return Boolean;
         function Disjoint_Roots
           (Left, Right : Landin.IR.Storage;
            Bytes : Landin.Targets.Byte_Count) return Boolean;
         --  Whether two storage roots share no byte of their complete
         --  extents, so any parts reached inside them are disjoint too.
         function Separate_Roots
           (Left, Right : Landin.IR.Storage) return Boolean;
         function Clear_Alignment
           (Place  : Landin.IR.Storage;
            Field  : Natural;
            Nested : Landin.IR.Path_Step_Array)
            return Landin.Targets.Byte_Alignment;
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

         --  D1769: the frame offset of a frame slot's part, as Part_Address
         --  reaches it, so that Scalar_Memory reads or writes it from sp
         --  where an offset form reaches it.
         function Part_Home
           (Place  : Landin.IR.Storage;
            Field  : Landin.IR.Element_Total;
            Nested : Landin.IR.Path_Step_Array)
            return Landin.Targets.Byte_Count;
         function Part_Home
           (Place  : Landin.IR.Storage;
            Field  : Landin.IR.Element_Total;
            Nested : Landin.IR.Path_Step_Array)
            return Landin.Targets.Byte_Count
         is
            Offset : Landin.Targets.Byte_Count := 0;
            function Shape return Landin.IR.Field_Shape is
              (if Field = 0 then Root_Shape_Of (Place, 0)
               else Part_Shape_Of (Place, Landin.IR.Part_Position (Field)));
         begin
            if Field > 0 then
               Offset := Slot_Offset (Layout, Place.Slot)
                 - Landin.Backend.Field_Offset
                   (Of_Unit, Item, Layout, Place.Slot,
                    Landin.IR.Part_Position (Field), Facts);
            end if;
            if Nested'Length > 0 then
               Offset := Offset + Path_Offset (Shape, Nested);
            end if;
            return Slot_Offset (Layout, Place.Slot) - Offset;
         end Part_Home;

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

         --  These are whole-array roots.  Module array alignment comes from
         --  its emitted .balign; frame offsets are relative to aligned r11.
         function Root_Word_Aligned (Place : Landin.IR.Storage)
           return Boolean is
         begin
            case Place.Kind is
               when Landin.IR.Module_Datum =>
                  --  A whole struct datum has no array shape to measure;
                  --  Clear_Alignment places either kind.
                  return Clear_Alignment
                    (Place, 0, Landin.IR.No_Path_Steps) >= 4;
               when Landin.IR.Frame_Slot =>
                  return Slot_Offset (Layout, Place.Slot) mod 4 = 0;
               when Landin.IR.Runtime_Address =>
                  return False;
            end case;
         end Root_Word_Aligned;

         function Same_Root
           (Left, Right : Landin.IR.Storage) return Boolean is
         begin
            if Left.Kind /= Right.Kind then
               return False;
            end if;
            case Left.Kind is
               when Landin.IR.Module_Datum =>
                  return Left.Datum = Right.Datum;
               when Landin.IR.Frame_Slot =>
                  return Left.Slot = Right.Slot;
               when Landin.IR.Runtime_Address =>
                  return False;
            end case;
         end Same_Root;

         function Disjoint_Roots
           (Left, Right : Landin.IR.Storage;
            Bytes : Landin.Targets.Byte_Count) return Boolean is
         begin
            if Left.Kind = Landin.IR.Runtime_Address
              or else Right.Kind = Landin.IR.Runtime_Address
            then
               return False;
            elsif Left.Kind /= Right.Kind then
               return True;
            elsif Left.Kind = Landin.IR.Module_Datum then
               return Left.Datum /= Right.Datum;
            else
               declare
                  A : constant Landin.Targets.Byte_Count :=
                    Slot_Offset (Layout, Left.Slot);
                  B : constant Landin.Targets.Byte_Count :=
                    Slot_Offset (Layout, Right.Slot);
               begin
                  return (if A >= B then A - B >= Bytes
                          else B - A >= Bytes);
               end;
            end if;
         end Disjoint_Roots;

         function Separate_Roots
           (Left, Right : Landin.IR.Storage) return Boolean is
         begin
            if Left.Kind = Landin.IR.Frame_Slot
              and then Right.Kind = Landin.IR.Frame_Slot
            then
               declare
                  A : constant Landin.Targets.Byte_Count :=
                    Slot_Offset (Layout, Left.Slot);
                  B : constant Landin.Targets.Byte_Count :=
                    Slot_Offset (Layout, Right.Slot);
               begin
                  --  A slot lies at its offset below the frame base.
                  return (if A >= B
                          then A - B >= Whole_Clear_Extent
                            (Left, 0, Landin.IR.No_Path_Steps)
                          else B - A >= Whole_Clear_Extent
                            (Right, 0, Landin.IR.No_Path_Steps));
               end;
            end if;
            return Disjoint_Roots (Left, Right, 0);
         end Separate_Roots;
         --  A runtime address may be supplied with weaker alignment than
         --  its shape.  Static storage and frame slots follow the target
         --  layout, including the offsets of their reached child fields.
         function Clear_Alignment
           (Place  : Landin.IR.Storage;
            Field  : Natural;
            Nested : Landin.IR.Path_Step_Array)
            return Landin.Targets.Byte_Alignment
         is
            Size : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
         begin
            if Place.Kind = Landin.IR.Runtime_Address then
               return 1;
            end if;
            if Field = 0 and then Nested'Length = 0 then
               case Place.Kind is
                  when Landin.IR.Module_Datum =>
                     if Landin.IR.Result_Of (Of_Unit, Place.Datum)
                          = Landin.Types.Aggregate
                     then
                        declare
                           Placed : Landin.Targets.Placement;
                           Ignored : Landin.Targets.Byte_Count;
                        begin
                           Place_Fields (Place.Datum, Placed, 0, Ignored);
                           return Landin.Targets.Alignment_Of (Placed);
                        end;
                     end if;
                  when Landin.IR.Frame_Slot =>
                     if Landin.IR.Is_Aggregate
                          (Of_Unit, Item, Place.Slot)
                     then
                        Landin.Backend.Aggregate_Extent
                          (Of_Unit, Item, Place.Slot, Facts,
                           Size, Alignment);
                        return Alignment;
                     end if;
                  when Landin.IR.Runtime_Address =>
                     null;
               end case;
            end if;
            Landin.Backend.Field_Extent
              (Of_Unit, Reached_Shape (Place, Field, Nested), Facts,
               Size, Alignment);
            return Alignment;
         end Clear_Alignment;

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

         --  [1630] on ARMv6-M.  Each input is loaded through its own
         --  register, so loading needs no other; the text runs; each output
         --  is stored through a low register no output still waiting
         --  holds.  Only a block whose outputs hold all of r0-r7 finds none
         --  for its first, which then waits in r12 -- a register no block
         --  names and every block may overwrite -- and is stored last.  The
         --  literal pool the text may have used is flushed behind a branch.
         --  On a float unit's profile a float input is loaded first by
         --  VLDR, through r6 while no input holds it, and a float output
         --  stored by VSTR through a free low register, as s(2n) for an
         --  f32 and d(n) for an f64 (D630).
         procedure Assembly_Block (Value : Landin.IR.Value_Id);

         procedure Assembly_Block (Value : Landin.IR.Value_Id) is
            Chosen : constant Landin.Targets.Assembly.Operand_Register_Array :=
              Landin.Backend.Assembly_Registers
                (Of_Unit, Item, Value, Names, Facts);
            After_Block : constant String := Fresh;
            Waiting : array (0 .. 7) of Boolean := [others => False];
            Input_Of : array (Chosen'Range) of Natural := [others => 0];
            Aside : Natural := 0;

            function Operand (Index : Positive)
              return Landin.IR.Assembly_Operand
              is (Landin.IR.Nth_Assembly_Operand
                    (Of_Unit, Item, Value, Index));

            function Is_Float (Index : Positive) return Boolean
              is (Operand (Index).Kind in Landin.Types.Float_Name);

            function Register (Index : Positive) return String
              is (Ada.Strings.Unbounded.To_String (Chosen (Index).Register));

            function Number (Index : Positive) return Natural
              is (Natural'Value
                    (Register (Index) (Register (Index)'First + 1
                       .. Register (Index)'Last)));

            --  A float operand's register at its float's width.
            function Float_Name (Index : Positive) return String
              is (if Operand (Index).Kind = Landin.Types.F64
                  then Register (Index)
                  else "s" & Trimmed (Natural'Image (2 * Number (Index))));

            function Free return String;

            function Free return String is
            begin
               for Candidate in reverse Waiting'Range loop
                  if not Waiting (Candidate) then
                     return "r" & Trimmed (Natural'Image (Candidate));
                  end if;
               end loop;
               raise Compiler_Defect with "no low register is free";
            end Free;

            procedure Store (Index : Positive; From : String);

            procedure Store (Index : Positive; From : String) is
               Base : constant String := Free;
            begin
               Frame_Address_Through
                 (Slot_Offset (Layout, Operand (Index).Output), Base);
               if Is_Float (Index) then
                  Emit ("vstr " & From & ", [" & Base & "]");
               else
                  Memory (True, Size_Of (Operand (Index).Kind, Facts),
                          From, Base);
               end if;
            end Store;
         begin
            declare
               Inputs : Natural := 0;
            begin
               for Index in Chosen'Range loop
                  if Operand (Index).Direction
                    in Landin.IR.Input | Landin.IR.Both
                  then
                     Inputs := Inputs + 1;
                     Input_Of (Index) := Inputs;
                  end if;
                  if Operand (Index).Output /= Landin.IR.No_Slot
                    and then not Is_Float (Index)
                  then
                     Waiting (Number (Index)) := True;
                  end if;
               end loop;
            end;
            for Float in reverse Boolean loop
               for Index in Chosen'Range loop
                  if Input_Of (Index) /= 0 and then Is_Float (Index) = Float
                  then
                     declare
                        Home : constant Landin.Targets.Byte_Count :=
                          Value_Offset (Layout, Landin.IR.Nth_Operand
                            (Of_Unit, Item, Value, Input_Of (Index)));
                     begin
                        if Float then
                           Frame_Address_Through (Home, "r6");
                           Emit ("vldr " & Float_Name (Index) & ", [r6]");
                        else
                           Frame_Address_Through (Home, Register (Index));
                           Memory (False,
                                   Size_Of (Operand (Index).Kind, Facts),
                                   Register (Index), Register (Index));
                           Extend (Register (Index), Operand (Index).Kind);
                        end if;
                     end;
                  end if;
               end loop;
            end loop;
            Assembly_Barriers.Append (Unbounded.Length (Out_Text) + 1);
            Emit_Verbatim (Landin.Backend.Assembly_Text
              (Of_Unit, Item, Value, Names, Facts));
            if (for all Held of Waiting => Held) then
               for Index in Chosen'Range loop
                  if Operand (Index).Output /= Landin.IR.No_Slot
                    and then not Is_Float (Index)
                  then
                     Aside := Index;
                     Emit ("mov r12, " & Register (Index));
                     Waiting (Number (Index)) := False;
                     exit;
                  end if;
               end loop;
            end if;
            for Index in Chosen'Range loop
               if Operand (Index).Output /= Landin.IR.No_Slot
                 and then Index /= Aside
               then
                  if Is_Float (Index) then
                     Store (Index, Float_Name (Index));
                  else
                     Store (Index, Register (Index));
                     Waiting (Number (Index)) := False;
                  end if;
               end if;
            end loop;
            if Aside /= 0 then
               declare
                  Held : constant String := Free;
               begin
                  Waiting (Natural'Value (Held (Held'First + 1 .. Held'Last)))
                    := True;
                  Emit ("mov " & Held & ", r12");
                  Store (Aside, Held);
               end;
            end if;
            Emit ("b " & After_Block);
            Emit (".ltorg");
            Put (After_Block & ":");
         end Assembly_Block;

         --  D617: with a float unit, a float's home moves into and out of
         --  a VFP register in one VLDR or VSTR, through r6 as every home
         --  does.  N is the register's number in the value's bank: s<N>
         --  for an f32, d<N> for an f64.
         function Bank (Scalar : Landin.Types.Type_Kind; N : Natural)
           return String
           is ((if Scalar = Landin.Types.F64 then "d" else "s")
               & Trimmed (N'Image));

         procedure VFP_Home
           (Store : Boolean; Offset : Landin.Targets.Byte_Count;
            Register : String);
         procedure VFP_Home
           (Store : Boolean; Offset : Landin.Targets.Byte_Count;
            Register : String) is
         begin
            Frame_Address (Offset);
            Emit ((if Store then "vstr " else "vldr ") & Register
              & ", [r6]");
         end VFP_Home;

         procedure VFP_Value
           (Store : Boolean; Value : Landin.IR.Value_Id; N : Natural := 0);
         procedure VFP_Value
           (Store : Boolean; Value : Landin.IR.Value_Id; N : Natural := 0)
         is
         begin
            VFP_Home (Store, Value_Offset (Layout, Value),
                      Bank (Kind (Value), N));
         end VFP_Value;

         --  D920: a C record by value.  Copy_Record moves BYTES from r2 to
         --  r0, both advanced, by words when the record's alignment lets
         --  ARMv6-M load them, and never past the record's extent.
         procedure Copy_Record
           (Bytes : Landin.Targets.Byte_Count; Aligned : Boolean);
         procedure Copy_Record
           (Bytes : Landin.Targets.Byte_Count; Aligned : Boolean) is
         begin
            if Aligned and then Bytes mod 4 = 0 then
               Copy_Words (Bytes);
            else
               Copy_Bytes (Bytes);
            end if;
         end Copy_Record;

         --  A record held in registers rather than by address, between
         --  them and the record at BASE: a VFP candidate's members in its
         --  s or d registers, each at its own offset since the members
         --  are all of one type, or a record of up to four bytes in r0,
         --  a byte at a time unless its size and alignment admit one
         --  access.  r4 is scratch for a load.
         procedure C_Record_Registers
           (Store : Boolean; Held : Arm32_ABI.Location; Base : String);
         procedure C_Record_Registers
           (Store : Boolean; Held : Arm32_ABI.Location; Base : String)
         is
            Size : constant Landin.Targets.Byte_Count := Held.Shape.Size;
            Op : constant String := (if Store then "str" else "ldr");
         begin
            if Held.VFP_Count > 0 then
               for Member in 1 .. Held.Shape.Members loop
                  Emit ("v" & Op & " "
                    & Arm32_ABI.VFP_Register (Held, Member) & ", [" & Base
                    & ", #" & Trimmed (Natural'Image
                      ((Member - 1)
                       * (if Held.Shape.Float_Base = Landin.Types.F64
                          then 8 else 4))) & "]");
               end loop;
            elsif Size = 4 and then Held.Shape.Alignment >= 4 then
               Emit (Op & " r0, [" & Base & "]");
            elsif Size = 2 and then Held.Shape.Alignment >= 2 then
               Emit (Op & "h r0, [" & Base & "]");
            elsif Size = 1 then
               Emit (Op & "b r0, [" & Base & "]");
            elsif Store then
               for Index in 1 .. Size loop
                  Emit ("strb r0, [" & Base & ", #"
                    & Trimmed (Landin.Targets.Byte_Count'Image (Index - 1))
                    & "]");
                  if Index < Size then
                     Emit ("lsrs r0, r0, #8");
                  end if;
               end loop;
            else
               Emit ("ldrb r0, [" & Base & ", #"
                 & Trimmed (Landin.Targets.Byte_Count'Image (Size - 1))
                 & "]");
               for Index in reverse 1 .. Size - 1 loop
                  Emit ("lsls r0, r0, #8");
                  Emit ("ldrb r4, [" & Base & ", #"
                    & Trimmed (Landin.Targets.Byte_Count'Image (Index - 1))
                    & "]");
                  Emit ("orrs r0, r4");
               end loop;
            end if;
         end C_Record_Registers;

         --  A call's C record argument, whose value is its address: its
         --  members into their VFP registers, or its words into the core
         --  registers' staging at sp + STAGING and the rest, a split
         --  record's suffix included, into the outgoing area.
         procedure Pass_C_Record
           (Actual : Landin.IR.Value_Id; Arg : Arm32_ABI.Location;
            Staging : Landin.Targets.Byte_Count);
         procedure Pass_C_Record
           (Actual : Landin.IR.Value_Id; Arg : Arm32_ABI.Location;
            Staging : Landin.Targets.Byte_Count)
         is
            Size : constant Landin.Targets.Byte_Count := Arg.Shape.Size;
            In_Core : constant Landin.Targets.Byte_Count :=
              Landin.Targets.Byte_Count'Min
                (Size, Landin.Targets.Byte_Count (Arg.Core_Count) * 4);
            Aligned : constant Boolean := Arg.Shape.Alignment >= 4;
         begin
            Load_Value (Actual, "r2");
            if Arg.VFP_Count > 0 then
               C_Record_Registers (False, Arg, "r2");
               return;
            end if;
            if Arg.Core_Count > 0 then
               Emit ("mov r0, sp");
               Add_Offset ("r0", Staging
                 + Landin.Targets.Byte_Count (Arg.First_Core) * 4);
               Copy_Record (In_Core, Aligned);
            end if;
            if Size > In_Core then
               Emit ("mov r0, sp");
               Add_Offset ("r0", Arg.Stack_At);
               Copy_Record (Size - In_Core, Aligned);
            end if;
         end Pass_C_Record;

         --  D617: what a float unit computes in its own instructions:
         --  f32 and f64 arithmetic, negation and comparison, conversion
         --  between the widths and between a float and an integer of at
         --  most 32 bits.  A conversion from or to 64 bits, and a float's
         --  test as a bool, keep the selection below, which needs no
         --  arithmetic helper; Handled says which.
         procedure Float_Instruction
           (Value : Landin.IR.Value_Id; Handled : out Boolean);
         procedure Float_Instruction
           (Value : Landin.IR.Value_Id; Handled : out Boolean)
         is
            Op : constant Landin.IR.Opcode :=
              Landin.IR.Op_Of (Of_Unit, Item, Value);
            function Operand (Index : Positive) return Landin.IR.Value_Id
              is (Landin.IR.Nth_Operand (Of_Unit, Item, Value, Index));
            Result : constant Landin.Types.Type_Kind :=
              Landin.IR.Result_Of (Of_Unit, Item, Value);
            Suffix : constant String :=
              (if Result = Landin.Types.F64 then ".f64" else ".f32");
         begin
            Handled := True;
            case Op is
               when Landin.IR.Add | Landin.IR.Subtract | Landin.IR.Multiply
                  | Landin.IR.Divide =>
                  if Result not in Landin.Types.Float_Name then
                     Handled := False;
                     return;
                  end if;
                  VFP_Value (False, Operand (1), 0);
                  VFP_Value (False, Operand (2), 1);
                  Emit ((case Op is
                           when Landin.IR.Add => "vadd",
                           when Landin.IR.Subtract => "vsub",
                           when Landin.IR.Multiply => "vmul",
                           when others => "vdiv")
                        & Suffix & " " & Bank (Result, 0) & ", "
                        & Bank (Result, 0) & ", " & Bank (Result, 1));
                  VFP_Value (True, Value, 0);
               when Landin.IR.Negation =>
                  if Result not in Landin.Types.Float_Name then
                     Handled := False;
                     return;
                  end if;
                  VFP_Value (False, Operand (1), 0);
                  Emit ("vneg" & Suffix & " " & Bank (Result, 0) & ", "
                    & Bank (Result, 0));
                  VFP_Value (True, Value, 0);
               when Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                  | Landin.IR.Less_Than | Landin.IR.Less_Or_Equal
                  | Landin.IR.Greater_Than | Landin.IR.Greater_Or_Equal =>
                  if Kind (Operand (1)) not in Landin.Types.Float_Name then
                     Handled := False;
                     return;
                  end if;
                  declare
                     Scalar : constant Landin.Types.Scalar_Name :=
                       Kind (Operand (1));
                     Yes : constant String := Fresh;
                     Done : constant String := Fresh;
                  begin
                     VFP_Value (False, Operand (1), 0);
                     VFP_Value (False, Operand (2), 1);
                     --  An ordered relation signals on a quiet NaN, as IEEE
                     --  754 has it; equality does not.  No trap is enabled,
                     --  so only FPSCR's cumulative flag can tell.
                     Emit ((if Op in Landin.IR.Equal_To
                              | Landin.IR.Not_Equal_To
                            then "vcmp" else "vcmpe")
                       & (if Scalar = Landin.Types.F64 then ".f64 "
                          else ".f32 ")
                       & Bank (Scalar, 0) & ", " & Bank (Scalar, 1));
                     Emit ("vmrs APSR_nzcv, fpscr");
                     --  Unordered sets C and V: every relation but
                     --  inequality is false then.
                     Branch ((case Op is
                                when Landin.IR.Equal_To => "eq",
                                when Landin.IR.Not_Equal_To => "ne",
                                when Landin.IR.Less_Than => "mi",
                                when Landin.IR.Less_Or_Equal => "ls",
                                when Landin.IR.Greater_Than => "gt",
                                when others => "ge"), Yes);
                     Emit ("movs r0, #0");
                     Jump (Done);
                     Put (Yes & ":");
                     Emit ("movs r0, #1");
                     Put (Done & ":");
                     Store_Value (Value);
                  end;
               when Landin.IR.Conversion =>
                  declare
                     From : constant Landin.Types.Scalar_Name :=
                       Kind (Operand (1));
                     Narrow_Source : constant Boolean :=
                       Size_Of_Value (Operand (1)) /= Landin.Targets.Byte_8;
                     Narrow_Result : constant Boolean :=
                       Size_Of_Value (Value) /= Landin.Targets.Byte_8;
                  begin
                     if From in Landin.Types.Float_Name
                       and then Result in Landin.Types.Float_Name
                     then
                        if From = Result then
                           Handled := False;
                           return;
                        end if;
                        VFP_Value (False, Operand (1), 0);
                        if Result = Landin.Types.F64 then
                           Emit ("vcvt.f64.f32 d1, s0");
                           VFP_Value (True, Value, 1);
                        else
                           --  Landin's finite-overflow guard: an infinite
                           --  or NaN result needs an infinite or NaN
                           --  source.
                           declare
                              Done : constant String := Fresh;
                           begin
                              Emit ("vcvt.f32.f64 s2, d0");
                              Emit ("vmov r0, s2");
                              Immediate ("r4", 16#7F80_0000#);
                              Emit ("ands r0, r4");
                              Emit ("cmp r0, r4");
                              Branch ("ne", Done);
                              Emit ("vmov r2, r3, d0");
                              Immediate ("r4", 16#7FF0_0000#);
                              Emit ("ands r3, r4");
                              Emit ("cmp r3, r4");
                              Branch ("ne", Trap);
                              Put (Done & ":");
                              VFP_Value (True, Value, 2);
                           end;
                        end if;
                     elsif Result in Landin.Types.Float_Name
                       and then From in Landin.Types.Integer_Name
                         | Landin.Types.Bool
                       and then Narrow_Source
                     then
                        Load_Value (Operand (1));
                        Extend ("r0", From);
                        Emit ("vmov s0, r0");
                        Emit ("vcvt" & Suffix
                          & (if From in Landin.Types.Integer_Name
                               and then Landin.Types.Is_Signed (From)
                             then ".s32 " else ".u32 ")
                          & Bank (Result, (if Result = Landin.Types.F64
                                           then 1 else 0))
                          & ", s0");
                        VFP_Value (True, Value,
                                   (if Result = Landin.Types.F64 then 1
                                    else 0));
                     elsif From in Landin.Types.Float_Name
                       and then Result in Landin.Types.Integer_Name
                       and then Narrow_Result
                     then
                        --  D171: truncate, then require the integer to be
                        --  the type's, which is the source lying strictly
                        --  between Lowest - 1 and Highest + 1.  Both are
                        --  exact as f64, so the f32 source widens to f64
                        --  first, exactly, and a NaN fails the first test.
                        declare
                           Signed : constant Boolean :=
                             Landin.Types.Is_Signed (Result);
                           procedure Bound (Edge : Landin.Types.Folded);
                           procedure Bound (Edge : Landin.Types.Folded) is
                              Bits : constant Landin.Types.Magnitude :=
                                Landin.Types.Convert_Integer_To_Float
                                  (Edge, Landin.Types.F64);
                           begin
                              Immediate ("r2", Pattern (Bits) mod 2 ** 32);
                              Immediate ("r3", Pattern (Bits) / 2 ** 32);
                              Emit ("vmov d1, r2, r3");
                              Emit ("vcmpe.f64 d0, d1");
                              Emit ("vmrs APSR_nzcv, fpscr");
                           end Bound;
                        begin
                           if From = Landin.Types.F32 then
                              VFP_Value (False, Operand (1), 2);
                              Emit ("vcvt.f64.f32 d0, s2");
                           else
                              VFP_Value (False, Operand (1), 0);
                           end if;
                           Bound (Landin.Types.Lowest
                             (Landin.Types.Integer_Name (Result), Facts) - 1);
                           --  At or below the low edge, or unordered.
                           Branch ("le", Trap);
                           Bound (Landin.Types.Highest
                             (Landin.Types.Integer_Name (Result), Facts) + 1);
                           --  At or above the high edge.
                           Branch ("pl", Trap);
                           Emit ("vcvt" & (if Signed then ".s32" else ".u32")
                             & ".f64 s0, d0");
                           Emit ("vmov r0, s0");
                           Store_Value (Value);
                        end;
                     else
                        Handled := False;
                     end if;
                  end;
               when others =>
                  Handled := False;
            end case;
         end Float_Instruction;

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

            --  D410: an indirect access whose address slot reaches a
            --  scalar inside a byte-packed C record.
            function Unaligned_Indirect return Boolean
              is (Landin.IR."/="
                    (Landin.IR.Indirect_Address_Slot (Of_Unit, Item, Value),
                     Landin.IR.No_Slot)
                  and then Landin.IR.Is_Unaligned_Address
                    (Of_Unit, Item,
                     Landin.IR.Indirect_Address_Slot (Of_Unit, Item, Value)));

            --  r0/r1 is a little-endian word pair; r2 is already in 0..63.
            --  ARMv6-M has no RRX. Split at a word boundary and use register
            --  shifts to transfer the crossing bits. Only r2/r3 are scratch.
            procedure Shift_Pair (Left : Boolean; Signed : Boolean := False)
            is
               Small : constant String := Fresh;
               Done : constant String := Fresh;
            begin
               Emit ("cmp r2, #32");
               Emit ("bcc " & Small);
               Emit ("subs r2, #32");
               if Left then
                  Emit ("mov r1, r0");
                  Emit ("movs r0, #0");
                  Emit ("lsls r1, r2");
               else
                  Emit ("mov r0, r1");
                  if Signed then
                     Emit ("asrs r1, r1, #31");
                     Emit ("asrs r0, r2");
                  else
                     Emit ("movs r1, #0");
                     Emit ("lsrs r0, r2");
                  end if;
               end if;
               Emit ("b " & Done);
               Put (Small & ":");
               if Left then
                  Emit ("mov r3, r0");
                  Emit ("lsls r0, r2");
                  Emit ("lsls r1, r2");
                  Emit ("rsbs r2, r2, #0");
                  Emit ("adds r2, #32");
                  Emit ("lsrs r3, r2");
                  Emit ("orrs r1, r3");
               else
                  Emit ("mov r3, r1");
                  Emit ((if Signed then "asrs" else "lsrs")
                    & " r1, r2");
                  Emit ("lsrs r0, r2");
                  Emit ("rsbs r2, r2, #0");
                  Emit ("adds r2, #32");
                  Emit ("lsls r3, r2");
                  Emit ("orrs r0, r3");
               end if;
               Put (Done & ":");
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
                       (Atoms_Ranked,
                        Landin.IR.Nth_Atom (Of_Unit, Set_Id, Index)));
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
               Jump (Trap (Landin.Panics.Bad_Conversion));
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
                  Sp_Depth := Sp_Depth + 8;
                  Deepest_Below :=
                    Landin.Targets.Byte_Count'Max (Deepest_Below, Sp_Depth);
                  Load_Value (Input);
                  if Size_Of_Value (Input) /= Landin.Targets.Byte_8 then
                     Emit ("movs r1, #0");
                  end if;
                  Packed_Atom (Atoms, True);
                  Immediate ("r4", (not Bits) and 16#FFFF_FFFF#);
                  Immediate ("r5", (not Bits) / 2 ** 32);
                  Emit ("tst r0, r4");
                  Branch ("ne", Trap (Landin.Panics.Bad_Conversion));
                  Emit ("tst r1, r5");
                  Branch ("ne", Trap (Landin.Panics.Bad_Conversion));
                  Emit ("ldr r2, [sp, #4]");
                  Shift_Pair (True);
                  Emit ("push {r0, r1}");
                  Sp_Depth := Sp_Depth + 8;
                  Deepest_Below :=
                    Landin.Targets.Byte_Count'Max (Deepest_Below, Sp_Depth);
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
                  Sp_Depth := Sp_Depth - 8;
                  Emit ("orrs r0, r4");
                  Emit ("orrs r1, r5");
                  Emit ("pop {r2, r4}");
                  Sp_Depth := Sp_Depth - 8;
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
               --  D1567: a held index is read in place; a stride of one
               --  or a power of two needs no multiplication.
               Index : constant String := Operand_In (Operand (1), "r4");
               Shift : Natural := 0;
            begin
               if not Unchecked then
                  if Pattern (Length) <= 255 then
                     Emit ("cmp " & Index & ", #"
                       & Trimmed (Pattern'Image (Pattern (Length))));
                  else
                     Immediate ("r5", Pattern (Length));
                     Emit ("cmp " & Index & ", r5");
                  end if;
                  Branch ("cs", Trap);
               end if;
               while Shift < 31 and then 2 ** (Shift + 1) <= Stride
                 and then Stride mod 2 ** (Shift + 1) = 0
               loop
                  Shift := Shift + 1;
               end loop;
               Storage_Address (Storage, Field, "r2", Which, Payload, Nested);
               if Stride = 1 then
                  Emit ("adds r2, r2, " & Index);
               elsif Stride = 2 ** Shift then
                  Emit ("lsls r4, " & Index & ", #"
                    & Trimmed (Natural'Image (Shift)));
                  Emit ("adds r2, r2, r4");
               else
                  if Index /= "r4" then
                     Emit ("mov r4, " & Index);
                  end if;
                  Immediate ("r5", Pattern (Stride));
                  Emit ("muls r4, r5, r4");
                  Emit ("adds r2, r2, r4");
               end if;
               if Below'Length > 0 then
                  Add_Offset ("r2", Path_Offset
                    (Element_Shape_Of (Storage, Field, Which, Payload, Nested),
                     Below));
               end if;
            end Index_Address;
         begin
            if Hard then
               declare
                  Handled : Boolean;
               begin
                  Float_Instruction (Value, Handled);
                  if Handled then
                     return;
                  end if;
               end;
            end if;
            case Op is
               when Landin.IR.Assembly =>
                  Assembly_Block (Value);
               when Landin.IR.Choose =>
                  --  D338.  Thumb-1 has no conditional move: a choice of one
                  --  or zero is the condition's own zero or one, and any
                  --  other keeps a branch around one load.
                  declare
                     use type Landin.Types.Magnitude;

                     function Is_Number
                       (Which : Landin.IR.Value_Id;
                        Of_Value : Landin.Types.Magnitude) return Boolean
                       is (Landin.IR.Op_Of (Of_Unit, Item, Which)
                             = Landin.IR.Number
                           and then Kind (Value) in Landin.Types.Integer_Name
                           and then Size_Of_Value (Value)
                             /= Landin.Targets.Byte_8
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
                     else
                        Load_Value (Operand (2));
                        Load_Value (Operand (1), "r2");
                        Emit ("cmp r2, #0");
                        Branch ("ne", Done);
                        Load_Value (Operand (3));
                        Put (Done & ":");
                     end if;
                     Store_Value (Value);
                  end;
               when Landin.IR.Range_Check =>
                  declare
                     Signed : constant Boolean :=
                       Landin.Types.Is_Signed (Kind (Value));
                  begin
                     Load_Value (Operand (1));
                     Extend ("r0", Kind (Value));
                     if Size_Of_Value (Value) /= Landin.Targets.Byte_8 then
                        declare
                           Minimum : constant Landin.Types.Folded :=
                             Landin.Types.Lowest (Kind (Value), Facts);
                           Maximum : constant Landin.Types.Folded :=
                             Landin.Types.Highest (Kind (Value), Facts);
                           Lower : constant Landin.Types.Folded :=
                             Landin.IR.Range_Lower (Of_Unit, Item, Value);
                           Upper : constant Landin.Types.Folded :=
                             Landin.IR.Range_Upper (Of_Unit, Item, Value);
                        begin
                           --  The scalar's representation already proves
                           --  any bound at or beyond its own limits.
                           if Upper < Minimum or else Lower > Maximum then
                              Jump (Trap);
                           else
                              if Lower > Minimum then
                                 Immediate ("r2", To_Pattern (Lower, 32));
                                 Emit ("cmp r0, r2");
                                 Branch
                                   ((if Signed then "lt" else "cc"), Trap);
                              end if;
                              if Upper < Maximum then
                                 Immediate ("r2", To_Pattern (Upper, 32));
                                 Emit ("cmp r0, r2");
                                 Branch
                                   ((if Signed then "gt" else "hi"), Trap);
                              end if;
                           end if;
                        end;
                     else
                        for Upper in Boolean loop
                           --  An edge at the type's own extreme passes
                           --  every value, so it is not tested.
                           if (if Upper
                               then Landin.IR.Range_Upper
                                      (Of_Unit, Item, Value)
                                    < Landin.Types.Highest
                                        (Kind (Value), Facts)
                               else Landin.IR.Range_Lower
                                      (Of_Unit, Item, Value)
                                    > Landin.Types.Lowest
                                        (Kind (Value), Facts))
                           then
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
                                 Branch
                                   ((if Upper then
                                       (if Signed then "gt" else "hi")
                                     else (if Signed then "lt" else "cc")),
                                    Trap);
                                 Branch ("ne", Next);
                                 Emit ("cmp r0, r2");
                                 Branch ((if Upper then "hi" else "cc"), Trap);
                                 Put (Next & ":");
                              end;
                           end if;
                        end loop;
                     end if;
                     Store_Value (Value);
                  end;
               when Landin.IR.Conversion | Landin.IR.Pointer_Address
                  | Landin.IR.Code_Address =>
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
                     --  An unsigned divisor that is a constant power of
                     --  two, 2 ** Power, is a shift: the quotient the bits
                     --  above Power, the remainder those below.  Zero
                     --  otherwise.
                     Power : Natural := 0;
                  begin
                     if not Float and then not Signed and then not Wide
                       and then Op in Landin.IR.Divide | Landin.IR.Remainder
                       and then Landin.IR.Op_Of (Of_Unit, Item, Operand (2))
                         = Landin.IR.Number
                       and then not Landin.IR.Is_Negated
                         (Of_Unit, Item, Operand (2))
                     then
                        for Bit in 1 .. 31 loop
                           if Landin.Types."="
                             (Landin.IR.Number_Of (Of_Unit, Item, Operand (2)),
                              Landin.Types."**" (2, Bit))
                           then
                              Power := Bit;
                           end if;
                        end loop;
                     end if;
                     if Power > 0 then
                        Load_Value (Operand (1));
                        Extend ("r0", Kind (Value));
                        if Op = Landin.IR.Divide then
                           Emit ("lsrs r0, r0, #" & Trimmed (Power'Image));
                        else
                           Emit ("lsls r0, r0, #"
                                 & Trimmed (Natural'Image (32 - Power)));
                           Emit ("lsrs r0, r0, #"
                                 & Trimmed (Natural'Image (32 - Power)));
                        end if;
                        Store_Value (Value);
                     else
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
                        elsif Op = Landin.IR.Wrapping_Multiply
                          and then not Wide
                        then
                           --  The low word is the whole wrapping result.
                           --  Thumb MULS uses only low registers and writes
                           --  that word.
                           Emit ("muls r0, r2, r0");
                        elsif Multiply and then not Wide
                          and then Has_Long_Multiply
                        then
                           --  D605: the whole 64-bit product of the extended
                           --  operands in r1:r0, as the helper returned it.
                           Emit ((if Signed then "smull" else "umull")
                                 & " r0, r1, r0, r2");
                           if Checked then
                              if Signed then
                                 Emit ("asrs r4, r0, #31");
                              else
                                 Emit ("movs r4, #0");
                              end if;
                              Emit ("cmp r1, r4");
                              Branch ("ne", Trap);
                              Check_Fit (Kind (Value));
                           end if;
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
                              Sp_Depth := Sp_Depth + 16;
                              Deepest_Below :=
                                Landin.Targets.Byte_Count'Max
                                  (Deepest_Below, Sp_Depth);
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
                              Sp_Depth := Sp_Depth - 16;
                              Put (Done & "_multiply:");
                           end if;
                           if Has_Long_Multiply then
                              --  D605: the low 64 bits of r1:r0 times r3:r2
                              --  are the low halves' whole product, with
                              --  each cross product added to its high word.
                              Emit ("mul r3, r0, r3");
                              Emit ("mla r3, r1, r2, r3");
                              Emit ("umull r0, r1, r0, r2");
                              Emit ("add r1, r1, r3");
                           else
                              Emit ("bl __aeabi_lmul");
                           end if;
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
                           elsif Has_Divide then
                              --  The guards above have already refused a zero
                              --  divisor and settled the minimum over -1, so
                              --  what reaches here divides as the helper did:
                              --  the quotient rounds toward zero, and the
                              --  remainder is the dividend less its product.
                              Emit ((if Signed then "sdiv" else "udiv")
                                    & " r1, r0, r2");
                              if Op = Landin.IR.Remainder then
                                 Emit ("mls r0, r1, r2, r0");
                              else
                                 Emit ("mov r0, r1");
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
                     end if;
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
                     --  D1567: a word's operation reads held operands in
                     --  place and writes a held result directly.
                     In_Place : constant Boolean :=
                       Size_Of_Value (Value) = Landin.Targets.Byte_4
                       and then Kind (Value) not in Landin.Types.Float_Name;
                  begin
                     if In_Place then
                        declare
                           Into : constant String := Result_In (Value);
                           --  D1767: a constant operand is an immediate
                           --  where a form takes it: Thumb-2's eight-bit
                           --  ones, Thumb-1's three-bit addition and its
                           --  eight-bit one into the same register.  An
                           --  operation that commutes takes it on either
                           --  side.
                           Commutes : constant Boolean :=
                             Op not in Landin.IR.Subtract
                               | Landin.IR.Wrapping_Subtract;
                           Swap : constant Boolean := Commutes
                             and then Immediate_Operand (Operand (1)) /= ""
                             and then Immediate_Operand (Operand (2)) = "";
                           First_Operand : constant Landin.IR.Value_Id :=
                             (if Swap then Operand (2) else Operand (1));
                           Second_Operand : constant Landin.IR.Value_Id :=
                             (if Swap then Operand (1) else Operand (2));
                           Left : constant String :=
                             Operand_In (First_Operand, "r0");
                           Constant_Text : constant String :=
                             Immediate_Operand (Second_Operand);
                           Arithmetic : constant Boolean :=
                             Op in Landin.IR.Add | Landin.IR.Wrapping_Add
                               | Landin.IR.Subtract
                               | Landin.IR.Wrapping_Subtract;
                           Usable : constant Boolean :=
                             Constant_Text /= ""
                             and then (Thumb2
                                       or else (Arithmetic
                                         and then (Into = Left
                                           or else Immediate_Operand
                                             (Second_Operand, 7) /= "")));
                           Right : constant String :=
                             (if Usable then Constant_Text
                              else Operand_In (Second_Operand, "r2"));
                           --  Thumb-1's eight-bit form names its register
                           --  once.
                           Sources : constant String :=
                             (if Usable and then not Thumb2
                                and then Immediate_Operand
                                  (Second_Operand, 7) = ""
                              then Into & ", " & Right
                              else Into & ", " & Left & ", " & Right);
                        begin
                           case Op is
                              when Landin.IR.Add | Landin.IR.Wrapping_Add =>
                                 Emit ("adds " & Sources);
                              when Landin.IR.Subtract
                                 | Landin.IR.Wrapping_Subtract =>
                                 Emit ("subs " & Sources);
                              when others =>
                                 if Usable then
                                    Emit ((if Op = Landin.IR.Bitwise_And
                                           then "ands "
                                           elsif Op = Landin.IR.Bitwise_Or
                                           then "orrs " else "eors ")
                                      & Sources);
                                 else
                                    if Into /= Left then
                                       Emit ("mov " & Into & ", " & Left);
                                    end if;
                                    Emit ((if Op = Landin.IR.Bitwise_And
                                           then "ands "
                                           elsif Op = Landin.IR.Bitwise_Or
                                           then "orrs " else "eors ")
                                      & Into & ", " & Right);
                                 end if;
                           end case;
                           if Checked then
                              Branch ((if Signed then "vs"
                                elsif Op = Landin.IR.Add then "cs" else "cc"),
                                Trap);
                           end if;
                           Store_Value (Value, Into);
                        end;
                        return;
                     end if;
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
                     Fuses : constant Boolean :=
                       Next_Value /= Landin.IR.No_Value
                       and then Landin.IR.Op_Of (Of_Unit, Item, Next_Value)
                         = Landin.IR.Branch
                       and then Landin.IR.Nth_Operand
                         (Of_Unit, Item, Next_Value, 1) = Value
                       and then Readers.Data (Positive (Value)) = 1;
                  begin
                     if not Wide and then Scalar not in Landin.Types.Float_Name
                     then
                        --  D1567: held operands are compared in place.
                        --  D1568: at the Thumb-2 levels an IT block makes
                        --  the truth value without a branch.
                        declare
                           Left : constant String :=
                             Operand_In (Operand (1), "r0", Scalar);
                           Constant_Text : constant String :=
                             Immediate_Operand (Operand (2));
                           Right : constant String :=
                             (if Constant_Text /= "" then Constant_Text
                              else Operand_In (Operand (2), "r2", Scalar));
                           Into : constant String := Result_In (Value);
                        begin
                           if Fuses and then Right = "#0"
                             and then Condition in "eq" | "ne"
                           then
                              Fused := Next_Value;
                              Zero_Transfer (Left, Condition,
                                Landin.IR.Target_Of
                                  (Of_Unit, Item, Next_Value),
                                Landin.IR.Alternative_Of
                                  (Of_Unit, Item, Next_Value));
                              return;
                           end if;
                           Emit ("cmp " & Left & ", " & Right);
                           if Fuses then
                              Fused := Next_Value;
                              Transfer (Condition,
                                Landin.IR.Target_Of
                                  (Of_Unit, Item, Next_Value),
                                Landin.IR.Alternative_Of
                                  (Of_Unit, Item, Next_Value));
                              return;
                           end if;
                           if Thumb2 then
                              --  The block's three instructions stay
                              --  together: a pool that would fall inside
                              --  it comes first.
                              if Pool_Distance + 8 >= 512 then
                                 Flush_Literals;
                              end if;
                              Emit ("ite " & Condition);
                              Emit ("mov" & Condition & " " & Into & ", #1");
                              Emit ("mov" & Inverse_Of (Condition) & " "
                                & Into & ", #0");
                           else
                              Branch (Condition, Yes);
                              Emit ("movs " & Into & ", #0");
                              Jump (Done);
                              Put (Yes & ":");
                              Emit ("movs " & Into & ", #1");
                              Put (Done & ":");
                           end if;
                           Store_Value (Value, Into, Extended => True);
                        end;
                        return;
                     end if;
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
                     if Fuses then
                        --  D1566: the branch after a comparison that only
                        --  it reads tests the comparison's flags.
                        Fused := Next_Value;
                        if not Wide then
                           Transfer (Condition,
                             Landin.IR.Target_Of (Of_Unit, Item, Next_Value),
                             Landin.IR.Alternative_Of
                               (Of_Unit, Item, Next_Value));
                        else
                           Branch (Low_Condition, Yes);
                           Put (No & ":");
                           Jump (Label (Item, Landin.IR.Alternative_Of
                             (Of_Unit, Item, Next_Value)));
                           Put (Yes & ":");
                           Jump_To_Block (Landin.IR.Target_Of
                             (Of_Unit, Item, Next_Value));
                        end if;
                        return;
                     end if;
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
               when Landin.IR.Rotate_Left =>
                  --  Simplification forms one only for x86-64 and arm64.
                  raise Compiler_Defect with
                    "a rotate on a target that selects none";
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
                     --  D1767: a constant count below the width shifts by
                     --  an immediate, with nothing to test.
                     if not Wide and then Deferred (Operand (2))
                       and then Constant_Of (Operand (2)) < Pattern (Bits)
                     then
                        declare
                           Count : constant Pattern :=
                             Constant_Of (Operand (2));
                           Left : constant String :=
                             Operand_In (Operand (1), "r0", Kind (Value));
                           Into : constant String := Result_In (Value);
                        begin
                           if Count = 0 then
                              if Into /= Left then
                                 Emit ("mov " & Into & ", " & Left);
                              end if;
                           else
                              Emit ((if Op = Landin.IR.Shift_Left then "lsls"
                                     elsif Signed then "asrs" else "lsrs")
                                & " " & Into & ", " & Left & ", #"
                                & Trimmed (Pattern'Image (Count)));
                           end if;
                           Store_Value (Value, Into);
                        end;
                        return;
                     end if;
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
                  if Deferred (Value) then
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
                     Immediate (Result_In (Value), Number and 16#FFFF_FFFF#);
                     if Size_Of_Value (Value) = Landin.Targets.Byte_8 then
                        Immediate ("r1", Number / 2 ** 32);
                     end if;
                     Store_Value (Value, Result_In (Value), Extended =>
                       Number < 2 ** (8 * Landin.Targets.Bytes
                                            (Size_Of_Value (Value))));
                  end;
               when Landin.IR.Truth =>
                  Immediate (Result_In (Value), (if Landin.IR.Truth_Of
                    (Of_Unit, Item, Value) then 1 else 0));
                  Store_Value (Value, Result_In (Value), Extended => True);
               when Landin.IR.Atom =>
                  Immediate (Result_In (Value), Pattern (Atom_Code
                    (Atoms_Ranked, Landin.IR.Atom_Of (Of_Unit, Item, Value))));
                  Store_Value (Value, Result_In (Value));
               when Landin.IR.Measurement_Kind =>
                  declare
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Measurement_Extent
                       (Of_Unit, Item, Value, Facts, Bytes, Alignment);
                     Immediate ("r0", (if Op /= Landin.IR.Measure_Align
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
                  --  D1567: a value read in place is its slot's register
                  --  and moves nothing; a held slot is already extended.
                  declare
                     Held : constant Natural := Slot_Register
                       (Landin.IR.Slot_Of (Of_Unit, Item, Value));
                  begin
                     if Held = 0
                       or else Landin.IR.Validates_Atoms
                         (Of_Unit, Item, Value)
                     then
                        --  D1769: into the value's own register.
                        Load_Slot (Landin.IR.Slot_Of (Of_Unit, Item, Value),
                                   Result_In (Value));
                        Store_Value (Value, Result_In (Value),
                                     Extended => True);
                     elsif Held = Value_Register (Value) then
                        null;
                     elsif Value_Register (Value) /= 0 then
                        Hold (Value_Register (Value), Name (Held),
                              Landin.Targets.Byte_4);
                     else
                        Store_Value (Value, Name (Held), Extended => True);
                     end if;
                  end;
               when Landin.IR.Store =>
                  --  A value stored into the slot it shares a register
                  --  with moves nothing.
                  declare
                     Held : constant Natural := Slot_Register
                       (Landin.IR.Slot_Of (Of_Unit, Item, Value));
                     Source : constant Natural := Value_Register (Operand (1));
                  begin
                     if Held = 0 and then Source not in 0 | 6 then
                        --  D1769: from the value's own register.
                        Store_Slot (Landin.IR.Slot_Of (Of_Unit, Item, Value),
                                    Name (Source));
                     elsif Held = 0 or else Source = 0 then
                        Load_Value (Operand (1));
                        Store_Slot (Landin.IR.Slot_Of (Of_Unit, Item, Value));
                     elsif Held /= Source then
                        Hold (Held, Name (Source), Landin.Targets.Byte_4);
                     end if;
                  end;
               when Landin.IR.Load_Indirect =>
                  if Unaligned_Indirect then
                     Load_Value (Operand (1), "r2");
                     Byte_Memory (False, Size_Of_Value (Value), "r0", "r2");
                     Store_Value (Value);
                  else
                     declare
                        Base : constant String :=
                          Operand_In (Operand (1), "r2");
                        Into : constant String := Result_In (Value);
                     begin
                        Memory (False, Size_Of_Value (Value), Into, Base);
                        Store_Value (Value, Into, Extended => True);
                     end;
                  end if;
               when Landin.IR.Store_Indirect =>
                  if not Unaligned_Indirect then
                     declare
                        Base : constant String :=
                          Operand_In (Operand (1), "r2");
                        From : constant String :=
                          Operand_In (Operand (2), "r0");
                     begin
                        Memory
                          (True, Size_Of_Value (Operand (2)), From, Base);
                     end;
                     return;
                  end if;
                  Load_Value (Operand (1), "r2");
                  Load_Value (Operand (2));
                  if Unaligned_Indirect then
                     Byte_Memory
                       (True, Size_Of_Value (Operand (2)), "r0", "r2");
                  else
                     Memory (True, Size_Of_Value (Operand (2)), "r0", "r2");
                  end if;
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
                     --  D1769: a frame slot's aligned part is read or
                     --  written where it is, in the value's own register.
                     if Place.Kind = Landin.IR.Frame_Slot
                       and then Shape.Packing.Bits = 0
                       and then not Unaligned_Part
                         (Place,
                          Landin.IR.Element_Total
                            (Landin.IR.Field_Of (Of_Unit, Item, Value)),
                          Landin.IR.Path_Of (Of_Unit, Item, Value))
                     then
                        declare
                           Home : constant Landin.Targets.Byte_Count :=
                             Part_Home
                               (Place, Landin.IR.Element_Total
                                  (Landin.IR.Field_Of (Of_Unit, Item, Value)),
                                Landin.IR.Path_Of (Of_Unit, Item, Value));
                        begin
                           if Op = Landin.IR.Load_Field then
                              declare
                                 Into : constant String :=
                                   (if Size_Of_Value (Value)
                                      = Landin.Targets.Byte_8
                                    then "r0" else Result_In (Value));
                              begin
                                 Scalar_Memory (False, Size_Of_Value (Value),
                                                Home, Into);
                                 Store_Value (Value, Into, Extended =>
                                   Size_Of_Value (Value)
                                     /= Landin.Targets.Byte_8);
                              end;
                           elsif Value_Register (Operand (1)) not in 0 | 6
                           then
                              Scalar_Memory
                                (True, Size_Of_Value (Operand (1)), Home,
                                 Name (Value_Register (Operand (1))));
                           else
                              Load_Value (Operand (1));
                              Scalar_Memory
                                (True, Size_Of_Value (Operand (1)), Home,
                                 "r0");
                           end if;
                        end;
                        return;
                     end if;
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
                     if Unaligned_Part
                       (Place,
                        Landin.IR.Element_Total
                       (Landin.IR.Field_Of (Of_Unit, Item, Value)),
                        Landin.IR.Path_Of (Of_Unit, Item, Value))
                     then
                        if Op = Landin.IR.Load_Field then
                           Byte_Memory
                             (False, Size_Of_Value (Value), "r0", "r2");
                           Store_Value (Value);
                        else
                           Load_Value (Operand (1));
                           Byte_Memory
                             (True, Size_Of_Value (Operand (1)), "r0", "r2");
                        end if;
                     elsif Op = Landin.IR.Load_Field then
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
                          (False, Size_Of_Value (Value), "r0", "r2");
                        Store_Value (Value);
                     else
                        Load_Value (Operand (2));
                        Byte_Memory
                          (True, Size_Of_Value (Operand (2)), "r0", "r2");
                     end if;
                  elsif Op = Landin.IR.Load_Element then
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
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
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
                       (Destination,
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
                     if Op = Landin.IR.Copy_Array
                       and then Bytes > 0 and then Bytes mod 4 = 0
                       and then Landin.IR.Variant_Case_Of
                         (Of_Unit, Item, Value) = 0
                       and then Landin.IR.Variant_Payload_Field_Of
                         (Of_Unit, Item, Value) = 0
                       and then Source.Kind /= Landin.IR.Runtime_Address
                       and then Destination.Kind /= Landin.IR.Runtime_Address
                     then
                        declare
                           To_Field : constant Natural :=
                             Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                           To_Path : constant Landin.IR.Path_Step_Array :=
                             Landin.IR.Path_Of (Of_Unit, Item, Value);
                        begin
                           if Same_Root (Source, Destination)
                             and then Field = 0 and then Nested'Length = 0
                             and then To_Field = 0 and then To_Path'Length = 0
                           then
                              null;
                           --  Static and frame storage follow the target
                           --  layout, so a reached part of word alignment
                           --  in a word-aligned root is word-aligned.
                           elsif Root_Word_Aligned (Source)
                             and then Root_Word_Aligned (Destination)
                             and then Clear_Alignment
                               (Source, Field, Nested) >= 4
                             and then Clear_Alignment
                               (Destination, To_Field, To_Path) >= 4
                             and then Separate_Roots (Source, Destination)
                           then
                              Copy_Words (Bytes);
                           else
                              Copy_Bytes (Bytes);
                           end if;
                        end;
                     else
                        Copy_Bytes (Bytes);
                     end if;
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
                        Storage_Address (Destination, Field, "r0", Nested =>
                          Nested);
                        if Op = Landin.IR.Select_Variant then
                           Add_Offset ("r0", Offset);
                        end if;
                        Zero_Bytes
                          (Bytes, Clear_Alignment
                             (Destination, Field, Nested));
                     end if;
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
                     --  The verifier requires First_Part <= Length, so
                     --  this fixed fill always has at least one element.
                     Put (Loop_Label & ":");
                     Memory (True, Held, "r0", "r2");
                     Emit ("adds r2, r2, #"
                       & Trimmed (Positive'Image (Landin.Targets.Bytes
                         (Held))));
                     Emit ("subs r4, r4, #1");
                     Branch ("ne", Loop_Label);
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
                     Load_Value (Operand (1));
                     --  D1769: a stride of one or a power of two needs no
                     --  multiplication.
                     declare
                        Shift : Natural := 0;
                     begin
                        while Shift < 31 and then 2 ** Shift < Bytes loop
                           Shift := Shift + 1;
                        end loop;
                        if Bytes = 1 then
                           null;
                        elsif 2 ** Shift = Bytes then
                           Emit ("lsls r2, r2, #"
                             & Trimmed (Natural'Image (Shift)));
                        else
                           Immediate ("r4", Pattern (Bytes));
                           Emit ("muls r2, r4, r2");
                        end if;
                     end;
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
                     --  The IR names a record result's destination as an
                     --  operand whatever the convention; only an indirect
                     --  result passes it in r0.  D920: a C record of up to
                     --  four bytes, or of floats in the VFP bank, comes
                     --  back in registers and is stored there.
                     Hidden : constant Natural :=
                       (if Call.Result.Shape.Composite then 1 else 0);
                     --  D1565: a call whose register arguments are all
                     --  scalars loads each into its register last, from
                     --  its home, which reads no other register.  One that
                     --  passes a C record in them stages them at sp, the
                     --  register homes rounded to the call boundary's
                     --  eight-byte alignment, and loads them together.
                     Direct : constant Boolean :=
                       (for all Arg of Call.Arguments =>
                          not Arg.Shape.Composite or else Arg.Shape.Indirect
                          or else Arg.Core_Count = 0);
                     Register_Bytes : constant Landin.Targets.Byte_Count :=
                       (if Direct then 0
                        else Landin.Targets.Byte_Count
                          ((Call.Core_Used + 1) / 2 * 8));
                     Bytes : constant Landin.Targets.Byte_Count :=
                       Call.Stack_Bytes + Register_Bytes;

                     --  Store r0, and r1 when Pair, Above bytes above sp.
                     procedure Stage
                       (Above : Landin.Targets.Byte_Count; Pair : Boolean);
                     procedure Stage
                       (Above : Landin.Targets.Byte_Count; Pair : Boolean) is
                     begin
                        if Above + 4 <= 1020 then
                           Emit ("str r0, [sp, #"
                             & Trimmed (Above'Image) & "]");
                           if Pair then
                              Emit ("str r1, [sp, #"
                                & Trimmed (Landin.Targets.Byte_Count'Image
                                    (Above + 4)) & "]");
                           end if;
                        else
                           Emit ("mov r6, sp");
                           Add_Offset ("r6", Above);
                           Emit ("str r0, [r6]");
                           if Pair then
                              Emit ("str r1, [r6, #4]");
                           end if;
                        end if;
                     end Stage;
                  begin
                     if Prepares and then Bytes > Unchecked_Bytes then
                        Check_Limit (Bytes);
                     end if;
                     Reserve (Bytes);
                     if Call.Result.Shape.Indirect and then not Direct then
                        Load_Value (Operand (Offset + 1));
                        Stage (Call.Stack_Bytes, False);
                     end if;
                     for Index in Call.Arguments'Range loop
                        declare
                           Arg : Arm32_ABI.Location renames
                             Call.Arguments (Index);
                           Actual : constant Landin.IR.Value_Id :=
                             Operand (Index + Offset + Hidden);
                        begin
                           --  D616: a banked float goes straight from its
                           --  home into its register, which nothing below
                           --  touches before the call.
                           if Arg.Shape.Composite
                             and then not Arg.Shape.Indirect
                           then
                              Pass_C_Record (Actual, Arg, Call.Stack_Bytes);
                           elsif Arg.VFP_Count > 0 then
                              VFP_Home (False, Value_Offset (Layout, Actual),
                                        Arm32_ABI.VFP_Register (Arg, 1));
                           elsif Arg.Core_Count = 0 or else not Direct then
                              Load_Value (Actual);
                              Extend ("r0", Kind (Actual));
                              Stage
                                ((if Arg.Core_Count > 0
                                  then Call.Stack_Bytes
                                    + Landin.Targets.Byte_Count
                                        (Arg.First_Core) * 4
                                  else Arg.Stack_At),
                                 Size_Of_Value (Actual)
                                   = Landin.Targets.Byte_8);
                           end if;
                        end;
                     end loop;
                     if Indirect then
                        Load_Value (Operand (1), "r4");
                     end if;
                     if Direct then
                        if Call.Result.Shape.Indirect then
                           Load_Value (Operand (Offset + 1), "r0");
                        end if;
                        for Index in Call.Arguments'Range loop
                           declare
                              Arg : Arm32_ABI.Location renames
                                Call.Arguments (Index);
                              Actual : constant Landin.IR.Value_Id :=
                                Operand (Index + Offset + Hidden);
                              Into : constant String :=
                                "r" & Trimmed (Natural'Image (Arg.First_Core));
                           begin
                              if Arg.Core_Count > 0
                                and then Arg.VFP_Count = 0
                                and then not (Arg.Shape.Composite
                                              and then not Arg.Shape.Indirect)
                              then
                                 Load_Value (Actual, Into);
                                 Extend (Into, Kind (Actual));
                              end if;
                           end;
                        end loop;
                     elsif Call.Core_Used > 0 then
                        Emit ("mov r6, sp");
                        Add_Offset ("r6", Call.Stack_Bytes);
                        case Call.Core_Used is
                           when 1 => Emit ("ldr r0, [r6]");
                           when 2 => Emit ("ldmia r6!, {r0, r1}");
                           when 3 => Emit ("ldmia r6!, {r0, r1, r2}");
                           when 4 => Emit ("ldmia r6!, {r0, r1, r2, r3}");
                           when 0 => null;
                        end case;
                     end if;
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
                     if Call.Result.Shape.Composite
                       and then not Call.Result.Shape.Indirect
                     then
                        Load_Value (Operand (Offset + 1), "r2");
                        C_Record_Registers (True, Call.Result, "r2");
                     elsif Call.Result.VFP_Count > 0 then
                        VFP_Home (True, Value_Offset (Layout, Value),
                                  Arm32_ABI.VFP_Register (Call.Result, 1));
                     elsif Landin.IR.Result_Of (Of_Unit, Item, Value)
                       in Landin.Types.Scalar_Name
                     then
                        Store_Value (Value);
                     end if;
                     Release (Bytes);
                  end;
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
                     Order : constant Landin.Memory.Ordering :=
                       Landin.IR.Memory_Order (Of_Unit, Item, Value);
                  begin
                     if M = Stack_Prepare then
                        --  D450/D460: the operands are the stack's base
                        --  and length, the entry and its argument.  The
                        --  top is aligned down to eight and the first frame
                        --  laid below it as the switch routine's pops read
                        --  it: CONTROL with SPSEL set, so the stack runs on
                        --  PSP; r8 to r11 zero, r11 ending the frame chain;
                        --  a zero word and the stack's limit, its base and
                        --  the margin (D472); r4 the argument, r5 the
                        --  entry, r6 and r7 zero; then the start routine,
                        --  past its nop, as the return address.  A slice
                        --  too short for those 48 bytes and the margin
                        --  traps stack_exhausted (D451), inside unchecked
                        --  too; the difference is signed, since aligning a
                        --  short slice's top may take it below the base.
                        Load_Value (Operand (1), "r0");
                        Load_Value (Operand (2), "r1");
                        Emit ("adds r1, r1, r0");
                        Emit ("movs r2, #7");
                        Emit ("bics r1, r2");
                        Emit ("subs r1, r1, r0");
                        Immediate ("r2", Pattern
                          (Stack_Frame + Limit_Margin));
                        Emit ("cmp r1, r2");
                        Branch ("lt", Trap);
                        Immediate ("r2", Pattern (Limit_Margin));
                        Emit ("adds r2, r2, r0");
                        Emit ("adds r0, r0, r1");
                        Emit ("subs r0, #" & Trimmed (Stack_Frame'Image));
                        --  D620: with a float unit, d8-d15 and FPSCR zero,
                        --  FPSCR's reset default, between r11 and the
                        --  limit, which moves up by their 72 bytes.
                        Emit ("str r2, [r0, #"
                          & Trimmed (Landin.Targets.Byte_Count'Image
                              (24 + VFP_Frame)) & "]");
                        Load_Value (Operand (4), "r1");
                        Emit ("str r1, [r0, #"
                          & Trimmed (Landin.Targets.Byte_Count'Image
                              (28 + VFP_Frame)) & "]");
                        Load_Value (Operand (3), "r1");
                        Emit ("str r1, [r0, #"
                          & Trimmed (Landin.Targets.Byte_Count'Image
                              (32 + VFP_Frame)) & "]");
                        Emit ("movs r1, #0");
                        for Offset in 1 .. 10 + VFP_Words loop
                           if Offset not in
                             6 + VFP_Words .. 8 + VFP_Words
                           then
                              Emit ("str r1, [r0, #"
                                & Trimmed (Natural'Image (4 * Offset))
                                & "]");
                           end if;
                        end loop;
                        Emit ("movs r1, #2");
                        Emit ("str r1, [r0]");
                        Address ("r1", Stack_Start & " + 2");
                        Emit ("str r1, [r0, #"
                          & Trimmed (Landin.Targets.Byte_Count'Image
                              (44 + VFP_Frame)) & "]");
                        Stack_Used := True;
                        Store_Value (Value);
                     elsif M = Stack_Switch then
                        --  D450/D472: the switch is one call of the
                        --  program's switch routine, so the routine holding
                        --  it is never call-free (Call_Free reads its bl);
                        --  it checked its frame (D471).
                        Load_Value (Operand (1), "r0");
                        Load_Value (Operand (2), "r1");
                        Emit ("bl " & Stack_Switcher);
                        Stack_Used := True;
                     elsif Landin.Memory.Operands (M) = 0 then
                        case M is
                           when Compiler_Barrier => null;
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
                        --  D499, Arm's mapping for a core without
                        --  acquire and release instructions: a relaxed
                        --  access is a plain LDR or STR, an acquire or
                        --  seq_cst load is followed by DMB, a release store
                        --  preceded by one and a seq_cst store by one on
                        --  each side.  ARMv6-M's DMB has only the SY option.
                        --  D606: on Armv8-M, ARMv8's mapping instead: an
                        --  acquire or seq_cst load is LDA and a release or
                        --  seq_cst store STL, in the access's width, and
                        --  neither has a DMB beside it.
                        if Has_Acquire_Release
                          and then M = Atomic_Load
                          and then Landin.Memory.Acquires (Order)
                        then
                           Emit ("lda" & (case Size is
                                    when Landin.Targets.Byte_1 => "b",
                                    when Landin.Targets.Byte_2 => "h",
                                    when others => "")
                                 & " r0, [r2]");
                        elsif Has_Acquire_Release
                          and then M = Atomic_Store
                          and then Landin.Memory.Releases (Order)
                        then
                           Load_Value (Operand (2));
                           Emit ("stl" & (case Size is
                                    when Landin.Targets.Byte_1 => "b",
                                    when Landin.Targets.Byte_2 => "h",
                                    when others => "")
                                 & " r0, [r2]");
                        elsif M in Atomic_Load | Volatile_Load then
                           Memory (False, Size, "r0", "r2");
                           if M = Atomic_Load
                             and then Landin.Memory.Acquires (Order)
                           then
                              Emit ("dmb sy");
                           end if;
                        else
                           Load_Value (Operand (2));
                           if M = Atomic_Store
                             and then Landin.Memory.Releases (Order)
                           then
                              Emit ("dmb sy");
                           end if;
                           Memory (True, Size, "r0", "r2");
                           if M = Atomic_Store and then Order = Seq_Cst then
                              Emit ("dmb sy");
                           end if;
                        end if;
                        if Landin.Memory.Returns_Value (M) then
                           Store_Value (Value);
                        end if;
                     end if;
                  end;
               when Landin.IR.Jump =>
                  Jump_To_Block (Landin.IR.Target_Of (Of_Unit, Item, Value));
               when Landin.IR.Branch =>
                  Zero_Transfer
                    (Operand_In (Operand (1), "r0"), "ne",
                     Landin.IR.Target_Of (Of_Unit, Item, Value),
                     Landin.IR.Alternative_Of (Of_Unit, Item, Value));
               when Landin.IR.Leave =>
                  if Result in Landin.Types.Aggregate
                    | Landin.Types.Fixed_Array
                    and then not Plan.Result.Shape.Indirect
                  then
                     --  D920: a C record of up to four bytes returns in
                     --  r0, and one of floats in its VFP registers.
                     Frame_Address (Slot_Offset
                       (Layout, Landin.IR.Result_Slot (Of_Unit, Item)), "r2");
                     C_Record_Registers (False, Plan.Result, "r2");
                  elsif Plan.Result.VFP_Count > 0 then
                     VFP_Value (False, Operand (1), 0);
                  elsif Result in Landin.Types.Scalar_Name then
                     Load_Value (Operand (1));
                     --  AAPCS32 has the callee extend a narrow C result;
                     --  the loads above already zero-extend.
                     if Landin.IR.Signature_Uses_C_ABI
                       (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
                     then
                        Extend ("r0", Result);
                     end if;
                  elsif Result in Landin.Types.Aggregate |
                    Landin.Types.Fixed_Array
                  then
                     declare
                        Slot : constant Landin.IR.Slot_Id :=
                          Landin.IR.Result_Slot (Of_Unit, Item);
                        Bytes : constant Landin.Targets.Byte_Count :=
                          Whole_Clear_Extent
                            ((Kind => Landin.IR.Frame_Slot, Slot => Slot), 0,
                              Landin.IR.No_Path_Steps);
                     begin
                        Load_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1));
                        Frame_Address (Slot_Offset (Layout, Slot), "r2");
                        --  The caller formed the result address from its
                        --  own storage of this shape, disjoint from this
                        --  frame's result slot.
                        if Bytes mod 4 = 0
                          and then Clear_Alignment
                            ((Kind => Landin.IR.Frame_Slot, Slot => Slot),
                             0, Landin.IR.No_Path_Steps) >= 4
                        then
                           Copy_Words (Bytes);
                        else
                           Copy_Bytes (Bytes);
                        end if;
                     end;
                  end if;
                  Emit ("movs r2, #0");
                  Emit ("mov r12, r2");
                  Return_From_Routine;
               when Landin.IR.Halt =>
                  if Panic = null or else Landin.Panics.Handler (Panic.all)
                    = Landin.IR.No_Item
                  then
                     Emit ("udf #1");
                  else
                     Jump (Trap (Landin.Panics.Unreachable));
                  end if;

               when Landin.IR.Fail =>
                  Load_Value (Operand (1));
                  Emit ("mov r12, r0");
                  Return_From_Routine;
            end case;
         end Instruction;
      begin
         Record_At := -1;
         for Index in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
            for Operand in 1 .. Landin.IR.Operand_Count
              (Of_Unit, Item, Landin.IR.Value_Id (Index))
            loop
               declare
                  Read : constant Positive := Positive (Landin.IR.Nth_Operand
                    (Of_Unit, Item, Landin.IR.Value_Id (Index), Operand));
               begin
                  Readers.Data (Read) := Readers.Data (Read) + 1;
               end;
            end loop;
         end loop;
         Leaf_Frame := Probe or Leaf;
         Leaf_Homes := Homes;
         for Reg in Saving_Low'Range loop
            if Saving_Low (Reg) then
               Save_Count := Save_Count + 4;
            end if;
         end loop;
         for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            for Position in 1 .. Landin.IR.Length
              (Of_Unit, Item, Landin.IR.Block_Id (Block))
            loop
               declare
                  Value : constant Landin.IR.Value_Id :=
                    Landin.IR.Nth_Value
                      (Of_Unit, Item, Landin.IR.Block_Id (Block), Position);
               begin
                  if Landin.IR.Op_Of (Of_Unit, Item, Value)
                    in Landin.IR.Leave | Landin.IR.Fail
                  then
                     Exit_Count := Exit_Count + 1;
                  end if;
               end;
            end loop;
         end loop;
         if Boot_Stage then
            --  D588: the stage's first instruction is the slot's first
            --  byte, which the boot ROM enters in its SRAM copy.
            Emit (".section .boot2,""ax"",%progbits");
            Emit (".globl _landin_firmware_boot2");
            Put ("_landin_firmware_boot2:");
         elsif Reset_Stage then
            --  D653: the table's reset word names the stage's entry.
            Emit (".section .text.landin_firmware_reset_stage,""ax"","
              & "%progbits");
            Emit (".globl " & Landin.Targets.Firmware.Reset_Stage_Symbol);
            Emit (".balign 2");
            Emit (".thumb_func");
            Put (Landin.Targets.Firmware.Reset_Stage_Symbol & ":");
         else
            Select_Section (Item, ".text.", "ax");
         end if;
         if Is_Exported_Item (Item) then
            Emit (".globl " & Symbol (Item));
         end if;
         Emit (".balign 2");
         Emit (".type " & Symbol (Item) & ", %function");
         Emit (".thumb_func");
         Put (Symbol (Item) & ":");
         if Debug /= null then
            Put (Dwarf.Label_Name (Debug_Prefix, "begin", Item) & ":");
            Put (Dwarf.Source_Line
              (Debug.all, Landin.IR.Origin_Of (Of_Unit, Item)));
            Emit (".cfi_startproc simple");
            Emit (".cfi_return_column lr");
            Emit (".cfi_def_cfa sp, 0");
            if not Ordinary then
               --  EXC_RETURN is not an ordinary source caller address.
               --  Naked bodies own all machine-state transitions.
               Emit (".cfi_undefined lr");
            end if;
         end if;
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
                    = Landin.IR.Assembly
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
            if Debug /= null then
               Put (Dwarf.Label_Name (Debug_Prefix, "end", Item) & ":");
               Emit (".cfi_endproc");
            end if;
            Emit (".size " & Symbol (Item) & ", . - " & Symbol (Item));
            if Boot_Stage then
               --  D588: the stage and its literals, then zeros to the
               --  checksum's word, which the driver writes once the stage
               --  is assembled.  GNU as gives a true comparison as -1, so
               --  the mask leaves the padding nothing when the stage is
               --  longer than its limit: it still assembles, and the
               --  driver refuses the section's size, naming it.
               Emit (".size _landin_firmware_boot2, . - _landin_firmware_"
                 & "boot2");
               Emit (".space (" & Trimmed (Natural'Image
                 (Landin.Targets.Firmware.Stage_Limit))
                 & " - (. - _landin_firmware_boot2)) & ((. - _landin_firm"
                 & "ware_boot2) <= " & Trimmed (Natural'Image
                   (Landin.Targets.Firmware.Stage_Limit)) & ")");
               Emit (".word 0");
            end if;
            Landin.Build_Reports.Append (Report,
              Landin.Build_Reports.Routine_Statistics'
                (Item => Item, Naked => True, others => <>));
            return;
         end if;
         Pool_Active := True;
         if Probe then
            null;
         elsif Leaf then
            if Save_Count > 0 then
               Emit ("push {" & Low_List & "}");
            end if;
            if Debug /= null then
               Emit (".cfi_def_cfa_offset " & Trimmed (Save_Count'Image));
               declare
                  Position : Natural := 0;
               begin
                  for Reg in Saving_Low'Range loop
                     if Saving_Low (Reg) then
                        Emit (".cfi_offset r" & Trimmed (Reg'Image)
                          & ", -" & Trimmed
                            (Integer'Image (Integer (Save_Count)
                              - Position * 4)));
                        Position := Position + 1;
                     end if;
                  end loop;
               end;
            end if;
         else
            --  D471: an interrupt handler runs on the main stack, which
            --  no prepared stack's limit describes, so it keeps the
            --  interrupted context's limit below its frame record and
            --  zero in the cell until it returns.  r0 to r3 are the
            --  exception frame's to restore.
            if Keeps_Limit then
               Address ("r0", Stack_Limit);
               Emit ("ldr r1, [r0]");
               Emit ("movs r2, #0");
               Emit ("str r2, [r0]");
               Emit ("push {r1, r2}");
               if Debug /= null then
                  Emit (".cfi_def_cfa_offset 8");
               end if;
            end if;
            Emit ("push {r4, r5, r6, r7}");
            if Debug /= null then
               Emit (".cfi_def_cfa_offset " & Trimmed (Integer'Image
                 (16 + Kept)));
               for Reg in 4 .. 7 loop
                  Emit (".cfi_offset r" & Trimmed (Reg'Image) & ", -"
                    & Trimmed (Integer'Image ((8 - Reg) * 4 + Kept)));
               end loop;
            end if;
            Emit ("mov r4, r11");
            Emit ("mov r5, lr");
            Emit ("push {r4, r5}");
            if Debug /= null then
               Emit (".cfi_def_cfa_offset " & Trimmed (Integer'Image
                 (24 + Kept)));
               Emit (".cfi_offset r11, -" & Trimmed (Integer'Image
                 (24 + Kept)));
               if Ordinary then
                  Emit (".cfi_offset lr, -20");
               end if;
            end if;
            Emit ("mov r11, sp");
            if Debug /= null then
               Emit (".cfi_def_cfa_register r11");
            end if;
            --  D471: the frame is checked against the current stack's
            --  limit before it is reserved.  A call-free leaf has no
            --  frame record and is not checked: its frame is one the
            --  margin pays for, or it is not a leaf.  The selected
            --  handler stores zero in the cell instead, so that it and
            --  what it calls run on what a failed check left, without a
            --  check that would enter it again.
            if Prepares and then Ordinary and then not Probe
              and then (Panic = null
                        or else Item /= Landin.Panics.Handler (Panic.all))
            then
               Check_Limit (Homes);
            end if;
         end if;
         Sp_Known := False;
         Reserve (Homes);
         if VFP_Save > 0 and then not Probe then
            Frame_Address_Through (VFP_Save_Offset, "r6");
            Emit ("vstmia r6, " & VFP_List (Saved_Run));
            if Debug /= null then
               for Reg in Saved_Run.Low .. Saved_Run.High loop
                  Emit (".cfi_offset d" & Trimmed (Reg'Image) & ", -"
                    & Trimmed (Landin.Targets.Byte_Count'Image
                      (24 + Landin.Targets.Byte_Count (Kept)
                       + VFP_Save_Offset
                       - Landin.Targets.Byte_Count (Reg - Saved_Run.Low)
                         * 8)));
               end loop;
            end if;
         end if;
         if Leaf and then Debug /= null then
            Emit (".cfi_def_cfa_offset " & Trimmed
              (Landin.Targets.Byte_Count'Image (Save_Count + Homes)));
         end if;
         if Panic /= null and then Item = Landin.Panics.Handler (Panic.all)
         then
            if Prepares then
               Address ("r6", Stack_Limit);
               Emit ("movs r7, #0");
               Emit ("str r7, [r6]");
            end if;
            Address ("r6", Local_Prefix & "landin_panic_active");
            Emit ("ldr r7, [r6]");
            Emit ("cmp r7, #0");
            Hard_Trap_Used := True;
            Branch ("ne", Hard_Trap);
            Emit ("movs r7, #1");
            Emit ("str r7, [r6]");
         end if;
         case Plan.Core_Used is
            when 0 => null;
            when 1 => Emit ("str r0, [sp]");
            when 2 =>
               Emit ("mov r6, sp");
               Emit ("stmia r6!, {r0, r1}");
            when 3 =>
               Emit ("mov r6, sp");
               Emit ("stmia r6!, {r0, r1, r2}");
            when 4 =>
               Emit ("mov r6, sp");
               Emit ("stmia r6!, {r0, r1, r2, r3}");
         end case;
         --  D1567: the parameter stores are position zero; what the
         --  prologue writes before them holds nothing yet.
         if not Probe and then Recording /= null then
            Recording.all := [others => 0];
            Record_At := 0;
         end if;
         if Plan.Result.Shape.Indirect then
            Store_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1));
         end if;
         for Index in Plan.Arguments'Range loop
            declare
               Arg : Arm32_ABI.Location renames Plan.Arguments (Index);
               --  A record result's destination is the first parameter
               --  slot even when D920's C record returns in registers.
               Slot : constant Landin.IR.Slot_Id := Landin.IR.Nth_Parameter
                 (Of_Unit, Item, Index
                  + (if Plan.Result.Shape.Composite then 1 else 0));
               Aggregate : constant Boolean := Landin.IR.Is_Aggregate
                 (Of_Unit, Item, Slot)
                 or else Landin.IR.Is_Array (Of_Unit, Item, Slot);
               Home : constant Landin.IR.Slot_Id :=
                 Landin.IR.In_Place_Home (Of_Unit, Item, Slot);
            begin
               --  D920: a C record parameter arrives by value, in its VFP
               --  registers or in its words of the incoming registers'
               --  homes and the caller's outgoing area, and is copied into
               --  its slot.
               if Arg.Shape.Composite and then not Arg.Shape.Indirect then
                  declare
                     Size : constant Landin.Targets.Byte_Count :=
                       Arg.Shape.Size;
                     In_Core : constant Landin.Targets.Byte_Count :=
                       Landin.Targets.Byte_Count'Min
                         (Size, Landin.Targets.Byte_Count (Arg.Core_Count)
                                * 4);
                     Aligned : constant Boolean := Arg.Shape.Alignment >= 4;
                  begin
                     if Arg.VFP_Count > 0 then
                        Frame_Address (Slot_Offset (Layout, Slot), "r2");
                        C_Record_Registers (True, Arg, "r2");
                        goto Next_Argument;
                     end if;
                     Frame_Address (Slot_Offset (Layout, Slot), "r0");
                     if Arg.Core_Count > 0 then
                        Frame_Address (Homes - Landin.Targets.Byte_Count
                          (Arg.First_Core) * 4, "r2");
                        Copy_Record (In_Core, Aligned);
                     end if;
                     if Size > In_Core then
                        if Probe or Leaf then
                           Emit ("mov r2, sp");
                           Immediate ("r6", Pattern
                             (Homes + Save_Count + Arg.Stack_At));
                           Emit ("adds r2, r2, r6");
                        else
                           Emit ("mov r2, r11");
                           Add_Offset ("r2", 24 + Arg.Stack_At);
                        end if;
                        Copy_Record (Size - In_Core, Aligned);
                     end if;
                  end;
                  goto Next_Argument;
               end if;
               --  D616: a banked float parameter's register is stored to
               --  its slot, before any call could clobber it.
               if Arg.VFP_Count > 0 then
                  VFP_Home (True, Slot_Offset (Layout, Slot),
                            Arm32_ABI.VFP_Register (Arg, 1));
                  goto Next_Argument;
               end if;
               if Arg.Core_Count > 0 then
                  Frame_Address (Homes - Landin.Targets.Byte_Count
                    (Arg.First_Core) * 4);
               else
                  if Probe or Leaf then
                     Emit ("mov r6, sp");
                     --  The argument-base adjustment must not introduce a
                     --  new callee-save register after the selection probe.
                     Immediate ("r2", Pattern
                       (Homes + Save_Count + Arg.Stack_At));
                     Emit ("adds r6, r6, r2");
                  else
                     Emit ("mov r6, r11");
                     Add_Offset ("r6", 24 + Arg.Stack_At);
                  end if;
               end if;
               if Aggregate then
                  declare
                     Zero_Label : constant String := Fresh;
                     Done_Label : constant String := Fresh;
                     Bytes : constant Landin.Targets.Byte_Count :=
                       Whole_Clear_Extent
                         ((Kind => Landin.IR.Frame_Slot, Slot => Slot), 0,
                           Landin.IR.No_Path_Steps);
                     Alignment : constant Landin.Targets.Byte_Alignment :=
                       Clear_Alignment
                         ((Kind => Landin.IR.Frame_Slot, Slot => Slot), 0,
                           Landin.IR.No_Path_Steps);
                     --  The carrier addresses storage aligned for this
                     --  shape (docs/ir.md), and the slot is fresh, so a
                     --  word-aligned whole-word extent moves by words.
                     Words : constant Boolean :=
                       Alignment >= 4 and then Bytes mod 4 = 0;
                  begin
                     Emit ("ldr r2, [r6]");
                     Frame_Address (Slot_Offset (Layout, Slot), "r0");
                     Emit ("cmp r2, #0");
                     Branch ("eq", Zero_Label);
                     if Words then
                        Copy_Words (Bytes);
                     else
                        Copy_Bytes (Bytes);
                     end if;
                     Jump (Done_Label);
                     Put (Zero_Label & ":");
                     if Words then
                        Zero_Words (Bytes);
                     else
                        Zero_Bytes (Bytes, Alignment);
                     end if;
                     Put (Done_Label & ":");
                  end;
               else
                  Memory (False, Size_Of
                    (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts),
                    "r0", "r6");
                  Store_Slot (Slot);
               end if;

               --  Landin.IR.In_Place's parameter is an address slot,
               --  stored above like a scalar, through which the body reads
               --  its caller's storage.  D97's zero carrier still clears
               --  the parameter's own home, which the parameter then
               --  addresses.
               if Home /= Landin.IR.No_Slot then
                  declare
                     Done_Label : constant String := Fresh;
                     Bytes : constant Landin.Targets.Byte_Count :=
                       Whole_Clear_Extent
                         ((Kind => Landin.IR.Frame_Slot, Slot => Home), 0,
                           Landin.IR.No_Path_Steps);
                     Alignment : constant Landin.Targets.Byte_Alignment :=
                       Clear_Alignment
                         ((Kind => Landin.IR.Frame_Slot, Slot => Home), 0,
                           Landin.IR.No_Path_Steps);
                  begin
                     Emit ("cmp r0, #0");
                     Branch ("ne", Done_Label);
                     Frame_Address (Slot_Offset (Layout, Home), "r0");
                     if Alignment >= 4 and then Bytes mod 4 = 0 then
                        Zero_Words (Bytes);
                     else
                        Zero_Bytes (Bytes, Alignment);
                     end if;
                     Frame_Address (Slot_Offset (Layout, Home), "r0");
                     Store_Slot (Slot);
                     Put (Done_Label & ":");
                  end;
               end if;
               <<Next_Argument>>
            end;
         end loop;
         if Probe then
            Put (Body_Marker);
         end if;
         Deepest_Below := 0;
         Helpers_Called := 0;
         for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            Put (Label (Item, Landin.IR.Block_Id (Block)) & ":");
            --  Every block starts with sp at the bottom of the homes.
            Sp_Depth := 0;
            Sp_Known := not Leaf_Frame;
            Current_Block := Block;
            for Position in 1 .. Landin.IR.Length
              (Of_Unit, Item, Landin.IR.Block_Id (Block))
            loop
               Current_Value := Landin.IR.Nth_Value
                 (Of_Unit, Item, Landin.IR.Block_Id (Block), Position);
               Tick := Tick + 1;
               if Record_At >= 0 then
                  Record_At := Tick;
               end if;
               Next_Value :=
                 (if Position < Landin.IR.Length
                    (Of_Unit, Item, Landin.IR.Block_Id (Block))
                  then Landin.IR.Nth_Value
                    (Of_Unit, Item, Landin.IR.Block_Id (Block), Position + 1)
                  else Landin.IR.No_Value);
               if Debug /= null then
                  Put (Dwarf.Source_Line (Debug.all,
                    Landin.IR.Origin_Of (Of_Unit, Item, Current_Value)));
               end if;
               if Current_Value /= Fused then
                  Instruction (Current_Value);
               end if;
            end loop;
         end loop;
         --  What follows the last value, the shared exit and the traps,
         --  runs where no location is live.
         Record_At := -1;
         Sp_Known := False;
         for Edge of Edges loop
            Put (Unbounded.To_String (Edge.Label) & ":");
            if Debug /= null then
               Put (Dwarf.Source_Line (Debug.all, Edge.Origin));
            end if;
            Immediate ("r0", Pattern (Landin.Panics.Code
              (Panic.all, Edge.Reason)));
            Immediate ("r1", Pattern (Edge.Site));
            Emit ("bl " & Symbol (Landin.Panics.Handler (Panic.all)));
            Emit ("udf #1");
         end loop;
         --  D471: a frame or an area that does not fit traps at the
         --  routine's own site, from the frame record: nothing below it
         --  was reserved for what did not fit, or what was is given back.
         --  Without a handler the trap is the terminal instruction.
         if Limit_Trapped then
            Put (Limit_Trap & ":");
            if Debug /= null then
               Put (Dwarf.Source_Line
                 (Debug.all, Landin.IR.Origin_Of (Of_Unit, Item)));
            end if;
            Emit ("mov sp, r11");
            if Panic /= null and then Landin.Panics.Handler (Panic.all)
              /= Landin.IR.No_Item
            then
               Immediate ("r0", Pattern (Landin.Panics.Code
                 (Panic.all, Landin.Panics.Stack_Exhausted)));
               Immediate ("r1", Pattern (Landin.Panics.Site
                 (Panic.all, Landin.IR.Origin_Of (Of_Unit, Item),
                  Landin.Panics.Stack_Exhausted)));
               Emit ("bl " & Symbol (Landin.Panics.Handler (Panic.all)));
            end if;
            Emit ("udf #1");
         end if;
         if Hard_Trap_Used then
            Put (Hard_Trap & ":");
            Emit ("udf #1");
         end if;
         if Exit_Count > 1 then
            Put (Return_Label & ":");
            Epilogue;
         end if;
         Flush_Literals;
         Pool_Active := False;
         if Debug /= null then
            Put (Dwarf.Label_Name (Debug_Prefix, "end", Item) & ":");
            Emit (".cfi_endproc");
         end if;
         Emit (".size " & Symbol (Item) & ", . - " & Symbol (Item));
         if Probe then
            declare
               Text : constant String := Unbounded.Slice
                 (Out_Text, Routine_Start, Unbounded.Length (Out_Text));
               --  D471: a call-free routine whose frame the margin does not
               --  pay for keeps a frame record, which its check needs.
               Eligible : Boolean := Ordinary and then Call_Free (Text)
                 and then not (Prepares and then Homes + 16 > Unchecked_Bytes);
            begin
               for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
                  for Position in 1 .. Landin.IR.Length
                    (Of_Unit, Item, Landin.IR.Block_Id (Block))
                  loop
                     if Landin.IR.Op_Of
                       (Of_Unit, Item, Landin.IR.Nth_Value
                          (Of_Unit, Item, Landin.IR.Block_Id (Block),
                           Position))
                       = Landin.IR.Assembly
                     then
                        Eligible := False;
                     end if;
                  end loop;
               end loop;
               Mark_Low (Text);
               Unbounded.Delete
                 (Out_Text, Routine_Start, Unbounded.Length (Out_Text));
               Serial := Before_Serial;
               Emission_Line := Before_Line;
               Pool_Generation := Before_Generation;
               Pool_Distance := Before_Distance;
               Literals.Clear;
               --  No byte positions survive the tentative emission. The
               --  final pass builds literal pools and branch sites anew.
               Emit_Routine (Item, Layout, Probe => False, Leaf => Eligible,
                             Saves => Used_Low, Registers => Registers);
               return;
            end;
         end if;
         Shorten_Local_Branches;
         declare
            --  The frame is what the prologue reserves below what it
            --  pushes: the laid-out frame, d8-d15's save and the incoming
            --  register homes.  The saves are r4-r7, or a leaf's low
            --  registers, and d8-d15; the frame record, r11 and lr, and
            --  an interrupt handler's kept limit are the stack's alone.
            Counts : Landin.Build_Reports.Routine_Statistics :=
              (Item => Item,
               Frame_Bytes => Homes,
               Spill_Bytes => Spill_Bytes (Layout),
               Save_Bytes => (if Leaf then Save_Count else 16) + VFP_Save,
               Spill_Count => Spill_Count (Layout),
               Stack_Bytes => Homes + (if Leaf then Save_Count else 24)
                 + Landin.Targets.Byte_Count (Kept) + Deepest_Below,
               Calls_Panic => not Edges.Is_Empty
                 or else (Limit_Trapped and then Panic /= null
                          and then Landin.Panics.Handler (Panic.all)
                            /= Landin.IR.No_Item),
               Helper_Calls => Helpers_Called,
               others => <>);
            Counted : Landin.Backend.Site_Counts.Counter
              (Landin.Backend.Site_Counts.Thumb);
         begin
            Landin.Backend.Site_Counts.Add_Lines
              (Counted, Unbounded.Slice
                 (Out_Text, Routine_Start, Unbounded.Length (Out_Text)));
            if Registers /= null then
               Counts.Register_Count := Held_Count (Registers.Held);
            end if;
            Landin.Backend.Site_Counts.Fill (Counted, Counts);
            if Deferring then
               Pending := Counts;
            else
               Landin.Build_Reports.Append (Report, Counts);
            end if;
         end;
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

                     when Landin.IR.Rotate_Left =>
                        --  Simplification forms one only in routines.
                        raise Compiler_Defect with
                          "a rotate in a static datum";
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

      --  Every module datum is typed and sized in the symbol table, as the
      --  other ELF backends' are, so that the image's symbol table says
      --  each one's extent, with an initial image or without: the
      --  Cortex-M lane identifies fibre backing in static RAM by it
      --  (D470).  The type precedes the label and the size, measured from
      --  the label, follows the datum's last byte.
      procedure Begin_Object (Item : Landin.IR.Item_Id);

      procedure Begin_Object (Item : Landin.IR.Item_Id) is
      begin
         Emit (".type " & Symbol (Item) & ", %object");
      end Begin_Object;

      procedure End_Object (Item : Landin.IR.Item_Id);

      procedure End_Object (Item : Landin.IR.Item_Id) is
      begin
         Emit (".size " & Symbol (Item) & ", . - " & Symbol (Item));
      end End_Object;

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

         if Is_Exported_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;
         Put
           (Character'Val (9) & ".balign "
            & Trimmed (Landin.Targets.Byte_Alignment'Image (Alignment)));
         Begin_Object (Item);
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
         Alignment : Landin.Targets.Byte_Alignment) is
      begin
         Select_Section
           (Item, (if Landin.IR.Is_Immutable (Of_Unit, Item)
                   then ".rodata." else ".bss."),
            (if Landin.IR.Is_Immutable (Of_Unit, Item) then "a" else "aw"));
         if Is_Exported_Item (Item) then
            Emit (".globl " & Symbol (Item));
         end if;
         Emit (".balign " & Trimmed (Alignment'Image));
         --  Typed and sized as the other ELF backends' data, so that the
         --  image's symbol table says each buffer's extent: the Cortex-M
         --  lane identifies fibre backing in static RAM by it (D470).
         Emit (".type " & Symbol (Item) & ", %object");
         Put (Symbol (Item) & ":");
         --  An empty datum keeps its aligned, zero-sized symbol, without
         --  a zero-count space directive: GNU as for Arm warns that it
         --  ignores one, and firmware assembly makes warnings fatal.
         if Size > 0 then
            Emit (".zero " & Trimmed (Size'Image));
         end if;
         Emit (".size " & Symbol (Item) & ", " & Trimmed (Size'Image));
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
            Begin_Object (Item);
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
         Begin_Object (Item);
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
         Begin_Object (Item);
         Put (Symbol (Item) & ":");
         Emit (Directive (Held) & " " & Written);
         End_Object (Item);
      end Emit_Datum;

   begin
      if Facts /= Landin.Targets.Cortex_M
        or else not Landin.Targets.Levels.Belongs_To (Level, Facts)
      then
         raise Compiler_Defect with "Cortex emission needs an M profile";
      end if;
      Collect_Retained_Sections;
      Allocate_Symbols;
      if Panic /= null and then Landin.Panics.Handler (Panic.all)
        /= Landin.IR.No_Item
      then
         Emit (".section .bss.landin_panic,""aw"",%nobits");
         Emit (".balign 4");
         --  Cortex-M's local prefix is kept in the symbol table (D469),
         --  so the compiler's own cells are typed and sized as data are.
         Emit (".type " & Local_Prefix & "landin_panic_active, %object");
         Put (Local_Prefix & "landin_panic_active:");
         Emit (".space 4");
         Emit (".size " & Local_Prefix & "landin_panic_active, 4");
      end if;
      Emit (".syntax unified");
      --  ARMv6-M keeps naming its core.  A higher level names its
      --  architecture, so the assembler admits exactly what it has (D255).
      if Level = Landin.Targets.Levels.Default_Level (Facts) then
         Emit (".cpu cortex-m0");
      else
         Emit (".arch " & Landin.Targets.Levels.Name (Level));
      end if;
      if Hard then
         --  D617: the unit, and the VFP variant's attributes, which the
         --  assembler does not infer from -mfloat-abi=hard.  The linker
         --  compares objects' Tag_ABI_VFP_args only when both declare an
         --  FP number model, so the IEEE one is declared too: a soft-float
         --  C object then does not link in, and a helper object that
         --  declares none leaves the image's VFP attribute alone.
         Emit (".fpu " & Landin.Targets.Firmware.Spelling
           (Landin.IR.Firmware_Profile (Of_Unit).Float));
         Emit (".eabi_attribute Tag_ABI_FP_number_model, 3");
         Emit (".eabi_attribute Tag_ABI_VFP_args, 1");
      else
         --  D780: without a unit, the same IEEE model and the base
         --  variant's arguments, as GCC's soft-float objects declare, so
         --  this object and a hard-float one refuse each other in either
         --  link order rather than linking with floats in the wrong
         --  registers.
         Emit (".eabi_attribute Tag_ABI_FP_number_model, 3");
         Emit (".eabi_attribute Tag_ABI_VFP_args, 0");
      end if;
      Emit (".thumb");
      Emit (".text");
      if Debug /= null then
         Put (Dwarf.Preamble (Debug.all, Debug_Prefix, Arm => True));
      end if;
      if Firmware_Entry /= Landin.IR.No_Item then
         Emit_Vectors;
         Put (Landin.Backend.Firmware.Startup
           (Symbol (Firmware_Entry),
            Landin.IR.Firmware_Profile (Of_Unit),
            Landin.Backend.Firmware.Used_Regions (Of_Unit, Names),
            (if Panic = null or else Landin.Panics.Handler (Panic.all)
               = Landin.IR.No_Item then "udf #1"
             else "ldr r0, =" & Trimmed (Positive'Image
               (Landin.Panics.Code (Panic.all, Landin.Panics.Unreachable)))
               & LF & "movs r1, #0" & LF & "bl "
               & Symbol (Landin.Panics.Handler (Panic.all))
               & LF & "udf #1"), Debug => Debug /= null));
      end if;
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then not Landin.IR.Is_External (Of_Unit, Item)
              and then not
                (Landin.IR.Placement_Of (Of_Unit, Item).Boot_Stage
                 and then not Landin.IR.Firmware_Profile (Of_Unit).Has_Stage)
            then
               --  D1567: at size and speed a routine is emitted first
               --  with every value in its home, recording what its text
               --  writes at each position; then with the slots and values
               --  Allocate_Registers places where nothing writes their
               --  registers.  The second emission's writes are checked
               --  against its plan, and a routine whose check fails keeps
               --  its first.
               declare
                  use type Landin.Optimization.Objective;
                  Count : constant Natural :=
                    Landin.IR.Value_Count (Of_Unit, Item);
                  Start : constant Natural := Unbounded.Length (Out_Text);
                  Start_Serial : constant Natural := Serial;
                  Start_Line : constant Natural := Emission_Line;
                  Start_Generation : constant Natural := Pool_Generation;
                  Start_Distance : constant Natural := Pool_Distance;

                  procedure Restore;
                  procedure Restore is
                  begin
                     Unbounded.Delete
                       (Out_Text, Start + 1, Unbounded.Length (Out_Text));
                     Serial := Start_Serial;
                     Emission_Line := Start_Line;
                     Pool_Generation := Start_Generation;
                     Pool_Distance := Start_Distance;
                     Literals.Clear;
                  end Restore;
               begin
                  if Options.Optimize /= Landin.Optimization.None
                    and then Landin.IR.Signature_Machine
                      (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
                        /= Landin.Machine.Naked_Routine
                    and then
                      (for all Value in 1 .. Count =>
                         Landin.IR.Op_Of
                           (Of_Unit, Item, Landin.IR.Value_Id (Value))
                           /= Landin.IR.Assembly)
                  then
                     Recording := new Write_Masks'(0 .. Count => 0);
                     Deferring := True;
                  end if;
                  Emit_Routine
                    (Item, Allocated_Frame
                       (Of_Unit, Item, Facts, 16#FFFF_FFC0#));
                  if Recording /= null then
                     declare
                        Placed : aliased constant Register_Plan :=
                          Allocate_Registers
                            (Of_Unit, Item, Facts, Options, Recording.all,
                             High => Thumb2);
                     begin
                        if Placed.Held /= 0 then
                           Restore;
                           Emit_Routine
                             (Item, Allocated_Frame
                                (Of_Unit, Item, Facts, 16#FFFF_FFC0#,
                                 Placed'Access),
                              Registers => Placed'Access);
                           if not Holds (Placed, Recording.all) then
                              Restore;
                              Free_Masks (Recording);
                              Emit_Routine
                                (Item, Allocated_Frame
                                   (Of_Unit, Item, Facts, 16#FFFF_FFC0#));
                           end if;
                        end if;
                     end;
                     Free_Masks (Recording);
                     Deferring := False;
                     Landin.Build_Reports.Append (Report, Pending);
                  end if;
               end;
            end if;
         end;
      end loop;
      --  D450, D447 and D460.  The switch routine is out of line, one per
      --  program, so that its unwind information is exact at every
      --  instruction.  It is called with the address to save through in r0
      --  and the stack pointer to resume in r1.  It pushes r4 to r7 and
      --  lr, then a scratch word and the current stack's limit (D472),
      --  then r8 to r11 through r4 to r7 with CONTROL below them, so the
      --  saved frame records which stack pointer the leaving context ran
      --  on; stores sp; reads the resumed frame's CONTROL word, writes the
      --  resumed stack pointer into MSP or PSP as that word's SPSEL says,
      --  then CONTROL and an ISB, which makes it the current sp; and pops
      --  the same frame, the limit into the cell.
      --  Both frames have the same 48-byte layout, so one CFA rule, sp
      --  plus what remains pushed, holds at every instruction: until
      --  CONTROL is written sp is still the leaving stack's, and after it
      --  the resumed one's.  Between the pop of r8 to r11 into r4 to r7
      --  and their moves back, the rule names the low register holding
      --  each, since the popped words below sp are an interrupt's to
      --  overwrite.  Every caller-saved register is left changed, as by a
      --  call.  A switch in handler mode, or in unprivileged thread mode,
      --  cannot write CONTROL and is outside D460's contract.
      --
      --  The start routine, past its first instruction, is the return
      --  address of a prepared stack's first frame: the pops leave the
      --  argument in r4, the entry in r5 and zero in r11, so the frame
      --  chain ends at the entry's first frame, and its unwind information
      --  says the return address is undefined, which ends a debugger's walk
      --  there.  It opens with a nop the resumed frame returns past,
      --  because a debugger looks up a return address less one, which then
      --  still names this routine.  An entry is `-> noreturn`; if it
      --  returns anyway, that is D232's `unreachable` at site zero, as a
      --  firmware entry's return is.
      if Stack_Used then
         Put (Character'Val (9)
              & ".section .text.landin_stack,""ax"",%progbits");
         Emit (".balign 2");
         Emit (".type " & Stack_Switcher & ", %function");
         Emit (".thumb_func");
         Put (Stack_Switcher & ":");
         if Debug /= null then
            Emit (".cfi_startproc simple");
            Emit (".cfi_return_column lr");
            Emit (".cfi_def_cfa sp, 0");
         end if;
         Emit ("push {r4, r5, r6, r7, lr}");
         if Debug /= null then
            Emit (".cfi_def_cfa_offset 20");
            for Reg in 4 .. 7 loop
               Emit (".cfi_offset r" & Trimmed (Reg'Image) & ", -"
                 & Trimmed (Integer'Image ((9 - Reg) * 4)));
            end loop;
            Emit (".cfi_offset lr, -4");
         end if;
         Emit ("ldr r2, =" & Stack_Limit);
         Emit ("ldr r3, [r2]");
         Emit ("push {r2, r3}");
         if Debug /= null then
            Emit (".cfi_def_cfa_offset 28");
         end if;
         --  D620: d8-d15, then FPSCR below them with a word above it.
         if Hard then
            Emit ("vpush {d8-d15}");
            if Debug /= null then
               Emit (".cfi_def_cfa_offset 92");
               for Reg in 8 .. 15 loop
                  Emit (".cfi_offset d" & Trimmed (Reg'Image) & ", -"
                    & Trimmed (Integer'Image (92 - (Reg - 8) * 8)));
               end loop;
            end if;
            Emit ("vmrs r2, fpscr");
            Emit ("push {r2, r3}");
            if Debug /= null then
               Emit (".cfi_def_cfa_offset 100");
            end if;
         end if;
         Emit ("mov r4, r8");
         Emit ("mov r5, r9");
         Emit ("mov r6, r10");
         Emit ("mov r7, r11");
         Emit ("mrs r3, control");
         Emit ("push {r3, r4, r5, r6, r7}");
         if Debug /= null then
            Emit (".cfi_def_cfa_offset " & Trimmed (Stack_Frame'Image));
            for Reg in 8 .. 11 loop
               Emit (".cfi_offset r" & Trimmed (Reg'Image) & ", -"
                 & Trimmed (Landin.Targets.Byte_Count'Image
                   (Stack_Frame
                    - Landin.Targets.Byte_Count (4 * (Reg - 7)))));
            end loop;
         end if;
         Emit ("mov r2, sp");
         Emit ("str r2, [r0]");
         Emit ("ldr r3, [r1]");
         Emit ("movs r2, #2");
         Emit ("tst r3, r2");
         Emit ("bne 1f");
         Emit ("msr msp, r1");
         Emit ("b 2f");
         Put ("1:");
         Emit ("msr psp, r1");
         Put ("2:");
         Emit ("msr control, r3");
         Emit ("isb sy");
         Emit ("pop {r3, r4, r5, r6, r7}");
         if Debug /= null then
            Emit (".cfi_def_cfa_offset "
              & Trimmed (Landin.Targets.Byte_Count'Image
                  (28 + VFP_Frame)));
            for Reg in 8 .. 11 loop
               Emit (".cfi_register r" & Trimmed (Reg'Image) & ", r"
                 & Trimmed (Integer'Image (Reg - 4)));
            end loop;
         end if;
         for Reg in 8 .. 11 loop
            Emit ("mov r" & Trimmed (Reg'Image) & ", r"
              & Trimmed (Integer'Image (Reg - 4)));
            if Debug /= null then
               Emit (".cfi_restore r" & Trimmed (Reg'Image));
            end if;
         end loop;
         if Hard then
            Emit ("pop {r2, r3}");
            if Debug /= null then
               Emit (".cfi_def_cfa_offset 92");
            end if;
            Emit ("vmsr fpscr, r2");
            Emit ("vpop {d8-d15}");
            if Debug /= null then
               Emit (".cfi_def_cfa_offset 28");
               for Reg in 8 .. 15 loop
                  Emit (".cfi_restore d" & Trimmed (Reg'Image));
               end loop;
            end if;
         end if;
         Emit ("pop {r2, r3}");
         if Debug /= null then
            Emit (".cfi_def_cfa_offset 20");
         end if;
         Emit ("ldr r2, =" & Stack_Limit);
         Emit ("str r3, [r2]");
         Emit ("pop {r4, r5, r6, r7, pc}");
         Emit (".ltorg");
         if Debug /= null then
            Emit (".cfi_endproc");
         end if;
         Emit (".size " & Stack_Switcher & ", . - " & Stack_Switcher);

         Emit (".balign 2");
         Emit (".type " & Stack_Start & ", %function");
         if Debug /= null then
            Emit (".cfi_startproc simple");
            Emit (".cfi_return_column lr");
            Emit (".cfi_def_cfa sp, 0");
            Emit (".cfi_undefined lr");
         end if;
         Emit (".thumb_func");
         Put (Stack_Start & ":");
         Emit ("nop");
         Emit ("mov r0, r4");
         Emit ("blx r5");
         if Panic /= null and then Landin.Panics.Handler (Panic.all)
           /= Landin.IR.No_Item
         then
            Emit ("ldr r0, =" & Trimmed (Positive'Image
              (Landin.Panics.Code (Panic.all, Landin.Panics.Unreachable))));
            Emit ("movs r1, #0");
            Emit ("bl " & Symbol (Landin.Panics.Handler (Panic.all)));
         end if;
         Emit ("udf #1");
         Emit (".ltorg");
         if Debug /= null then
            Emit (".cfi_endproc");
         end if;
         Emit (".size " & Stack_Start & ", . - " & Stack_Start);
         --  D471's cell, zero until a switch resumes a prepared stack.
         Emit (".pushsection .bss.landin_stack_limit,""aw"",%nobits");
         Emit (".balign 4");
         Emit (".type " & Stack_Limit & ", %object");
         Put (Stack_Limit & ":");
         Emit (".space 4");
         Emit (".size " & Stack_Limit & ", 4");
         Emit (".popsection");
      end if;
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
                     Field_Extent
                       (Of_Unit, Landin.IR.Evidence_Represented (Of_Unit, Id),
                        Facts, Bytes, Alignment);
                     --  One section per physical table, including both
                     --  aliases of a proven-identical dispatch table.
                     Emit (".section .rodata.landin_evidence_"
                       & Trimmed (Id'Image) & ",""a"",%progbits");
                     Emit (".balign 4");
                     --  Typed and sized as data are, the alias with it.
                     Emit (".type " & Evidence_Symbol (Id) & ", %object");
                     if Alias_Next then
                        Emit (".type " & Evidence_Symbol
                          (Landin.IR.Evidence_Id (Index + 1)) & ", %object");
                     end if;
                     Put (Evidence_Symbol (Id) & ":");
                     if Alias_Next then
                        Put (Evidence_Symbol
                          (Landin.IR.Evidence_Id (Index + 1)) & ":");
                     end if;
                     Emit (".long " & Trimmed (Landin.Targets.Byte_Count'Image
                       (Bytes)));
                     Emit (".long " & Trimmed
                       (Landin.Targets.Byte_Alignment'Image (Alignment)));
                     for Entry_Index in 1 .. Landin.IR.Evidence_Entry_Count
                       (Of_Unit, Id) loop
                        --  D374: an entry nothing can project is a zero word.
                        if Is_Kept (Kept, Id, Entry_Index) then
                           Emit (".long " & Symbol
                             (Landin.IR.Evidence_Entry_Target (Of_Unit, Id,
                               Entry_Index)));
                        else
                           Emit (".long 0");
                        end if;
                     end loop;
                     Emit (".size " & Evidence_Symbol (Id) & ", . - "
                       & Evidence_Symbol (Id));
                     if Alias_Next then
                        declare
                           Alias : constant String := Evidence_Symbol
                             (Landin.IR.Evidence_Id (Index + 1));
                        begin
                           Emit (".size " & Alias & ", . - " & Alias);
                        end;
                     end if;
                  end if;
               end;
            end loop;
         end;
      end if;
      if Debug /= null then
         Unbounded.Append (Out_Text, Dwarf.Line_Sections
           (Of_Unit, Meanings, Names, Facts, Debug.all,
            Debug_Prefix, Symbol'Access));
      end if;
      Emit (".section .note.GNU-stack,"""",%progbits");
      Assembly := Out_Text;
   end Emit;

end Landin.Backend.Cortex_M;
