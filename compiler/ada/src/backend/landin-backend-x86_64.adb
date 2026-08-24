with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Types;

package body Landin.Backend.X86_64 is

   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Count;
   use type Landin.IR.Item_Kind;
   use type Landin.IR.Opcode;
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

               when others =>
                  raise Compiler_Defect
                    with "this backend does not emit "
                         & Landin.IR.Opcode'Image (Op) & " yet";
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

   begin
      Put (Character'Val (9) & ".text");

      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine then
               Emit_Routine (Item);
            else
               raise Compiler_Defect
                 with "this backend does not emit a datum yet";
            end if;
         end;
      end loop;

      --  An executable stack is inherited when nothing says otherwise,
      --  and nothing this compiler emits needs one.
      Put (Character'Val (9)
           & ".section .note.GNU-stack,"""",@progbits");
      return Unbounded.To_String (Out_Text);
   end Text;

end Landin.Backend.X86_64;
