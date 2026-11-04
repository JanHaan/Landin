with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;

package body Landin.Backend.Xtensa_Machine is
   package U renames Ada.Strings.Unbounded;
   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   function Trim (Text : String) return String
     is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));
   function Image (Number : Integer) return String
     is (Trim (Number'Image));

   function Word_Offset (Word : Natural; Compact : Boolean) return Natural is
   begin
      if not Compact and then Word <= 31 then
         return Word * 4;
      elsif Compact and then Word in 10 .. 17 then
         return (Word - 10) * 4;
      elsif Compact and then Word in 19 .. 25 then
         return 32 + (Word - 19) * 4;
      elsif Compact and then Word in 27 .. 31 then
         return 60 + (Word - 27) * 4;
      end if;
      raise Compiler_Defect with "Xtensa logical word has no frame home";
   end Word_Offset;

   procedure Select_Word
     (Instruction : String;
      Into : in out U.Unbounded_String;
      Serial : in out Natural;
      Frame_Bytes : Natural := 0;
      Scratch_Registers : Boolean := False)
   is
      Text : constant String := Trim (Instruction);
      Space : constant Natural := Ada.Strings.Fixed.Index (Text, " ");
      Op : constant String :=
        (if Space = 0 then Text else Text (Text'First .. Space - 1));
      Rest : constant String :=
        (if Space = 0 then "" else Text (Space + 1 .. Text'Last));
      Args : array (1 .. 4) of U.Unbounded_String;
      Count : Natural := 0;
      Start : Positive := Rest'First;

      function Arg (Index : Positive) return String
        is (U.To_String (Args (Index)));
      procedure Raw (Line : String);
      procedure Raw (Line : String) is
      begin
         U.Append (Into, HT & Line & LF);
      end Raw;
      function Number (Name : String) return Natural;
      function Number (Name : String) return Natural is
      begin
         if Name = "zero" then return 0;
         elsif Name = "ra" then return 1;
         elsif Name = "sp" then return 2;
         elsif Name'Length > 1 and then Name (Name'First) = 'x' then
            return Natural'Value (Name (Name'First + 1 .. Name'Last));
         end if;
         raise Compiler_Defect with "invalid Xtensa logical word " & Name;
      end Number;
      function Mapped (Name : String) return String;
      function Mapped (Name : String) return String is
      begin
         if not Scratch_Registers then return ""; end if;
         return (case Number (Name) is
           when 5 => "a2", when 6 => "a3", when 7 => "a4", when 9 => "a5",
           when 18 => "a6",
           when others => "");
      end Mapped;
      procedure Read (Name, Physical : String);
      procedure Read (Name, Physical : String) is
         Id : constant Natural := Number (Name);
      begin
         if Mapped (Name) /= "" then
            if Mapped (Name) /= Physical then
               Raw ("mov " & Physical & ", " & Mapped (Name));
            end if;
         elsif Id = 0 then Raw ("movi " & Physical & ", 0");
         elsif Id = 2 then Raw ("mov " & Physical & ", a1");
         elsif Id = 8 and then Scratch_Registers then
            if Frame_Bytes = 0 then
               raise Compiler_Defect with "Xtensa CFA has no native frame";
            end if;
            Raw ("movi " & Physical & ", " & Image (Frame_Bytes));
            Raw ("add " & Physical & ", a7, " & Physical);
         elsif Id <= 31 then
            Raw ("l32i " & Physical & ", a7, "
                 & Image (Word_Offset (Id, Scratch_Registers)));
         else raise Compiler_Defect with "Xtensa logical word exceeds bank";
         end if;
      end Read;
      function Read_Only (Name, Physical : String) return String;
      function Read_Only (Name, Physical : String) return String is
      begin
         if Mapped (Name) /= "" then return Mapped (Name); end if;
         Read (Name, Physical);
         return Physical;
      end Read_Only;
      function Destination (Name, Physical : String) return String;
      function Destination (Name, Physical : String) return String
        is (if Mapped (Name) /= "" then Mapped (Name) else Physical);
      procedure Write (Name, Physical : String);
      procedure Write (Name, Physical : String) is
         Id : constant Natural := Number (Name);
      begin
         if Mapped (Name) /= "" then
            if Mapped (Name) /= Physical then
               Raw ("mov " & Mapped (Name) & ", " & Physical);
            end if;
         elsif Id = 0 then null;
         elsif Id = 2 then
            Raw ("mov a1, " & Physical);
            --  Outgoing stack arguments can cover the previous spill
            --  backchain. Every new SP needs the current caller's link.
            Read ("x8", "a11");
            Raw ("s32e a11, a1, -12");
         elsif Id = 8 and then Scratch_Registers then
            raise Compiler_Defect with "Xtensa CFA is immutable";
         elsif Id <= 31 then
            Raw ("s32i " & Physical & ", a7, "
                 & Image (Word_Offset (Id, Scratch_Registers)));
         else raise Compiler_Defect with "Xtensa logical word exceeds bank";
         end if;
      end Write;
      function Fresh return String;
      function Fresh return String is
      begin
         Serial := Serial + 1;
         return ".Lxtensa_word_" & Image (Serial);
      end Fresh;
      procedure Jump (Target : String);
      procedure Jump (Target : String) is
      begin
         Raw ("movi a10, " & Target);
         Raw ("jx a10");
      end Jump;
      procedure Call (Target : String; Indirect : Boolean := False);
      procedure Call (Target : String; Indirect : Boolean := False) is
      begin
         if Indirect then
            Read (Target, "a9");
         end if;
         for Index in 0 .. 5 loop
            Raw ("l32i a" & Image (Index + 10)
                 & ", a7, "
                 & Image (Word_Offset (Index + 10, Scratch_Registers)));
         end loop;
         Raw (if Indirect then "callx8 a9" else "call8 " & Target);
         for Index in 0 .. 3 loop
            Raw ("s32i a" & Image (Index + 10)
                 & ", a7, "
                 & Image (Word_Offset (Index + 10, Scratch_Registers)));
         end loop;
         Raw ("s32i a14, a7, "
              & Image (Word_Offset (31, Scratch_Registers)));
      end Call;
      procedure Boolean_Result (Condition, Left, Right : String);
      procedure Boolean_Result (Condition, Left, Right : String) is
         Done : constant String := Fresh;
      begin
         Raw ("movi a10, 1");
         Raw (Condition & " " & Left & ", " & Right & ", " & Done);
         Raw ("movi a10, 0");
         U.Append (Into, Done & ":" & LF);
      end Boolean_Result;
   begin
      if Text'Length = 0 then return; end if;
      for Index in Text'Range loop
         if Text (Index) = LF then
            Select_Word
              (Text (Text'First .. Index - 1), Into, Serial, Frame_Bytes,
               Scratch_Registers);
            Select_Word
              (Text (Index + 1 .. Text'Last), Into, Serial, Frame_Bytes,
               Scratch_Registers);
            return;
         end if;
      end loop;
      if Text (Text'First) = '.' then
         if Op = ".option" or else Op = ".attribute" then return; end if;
         --  Source debugging is not yet a target capability; generic CFI
         --  names logical words and must never reach the native assembler.
         if Op'Length >= 4 and then Op (Op'First .. Op'First + 3) = ".cfi"
         then return; end if;
         Raw (Text);
         return;
      end if;
      for Index in Rest'First .. Rest'Last + 1 loop
         if Index > Rest'Last or else Rest (Index) = ',' then
            Count := Count + 1;
            if Count > Args'Length then
               raise Compiler_Defect with "too many Xtensa word operands";
            end if;
            Args (Count) := U.To_Unbounded_String
              (Trim (Rest (Start .. Index - 1)));
            Start := Index + 1;
         end if;
      end loop;
      if Op = "li" or else Op = "lui" then
         declare Into_Reg : constant String := Destination (Arg (1), "a10");
         begin
            Raw ("movi " & Into_Reg & ", " & Arg (2));
            if Op = "lui" then
               Raw ("slli " & Into_Reg & ", " & Into_Reg & ", 12");
            end if;
            Write (Arg (1), Into_Reg);
         end;
      elsif Op in "la" | "lla" then
         Raw ("movi a10, " & Arg (2));
         Write (Arg (1), "a10");
      elsif Op in "mv" | "sext.w" | "neg" | "not" then
         Read (Arg (2), "a8");
         if Op = "neg" then Raw ("neg a10, a8");
         elsif Op = "not" then
            Raw ("movi a9, -1"); Raw ("xor a10, a8, a9");
         else Write (Arg (1), "a8"); return; end if;
         Write (Arg (1), "a10");
      elsif Op in "lw" | "lbu" | "lb" | "lhu" | "lh"
        | "sw" | "sb" | "sh"
      then
         declare
            Memory : constant String := Arg (2);
            Open : constant Natural := Ada.Strings.Fixed.Index (Memory, "(");
            Offset : constant String := Memory (Memory'First .. Open - 1);
            Base : constant String := Memory (Open + 1 .. Memory'Last - 1);
            Store : constant Boolean := Op (Op'First) = 's';
            Frame_Offset : constant Long_Long_Integer :=
              Long_Long_Integer (Frame_Bytes)
              + Long_Long_Integer'Value (Offset);
            Scale : constant Positive :=
              (if Op in "lw" | "sw" then 4
               elsif Op in "lh" | "lhu" | "sh" then 2 else 1);
         begin
            --  x8 is the immutable CFA, a7+Frame_Bytes, including when
            --  outgoing arguments move the current SP.
            if Frame_Bytes /= 0 and then Base = "x8"
              and then Frame_Offset in 0 .. Long_Long_Integer (255 * Scale)
              and then Frame_Offset mod Long_Long_Integer (Scale) = 0
            then
               declare
                  Value_Reg : constant String :=
                    (if Store then Read_Only (Arg (1), "a8")
                     else Destination (Arg (1), "a10"));
               begin
                  Raw ((if Op = "lw" then "l32i"
                        elsif Op = "lbu" or else Op = "lb" then "l8ui"
                        elsif Op = "lhu" then "l16ui"
                        elsif Op = "lh" then "l16si"
                        elsif Op = "sw" then "s32i"
                        elsif Op = "sb" then "s8i" else "s16i")
                       & " " & Value_Reg & ", a7, "
                       & Image (Integer (Frame_Offset)));
                  if not Store then
                     if Op = "lb" then
                        Raw ("sext " & Value_Reg & ", " & Value_Reg & ", 7");
                     end if;
                     Write (Arg (1), Value_Reg);
                  end if;
               end;
               return;
            end if;
            Read (Base, "a9");
            if Store then Read (Arg (1), "a8"); end if;
            if Offset /= "0" and then Offset /= "" then
               Raw ("movi a11, " & Offset);
               Raw ("add a9, a9, a11");
            end if;
            Raw ((if Op = "lw" then "l32i a10"
                  elsif Op = "lbu" or else Op = "lb" then "l8ui a10"
                  elsif Op = "lhu" then "l16ui a10"
                  elsif Op = "lh" then "l16si a10"
                  elsif Op = "sw" then "s32i a8"
                  elsif Op = "sb" then "s8i a8" else "s16i a8")
                 & ", a9, 0");
            if not Store then
               if Op = "lb" then Raw ("sext a10, a10, 7"); end if;
               Write (Arg (1), "a10");
            end if;
         end;
      elsif Op in "add" | "sub" | "mul" | "mulhu" | "mulh"
        | "and" | "or" | "xor" | "addi" | "andi" | "ori" | "xori"
        | "div" | "divu" | "rem" | "remu"
      then
         if Op = "addi" and then Frame_Bytes /= 0 and then Arg (2) = "x8"
         then
            declare
               Offset : constant Long_Long_Integer :=
                 Long_Long_Integer (Frame_Bytes)
                 + Long_Long_Integer'Value (Arg (3));
            begin
               if Offset in 0 .. Long_Long_Integer (Natural'Last) then
                  if Offset <= 127 then
                     Raw ("addi a10, a7, " & Image (Integer (Offset)));
                  else
                     Raw ("movi a10, " & Image (Integer (Offset)));
                     Raw ("add a10, a7, a10");
                  end if;
                  Write (Arg (1), "a10");
                  return;
               end if;
            end;
         end if;
         Read (Arg (2), "a8");
         if Op in "addi" | "andi" | "ori" | "xori" then
            Raw ("movi a9, " & Arg (3));
         else Read (Arg (3), "a9"); end if;
         Raw ((if Op = "mul" then "mull"
               elsif Op = "mulhu" then "muluh"
               elsif Op = "mulh" then "mulsh"
               elsif Op = "div" then "quos"
               elsif Op = "divu" then "quou"
               elsif Op = "rem" then "rems"
               elsif Op = "remu" then "remu"
               elsif Op = "addi" then "add"
               elsif Op = "andi" then "and"
               elsif Op = "ori" then "or"
               elsif Op = "xori" then "xor" else Op)
              & " a10, a8, a9");
         Write (Arg (1), "a10");
      elsif Op in "sll" | "srl" | "sra" | "slli" | "srli" | "srai"
      then
         Read (Arg (2), "a8");
         if Op in "slli" | "srli" | "srai" then
            declare Amount : constant Natural := Natural'Value (Arg (3));
            begin
               if Amount = 0 then Raw ("mov a10, a8");
               elsif Op = "slli" then
                  Raw ("slli a10, a8, " & Image (Amount));
               elsif Op = "srai" then
                  Raw ("srai a10, a8, " & Image (Amount));
               elsif Amount <= 15 then
                  Raw ("srli a10, a8, " & Image (Amount));
               else
                  Raw ("movi a9, " & Image (Amount));
                  Raw ("ssr a9"); Raw ("srl a10, a8");
               end if;
            end;
         else
            Read (Arg (3), "a9");
            Raw (if Op = "sll" then "ssl a9" else "ssr a9");
            Raw (Op & " a10, a8");
         end if;
         Write (Arg (1), "a10");
      elsif Op in "seqz" | "snez" | "sgtz" | "sltu" | "slt"
        | "slti" | "sltiu"
      then
         Read (Arg (2), "a8");
         if Op in "seqz" | "snez" | "sgtz" then Raw ("movi a9, 0");
         elsif Op in "slti" | "sltiu" then Raw ("movi a9, " & Arg (3));
         else Read (Arg (3), "a9"); end if;
         if Op = "sgtz" then Boolean_Result ("blt", "a9", "a8");
         else
            Boolean_Result
              ((if Op = "seqz" then "beq" elsif Op = "snez" then "bne"
                elsif Op in "sltu" | "sltiu" then "bltu" else "blt"),
               "a8", "a9");
         end if;
         Write (Arg (1), "a10");
      elsif Op in "beq" | "bne" | "blt" | "bge" | "bltu" | "bgeu"
        | "beqz" | "bnez" | "bltz" | "bgez" | "blez" | "bgtz"
      then
         declare
            Unary : constant Boolean := Count = 2;
            Skip : constant String := Fresh;
            Inverse : constant String :=
              (if Op = "beq" then "bne" elsif Op = "bne" then "beq"
               elsif Op = "blt" then "bge" elsif Op = "bge" then "blt"
               elsif Op = "bltu" then "bgeu" elsif Op = "bgeu" then "bltu"
               elsif Op = "beqz" then "bnez" elsif Op = "bnez" then "beqz"
               elsif Op = "bltz" then "bgez" elsif Op = "bgez" then "bltz"
               elsif Op = "blez" then "bgtz" else "blez");
         begin
            Read (Arg (1), "a8");
            if not Unary then Read (Arg (2), "a9"); end if;
            Raw (Inverse & " a8, " & (if Unary then "" else "a9, ") & Skip);
            Jump (Arg (Count));
            U.Append (Into, Skip & ":" & LF);
         end;
      elsif Op = "j" then Jump (Arg (1));
      elsif Op = "jr" then Read (Arg (1), "a10"); Raw ("jx a10");
      elsif Op = "call" then Call (Arg (1));
      elsif Op = "jalr" then
         declare
            Address : constant String := Arg (2);
            Open : constant Natural := Ada.Strings.Fixed.Index (Address, "(");
         begin
            Call (Address (Open + 1 .. Address'Last - 1), Indirect => True);
         end;
      elsif Op = "fence" or else Op = "fence.tso" then Raw ("memw");
      elsif Op = "unimp" then Raw ("ill");
      elsif Op = "nop" then Raw ("nop");
      else
         raise Compiler_Defect with "unsupported Xtensa word operation " & Op;
      end if;
   end Select_Word;

   procedure Compact_Jumps
     (Into : in out U.Unbounded_String; First : Positive)
   is
      Text : constant String := U.To_String (Into);
      package Positions is new Ada.Containers.Indefinite_Hashed_Maps
        (String, Natural, Ada.Strings.Hash, "=");
      Labels : Positions.Map;
      Bound : Natural := 0;
      Start : Positive := First;
      Result : U.Unbounded_String;
      Prefix : constant String := HT & "movi a10, ";
      Suffix : constant String := HT & "jx a10" & LF;
      Line_Bytes : constant := 16;
   begin
      --  Sixteen bytes per source line bounds native instructions, their
      --  automatic literal entries, pool jumps and alignment in a routine.
      --  The routine has no source assembly directives or embedded data.
      --  Shortening a jump only decreases every intervening distance.
      for Index in First .. Text'Last loop
         if Text (Index) = LF then
            if Index > Start and then Text (Index - 1) = ':' then
               Labels.Include (Text (Start .. Index - 2), Bound);
            end if;
            Bound := Bound + Line_Bytes;
            Start := Index + 1;
         end if;
      end loop;
      Bound := 0;
      Start := First;
      while Start <= Text'Last loop
         declare
            Stop : constant Positive := Ada.Strings.Fixed.Index
              (Text, String'(1 => LF), Start);
            Line : constant String := Text (Start .. Stop - 1);
            Target : constant String :=
              (if Line'Length > Prefix'Length
                 and then Line (Line'First .. Line'First + Prefix'Length - 1)
                   = Prefix
               then Line (Line'First + Prefix'Length .. Line'Last) else "");
         begin
            if Labels.Contains (Target)
              and then abs (Integer (Labels.Element (Target))
                            - Integer (Bound)) <= 131_000
              and then Stop + Suffix'Length <= Text'Last
              and then Text (Stop + 1 .. Stop + Suffix'Length) = Suffix
            then
               U.Append (Result, HT & "j " & Target & LF);
               Start := Stop + Suffix'Length + 1;
               Bound := Bound + 2 * Line_Bytes;
            else
               U.Append (Result, Line & LF);
               Start := Stop + 1;
               Bound := Bound + Line_Bytes;
            end if;
         end;
      end loop;
      U.Replace_Slice (Into, First, Text'Last, U.To_String (Result));
   end Compact_Jumps;
end Landin.Backend.Xtensa_Machine;
