with Ada.Containers.Generic_Sort;
with Ada.Containers.Ordered_Maps;
with Landin.Backend.C_ABI;
with Landin.Backend.Work_Arrays;
with Landin.IR.Control_Flow;
with Landin.IR.Liveness;
with Landin.Memory;
with Landin.Targets.Layouts;
with Landin.Types;

package body Landin.Backend.X86_64.Allocation is

   use type Landin.IR.Block_Id;
   use type Landin.IR.Declaration_Id;
   use type Landin.IR.Opcode;
   use type Landin.IR.Signature_Id;
   use type Landin.IR.Slot_Id;
   use type Landin.IR.Storage_Kind;
   use type Landin.Optimization.Objective;
   use type Landin.Targets.Scalar_Size;
   use type Landin.Types.Magnitude;
   use type Landin.Types.Type_Kind;

   Value_Order : constant array (1 .. 9) of General_Register :=
     [RSI, RDI, R8, R9, RBX, R12, R13, R14, R15];

   --  The slots placed in one register for their whole interval, by the
   --  position each interval opens at.
   package Reservations is new Ada.Containers.Ordered_Maps
     (Key_Type => Natural, Element_Type => Positive);

   --  Per-routine scratch.  Instantiated here, once, rather than in each
   --  call that uses it: every instance elaborates a controlled buffer
   --  type, and registering a tagged type on every routine is not free.
   type Counts is array (Positive range <>) of Natural;
   type Blocks is array (Positive range <>) of Landin.IR.Block_Id;
   package Count_Buffers is new Work_Arrays (Natural, Counts, 0);
   package Block_Buffers is new Work_Arrays
     (Landin.IR.Block_Id, Blocks, Landin.IR.No_Block);
   package Mask_Buffers is new Work_Arrays (Boolean, Home_Mask, False);
   package Value_Buffers is new Work_Arrays (Natural, Spill_Assignments, 0);
   package Extent_Buffers is new Work_Arrays
     (Landin.Targets.Layouts.Field_Extent,
      Landin.Targets.Layouts.Field_Extent_Array, (0, 1));

   function Name (Register : General_Register; Size : Width) return String is
   begin
      case Register is
         when RBX =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%bl",
                       when Landin.Targets.Byte_2 => "%bx",
                       when Landin.Targets.Byte_4 => "%ebx",
                       when Landin.Targets.Byte_8 => "%rbx");
         when R12 =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%r12b",
                       when Landin.Targets.Byte_2 => "%r12w",
                       when Landin.Targets.Byte_4 => "%r12d",
                       when Landin.Targets.Byte_8 => "%r12");
         when R13 =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%r13b",
                       when Landin.Targets.Byte_2 => "%r13w",
                       when Landin.Targets.Byte_4 => "%r13d",
                       when Landin.Targets.Byte_8 => "%r13");
         when R14 =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%r14b",
                       when Landin.Targets.Byte_2 => "%r14w",
                       when Landin.Targets.Byte_4 => "%r14d",
                       when Landin.Targets.Byte_8 => "%r14");
         when R15 =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%r15b",
                       when Landin.Targets.Byte_2 => "%r15w",
                       when Landin.Targets.Byte_4 => "%r15d",
                       when Landin.Targets.Byte_8 => "%r15");
         when RSI =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%sil",
                       when Landin.Targets.Byte_2 => "%si",
                       when Landin.Targets.Byte_4 => "%esi",
                       when Landin.Targets.Byte_8 => "%rsi");
         when RDI =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%dil",
                       when Landin.Targets.Byte_2 => "%di",
                       when Landin.Targets.Byte_4 => "%edi",
                       when Landin.Targets.Byte_8 => "%rdi");
         when R8 =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%r8b",
                       when Landin.Targets.Byte_2 => "%r8w",
                       when Landin.Targets.Byte_4 => "%r8d",
                       when Landin.Targets.Byte_8 => "%r8");
         when R9 =>
            return (case Size is
                       when Landin.Targets.Byte_1 => "%r9b",
                       when Landin.Targets.Byte_2 => "%r9w",
                       when Landin.Targets.Byte_4 => "%r9d",
                       when Landin.Targets.Byte_8 => "%r9");
      end case;
   end Name;

   function Name (Register : SSE_Register) return String is
     ("%xmm" & Natural'Image (SSE_Register'Pos (Register) + 8)
      (2 .. Natural'Image (SSE_Register'Pos (Register) + 8)'Last));

   function SSE_Count (Of_Plan : Plan) return Natural is
      Count : Natural := 0;
   begin
      for Used of Of_Plan.Used_SSE loop
         if Used then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end SSE_Count;

   function Save_Count (Of_Plan : Plan) return Natural is
      Count : Natural := 0;
   begin
      for Used of Of_Plan.Used loop
         if Used then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Save_Count;

   function Save_Index
     (Of_Plan : Plan; Register : Saved_Register) return Positive
   is
      Count : Natural := 0;
   begin
      for Which in Saved_Register loop
         if Of_Plan.Used (Which) then
            Count := Count + 1;
         end if;
         if Which = Register and then Of_Plan.Used (Which) then
            return Positive (Count);
         end if;
      end loop;
      raise Landin.Compiler_Defect with "an unsaved register has no save home";
   end Save_Index;

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

   function Touches
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Value : Landin.IR.Value_Id;
      Register : Caller_Saved) return Boolean is
   begin
      case Landin.IR.Op_Of (Of_Unit, Item, Value) is
         when Landin.IR.Call | Landin.IR.Indirect_Call
            | Landin.IR.Copy_Array | Landin.IR.Copy_Variant
            | Landin.IR.Clear_Array | Landin.IR.Fill_Array
            | Landin.IR.Select_Variant | Landin.IR.Assembly =>
            return True;
         when Landin.IR.Memory_Access =>
            --  D450: a switch calls out of line and resumes another
            --  stack, which leaves every caller-saved register changed.
            return Is_Switch (Of_Unit, Item, Value);
         when Landin.IR.Leave =>
            --  A scalar result moves to the accumulator and a `-> none`
            --  routine moves nothing; the teardown names none of them.
            return Landin.IR.Result_Of (Of_Unit, Item)
                     not in Landin.Types.Scalar_Name
                       | Landin.Types.No_Value
              or else
                (Landin.IR.Signature_Of (Of_Unit, Item)
                   /= Landin.IR.No_Signature
                 and then Landin.IR.Signature_Uses_C_ABI
                   (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item)));
         when Landin.IR.Conversion =>
            --  Decoding a float into an integer.
            return Register in R8 | R9
              and then Landin.IR.Result_Of (Of_Unit, Item, Value)
                in Landin.Types.Integer_Name
              and then Landin.IR.Result_Of
                (Of_Unit, Item,
                 Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1))
                in Landin.Types.Float_Name;
         when Landin.IR.Load_Field | Landin.IR.Load_Element =>
            --  An atom is carried as a u32, which a packed part
            --  translates through a table.
            return Register in R8 | R9
              and then Landin.IR.Result_Of (Of_Unit, Item, Value)
                in Landin.Types.U32 | Landin.Types.Atom_Value;
         when Landin.IR.Store_Field | Landin.IR.Store_Element =>
            return Register in R8 | R9
              and then Landin.IR.Result_Of
                (Of_Unit, Item, Landin.IR.Nth_Operand
                   (Of_Unit, Item, Value,
                    (if Landin.IR.Op_Of (Of_Unit, Item, Value)
                          = Landin.IR.Store_Field then 1 else 2)))
                in Landin.Types.U32 | Landin.Types.Atom_Value;
         when others =>
            return False;
      end case;
   end Touches;

   --  [1630]: the callee-saved registers some block of the routine
   --  declares.  None of them holds a value anywhere in the routine, and
   --  each is saved and restored by it, which is what declaring one means.
   function Declared
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id)
      return Register_Set;

   function Declared
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id)
      return Register_Set
   is
      Result : Register_Set := [others => False];
   begin
      for Index in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
         declare
            Value : constant Landin.IR.Value_Id := Landin.IR.Value_Id (Index);
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Assembly then
               for Which in 1 .. Landin.IR.Assembly_Operand_Count
                 (Of_Unit, Item, Value)
               loop
                  declare
                     Named : constant String := Landin.IR.Register_Of
                       (Landin.IR.Nth_Assembly_Operand
                          (Of_Unit, Item, Value, Which));
                  begin
                     for Register in Saved_Register loop
                        if Named = Name (Register, Landin.Targets.Byte_8)
                          (2 .. Name (Register, Landin.Targets.Byte_8)'Last)
                        then
                           Result (Register) := True;
                        end if;
                     end loop;
                  end;
               end loop;
            end if;
         end;
      end loop;
      return Result;
   end Declared;

   function Immediate
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Value : Landin.IR.Value_Id;
      Facts : Landin.Targets.Target_Facts) return String
   is
      Kind : constant Landin.Types.Type_Kind :=
        Landin.IR.Result_Of (Of_Unit, Item, Value);
   begin
      if Landin.IR.Op_Of (Of_Unit, Item, Value) /= Landin.IR.Number
        or else Kind not in Landin.Types.Integer_Name
      then
         return "";
      end if;
      declare
         Bits : constant Natural := Natural
           (Landin.Types.Width (Landin.Types.Integer_Name (Kind), Facts));
         Highest : constant Landin.Types.Magnitude :=
           (if Bits = 64 then Landin.Types.Magnitude'Last
            else 2 ** Bits - 1);
         Digits_Of : constant Landin.Types.Magnitude :=
           Landin.IR.Number_Of (Of_Unit, Item, Value);
         --  The checker has refused a literal its type cannot hold, so
         --  this is selection's own pattern for it and needs no mask.
         Pattern : constant Landin.Types.Magnitude :=
           (if not Landin.IR.Is_Negated (Of_Unit, Item, Value)
              or else Digits_Of = 0
            then Digits_Of
            else Highest - Digits_Of + 1);
         Negative : constant Boolean := Pattern >= 2 ** (Bits - 1);
         --  The signed reading's magnitude.  Only a 64-bit instruction
         --  widens its immediate, so only there can it fail to fit.
         Size : constant Landin.Types.Magnitude :=
           (if Negative then Highest - Pattern + 1 else Pattern);
         Image : constant String := Landin.Types.Magnitude'Image (Size);
      begin
         if Bits = 64 and then Size > (if Negative then 2 ** 31
                                        else 2 ** 31 - 1)
         then
            return "";
         end if;
         return "$" & (if Negative then "-" else "")
           & Image (Image'First + 1 .. Image'Last);
      end;
   end Immediate;

   --  Whether selection writes operand Position of User as an immediate
   --  whenever that operand has one; see the specification.  A signed
   --  `imul` has a 16-, 32- and 64-bit immediate form, and a wrapping
   --  multiply's low half is the same at either signedness; an unsigned
   --  checked multiply needs `mul`'s high half, which has none.
   function Takes_Immediate
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      User : Landin.IR.Value_Id;
      Position : Positive;
      Facts : Landin.Targets.Target_Facts) return Boolean;

   function Takes_Immediate
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      User : Landin.IR.Value_Id;
      Position : Positive;
      Facts : Landin.Targets.Target_Facts) return Boolean
   is
      Kind : constant Landin.Types.Type_Kind :=
        Landin.IR.Result_Of (Of_Unit, Item, User);
      Wide : constant Boolean :=
        Kind in Landin.Types.Integer_Name
        and then Size_Of (Kind, Facts) /= Landin.Targets.Byte_1;
   begin
      case Landin.IR.Op_Of (Of_Unit, Item, User) is
         when Landin.IR.Add | Landin.IR.Subtract =>
            return Position = 2 and then Kind in Landin.Types.Integer_Name;
         when Landin.IR.Wrapping_Add | Landin.IR.Wrapping_Subtract
            | Landin.IR.Bitwise_And | Landin.IR.Bitwise_Xor
            | Landin.IR.Bitwise_Or =>
            return Position = 2;
         when Landin.IR.Multiply =>
            return Position = 2 and then Wide
              and then Landin.Types.Is_Signed
                (Landin.Types.Integer_Name (Kind));
         when Landin.IR.Wrapping_Multiply =>
            return Position = 2 and then Wide;
         when Landin.IR.Shift_Left | Landin.IR.Shift_Right =>
            declare
               Amount : constant Landin.IR.Value_Id :=
                 Landin.IR.Nth_Operand (Of_Unit, Item, User, 2);
            begin
               return Position = 2
                 and then Landin.IR.Op_Of (Of_Unit, Item, Amount)
                   = Landin.IR.Number
                 and then not Landin.IR.Is_Negated (Of_Unit, Item, Amount);
            end;
         when Landin.IR.Equal_To | Landin.IR.Not_Equal_To
            | Landin.IR.Less_Than | Landin.IR.Less_Or_Equal
            | Landin.IR.Greater_Than | Landin.IR.Greater_Or_Equal =>
            return Position = 2;
         when Landin.IR.Choose =>
            return Position in 2 | 3;
         when Landin.IR.Store | Landin.IR.Store_Field
            | Landin.IR.Store_Datum =>
            return Position = 1;
         when Landin.IR.Store_Element | Landin.IR.Store_Indirect =>
            return Position = 2;
         when others =>
            return False;
      end case;
   end Takes_Immediate;

   function Flags_Choice
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Value : Landin.IR.Value_Id) return Boolean
   is
      use type Landin.IR.Value_Id;
      Next : constant Landin.IR.Value_Id := Value + 1;
      Op : constant Landin.IR.Opcode :=
        Landin.IR.Op_Of (Of_Unit, Item, Value);
   begin
      return Op in Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                 | Landin.IR.Less_Than | Landin.IR.Less_Or_Equal
                 | Landin.IR.Greater_Than | Landin.IR.Greater_Or_Equal
        and then (Op not in Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                  or else Landin.IR.Result_Of
                    (Of_Unit, Item,
                     Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1))
                    not in Landin.Types.Float_Name)
        and then Natural (Next) <= Landin.IR.Value_Count (Of_Unit, Item)
        and then Landin.IR.Block_Of (Of_Unit, Item, Next)
          = Landin.IR.Block_Of (Of_Unit, Item, Value)
        and then Landin.IR.Op_Of (Of_Unit, Item, Next) = Landin.IR.Choose
        and then Landin.IR.Nth_Operand (Of_Unit, Item, Next, 1) = Value
        and then Landin.IR.Nth_Operand (Of_Unit, Item, Next, 2) /= Value
        and then Landin.IR.Nth_Operand (Of_Unit, Item, Next, 3) /= Value;
   end Flags_Choice;

   --  One pass over every operand: a constant that some use needs in a
   --  location keeps the one it has, and every other constant with an
   --  immediate is left absent, so it takes no register and no home.
   procedure Omit_Immediates
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Values : in out Location_Vectors.Vector);

   procedure Omit_Immediates
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Values : in out Location_Vectors.Vector)
   is
      Count : constant Natural := Landin.IR.Value_Count (Of_Unit, Item);
      Kept_Data : Mask_Buffers.Buffer (Count);
      Kept : Home_Mask renames Kept_Data.Data.all;
   begin
      for Index in 1 .. Count loop
         declare
            User : constant Landin.IR.Value_Id := Landin.IR.Value_Id (Index);
         begin
            for Position in 1 .. Landin.IR.Operand_Count
              (Of_Unit, Item, User)
            loop
               if not Takes_Immediate
                 (Of_Unit, Item, User, Position, Facts)
               then
                  Kept (Positive (Landin.IR.Nth_Operand
                    (Of_Unit, Item, User, Position))) := True;
               end if;
            end loop;
         end;
      end loop;
      for Index in 1 .. Count loop
         if not Kept (Index)
           and then Immediate
             (Of_Unit, Item, Landin.IR.Value_Id (Index), Facts) /= ""
         then
            Values (Index).Kind := Absent;
         end if;
      end loop;
   end Omit_Immediates;

   function Make
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Plan
   is
      Slot_Count : constant Natural := Landin.IR.Slot_Count (Of_Unit, Item);
      Value_Count : constant Natural := Landin.IR.Value_Count (Of_Unit, Item);
      Result : Plan (Slot_Count, Value_Count);
   begin
      Result.Slot := Location_Vectors.To_Vector
        (Location'(others => <>), Ada.Containers.Count_Type (Slot_Count));
      Result.Value := Location_Vectors.To_Vector
        (Location'(others => <>), Ada.Containers.Count_Type (Value_Count));
      Result.Used := Declared (Of_Unit, Item);
      if Options.Optimize = Landin.Optimization.None then
         --  No liveness, promotion or reuse scratch belongs to reference
         --  emission.  Every scalar retains its individual instruction home.
         for Index in 1 .. Slot_Count loop
            Result.Slot (Index).Kind := Stack;
            Result.Slot (Index).Home := Index;
            if not Landin.IR.Is_Aggregate
              (Of_Unit, Item, Landin.IR.Slot_Id (Index))
              and then not Landin.IR.Is_Array
                (Of_Unit, Item, Landin.IR.Slot_Id (Index))
            then
               Result.Slot (Index).Size := Size_Of
                 (Landin.IR.Type_Of
                    (Of_Unit, Item, Landin.IR.Slot_Id (Index)), Facts);
            end if;
         end loop;
         for Index in 1 .. Value_Count loop
            declare
               Kind : constant Landin.Types.Type_Kind := Landin.IR.Result_Of
                 (Of_Unit, Item, Landin.IR.Value_Id (Index));
            begin
               if Kind in Landin.Types.Scalar_Name then
                  Result.Spill_Homes := Result.Spill_Homes + 1;
                  Result.Value (Index) :=
                    (Kind => Stack, Size => Size_Of (Kind, Facts),
                     Home => Result.Spill_Homes, others => <>);
               end if;
            end;
         end loop;
         return Result;
      end if;
      declare
         Start_Data, Last_Data, Sequence_Data :
           Count_Buffers.Buffer (Value_Count);
         Use_Data, Weight_Data : Count_Buffers.Buffer (Slot_Count);
         Block_Data : Block_Buffers.Buffer (Slot_Count);
         Across_Data, Eligible_Data, Parameter_Data, Alias_Data,
           Deferred_Data :
           Mask_Buffers.Buffer (Slot_Count);
         --  How many stores write each slot.
         Store_Data : Count_Buffers.Buffer (Slot_Count);
         Stores : Counts renames Store_Data.Data.all;
         Float_Data : Mask_Buffers.Buffer (Value_Count);
         --  Each slot's first and last load or store, by position; the slot
         --  a position's store opens for a span of its own; and how many
         --  calls the routine has made by each position.
         First_Use_Data, Last_Use_Data : Count_Buffers.Buffer (Slot_Count);
         Opening_Data, Call_Data : Count_Buffers.Buffer (Value_Count);
         First_Use : Counts renames First_Use_Data.Data.all;
         Last_Use : Counts renames Last_Use_Data.Data.all;
         Opening : Counts renames Opening_Data.Data.all;
         Calls_Through : Counts renames Call_Data.Data.all;
         Calls : Natural := 0;
         Has_Assembly : Boolean := False;
         Starts : Counts renames Start_Data.Data.all;
         Lasts : Counts renames Last_Data.Data.all;
         Sequence : Counts renames Sequence_Data.Data.all;
         Uses : Counts renames Use_Data.Data.all;
         Weights : Counts renames Weight_Data.Data.all;
         First_Block : Blocks renames Block_Data.Data.all;
         Across_Blocks : Home_Mask renames Across_Data.Data.all;
         Eligible : Home_Mask renames Eligible_Data.Data.all;
         Parameter_Slot : Home_Mask renames Parameter_Data.Data.all;
         Alias : Home_Mask renames Alias_Data.Data.all;
         --  Slots the scan gives a span rather than Place_Intervals a
         --  register for their interval.
         Deferred : Home_Mask renames Deferred_Data.Data.all;
         Float_Eligible : Home_Mask renames Float_Data.Data.all;
         Permanent : constant Register_Set := Result.Used;
         Busy_Until : array (General_Register) of Natural := [others => 0];
         --  At speed, whether a register last held a source variable and
         --  no value has taken it since: a debugger reads the variable there
         --  until something writes over it, so it is the last offered.
         Variable_Held : array (General_Register) of Boolean :=
           [others => False];
         SSE_Busy_Until : array (SSE_Register) of Natural := [others => 0];
         --  Release buckets make spill reuse linear in instruction count,
         --  without scanning all previous homes at every definition.
         Release_Data : Count_Buffers.Buffer (Value_Count + 1);
         Next_Release_Data, Free_Data : Count_Buffers.Buffer (Value_Count);
         Releases : Counts renames Release_Data.Data.all;
         Next_Release : Counts renames Next_Release_Data.Data.all;
         Free_Homes : array (Width) of Natural := [others => 0];
         Next_Free : Counts renames Free_Data.Data.all;
         Tick : Natural := 0;
         Traffic : Natural := 0;
         Allocate_GP : constant Boolean :=
           Options.Optimize /= Landin.Optimization.None;
         --  Whether a callee-saved register may be given: a routine with
         --  little traffic would spend more saving one than it saves.
         Saves : Boolean := True;
         --  Whether the entry copies an aggregate argument, which writes
         --  the first two argument registers after the scalar ones moved.
         Entry_Copies : Boolean := False;
         --  Whether the entry clears an in-place parameter's home for a
         --  zero carrier (Landin.IR.In_Place), which writes the first
         --  argument register, through which it clears, after the scalar
         --  ones moved.
         Entry_Clears : Boolean := False;
         --  The parameter slot arriving in each register, if any, which
         --  the entry reads in order: no other parameter may move into
         --  one before that.
         Arriving : array (Caller_Saved) of Natural := [others => 0];
         C_Entry : constant Boolean :=
           Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
           and then Landin.IR.Signature_Uses_C_ABI
             (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item));
         Allocate_SSE : Boolean :=
           Options.Optimize = Landin.Optimization.Speed
           and then not C_Entry;
         --  Speed ranks slots by references weighted with the loop nesting
         --  of their blocks, and lets a source variable's register hold it
         --  only over its live interval.  Size keeps the static count, and
         --  a variable it holds in a register is held there throughout.
         Weighted : constant Boolean :=
           Options.Optimize = Landin.Optimization.Speed;
         Graph : constant Landin.IR.Control_Flow.Graph :=
           Landin.IR.Control_Flow.Make (Of_Unit, Item);
         Depth : constant Landin.IR.Liveness.Count_Vectors.Vector :=
           (if Weighted then Landin.IR.Liveness.Loop_Depths (Graph)
            else Landin.IR.Liveness.Count_Vectors.Empty_Vector);
         Spans : Landin.IR.Liveness.Interval_Vectors.Vector :=
           Landin.IR.Liveness.Slot_Intervals (Of_Unit, Item, Graph);
         --  The slots placed for their whole interval before the scan
         --  below, each register's in order of where they open, and the
         --  next of them each register has still to open.
         Interval_Data : Count_Buffers.Buffer (Slot_Count);
         Interval_Slots : Counts renames Interval_Data.Data.all;
         --  How many operations before each position plus one use the
         --  argument registers, and how many use those or %r8 and %r9.
         Argument_Data, Wide_Data : Count_Buffers.Buffer (Value_Count + 1);
         Argument_Uses : Counts renames Argument_Data.Data.all;
         Wide_Uses : Counts renames Wide_Data.Data.all;
         --  For each load, the position of the next store to its slot in
         --  the same block, and of the next load of it there, if any.
         Written_Data, Loaded_Data : Count_Buffers.Buffer (Value_Count);
         Written_After : Counts renames Written_Data.Data.all;
         Loaded_After : Counts renames Loaded_Data.Data.all;
         --  For each slot, the last position at which a load read in its
         --  register so far is still read.
         Read_Data : Count_Buffers.Buffer (Slot_Count);
         Read_Until : Counts renames Read_Data.Data.all;
         --  For each value computed in a slot's register by Rewrites, that
         --  slot.
         Chain_Data : Count_Buffers.Buffer (Value_Count);
         Chained : Counts renames Chain_Data.Data.all;
         Placed : array (General_Register) of Reservations.Map;
         Placed_SSE : array (SSE_Register) of Reservations.Map;
         Upcoming : array (General_Register) of Reservations.Cursor :=
           [others => Reservations.No_Element];
         Upcoming_SSE : array (SSE_Register) of Reservations.Cursor;

         procedure Pin (Place : Landin.IR.Storage);
         procedure Pin_Value (Value : Landin.IR.Value_Id);
         procedure Count_Use
           (Of_Slot : Landin.IR.Slot_Id; Value : Landin.IR.Value_Id);
         procedure Reach
           (Place : Landin.IR.Storage; Value : Landin.IR.Value_Id);
         procedure Place_Intervals;
         procedure Open (Position : Natural);
         function Inherited (Value : Landin.IR.Value_Id) return Natural;
         function Clear
           (Register : General_Register; Position, Last : Natural)
            return Boolean;
         function Clear
           (Register : SSE_Register; Position, Last : Natural)
            return Boolean;
         function Stored_Into (Value : Positive) return Natural;
         function Slot_Read (Value : Positive) return Positive;
         function Read_In_Place (Value : Positive) return Boolean;
         function Released_By (Value : Positive) return Natural;
         function Rewrites (Value, Left : Natural) return Natural;

         --  The left operand of an operation selection computes where its
         --  result lives, when that operand's last use is this one; else 0.
         function Inherited (Value : Landin.IR.Value_Id) return Natural is
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, Value) in Landin.IR.Add
              | Landin.IR.Subtract | Landin.IR.Multiply
              | Landin.IR.Wrapping_Add | Landin.IR.Wrapping_Subtract
              | Landin.IR.Wrapping_Multiply | Landin.IR.Bitwise_And
              | Landin.IR.Bitwise_Xor | Landin.IR.Bitwise_Or
              | Landin.IR.Negation | Landin.IR.Complement
              | Landin.IR.Logical_Not | Landin.IR.Shift_Left
              | Landin.IR.Shift_Right | Landin.IR.Pointer_Address
              | Landin.IR.Conversion
            then
               declare
                  Left : constant Positive := Positive
                    (Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1));
               begin
                  if Lasts (Left) = Starts (Positive (Value)) then
                     return Left;
                  end if;
               end;
            end if;
            return 0;
         end Inherited;

         --  SysV preserves no XMM register across a call, so an XMM
         --  location must not hold anything a call lies strictly inside.
         function Crosses_Call (First, Last : Natural) return Boolean is
           (Last > First + 1
            and then Calls_Through (Last - 1) > Calls_Through (First));

         --  Nor may a slot's interval hold one over a call at any position
         --  but its last, where the slot is read or the block ends; the
         --  interval may open at a block it is live into.
         function Interval_Crosses_Call
           (Span : Landin.IR.Liveness.Interval) return Boolean is
           (Span.Last > 1
            and then Calls_Through (Span.Last - 1)
              > (if Span.First <= 1 then 0
                 else Calls_Through (Span.First - 1)));

         --  Whether selection leaves a caller-saved register alone from
         --  Position through Last, which Touches answers for each
         --  operation; position zero is the entry, which copies aggregate
         --  arguments through the first two and clears an in-place
         --  parameter's home through the first.  A routine with assembly
         --  gives a location none of them at all, so its blocks' operands
         --  move straight into their registers.
         function Untouched
           (Register : Caller_Saved; Position, Last : Natural)
            return Boolean is
           (if Has_Assembly then False
            elsif Position = 0 and then Entry_Copies
              and then Register in RSI | RDI
            then False
            elsif Position = 0 and then Entry_Clears and then Register = RDI
            then False
            elsif Register in RSI | RDI
            then Argument_Uses (Last + 1)
              = Argument_Uses (Natural'Max (Position, 1))
            else Wide_Uses (Last + 1)
              = Wide_Uses (Natural'Max (Position, 1)));

         --  Whether a location from Position through Last may take
         --  Register: nothing holds it now, and the next slot interval
         --  placed in it opens after Last, or at Last by storing what is
         --  read there for the last time.
         function Reserved_After
           (Next : Reservations.Cursor; Last : Natural) return Boolean is
           (not Reservations.Has_Element (Next)
            or else Last < Reservations.Key (Next)
            or else
              (Last = Reservations.Key (Next)
               and then Landin.IR.Op_Of
                 (Of_Unit, Item, Landin.IR.Value_Id (Sequence (Last)))
                 = Landin.IR.Store
               and then Positive (Landin.IR.Slot_Of
                 (Of_Unit, Item, Landin.IR.Value_Id (Sequence (Last))))
                 = Reservations.Element (Next)));

         function Clear
           (Register : General_Register; Position, Last : Natural)
            return Boolean is
           ((Register in Caller_Saved
             or else (Saves and then not Permanent (Register)))
            and then Busy_Until (Register) <= Position
            and then Reserved_After (Upcoming (Register), Last)
            and then (Register not in Caller_Saved
                      or else Untouched (Register, Position, Last)));

         function Clear
           (Register : SSE_Register; Position, Last : Natural)
            return Boolean is
           (SSE_Busy_Until (Register) <= Position
            and then Reserved_After (Upcoming_SSE (Register), Last));

         --  The slot a value's last use stores it into, when that store
         --  opens the slot's placed interval; else 0.  The value may take
         --  the slot's register, and the store then moves nothing.
         function Stored_Into (Value : Positive) return Natural is
            User : constant Landin.IR.Value_Id :=
              Landin.IR.Value_Id (Sequence (Lasts (Value)));
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, User) = Landin.IR.Store then
               declare
                  Slot : constant Positive :=
                    Positive (Landin.IR.Slot_Of (Of_Unit, Item, User));
               begin
                  if Interval_Slots (Slot) /= 0
                    and then Spans (Slot).First = Lasts (Value)
                  then
                     return Slot;
                  end if;
               end;
            end if;
            return 0;
         end Stored_Into;

         function Slot_Read (Value : Positive) return Positive is
           (Positive (Landin.IR.Slot_Of
              (Of_Unit, Item, Landin.IR.Value_Id (Value))));

         --  At speed, whether a debugger describes Slot in its register
         --  until something writes over it: a source variable.
         function Described (Slot : Positive) return Boolean is
           (Weighted
            and then Landin.IR.Declares
              (Of_Unit, Item, Landin.IR.Slot_Id (Slot))
              /= Landin.IR.No_Declaration);

         --  Whether Value is a load holding such a variable's register,
         --  which no other value may then compute in: the variable would
         --  vanish from the debugger at its last use.
         function Holds_Variable (Value : Positive) return Boolean is
           (Landin.IR.Op_Of (Of_Unit, Item, Landin.IR.Value_Id (Value))
              = Landin.IR.Load
            and then Described (Slot_Read (Value))
            and then Result.Slot (Slot_Read (Value)).Kind = GP
            and then Result.Value (Value).Register
              = Result.Slot (Slot_Read (Value)).Register);

         --  A load whose value dies before the slot is next stored, and
         --  while the slot still holds its register, is that register:
         --  nothing writes it in between, so the load moves nothing.
         function Read_In_Place (Value : Positive) return Boolean is
         begin
            if Has_Assembly or else Result.Value (Value).Address_Required
              or else Landin.IR.Op_Of
                (Of_Unit, Item, Landin.IR.Value_Id (Value)) /= Landin.IR.Load
            then
               return False;
            end if;
            declare
               Slot : constant Positive := Slot_Read (Value);
               Holds_Through : constant Natural :=
                 (if Interval_Slots (Slot) /= 0 then Spans (Slot).Last
                  else Last_Use (Slot));
            begin
               --  An XMM register only for a value every use of which
               --  reads one.
               return (Result.Slot (Slot).Kind = GP
                       or else (Result.Slot (Slot).Kind = SSE
                                and then Float_Eligible (Value)))
                 and then Lasts (Value) <= Written_After (Value)
                 and then Lasts (Value) <= Holds_Through;
            end;
         end Read_In_Place;

         --  The slot whose register a value may be computed in when Left,
         --  the operand it inherits, is a load read in that register, and
         --  a chain of values each inheriting the one before ends in a
         --  store back into that slot: nothing loads the slot between, no
         --  other operand is there, and any store between stores a value
         --  of the chain, so the slot's old value is not needed once Left
         --  dies here and no store moves anything.  `inc`, `dec` and
         --  `total = total + x + 3` are the case.  An address slot is read
         --  by every access through it, so it is left out.  Marks the
         --  chain in Chained; else 0.
         function Rewrites (Value, Left : Natural) return Natural is
         begin
            if Left = 0 or else Has_Assembly
              or else Landin.IR.Op_Of
                (Of_Unit, Item, Landin.IR.Value_Id (Left)) /= Landin.IR.Load
              or else Result.Value (Left).Kind /= GP
            then
               return 0;
            end if;
            declare
               Slot : constant Positive := Slot_Read (Left);
               Register : constant Register_Id :=
                 Result.Value (Left).Register;
               Current : Positive := Value;
               Next : Natural := Written_After (Left);
            begin
               if Result.Slot (Slot).Kind /= GP
                 or else Result.Slot (Slot).Register /= Register
                 or else Landin.IR.Is_Address
                   (Of_Unit, Item, Landin.IR.Slot_Id (Slot))
                 or else Read_Until (Slot) > Starts (Value)
               then
                  return 0;
               end if;
               for Position in 2 .. Landin.IR.Operand_Count
                 (Of_Unit, Item, Landin.IR.Value_Id (Value))
               loop
                  declare
                     Other : Location renames Result.Value
                       (Positive (Landin.IR.Nth_Operand
                          (Of_Unit, Item, Landin.IR.Value_Id (Value),
                           Position)));
                  begin
                     if Other.Kind = GP and then Other.Register = Register
                     then
                        return 0;
                     end if;
                  end;
               end loop;
               --  Each value of the chain dies in the next, which inherits
               --  it, until the last is stored back into the slot.
               Chained (Current) := Slot;
               loop
                  declare
                     User : constant Landin.IR.Value_Id :=
                       Landin.IR.Value_Id (Sequence (Lasts (Current)));
                  begin
                     exit when Landin.IR.Op_Of (Of_Unit, Item, User)
                         = Landin.IR.Store
                       and then Positive
                         (Landin.IR.Slot_Of (Of_Unit, Item, User)) = Slot;
                     if Inherited (User) /= Current
                       or else Result.Value (Positive (User)).Kind /= Stack
                       or else Result.Value (Positive (User)).Address_Required
                       or else Landin.IR.Result_Of (Of_Unit, Item, User)
                         in Landin.Types.Float_Name
                     then
                        Next := 0;
                        exit;
                     end if;
                     Current := Positive (User);
                     Chained (Current) := Slot;
                  end;
               end loop;
               --  Every store to the slot between stores a value of the
               --  chain, and nothing loads it.
               while Next /= 0 and then Next < Lasts (Current) loop
                  Next :=
                    (if Chained (Positive (Landin.IR.Nth_Operand
                          (Of_Unit, Item,
                           Landin.IR.Value_Id (Sequence (Next)), 1)))
                        = Slot
                     then Written_After (Sequence (Next)) else 0);
               end loop;
               if Next = Lasts (Current)
                 and then Loaded_After (Left) > Lasts (Current)
               then
                  return Slot;
               end if;
               --  No chain after all.
               Current := Value;
               while Chained (Current) = Slot loop
                  Chained (Current) := 0;
                  exit when Inherited
                    (Landin.IR.Value_Id (Sequence (Lasts (Current))))
                    /= Current;
                  Current := Sequence (Lasts (Current));
               end loop;
               return 0;
            end;
         end Rewrites;

         --  The slot a load reads for the last time in the register it
         --  holds there; else 0.
         function Released_By (Value : Positive) return Natural is
         begin
            if Landin.IR.Op_Of (Of_Unit, Item, Landin.IR.Value_Id (Value))
              /= Landin.IR.Load
            then
               return 0;
            end if;
            declare
               Slot : constant Positive := Slot_Read (Value);
            begin
               if Result.Slot (Slot).Kind = GP
                 and then (if Interval_Slots (Slot) /= 0
                           then Spans (Slot).Last
                           else Last_Use (Slot)) = Starts (Value)
               then
                  return Slot;
               end if;
            end;
            return 0;
         end Released_By;

         procedure Pin (Place : Landin.IR.Storage) is
         begin
            case Place.Kind is
               when Landin.IR.Frame_Slot =>
                  Eligible (Positive (Place.Slot)) := False;
               when Landin.IR.Runtime_Address =>
                  Eligible (Positive (Place.Address)) := False;
               when Landin.IR.Module_Datum => null;
            end case;
         end Pin;

         --  One load or store of a slot, or read of the address it holds.
         procedure Count_Use
           (Of_Slot : Landin.IR.Slot_Id; Value : Landin.IR.Value_Id)
         is
            Slot : constant Positive := Positive (Of_Slot);
            At_Position : constant Positive := Starts (Positive (Value));
            Block : constant Landin.IR.Block_Id :=
              Landin.IR.Block_Of (Of_Unit, Item, Value);
            --  Each level counts eight of the one outside it, up to four,
            --  and a sum saturates at its bound.
            Step : constant Natural :=
              (if Weighted then 8 ** Natural'Min (Depth (Positive (Block)), 4)
               else 1);
         begin
            if First_Use (Slot) = 0 or else At_Position < First_Use (Slot) then
               First_Use (Slot) := At_Position;
            end if;
            Last_Use (Slot) := Natural'Max (Last_Use (Slot), At_Position);
            Uses (Slot) := Uses (Slot) + 1;
            Weights (Slot) :=
              (if Weights (Slot) > Natural'Last - Step
               then Natural'Last else Weights (Slot) + Step);
            if First_Block (Slot) = Landin.IR.No_Block then
               First_Block (Slot) := Block;
            elsif First_Block (Slot) /= Block then
               Across_Blocks (Slot) := True;
            end if;
         end Count_Use;

         --  An operation reaching storage needs a frame slot's cell, and
         --  reads only the address an address slot holds.
         procedure Reach
           (Place : Landin.IR.Storage; Value : Landin.IR.Value_Id) is
         begin
            if Place.Kind = Landin.IR.Runtime_Address then
               Count_Use (Place.Address, Value);
            else
               Pin (Place);
            end if;
         end Reach;

         procedure Pin_Value (Value : Landin.IR.Value_Id) is
         begin
            if Result.Value (Positive (Value)).Kind /= Absent then
               Result.Value (Positive (Value)).Address_Required := True;
            end if;
         end Pin_Value;

         --  Each eligible slot read or written twice, and each parameter
         --  read once, may hold a register over its whole interval, and
         --  eight GP and six XMM registers are offered: the heaviest slot
         --  first, ties to the earlier, and each to the first register
         --  whose intervals so far it does not meet.  A caller-saved
         --  register comes first, which costs no save, and only where
         --  nothing in the interval touches it; a parameter tries the one
         --  it arrives in first, where the entry then moves nothing, and
         --  takes another only when no parameter arrives in that.  Slots
         --  with disjoint intervals share a register; the rest of every
         --  register is the scan's.  An XMM interval holds across no call.
         procedure Place_Intervals is
            Count : Natural := 0;
            Interval_Order : constant array (1 .. 8) of General_Register :=
              [RSI, RDI, R8, R9, RBX, R12, R13, R14];

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

            function Meets
              (Taken : Reservations.Map;
               Span : Landin.IR.Liveness.Interval) return Boolean;
            function Meets
              (Taken : Reservations.Map;
               Span : Landin.IR.Liveness.Interval) return Boolean
            is
               Below : constant Reservations.Cursor :=
                 Taken.Floor (Span.Last);
            begin
               return Reservations.Has_Element (Below)
                 and then Spans (Reservations.Element (Below)).Last
                   >= Span.First;
            end Meets;

            --  Whether slot Index may hold Register over Span.
            function Takes
              (Register : General_Register; Index : Positive;
               Span : Landin.IR.Liveness.Interval) return Boolean
            is
              (not Meets (Placed (Register), Span)
               and then
                 (if Register in Caller_Saved
                  then Untouched (Register, Span.First, Span.Last)
                    and then (not Parameter_Slot (Index)
                              or else Arriving (Register) in 0 | Index)
                  else Saves and then not Permanent (Register)));
         begin
            for Index in 1 .. Slot_Count loop
               if Eligible (Index) and then not Deferred (Index)
                 and then Uses (Index)
                   >= (if Parameter_Slot (Index) then 1 else 2)
                 and then not Landin.IR.Liveness.Is_Empty (Spans (Index))
                 and then
                   (if Landin.IR.Type_Of
                         (Of_Unit, Item, Landin.IR.Slot_Id (Index))
                         in Landin.Types.Float_Name
                    then Allocate_SSE
                      and then not Interval_Crosses_Call (Spans (Index))
                    else Allocate_GP)
               then
                  Count := Count + 1;
                  Interval_Slots (Count) := Index;
               end if;
            end loop;
            Sort (1, Count);
            for Position in 1 .. Count loop
               declare
                  Index : constant Positive := Interval_Slots (Position);
                  Span : constant Landin.IR.Liveness.Interval :=
                    Spans (Index);
                  Slot : Location renames Result.Slot (Index);
               begin
                  if Landin.IR.Type_Of
                    (Of_Unit, Item, Landin.IR.Slot_Id (Index))
                      in Landin.Types.Float_Name
                  then
                     for Register in XMM8 .. XMM13 loop
                        if not Meets (Placed_SSE (Register), Span) then
                           Placed_SSE (Register).Insert (Span.First, Index);
                           Slot.Kind := SSE;
                           Slot.Float_Register := Register;
                           Result.Used_SSE (Register) := True;
                           exit;
                        end if;
                     end loop;
                  else
                     for Register in Arriving'Range loop
                        if Arriving (Register) = Index
                          and then Takes (Register, Index, Span)
                        then
                           Slot.Kind := GP;
                           Slot.Register := Register;
                        end if;
                     end loop;
                     --  A register a parameter still to be placed
                     --  arrives in is the last offered to anything else.
                     for Pass in 1 .. 2 loop
                        for Register of Interval_Order loop
                           exit when Slot.Kind = GP;
                           if (Pass = 2 or else Register not in Caller_Saved
                               or else Arriving (Register) in 0 | Index
                               or else not Eligible (Arriving (Register)))
                             and then Takes (Register, Index, Span)
                           then
                              Slot.Kind := GP;
                              Slot.Register := Register;
                           end if;
                        end loop;
                     end loop;
                     if Slot.Kind = GP then
                        Placed (Slot.Register).Insert (Span.First, Index);
                        if Slot.Register in Saved_Register then
                           Result.Used (Slot.Register) := True;
                        end if;
                     end if;
                  end if;
                  if Slot.Kind /= Stack then
                     Slot.Home := 0;
                     Eligible (Index) := False;
                     if Span.First > 0 or else Span.Last < Value_Count then
                        Slot.From :=
                          (if Span.First = 0 then Landin.IR.No_Value
                           else Landin.IR.Value_Id (Sequence (Span.First)));
                        Slot.Through :=
                          Landin.IR.Value_Id (Sequence (Span.Last));
                     end if;
                  end if;
               end;
            end loop;
            --  Interval_Slots now answers which slots were placed.
            Interval_Slots := [others => 0];
            for Register in General_Register loop
               for Cursor in Placed (Register).Iterate loop
                  Interval_Slots (Reservations.Element (Cursor)) := 1;
               end loop;
               Upcoming (Register) := Placed (Register).First;
            end loop;
            for Register in SSE_Register loop
               for Cursor in Placed_SSE (Register).Iterate loop
                  Interval_Slots (Reservations.Element (Cursor)) := 1;
               end loop;
               Upcoming_SSE (Register) := Placed_SSE (Register).First;
            end loop;
         end Place_Intervals;

         --  The placed intervals opening at Position take their registers
         --  through their last position.
         procedure Open (Position : Natural) is
         begin
            for Register in General_Register loop
               if Reservations.Has_Element (Upcoming (Register))
                 and then Reservations.Key (Upcoming (Register)) = Position
               then
                  Busy_Until (Register) := Spans
                    (Reservations.Element (Upcoming (Register))).Last;
                  Variable_Held (Register) := Described
                    (Reservations.Element (Upcoming (Register)));
                  Reservations.Next (Upcoming (Register));
               end if;
            end loop;
            for Register in SSE_Register loop
               if Reservations.Has_Element (Upcoming_SSE (Register))
                 and then Reservations.Key (Upcoming_SSE (Register))
                   = Position
               then
                  SSE_Busy_Until (Register) := Spans
                    (Reservations.Element (Upcoming_SSE (Register))).Last;
                  Reservations.Next (Upcoming_SSE (Register));
               end if;
            end loop;
         end Open;
      begin
         for Index in 1 .. Slot_Count loop
            declare
               Slot : constant Landin.IR.Slot_Id := Landin.IR.Slot_Id (Index);
               Kind : constant Landin.Types.Type_Kind :=
                 (if Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                    or else Landin.IR.Is_Array (Of_Unit, Item, Slot)
                  then Landin.Types.No_Value
                  else Landin.IR.Type_Of (Of_Unit, Item, Slot));
            begin
               Result.Slot (Index).Kind := Stack;
               Result.Slot (Index).Home := Index;
               if Kind in Landin.Types.Scalar_Name then
                  Result.Slot (Index).Size := Size_Of (Kind, Facts);
                  Eligible (Index) := True;
               end if;
            end;
         end loop;
         for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
            declare
               Slot : constant Positive := Positive
                 (Landin.IR.Nth_Parameter (Of_Unit, Item, Index));
            begin
               Parameter_Slot (Slot) := True;
               --  The internal convention's first, second, fifth and
               --  sixth argument registers; an aggregate's address
               --  arrives in one as well.
               case Index is
                  when 1 => Arriving (RDI) := Slot;
                  when 2 => Arriving (RSI) := Slot;
                  when 5 => Arriving (R8) := Slot;
                  when 6 => Arriving (R9) := Slot;
                  when others => null;
               end case;
               Entry_Copies := Entry_Copies
                 or else Landin.IR.Is_Aggregate
                   (Of_Unit, Item, Landin.IR.Slot_Id (Slot))
                 or else Landin.IR.Is_Array
                   (Of_Unit, Item, Landin.IR.Slot_Id (Slot));
               Entry_Clears := Entry_Clears
                 or else Landin.IR.In_Place_Home
                   (Of_Unit, Item, Landin.IR.Slot_Id (Slot))
                   /= Landin.IR.No_Slot;
            end;
         end loop;
         --  C entry copies use addresses, including scalar entries.  Hidden
         --  destinations/results are implicit uses, never promoted; a
         --  scalar named result is a slot like any other.
         if C_Entry then
            for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
               Eligible (Positive
                 (Landin.IR.Nth_Parameter (Of_Unit, Item, Index))) := False;
            end loop;
            if Landin.IR.Result_Slot (Of_Unit, Item) /= Landin.IR.No_Slot
            then
               Eligible
                 (Positive (Landin.IR.Result_Slot (Of_Unit, Item))) := False;
            end if;
         end if;
         --  A source alias is described through its storage's location
         --  wherever the alias is in scope, so that location must hold
         --  throughout the routine.
         for Index in 1 .. Landin.IR.Source_Alias_Count (Of_Unit, Item) loop
            Pin (Landin.IR.Nth_Source_Alias (Of_Unit, Item, Index).Place);
         end loop;
         for Block_Index in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            declare
               Block : constant Landin.IR.Block_Id :=
                 Landin.IR.Block_Id (Block_Index);
            begin
               for Position in 1 .. Landin.IR.Length
                 (Of_Unit, Item, Block)
               loop
                  declare
                     Value : constant Landin.IR.Value_Id :=
                       Landin.IR.Nth_Value (Of_Unit, Item, Block, Position);
                     Index : constant Positive := Positive (Value);
                     Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Op : constant Landin.IR.Opcode :=
                       Landin.IR.Op_Of (Of_Unit, Item, Value);
                  begin
                     Tick := Tick + 1;
                     Sequence (Tick) := Index;
                     Starts (Index) := Tick;
                     Lasts (Index) := Tick;
                     if Op in Landin.IR.Call | Landin.IR.Indirect_Call
                       or else Is_Switch (Of_Unit, Item, Value)
                     then
                        Calls := Calls + 1;
                     end if;
                     Calls_Through (Tick) := Calls;
                     Argument_Uses (Tick + 1) := Argument_Uses (Tick)
                       + Boolean'Pos (Touches (Of_Unit, Item, Value, RSI));
                     Wide_Uses (Tick + 1) := Wide_Uses (Tick)
                       + Boolean'Pos (Touches (Of_Unit, Item, Value, R8));
                     if Kind in Landin.Types.Scalar_Name then
                        Result.Value (Index).Kind := Stack;
                        Result.Value (Index).Size := Size_Of (Kind, Facts);
                        Traffic := Traffic + 1;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         Omit_Immediates (Of_Unit, Item, Facts, Result.Value);
         for Index in 1 .. Value_Count loop
            declare
               Value : constant Landin.IR.Value_Id :=
                 Landin.IR.Value_Id (Index);
               Op : constant Landin.IR.Opcode :=
                 Landin.IR.Op_Of (Of_Unit, Item, Value);
            begin
               Float_Eligible (Index) :=
                 Landin.IR.Result_Of (Of_Unit, Item, Value)
                   in Landin.Types.Float_Name
                 and then Op in Landin.IR.Number | Landin.IR.Load
                   | Landin.IR.Add | Landin.IR.Subtract
                   | Landin.IR.Multiply | Landin.IR.Divide
                   | Landin.IR.Conversion | Landin.IR.Call
                   | Landin.IR.Indirect_Call;
            end;
         end loop;
         for Index in 1 .. Value_Count loop
            declare
               Value : constant Landin.IR.Value_Id :=
                 Landin.IR.Value_Id (Index);
               Op : constant Landin.IR.Opcode :=
                 Landin.IR.Op_Of (Of_Unit, Item, Value);
            begin
               if Op = Landin.IR.Assembly then
                  --  Assembly text may name any XMM register.  Keep this
                  --  bank, and slot spans, out of routines that have any.
                  Allocate_SSE := False;
                  Has_Assembly := True;
               end if;
               for Position in 1 .. Landin.IR.Operand_Count
                 (Of_Unit, Item, Value)
               loop
                  declare
                     Operand : constant Positive :=
                       Positive (Landin.IR.Nth_Operand
                         (Of_Unit, Item, Value, Position));
                  begin
                     Lasts (Operand) := Natural'Max
                       (Lasts (Operand), Starts (Index));
                     Traffic := Traffic + 1;
                     if Op not in Landin.IR.Store | Landin.IR.Leave
                       | Landin.IR.Add | Landin.IR.Subtract
                       | Landin.IR.Multiply | Landin.IR.Divide
                       | Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                       | Landin.IR.Less_Than | Landin.IR.Less_Or_Equal
                       | Landin.IR.Greater_Than
                       | Landin.IR.Greater_Or_Equal
                     then
                        Float_Eligible (Operand) := False;
                     end if;
                  end;
               end loop;
               --  The emitter rereads the receiver through Evidence_Function.
               --  This transitive use is not an ordinary operand of Self.
               if Op = Landin.IR.Evidence_Self then
                  declare
                     Projection : constant Landin.IR.Value_Id :=
                       Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1);
                     Receiver : constant Positive := Positive
                       (Landin.IR.Nth_Operand (Of_Unit, Item, Projection, 1));
                  begin
                     Lasts (Receiver) := Natural'Max
                       (Lasts (Receiver), Starts (Index));
                  end;
               end if;
               case Op is
                  when Landin.IR.Load | Landin.IR.Store =>
                     Count_Use (Landin.IR.Slot_Of (Of_Unit, Item, Value),
                                Value);
                     if Op = Landin.IR.Store then
                        Stores (Positive (Landin.IR.Slot_Of
                          (Of_Unit, Item, Value))) :=
                          Stores (Positive (Landin.IR.Slot_Of
                            (Of_Unit, Item, Value))) + 1;
                     end if;
                  when Landin.IR.Load_Field | Landin.IR.Store_Field
                     | Landin.IR.Load_Element | Landin.IR.Store_Element =>
                     if Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value) then
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
                     Reach (Landin.IR.Source_Of (Of_Unit, Item, Value), Value);
                     Reach (Landin.IR.Destination_Of (Of_Unit, Item, Value),
                            Value);
                  when Landin.IR.Load_Variant_Tag
                     | Landin.IR.Load_Variant_Field =>
                     Reach (Landin.IR.Source_Of (Of_Unit, Item, Value), Value);
                  when Landin.IR.Storage_Address | Landin.IR.Place_Address
                     | Landin.IR.Clear_Array | Landin.IR.Fill_Array
                     | Landin.IR.Select_Variant
                     | Landin.IR.Store_Variant_Field =>
                     Reach (Landin.IR.Destination_Of (Of_Unit, Item, Value),
                            Value);
                  when Landin.IR.Call | Landin.IR.Indirect_Call =>
                     declare
                        Signature : constant Landin.IR.Signature_Id :=
                          (if Op = Landin.IR.Indirect_Call
                           then Landin.IR.Call_Signature (Of_Unit, Item, Value)
                           else Landin.IR.Signature_Of
                             (Of_Unit, Landin.IR.Callee_Of
                                (Of_Unit, Item, Value)));
                        Failure : constant Landin.IR.Slot_Id :=
                          Landin.IR.Failure_Slot_Of (Of_Unit, Item, Value);
                     begin
                        if Failure /= Landin.IR.No_Slot then
                           Eligible (Positive (Failure)) := False;
                        end if;
                        if Signature /= Landin.IR.No_Signature
                          and then Landin.IR.Signature_Uses_C_ABI
                            (Of_Unit, Signature)
                        then
                           declare
                              Plan : constant Landin.Backend.C_ABI.Plan :=
                                Landin.Backend.C_ABI.Call_Plan
                                  (Of_Unit, Item, Value, Facts);
                              Offset : constant Natural :=
                                (if Op = Landin.IR.Indirect_Call then 1
                                 else 0);
                              Hidden : constant Natural :=
                                (if Plan.Result.Shape.Aggregate then 1
                                 else 0);
                           begin
                              --  The result is addressed by C result
                              --  marshalling.  Keep the indirect target,
                              --  hidden destination and aggregate carriers
                              --  in their existing homes.  Scalar arguments
                              --  are read as values, including stack-bound
                              --  and floating-point arguments.
                              Pin_Value (Value);
                              for Position in 1 .. Offset + Hidden loop
                                 Pin_Value (Landin.IR.Nth_Operand
                                   (Of_Unit, Item, Value, Position));
                              end loop;
                              for Position in Plan.Arguments'Range loop
                                 if Plan.Arguments (Position).Shape.Aggregate
                                 then
                                    Pin_Value (Landin.IR.Nth_Operand
                                      (Of_Unit, Item, Value,
                                       Position + Offset + Hidden));
                                 end if;
                              end loop;
                           end;
                        end if;
                     end;
                  when Landin.IR.Leave =>
                     if C_Entry then
                        for Position in 1 .. Landin.IR.Operand_Count
                          (Of_Unit, Item, Value)
                        loop
                           Pin_Value (Landin.IR.Nth_Operand
                             (Of_Unit, Item, Value, Position));
                        end loop;
                     end if;
                  when others => null;
               end case;
            end;
         end loop;
         Saves := Traffic >= 12;
         --  A comparison whose one use is the branch right after it leaves
         --  its verdict in the flags, which selection branches on: it
         --  needs no location.
         for Index in 1 .. Value_Count loop
            if Landin.IR.Op_Of (Of_Unit, Item, Landin.IR.Value_Id (Index))
                 in Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                  | Landin.IR.Less_Than | Landin.IR.Less_Or_Equal
                  | Landin.IR.Greater_Than | Landin.IR.Greater_Or_Equal
              and then Lasts (Index) = Starts (Index) + 1
              and then Landin.IR.Op_Of
                (Of_Unit, Item, Landin.IR.Value_Id (Sequence (Lasts (Index))))
                = Landin.IR.Branch
              and then Landin.IR.Block_Of
                (Of_Unit, Item, Landin.IR.Value_Id (Sequence (Lasts (Index))))
                = Landin.IR.Block_Of
                  (Of_Unit, Item, Landin.IR.Value_Id (Index))
            then
               Result.Value (Index).Kind := Absent;
            end if;
            --  So does one whose one use is the choice right after it.
            if Lasts (Index) = Starts (Index) + 1
              and then Flags_Choice
                (Of_Unit, Item, Landin.IR.Value_Id (Index))
            then
               Result.Value (Index).Kind := Absent;
            end if;
         end loop;
         --  Size holds a source variable it gives a register there
         --  throughout, as it holds one in its frame cell, for debuggers.
         --  So does a routine with assembly, whose text names registers.
         for Index in 1 .. Slot_Count loop
            if not Landin.IR.Liveness.Is_Empty (Spans (Index))
              and then
                (Has_Assembly
                 or else
                   (not Weighted
                    and then Landin.IR.Declares
                      (Of_Unit, Item, Landin.IR.Slot_Id (Index))
                      /= Landin.IR.No_Declaration))
            then
               Spans (Index) := (0, Value_Count);
            end if;
         end loop;
         --  A slot loaded and stored in one block only, which that block
         --  stores before anything reads it, is dead on entering the block
         --  and after its last use there.  Like a value it needs a register
         --  only in between, from the scan below.  A source variable then
         --  has no home outside that span, so size, which debuggers rely
         --  on, keeps every such variable in its frame cell.  One stored
         --  once, with a value that outlives its last use, is that value
         --  over its span: the scan gives it the value's register, which
         --  nothing else writes meanwhile, and the store moves nothing.
         --  One stored once with a value that dies there is left to the
         --  scan too, which offers it that register first.
         if not Has_Assembly then
            for Index in 1 .. Slot_Count loop
               if Eligible (Index) and then not Across_Blocks (Index)
                 and then not Parameter_Slot (Index)
                 and then First_Use (Index) /= 0
                 and then Landin.IR.Op_Of
                   (Of_Unit, Item,
                    Landin.IR.Value_Id (Sequence (First_Use (Index))))
                   = Landin.IR.Store
                 and then
                   (Options.Optimize = Landin.Optimization.Speed
                    or else Landin.IR.Declares
                      (Of_Unit, Item, Landin.IR.Slot_Id (Index))
                      = Landin.IR.No_Declaration)
               then
                  Opening (First_Use (Index)) := Index;
                  declare
                     Stored : constant Positive := Positive
                       (Landin.IR.Nth_Operand
                          (Of_Unit, Item,
                           Landin.IR.Value_Id (Sequence (First_Use (Index))),
                           1));
                  begin
                     Alias (Index) := Stores (Index) = 1
                       and then Lasts (Stored) >= Last_Use (Index)
                       and then Landin.IR.Type_Of
                         (Of_Unit, Item, Landin.IR.Slot_Id (Index))
                         not in Landin.Types.Float_Name;
                     Deferred (Index) := Alias (Index)
                       or else (Stores (Index) = 1
                                and then Lasts (Stored) = First_Use (Index)
                                and then Landin.IR.Type_Of
                                  (Of_Unit, Item, Landin.IR.Slot_Id (Index))
                                  not in Landin.Types.Float_Name);
                  end;
               end if;
            end loop;
         end if;
         Place_Intervals;
         --  A slot placed for its whole interval opens no span.
         for Index in 1 .. Slot_Count loop
            if Result.Slot (Index).Kind /= Stack
              and then First_Use (Index) /= 0
              and then Opening (First_Use (Index)) = Index
            then
               Opening (First_Use (Index)) := 0;
            end if;
         end loop;
         --  A register is free again at its value's last use, so that use
         --  may define into it.  Selection reads every operand before it
         --  writes the result, except on a path that reads none after, and
         --  except where it computes the result where that lives: there it
         --  moves the left operand in first and never writes the register
         --  of an operand it has still to read.  A left operand dying here
         --  hands its register on, so that move disappears.
         --  The next store to each loaded slot in the load's own block,
         --  and the next load of it there.
         declare
            Stamp_Data, Next_Data, Load_Stamp_Data, Next_Load_Data :
              Count_Buffers.Buffer (Slot_Count);
            Stamp : Counts renames Stamp_Data.Data.all;
            Next_Store : Counts renames Next_Data.Data.all;
            Load_Stamp : Counts renames Load_Stamp_Data.Data.all;
            Next_Load : Counts renames Next_Load_Data.Data.all;
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
                           Written_After (Positive (Value)) :=
                             (if Stamp (Slot) = Block then Next_Store (Slot)
                              else Natural'Last);
                           Stamp (Slot) := Block;
                           Next_Store (Slot) := Position;
                        else
                           Written_After (Positive (Value)) :=
                             (if Stamp (Slot) = Block then Next_Store (Slot)
                              else Natural'Last);
                           Loaded_After (Positive (Value)) :=
                             (if Load_Stamp (Slot) = Block
                              then Next_Load (Slot) else Natural'Last);
                           Load_Stamp (Slot) := Block;
                           Next_Load (Slot) := Position;
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end;
         Open (0);
         for Position in 1 .. Value_Count loop
            declare
               Index : constant Positive := Positive (Sequence (Position));
               Value : constant Landin.IR.Value_Id :=
                 Landin.IR.Value_Id (Index);
               Place : Location renames Result.Value (Index);
               Released : Natural := Releases (Position);
               Left : constant Natural := Inherited (Value);
               Into : Natural := 0;
            begin
               while Released /= 0 loop
                  declare
                     Old : Location renames Result.Value (Released);
                  begin
                     Next_Free (Old.Home) := Free_Homes (Old.Size);
                     Free_Homes (Old.Size) := Old.Home;
                     Released := Next_Release (Released);
                  end;
               end loop;
               Open (Position);
               --  The store opening a slot's span defines no value, so the
               --  span takes the first register free here, which may be the
               --  stored value's own.
               if Opening (Position) /= 0 then
                  declare
                     Slot : Location renames Result.Slot (Opening (Position));
                     Last : constant Positive := Last_Use (Opening (Position));
                  begin
                     if Landin.IR.Type_Of
                       (Of_Unit, Item, Landin.IR.Slot_Id (Opening (Position)))
                       in Landin.Types.Float_Name
                     then
                        if Allocate_SSE and then not Crosses_Call
                          (Position, Last)
                        then
                           for Register in SSE_Register loop
                              if Clear (Register, Position, Last) then
                                 Slot.Kind := SSE;
                                 Slot.Float_Register := Register;
                                 SSE_Busy_Until (Register) := Last;
                                 Result.Used_SSE (Register) := True;
                                 exit;
                              end if;
                           end loop;
                        end if;
                     elsif Allocate_GP then
                        --  The stored value's own register first, so the
                        --  store moves nothing.  A debugger describes a
                        --  source variable in a caller-saved register until
                        --  something touches it, as Touches says.
                        declare
                           Stored : Location renames Result.Value
                             (Positive (Landin.IR.Nth_Operand
                                (Of_Unit, Item, Value, 1)));
                        begin
                           if Stored.Kind = GP
                             and then (Alias (Opening (Position))
                                       or else Clear
                                         (Stored.Register, Position, Last))
                           then
                              Slot.Kind := GP;
                              Slot.Register := Stored.Register;
                           end if;
                           for Register of Value_Order loop
                              exit when Slot.Kind = GP;
                              if Clear (Register, Position, Last) then
                                 Slot.Kind := GP;
                                 Slot.Register := Register;
                              end if;
                           end loop;
                           if Slot.Kind = GP then
                              Busy_Until (Slot.Register) := Natural'Max
                                (Busy_Until (Slot.Register), Last);
                              Variable_Held (Slot.Register) :=
                                Described (Opening (Position));
                              if Slot.Register in Saved_Register then
                                 Result.Used (Slot.Register) := True;
                              end if;
                           end if;
                        end;
                     end if;
                     if Slot.Kind /= Stack then
                        Slot.Home := 0;
                        Slot.From := Value;
                        Slot.Through := Landin.IR.Value_Id (Sequence (Last));
                     end if;
                  end;
               end if;
               if Place.Kind /= Absent then
                  Into := Stored_Into (Index);
                  if Read_In_Place (Index) then
                     declare
                        Held : Location renames
                          Result.Slot (Slot_Read (Index));
                     begin
                        Place.Kind := Held.Kind;
                        Place.Register := Held.Register;
                        Place.Float_Register := Held.Float_Register;
                        Read_Until (Slot_Read (Index)) := Natural'Max
                          (Read_Until (Slot_Read (Index)), Lasts (Index));
                     end;
                  end if;
                  if Place.Kind = Stack
                    and then Allocate_GP and then not Place.Address_Required
                    and then Landin.IR.Result_Of (Of_Unit, Item, Value)
                      not in Landin.Types.Float_Name
                  then
                     if Chained (Index) /= 0
                       or else Rewrites (Index, Left) /= 0
                     then
                        --  The slot's register, which the slot itself
                        --  holds on through the store.
                        Place.Kind := GP;
                        Place.Register :=
                          Result.Slot (Chained (Index)).Register;
                     elsif Left /= 0 and then Result.Value (Left).Kind = GP
                       and then (not Holds_Variable (Left)
                                 or else Landin.IR.Op_Of (Of_Unit, Item, Value)
                                   = Landin.IR.Pointer_Address)
                       and then Clear (Result.Value (Left).Register,
                                       Position, Lasts (Index))
                     then
                        Place.Kind := GP;
                        Place.Register := Result.Value (Left).Register;
                        Busy_Until (Place.Register) := Lasts (Index);
                     elsif Into /= 0 and then Result.Slot (Into).Kind = GP
                       and then Clear (Result.Slot (Into).Register,
                                       Position, Lasts (Index))
                     then
                        Place.Kind := GP;
                        Place.Register := Result.Slot (Into).Register;
                        Busy_Until (Place.Register) := Lasts (Index);
                     elsif Released_By (Index) /= 0
                       and then Clear (Result.Slot (Released_By (Index))
                                         .Register, Position, Lasts (Index))
                     then
                        --  The slot's register, which this load frees.
                        Place.Kind := GP;
                        Place.Register :=
                          Result.Slot (Released_By (Index)).Register;
                        Busy_Until (Place.Register) := Lasts (Index);
                     end if;
                     --  A caller-saved register first, which costs no
                     --  save, and one still holding a variable last.
                     for Pass in 1 .. 2 loop
                        for Register of Value_Order loop
                           exit when Place.Kind = GP;
                           if (Pass = 2 or else not Variable_Held (Register))
                             and then Clear (Register, Position, Lasts (Index))
                           then
                              Place.Kind := GP;
                              Place.Register := Register;
                              Busy_Until (Register) := Lasts (Index);
                              if Register in Saved_Register then
                                 Result.Used (Register) := True;
                              end if;
                           end if;
                        end loop;
                     end loop;
                     if Place.Kind = GP and then not Read_In_Place (Index)
                       and then Chained (Index) = 0
                     then
                        Variable_Held (Place.Register) := False;
                     end if;
                  end if;
                  if Place.Kind = Stack
                    and then Allocate_SSE and then Float_Eligible (Index)
                    and then not Place.Address_Required
                    and then not Crosses_Call (Position, Lasts (Index))
                  then
                     if Left /= 0 and then Result.Value (Left).Kind = SSE
                       and then Clear (Result.Value (Left).Float_Register,
                                       Position, Lasts (Index))
                     then
                        Place.Kind := SSE;
                        Place.Float_Register :=
                          Result.Value (Left).Float_Register;
                        SSE_Busy_Until (Place.Float_Register) :=
                          Lasts (Index);
                     elsif Into /= 0 and then Result.Slot (Into).Kind = SSE
                       and then Clear (Result.Slot (Into).Float_Register,
                                       Position, Lasts (Index))
                     then
                        Place.Kind := SSE;
                        Place.Float_Register :=
                          Result.Slot (Into).Float_Register;
                        SSE_Busy_Until (Place.Float_Register) :=
                          Lasts (Index);
                     end if;
                     for Register in SSE_Register loop
                        exit when Place.Kind = SSE;
                        if Clear (Register, Position, Lasts (Index)) then
                           Place.Kind := SSE;
                           Place.Float_Register := Register;
                           SSE_Busy_Until (Register) := Lasts (Index);
                           Result.Used_SSE (Register) := True;
                           exit;
                        end if;
                     end loop;
                  end if;
                  if Place.Kind = Stack then
                     if Options.Optimize /= Landin.Optimization.None
                       and then Free_Homes (Place.Size) /= 0
                     then
                        Place.Home := Free_Homes (Place.Size);
                        Free_Homes (Place.Size) := Next_Free (Place.Home);
                     else
                        Result.Spill_Homes := Result.Spill_Homes + 1;
                        Place.Home := Result.Spill_Homes;
                     end if;
                     Next_Release (Index) := Releases (Lasts (Index) + 1);
                     Releases (Lasts (Index) + 1) := Index;
                  end if;
               end if;
            end;
         end loop;
      end;
      return Result;
   end Make;

   function Frame_For
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Of_Plan : Plan;
      Options : Landin.Optimization.Options;
      Maximum : Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count'Last) return Frame
   is
   begin
      if Options.Optimize = Landin.Optimization.None
        and then Save_Count (Of_Plan) = 0
      then
         return Laid_Out (Of_Unit, Item, Facts, Maximum);
      end if;
      declare
         Slot_Data : Mask_Buffers.Buffer (Of_Plan.Slots);
         Value_Data : Value_Buffers.Buffer (Of_Plan.Values);
         Spill_Data : Extent_Buffers.Buffer (Of_Plan.Spill_Homes);
         Slots : Home_Mask renames Slot_Data.Data.all;
         Values : Spill_Assignments renames Value_Data.Data.all;
         Spills : Landin.Targets.Layouts.Field_Extent_Array renames
           Spill_Data.Data.all;
         Saves : constant Landin.Targets.Layouts.Field_Extent_Array
           (1 .. Save_Count (Of_Plan)) :=
             [others => (Size => 8, Alignment => 8)];
      begin
         for Index in Slots'Range loop
            Slots (Index) := Of_Plan.Slot (Index).Kind = Stack;
         end loop;
         for Index in Values'Range loop
            declare
               Place : Location renames Of_Plan.Value (Index);
            begin
               Values (Index) := Place.Home;
               if Place.Kind = Stack then
                  Spills (Place.Home) :=
                    (Size => Landin.Targets.Byte_Count
                       (Landin.Targets.Bytes (Place.Size)),
                     Alignment =>
                       Landin.Targets.Alignment_Of (Facts, Place.Size));
               end if;
            end;
         end loop;
         return Laid_Out
           (Of_Unit, Item, Facts, Slots, Values, Spills, Saves, Maximum);
      end;
   end Frame_For;

end Landin.Backend.X86_64.Allocation;
