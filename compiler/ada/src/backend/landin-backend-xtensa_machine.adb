with Ada.Containers.Generic_Array_Sort;
with Ada.Containers.Hashed_Maps;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Maps;
with Ada.Unchecked_Deallocation;

package body Landin.Backend.Xtensa_Machine is
   package U renames Ada.Strings.Unbounded;
   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   --  A line is trimmed of its layout, spaces and tabs alike: a directive
   --  the backend writes after another in one instruction, as an item's
   --  section and its placement's `.balign` are, arrives here as a second
   --  line indented with a tab, and is still a directive.
   Layout : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set (' ' & HT);
   function Trim (Text : String) return String
     is (Ada.Strings.Fixed.Trim (Text, Layout, Layout));
   function Image (Number : Integer) return String
     is (Trim (Number'Image));
   --  Target bytes are counted in the target's own type, never the
   --  host's Natural, and spelled from it.
   function Byte_Image (Number : Landin.Targets.Byte_Count) return String
     is (Trim (Number'Image));

   function Word_Offset (Word : Natural; Compact : Boolean)
      return Landin.Targets.Byte_Count
   is
      use type Landin.Targets.Byte_Count;
      At_Word : constant Landin.Targets.Byte_Count :=
        Landin.Targets.Byte_Count (Word);
   begin
      if not Compact and then Word <= 31 then
         return At_Word * 4;
      elsif Compact and then Word in 10 .. 17 then
         return (At_Word - 10) * 4;
      elsif Compact and then Word in 19 .. 25 then
         return 32 + (At_Word - 19) * 4;
      elsif Compact and then Word in 27 .. 31 then
         return 60 + (At_Word - 27) * 4;
      end if;
      raise Compiler_Defect with "Xtensa logical word has no frame home";
   end Word_Offset;

   --  A word's number: x0-x31 by their names, and vN First_Value_Word
   --  above N.
   function Word_Number (Name : String) return Natural;
   function Word_Number (Name : String) return Natural is
   begin
      if Name = "zero" then return 0;
      elsif Name = "ra" then return 1;
      elsif Name = "sp" then return 2;
      elsif Name'Length > 1 and then Name (Name'First) = 'x' then
         return Natural'Value (Name (Name'First + 1 .. Name'Last));
      elsif Name'Length > 1 and then Name (Name'First) = 'v' then
         return First_Value_Word
           + Natural'Value (Name (Name'First + 1 .. Name'Last));
      end if;
      raise Compiler_Defect with "invalid Xtensa logical word " & Name;
   end Word_Number;

   function Load_Op (Bytes : Positive) return String
     is (case Bytes is when 1 => "l8ui", when 2 => "l16ui",
         when others => "l32i");
   function Store_Op (Bytes : Positive) return String
     is (case Bytes is when 1 => "s8i", when 2 => "s16i",
         when others => "s32i");
   --  Whether an access of Bytes reaches Offset from its base directly.
   function In_Reach (Offset : Long_Long_Integer; Bytes : Positive)
     return Boolean
     is (Offset >= 0 and then Offset <= Long_Long_Integer (255 * Bytes)
         and then Offset mod Long_Long_Integer (Bytes) = 0);

   --  The selector of a routine whose words keep their homes, the first
   --  form of this layer and its fallback (D1627).
   procedure Select_Old
     (Instruction : String;
      Into : in out U.Unbounded_String;
      Serial : in out Natural;
      Frame_Bytes : Landin.Targets.Byte_Count;
      Scratch_Registers : Boolean;
      Homes : Home_Vectors.Vector);

   procedure Select_Old
     (Instruction : String;
      Into : in out U.Unbounded_String;
      Serial : in out Natural;
      Frame_Bytes : Landin.Targets.Byte_Count;
      Scratch_Registers : Boolean;
      Homes : Home_Vectors.Vector)
   is
      use type Landin.Targets.Byte_Count;
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
      function Number (Name : String) return Natural
        renames Word_Number;
      function Value_Home (Id : Natural) return Home;
      function Value_Home (Id : Natural) return Home is
      begin
         if Id - First_Value_Word > Homes.Last_Index
           or else not Homes (Id - First_Value_Word).Declared
         then
            raise Compiler_Defect with "Xtensa value word has no home";
         end if;
         return Homes (Id - First_Value_Word);
      end Value_Home;
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
            Raw ("movi " & Physical & ", " & Byte_Image (Frame_Bytes));
            Raw ("add " & Physical & ", a7, " & Physical);
         elsif Id >= First_Value_Word then
            declare
               At_Home : constant Home := Value_Home (Id);
            begin
               if In_Reach (Long_Long_Integer (At_Home.Offset), At_Home.Bytes)
               then
                  Raw (Load_Op (At_Home.Bytes) & " " & Physical & ", a7, "
                       & Byte_Image (At_Home.Offset));
               else
                  Raw ("movi " & Physical & ", "
                       & Byte_Image (At_Home.Offset));
                  Raw ("add " & Physical & ", " & Physical & ", a7");
                  Raw (Load_Op (At_Home.Bytes) & " " & Physical & ", "
                       & Physical & ", 0");
               end if;
            end;
         elsif Id <= 31 then
            Raw ("l32i " & Physical & ", a7, "
                 & Byte_Image (Word_Offset (Id, Scratch_Registers)));
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
         elsif Id >= First_Value_Word then
            declare
               At_Home : constant Home := Value_Home (Id);
               Address : constant String :=
                 (if Physical = "a11" then "a9" else "a11");
            begin
               if In_Reach (Long_Long_Integer (At_Home.Offset), At_Home.Bytes)
               then
                  Raw (Store_Op (At_Home.Bytes) & " " & Physical & ", a7, "
                       & Byte_Image (At_Home.Offset));
               else
                  Raw ("movi " & Address & ", "
                       & Byte_Image (At_Home.Offset));
                  Raw ("add " & Address & ", " & Address & ", a7");
                  Raw (Store_Op (At_Home.Bytes) & " " & Physical & ", "
                       & Address & ", 0");
               end if;
            end;
         elsif Id <= 31 then
            Raw ("s32i " & Physical & ", a7, "
                 & Byte_Image (Word_Offset (Id, Scratch_Registers)));
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
                 & Byte_Image (Word_Offset (Index + 10, Scratch_Registers)));
         end loop;
         Raw (if Indirect then "callx8 a9" else "call8 " & Target);
         for Index in 0 .. 3 loop
            Raw ("s32i a" & Image (Index + 10)
                 & ", a7, "
                 & Byte_Image (Word_Offset (Index + 10, Scratch_Registers)));
         end loop;
         Raw ("s32i a14, a7, "
              & Byte_Image (Word_Offset (31, Scratch_Registers)));
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
            Select_Old
              (Text (Text'First .. Index - 1), Into, Serial, Frame_Bytes,
               Scratch_Registers, Homes);
            Select_Old
              (Text (Index + 1 .. Text'Last), Into, Serial, Frame_Bytes,
               Scratch_Registers, Homes);
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
      elsif Op in "zext.b" | "zext.h" then
         Read (Arg (2), "a8");
         Raw ("extui a10, a8, 0, " & (if Op = "zext.b" then "8" else "16"));
         Write (Arg (1), "a10");
      elsif Op = "landin.entry" then
         for Index in 0 .. 4 loop
            Raw ("s32i a" & Image (Index + 2) & ", a7, "
                 & Byte_Image (Word_Offset (Index + 10, Scratch_Registers)));
         end loop;
      elsif Op = "landin.leave" then
         for Index in 0 .. 3 loop
            Raw ("l32i a" & Image (Index + 2) & ", a7, "
                 & Byte_Image (Word_Offset (Index + 10, Scratch_Registers)));
         end loop;
         Raw ("l32i a6, a7, "
              & Byte_Image (Word_Offset (31, Scratch_Registers)));
         --  SP is where the prologue left it, which RETW's underflow
         --  handler reads the caller's base save below.
         Raw ("retw");
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
   end Select_Old;

   procedure Select_Word
     (Instruction : String;
      Into : in out U.Unbounded_String;
      Serial : in out Natural;
      Frame_Bytes : Landin.Targets.Byte_Count := 0;
      Scratch_Registers : Boolean := False) is
   begin
      Select_Old (Instruction, Into, Serial, Frame_Bytes, Scratch_Registers,
                  Home_Vectors.Empty_Vector);
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

   ---------------------------------------------------------------------
   --  Placement of an assembly-free routine's words (D1627).
   ---------------------------------------------------------------------

   procedure Begin_Routine
     (Of_Routine : in out Routine;
      Frame_Bytes : Landin.Targets.Byte_Count) is
   begin
      Of_Routine.Active := True;
      Of_Routine.Frame_Bytes := Frame_Bytes;
      Of_Routine.Lines.Clear;
      Of_Routine.Homes.Clear;
   end Begin_Routine;

   function Buffering (Of_Routine : Routine) return Boolean
     is (Of_Routine.Active);

   procedure Declare_Home
     (Of_Routine : in out Routine;
      Word : Natural;
      Offset : Landin.Targets.Byte_Count;
      Bytes : Positive) is
   begin
      if Word < First_Value_Word or else Bytes not in 1 | 2 | 4 then
         raise Compiler_Defect with "invalid Xtensa value word home";
      end if;
      while Of_Routine.Homes.Last_Index < Word - First_Value_Word loop
         Of_Routine.Homes.Append (Home'(others => <>));
      end loop;
      Of_Routine.Homes (Word - First_Value_Word) :=
        (Declared => True, Offset => Offset, Bytes => Bytes);
   end Declare_Home;

   procedure Add (Of_Routine : in out Routine; Instruction : String) is
      Start : Positive := Instruction'First;
      procedure One (Piece : String);
      procedure One (Piece : String) is
         Text : constant String := Trim (Piece);
         Space : constant Natural := Ada.Strings.Fixed.Index (Text, " ");
         Op : constant String :=
           (if Space = 0 then Text else Text (Text'First .. Space - 1));
      begin
         if Text'Length = 0 then
            return;
         elsif Text (Text'First) = '.' then
            --  As the first selector: the generic directives that name
            --  logical words never reach the native assembler.
            if Op = ".option" or else Op = ".attribute"
              or else (Op'Length >= 4
                       and then Op (Op'First .. Op'First + 3) = ".cfi")
            then
               return;
            end if;
            Of_Routine.Lines.Append
              (Buffered'(Kind => Line,
                         Text => U.To_Unbounded_String (HT & Text)));
         else
            Of_Routine.Lines.Append
              (Buffered'(Kind => Logical,
                         Text => U.To_Unbounded_String (Text)));
         end if;
      end One;
   begin
      for Index in Instruction'Range loop
         if Instruction (Index) = LF then
            One (Instruction (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      if Start <= Instruction'Last then
         One (Instruction (Start .. Instruction'Last));
      end if;
   end Add;

   procedure Add_Line (Of_Routine : in out Routine; Line : String) is
   begin
      Of_Routine.Lines.Append
        (Buffered'(Kind => Xtensa_Machine.Line,
                   Text => U.To_Unbounded_String (Line)));
   end Add_Line;

   function Directive (Line : String) return Boolean
     is (Trim (Line)'Length > 0 and then Trim (Line) (1) = '.');
   type Arguments is array (1 .. 4) of U.Unbounded_String;
   type Op_Kind is (Plain, Branch, Jump, Stop, Call, Enter, Leave);
   Most_Words : constant := 8;
   type Word_List is array (1 .. Most_Words) of Natural;
   type Step is record
      Instruction : Boolean := False;
      Text : U.Unbounded_String;
      Op : U.Unbounded_String;
      Args : Arguments;
      Count : Natural := 0;
      Kind : Op_Kind := Plain;
      --  A branch's or jump's target block.
      Target : Natural := 0;
      --  Words, by their dense numbers, the argument each came from (zero
      --  for a call's implicit ones), and the nodes placement gives them.
      Uses, Use_Arg, Use_Nodes : Word_List := [others => 0];
      Defs, Def_Arg, Def_Nodes : Word_List := [others => 0];
      Use_Count, Def_Count : Natural := 0;
      --  An operation without effect whose results nothing reads.
      Dead : Boolean := False;
      --  A `mul` or `add` one of whose operands is a constant: the other
      --  operand's argument, and the shift or addend it becomes.
      Folded : Natural := 0;
      Shift : Natural := 0;
      Addend : Long_Long_Integer := 0;
      --  A zero test's step whose comparison it makes itself, and that
      --  comparison's own step, which is then not selected.
      Tests : Natural := 0;
      Tested : Boolean := False;
   end record;
   package Step_Vectors is new Ada.Containers.Vectors (Positive, Step);
   package Natural_Vectors is new Ada.Containers.Vectors (Positive, Natural);
   package Flag_Vectors is new Ada.Containers.Vectors (Positive, Boolean);
   package Block_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (String, Positive, Ada.Strings.Hash, "=");
   function Key_Hash (Key : Natural) return Ada.Containers.Hash_Type
     is (Ada.Containers.Hash_Type (Key));
   package Node_Maps is new Ada.Containers.Hashed_Maps
     (Natural, Positive, Key_Hash, "=");

   type Bit_Array is array (Positive range <>) of Boolean with Pack;
   type Bit_Access is access Bit_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Bit_Array, Bit_Access);
   type Natural_Array is array (Positive range <>) of Natural;
   type Natural_Access is access Natural_Array;
   procedure Free is new Ada.Unchecked_Deallocation
     (Natural_Array, Natural_Access);

   --  The registers a placed word may take.  CALL8 rotates the window by
   --  eight: a2-a7 survive a call and a8-a15 do not.  a7 is the base of
   --  the homes, a8 and a9 selection's transients, a10-a15 a call's
   --  argument and result words.
   subtype Physical is Natural range 2 .. 15;
   type Physical_Flags is array (Physical) of Boolean;
   Preserved : constant Physical_Flags :=
     [2 .. 6 => True, others => False];
   Placeable : constant Physical_Flags :=
     [2 .. 6 | 10 .. 15 => True, others => False];

   procedure Place
     (Of_Routine : Routine;
      Into : in out U.Unbounded_String;
      Serial : in out Natural;
      Registers : out Natural;
      Placed : out Boolean);

   procedure Place
     (Of_Routine : Routine;
      Into : in out U.Unbounded_String;
      Serial : in out Natural;
      Registers : out Natural;
      Placed : out Boolean)
   is
      use type Ada.Containers.Count_Type;
      Not_Placed : exception;
      Steps : Step_Vectors.Vector;
      Labels : Block_Maps.Map;
      Block_First, Block_Last : Natural_Vectors.Vector;
      --  Dense word numbers: each word the text names but zero, SP and
      --  the CFA, which are no web's.
      Dense_Of : Natural_Vectors.Vector;
      Word_Of : Natural_Vectors.Vector;
      Output : U.Unbounded_String;
      Labels_Made : Natural := Serial;

      function Dense (Word : Natural) return Natural;
      function Dense (Word : Natural) return Natural is
      begin
         while Natural (Dense_Of.Length) < Word + 1 loop
            Dense_Of.Append (0);
         end loop;
         if Dense_Of (Word + 1) = 0 then
            Word_Of.Append (Word);
            Dense_Of (Word + 1) := Natural (Word_Of.Length);
         end if;
         return Dense_Of (Word + 1);
      end Dense;

      function Special (Word : Natural) return Boolean
        is (Word in 0 | 2 | 8);

      procedure Note
        (At_Step : in out Step; Name : String; Argument : Natural;
         Defined : Boolean);
      procedure Note
        (At_Step : in out Step; Name : String; Argument : Natural;
         Defined : Boolean)
      is
         Word : constant Natural := Word_Number (Name);
      begin
         if Defined and then Word in 2 | 8 then
            raise Not_Placed;
         elsif Special (Word) or else (Defined and then Word = 0) then
            return;
         elsif Defined then
            At_Step.Def_Count := At_Step.Def_Count + 1;
            At_Step.Defs (At_Step.Def_Count) := Dense (Word);
            At_Step.Def_Arg (At_Step.Def_Count) := Argument;
         else
            At_Step.Use_Count := At_Step.Use_Count + 1;
            At_Step.Uses (At_Step.Use_Count) := Dense (Word);
            At_Step.Use_Arg (At_Step.Use_Count) := Argument;
         end if;
      end Note;

      --  The base word of an `offset(base)` operand.
      function Base_Of (Operand : String) return String;
      function Base_Of (Operand : String) return String is
         Open : constant Natural := Ada.Strings.Fixed.Index (Operand, "(");
      begin
         if Open = 0 or else Operand (Operand'Last) /= ')' then
            raise Not_Placed;
         end if;
         return Operand (Open + 1 .. Operand'Last - 1);
      end Base_Of;
      function Offset_Of (Operand : String) return Long_Long_Integer;
      function Offset_Of (Operand : String) return Long_Long_Integer is
         Open : constant Natural := Ada.Strings.Fixed.Index (Operand, "(");
      begin
         return (if Open = Operand'First then 0
                 else Long_Long_Integer'Value
                   (Operand (Operand'First .. Open - 1)));
      end Offset_Of;

      function Words_Of_Call (At_Step : Step; Position : Positive)
        return Natural
        is (if At_Step.Count >= Position
            then Natural'Value (U.To_String (At_Step.Args (Position)))
            else 6);

      procedure Parse (At_Step : in out Step);
      procedure Parse (At_Step : in out Step) is
         Op : constant String := U.To_String (At_Step.Op);
         function Arg (Index : Positive) return String
           is (U.To_String (At_Step.Args (Index)));
      begin
         if Op in "li" | "lui" | "la" | "lla" then
            Note (At_Step, Arg (1), 1, True);
         elsif Op in "mv" | "sext.w" | "neg" | "not" | "zext.b" | "zext.h"
           | "seqz" | "snez" | "sgtz" | "addi" | "andi" | "ori" | "xori"
           | "slli" | "srli" | "srai" | "slti" | "sltiu"
         then
            Note (At_Step, Arg (2), 2, False);
            Note (At_Step, Arg (1), 1, True);
         elsif Op in "lw" | "lbu" | "lb" | "lhu" | "lh" then
            Note (At_Step, Base_Of (Arg (2)), 2, False);
            Note (At_Step, Arg (1), 1, True);
         elsif Op in "sw" | "sb" | "sh" then
            Note (At_Step, Arg (1), 1, False);
            Note (At_Step, Base_Of (Arg (2)), 2, False);
         elsif Op in "add" | "sub" | "mul" | "mulhu" | "mulh" | "and" | "or"
           | "xor" | "div" | "divu" | "rem" | "remu" | "sll" | "srl" | "sra"
           | "sltu" | "slt"
         then
            Note (At_Step, Arg (2), 2, False);
            Note (At_Step, Arg (3), 3, False);
            Note (At_Step, Arg (1), 1, True);
         elsif Op in "beq" | "bne" | "blt" | "bge" | "bltu" | "bgeu" then
            Note (At_Step, Arg (1), 1, False);
            Note (At_Step, Arg (2), 2, False);
            At_Step.Kind := Branch;
         elsif Op in "beqz" | "bnez" | "bltz" | "bgez" | "blez" | "bgtz" then
            Note (At_Step, Arg (1), 1, False);
            At_Step.Kind := Branch;
         elsif Op = "j" then
            At_Step.Kind := Jump;
         elsif Op in "call" | "jalr" then
            if Op = "jalr" then
               Note (At_Step, Base_Of (Arg (2)), 2, False);
            end if;
            for Index in 0 .. Words_Of_Call
              (At_Step, (if Op = "call" then 2 else 3)) - 1
            loop
               Note (At_Step, "x" & Image (Index + 10), 0, False);
            end loop;
            for Index in 0 .. 3 loop
               Note (At_Step, "x" & Image (Index + 10), 0, True);
            end loop;
            Note (At_Step, "x31", 0, True);
            At_Step.Kind := Call;
         elsif Op = "landin.entry" then
            for Index in 0 .. 5 loop
               Note (At_Step, "x" & Image (Index + 10), 0, True);
            end loop;
            At_Step.Kind := Enter;
         elsif Op = "landin.leave" then
            for Index in 0 .. 3 loop
               Note (At_Step, "x" & Image (Index + 10), 0, False);
            end loop;
            Note (At_Step, "x31", 0, False);
            At_Step.Kind := Leave;
         elsif Op = "unimp" then
            At_Step.Kind := Stop;
         elsif Op in "fence" | "fence.tso" | "nop" then
            null;
         else
            raise Not_Placed;
         end if;
      end Parse;

      Word_Count, Block_Count : Natural := 0;
      --  The words live where some block begins, the only ones liveness
      --  tracks: each is read in some block before that block writes it.
      --  Global_Of numbers them from one, and Global_Word gives back the
      --  word.
      Global_Count : Natural := 0;
      Global_Of : Natural_Access;
      Global_Word : Natural_Vectors.Vector;
      Live_In : Bit_Access;
      Current : Natural_Access;
      Scratch : Bit_Access;

      --  Union-find over the nodes: a block's live-in word, a definition,
      --  or a use no definition reaches.
      Parent, Node_Word : Natural_Vectors.Vector;
      First_At, Last_At, Weight, Hint : Natural_Vectors.Vector;
      Occurrences : Natural_Vectors.Vector;
      Forced : Flag_Vectors.Vector;
      In_Nodes : Node_Maps.Map;
      Depth : Natural_Vectors.Vector;

      function New_Node (Word : Positive; Is_Forced : Boolean := False)
        return Positive;
      function New_Node (Word : Positive; Is_Forced : Boolean := False)
        return Positive is
      begin
         Parent.Append (Natural (Parent.Length) + 1);
         Node_Word.Append (Word);
         First_At.Append (Natural'Last);
         Last_At.Append (0);
         Weight.Append (0);
         Hint.Append (0);
         Occurrences.Append (0);
         Forced.Append (Is_Forced);
         return Natural (Parent.Length);
      end New_Node;

      function Root (Node : Positive) return Positive;
      function Root (Node : Positive) return Positive is
         At_Node : Positive := Node;
      begin
         while Parent (At_Node) /= At_Node loop
            Parent (At_Node) := Parent (Parent (At_Node));
            At_Node := Parent (At_Node);
         end loop;
         return At_Node;
      end Root;

      procedure Extend (Node : Positive; Position : Natural);
      procedure Extend (Node : Positive; Position : Natural) is
         Top : constant Positive := Root (Node);
      begin
         First_At (Top) := Natural'Min (First_At (Top), Position);
         Last_At (Top) := Natural'Max (Last_At (Top), Position);
      end Extend;

      procedure Join (Left, Right : Positive);
      procedure Join (Left, Right : Positive) is
         A : constant Positive := Root (Left);
         B : constant Positive := Root (Right);
      begin
         if A = B then
            return;
         end if;
         Parent (B) := A;
         First_At (A) := Natural'Min (First_At (A), First_At (B));
         Last_At (A) := Natural'Max (Last_At (A), Last_At (B));
         Weight (A) := Weight (A) + Weight (B);
         Occurrences (A) := Occurrences (A) + Occurrences (B);
         Forced (A) := Forced (A) or else Forced (B);
         if Hint (A) = 0 then
            Hint (A) := Hint (B);
         end if;
      end Join;

      function Live (Block, Global : Positive) return Boolean
        is (Live_In ((Block - 1) * Global_Count + Global));

      function In_Node (Block, Global : Positive) return Positive;
      function In_Node (Block, Global : Positive) return Positive is
         Key : constant Natural := (Block - 1) * Global_Count + Global;
         Found : constant Node_Maps.Cursor := In_Nodes.Find (Key);
      begin
         if Node_Maps.Has_Element (Found) then
            return Node_Maps.Element (Found);
         end if;
         declare
            Made : constant Positive :=
              New_Node (Global_Word (Global), Block = 1);
         begin
            In_Nodes.Insert (Key, Made);
            Extend (Made, 2 * Block_First (Block));
            return Made;
         end;
      end In_Node;

      function Has_Home (Word : Positive) return Boolean is
        (declare
            Number : constant Natural := Word_Of (Word);
         begin
           (if Number >= First_Value_Word
            then Number - First_Value_Word <= Of_Routine.Homes.Last_Index
              and then Of_Routine.Homes (Number - First_Value_Word).Declared
            else Number in 10 .. 17 | 19 .. 25 | 27 .. 31));

      function Home_Offset (Word : Positive) return Long_Long_Integer is
        (declare
            Number : constant Natural := Word_Of (Word);
         begin
           (if Number >= First_Value_Word
            then Long_Long_Integer
              (Of_Routine.Homes (Number - First_Value_Word).Offset)
            else Long_Long_Integer (Word_Offset (Number, True))));

      function Home_Bytes (Word : Positive) return Positive is
        (declare
            Number : constant Natural := Word_Of (Word);
         begin
           (if Number >= First_Value_Word
            then Of_Routine.Homes (Number - First_Value_Word).Bytes
            else 4));

      Register_Of : Natural_Vectors.Vector;
      --  How many definitions each web has, and the step of its last.
      Defined, Defined_At : Natural_Vectors.Vector;
      Crosses : Flag_Vectors.Vector;
      Calls_Upto : Natural_Vectors.Vector;
   begin
      Placed := False;
      Registers := 0;
      --  A routine this long is selected word by word: its steps alone
      --  would take hundreds of megabytes.
      if Natural (Of_Routine.Lines.Length) > 150_000 then
         raise Not_Placed;
      end if;
      --  Steps, labels and blocks.
      Block_First.Append (1);
      for Index in 1 .. Natural (Of_Routine.Lines.Length) loop
         declare
            Held : constant Buffered := Of_Routine.Lines (Index);
            Text : constant String := U.To_String (Held.Text);
            Made : Step;
         begin
            if Held.Kind = Line then
               Made.Text := Held.Text;
               if Text'Length > 1 and then Text (Text'Last) = ':'
                 and then Text (Text'First) not in ' ' | HT
               then
                  if Index > 1 then
                     Block_Last.Append (Index - 1);
                     Block_First.Append (Index);
                  end if;
                  Labels.Include
                    (Text (Text'First .. Text'Last - 1),
                     Natural (Block_First.Length));
               elsif Trim (Text)'Length = 0
                 or else Trim (Text) (Trim (Text)'First) /= '.'
               then
                  --  A native line in the body names registers placement
                  --  cannot see.
                  raise Not_Placed;
               end if;
            else
               declare
                  Space : constant Natural :=
                    Ada.Strings.Fixed.Index (Text, " ");
                  Rest : constant String :=
                    (if Space = 0 then "" else Text (Space + 1 .. Text'Last));
                  Start : Positive := Rest'First;
               begin
                  Made.Instruction := True;
                  Made.Text := Held.Text;
                  Made.Op := U.To_Unbounded_String
                    (if Space = 0 then Text
                     else Text (Text'First .. Space - 1));
                  if Rest'Length > 0 then
                     for Position in Rest'First .. Rest'Last + 1 loop
                        if Position > Rest'Last or else Rest (Position) = ','
                        then
                           Made.Count := Made.Count + 1;
                           if Made.Count > Made.Args'Length then
                              raise Not_Placed;
                           end if;
                           Made.Args (Made.Count) := U.To_Unbounded_String
                             (Trim (Rest (Start .. Position - 1)));
                           Start := Position + 1;
                        end if;
                     end loop;
                  end if;
                  Parse (Made);
               end;
            end if;
            Steps.Append (Made);
         end;
      end loop;
      if Steps.Is_Empty then
         raise Not_Placed;
      end if;
      Block_Last.Append (Natural (Steps.Length));
      Block_Count := Natural (Block_First.Length);
      Word_Count := Natural'Max (1, Natural (Word_Of.Length));
      for Index in 1 .. Natural (Steps.Length) loop
         declare
            At_Step : Step renames Steps (Index);
         begin
            if At_Step.Kind in Branch | Jump then
               declare
                  Name : constant String := U.To_String
                    (At_Step.Args (if At_Step.Kind = Jump then 1
                                   else At_Step.Count));
               begin
                  if not Labels.Contains (Name) then
                     raise Not_Placed;
                  end if;
                  At_Step.Target := Labels.Element (Name);
               end;
            end if;
         end;
      end loop;

      --  Each step's loop depth: a branch back to a block at or before it
      --  closes a loop over the steps between.
      declare
         Opened, Closed : Natural_Vectors.Vector;
         Running : Natural := 0;
      begin
         Opened.Append (0, Steps.Length + 1);
         Closed.Append (0, Steps.Length + 1);
         for Index in 1 .. Natural (Steps.Length) loop
            if Steps (Index).Kind in Branch | Jump
              and then Block_First (Steps (Index).Target) <= Index
            then
               Opened (Block_First (Steps (Index).Target)) :=
                 Opened (Block_First (Steps (Index).Target)) + 1;
               Closed (Index + 1) := Closed (Index + 1) + 1;
            end if;
         end loop;
         for Index in 1 .. Natural (Steps.Length) loop
            Running := Running + Opened (Index) - Closed (Index);
            Depth.Append (Running);
         end loop;
      end;

      --  The words some block reads before it writes them.
      Global_Of := new Natural_Array'(1 .. Word_Count => 0);
      declare
         Stamp : Natural_Access := new Natural_Array'(1 .. Word_Count => 0);
         Segment : Natural := 0;
      begin
         for Block in 1 .. Block_Count loop
            Segment := Segment + 1;
            for Index in Natural'(Block_First (Block)) .. Block_Last (Block)
            loop
               declare
                  At_Step : Step renames Steps (Index);
               begin
                  if At_Step.Instruction then
                     for Which in 1 .. At_Step.Use_Count loop
                        declare
                           Word : constant Positive := At_Step.Uses (Which);
                        begin
                           if Stamp (Word) /= Segment
                             and then Global_Of (Word) = 0
                           then
                              Global_Count := Global_Count + 1;
                              Global_Of (Word) := Global_Count;
                              Global_Word.Append (Word);
                           end if;
                        end;
                     end loop;
                     for Which in 1 .. At_Step.Def_Count loop
                        Stamp (At_Step.Defs (Which)) := Segment;
                     end loop;
                     if At_Step.Kind in Jump | Stop | Leave then
                        Segment := Segment + 1;
                     end if;
                  end if;
               end;
            end loop;
         end loop;
         Free (Stamp);
      end;
      if Long_Long_Integer (Block_Count)
        * Long_Long_Integer (Natural'Max (1, Global_Count)) > 2 ** 26
      then
         raise Not_Placed;
      end if;

      --  Liveness over the blocks, to a fixed point, of those words.
      declare
         G : constant Natural := Natural'Max (1, Global_Count);
         function Slice_Of (Block : Positive) return Bit_Array
           is (Live_In ((Block - 1) * G + 1 .. Block * G));
         Changed : Boolean := True;
      begin
         Live_In := new Bit_Array'(1 .. Block_Count * G => False);
         Scratch := new Bit_Array'(1 .. G => False);
         while Changed loop
            Changed := False;
            for Block in reverse 1 .. Block_Count loop
               if Block < Block_Count then
                  Scratch.all := Slice_Of (Block + 1);
               else
                  Scratch.all := [others => False];
               end if;
               for Index in reverse
                 Natural'(Block_First (Block)) .. Block_Last (Block)
               loop
                  declare
                     At_Step : Step renames Steps (Index);
                  begin
                     if At_Step.Instruction then
                        case At_Step.Kind is
                           when Jump =>
                              Scratch.all := Slice_Of (At_Step.Target);
                           when Stop | Leave =>
                              Scratch.all := [others => False];
                           when Branch =>
                              Scratch.all := Scratch.all
                                or Slice_Of (At_Step.Target);
                           when others =>
                              null;
                        end case;
                        for Which in 1 .. At_Step.Def_Count loop
                           if Global_Of (At_Step.Defs (Which)) /= 0 then
                              Scratch (Global_Of (At_Step.Defs (Which))) :=
                                False;
                           end if;
                        end loop;
                        for Which in 1 .. At_Step.Use_Count loop
                           if Global_Of (At_Step.Uses (Which)) /= 0 then
                              Scratch (Global_Of (At_Step.Uses (Which))) :=
                                True;
                           end if;
                        end loop;
                     end if;
                  end;
               end loop;
               if Scratch.all /= Slice_Of (Block) then
                  Live_In ((Block - 1) * G + 1 .. Block * G) := Scratch.all;
                  Changed := True;
               end if;
            end loop;
         end loop;
      end;

      --  Webs: each use joins the definitions that reach it.  Current is
      --  cleared where a block or a terminator touched it.
      Current := new Natural_Array'(1 .. Word_Count => 0);
      declare
         Touched : Natural_Vectors.Vector;
         procedure Clear;
         procedure Clear is
         begin
            for Word of Touched loop
               Current (Word) := 0;
            end loop;
            Touched.Clear;
         end Clear;
         procedure Set (Word, Node : Positive);
         procedure Set (Word, Node : Positive) is
         begin
            if Current (Word) = 0 then
               Touched.Append (Word);
            end if;
            Current (Word) := Node;
         end Set;
      begin
         for Block in 1 .. Block_Count loop
            declare
               Terminated : Boolean := False;
               procedure Edge (Into_Block : Positive; Position : Natural);
               procedure Edge (Into_Block : Positive; Position : Natural)
               is
               begin
                  for Global in 1 .. Global_Count loop
                     if Live (Into_Block, Global) then
                        declare
                           Word : constant Positive := Global_Word (Global);
                        begin
                           if Current (Word) = 0 then
                              Set (Word, New_Node (Word, True));
                           end if;
                           Join (Current (Word), In_Node (Into_Block, Global));
                           Extend (Current (Word), Position);
                        end;
                     end if;
                  end loop;
               end Edge;
            begin
               Clear;
               for Global in 1 .. Global_Count loop
                  if Live (Block, Global) then
                     Set (Global_Word (Global), In_Node (Block, Global));
                  end if;
               end loop;
               for Index in Natural'(Block_First (Block))
                 .. Block_Last (Block)
               loop
                  declare
                     At_Step : Step renames Steps (Index);
                     Cost : constant Natural :=
                       8 ** Natural'Min (3, Depth (Index));
                  begin
                     if At_Step.Instruction then
                        for Which in 1 .. At_Step.Use_Count loop
                           declare
                              Word : constant Positive :=
                                At_Step.Uses (Which);
                           begin
                              if Current (Word) = 0 then
                                 Set (Word, New_Node (Word, True));
                              end if;
                              At_Step.Use_Nodes (Which) := Current (Word);
                              Extend (Current (Word), 2 * Index);
                              Weight (Root (Current (Word))) :=
                                Weight (Root (Current (Word))) + Cost;
                              Occurrences (Root (Current (Word))) :=
                                Occurrences (Root (Current (Word))) + 1;
                           end;
                        end loop;
                        if At_Step.Kind in Branch | Jump then
                           Edge (At_Step.Target, 2 * Index + 1);
                        end if;
                        for Which in 1 .. At_Step.Def_Count loop
                           declare
                              Word : constant Positive :=
                                At_Step.Defs (Which);
                              Made : constant Positive := New_Node (Word);
                           begin
                              Set (Word, Made);
                              At_Step.Def_Nodes (Which) := Made;
                              Extend (Made, 2 * Index + 1);
                              Weight (Made) := Weight (Made) + Cost;
                           end;
                        end loop;
                        Terminated := At_Step.Kind in Jump | Stop | Leave;
                        if Terminated then
                           Clear;
                        end if;
                     end if;
                  end;
               end loop;
               if not Terminated and then Block < Block_Count then
                  Edge (Block + 1, 2 * Block_Last (Block) + 1);
               end if;
            end;
         end loop;
      end;

      --  A web defined once, by `li` of a number, is that number: a `mul`
      --  by a power of two is a shift and an `add` of a small one an
      --  `addi`, and the `li` is then unread.
      declare
         function Numeric (Text : String) return Boolean is
           (Text'Length > 0 and then Text'Length < 18
            and then (for all Index in Text'Range =>
                        Text (Index) in '0' .. '9'
                        or else (Index = Text'First
                                 and then Text (Index) = '-')));
         --  The number Node's web always holds, when it holds one: a web
         --  defined once, by `li` of a number or a copy of such a web.
         function Constant_Of
           (Node : Positive; Known : out Boolean; Depth : Natural := 0)
           return Long_Long_Integer;
         function Constant_Of
           (Node : Positive; Known : out Boolean; Depth : Natural := 0)
           return Long_Long_Integer
         is
            Web : constant Positive := Root (Node);
         begin
            Known := False;
            if Defined (Web) /= 1 or else Forced (Web) or else Depth > 8 then
               return 0;
            end if;
            declare
               At_Step : Step renames Steps (Defined_At (Web));
            begin
               if U.To_String (At_Step.Op) = "li"
                 and then Numeric (U.To_String (At_Step.Args (2)))
               then
                  Known := True;
                  return Long_Long_Integer'Value
                    (U.To_String (At_Step.Args (2)));
               elsif U.To_String (At_Step.Op) in "mv" | "sext.w"
                 and then At_Step.Use_Count = 1
               then
                  return Constant_Of
                    (At_Step.Use_Nodes (1), Known, Depth + 1);
               end if;
            end;
            return 0;
         end Constant_Of;
      begin
         Defined.Append (0, Parent.Length);
         Defined_At.Append (0, Parent.Length);
         for Index in 1 .. Natural (Steps.Length) loop
            for Which in 1 .. Steps (Index).Def_Count loop
               declare
                  Web : constant Positive :=
                    Root (Steps (Index).Def_Nodes (Which));
               begin
                  Defined (Web) := Defined (Web) + 1;
                  Defined_At (Web) := Index;
               end;
            end loop;
         end loop;
         for Index in 1 .. Natural (Steps.Length) loop
            declare
               At_Step : Step renames Steps (Index);
               Op : constant String := U.To_String (At_Step.Op);
            begin
               --  A zero test of a number is decided.
               if At_Step.Kind = Branch and then Op in "beqz" | "bnez"
                 and then At_Step.Use_Count = 1
               then
                  declare
                     Known : Boolean;
                     Value : constant Long_Long_Integer :=
                       Constant_Of (At_Step.Use_Nodes (1), Known);
                  begin
                     if Known and then (Value = 0) = (Op = "bnez") then
                        At_Step.Dead := True;
                        Occurrences (Root (At_Step.Use_Nodes (1))) :=
                          Occurrences (Root (At_Step.Use_Nodes (1))) - 1;
                     end if;
                  end;
               end if;
               if Op in "mul" | "add" | "divu" | "remu"
                 and then At_Step.Use_Count = 2
                 and then At_Step.Use_Arg (1) = 2
                 and then At_Step.Use_Arg (2) = 3
               then
                  for Which in reverse 1 .. 2 loop
                     declare
                        Known : Boolean;
                        Value : constant Long_Long_Integer :=
                          Constant_Of (At_Step.Use_Nodes (Which), Known);
                     begin
                        if not Known or else At_Step.Folded /= 0
                          or else (Op in "divu" | "remu"
                                   and then At_Step.Use_Arg (Which) /= 3)
                        then
                           null;
                        elsif Op in "mul" | "divu" | "remu" and then Value > 0
                          and then Value <= 2 ** 30
                          and then (for some Power in 0 .. 30 =>
                                      2 ** Power = Value)
                        then
                           for Power in 0 .. 30 loop
                              if 2 ** Power = Value then
                                 At_Step.Shift := Power;
                              end if;
                           end loop;
                           At_Step.Folded := 5 - At_Step.Use_Arg (Which);
                        elsif Op = "add" and then Value in -128 .. 127 then
                           At_Step.Addend := Value;
                           At_Step.Folded := 5 - At_Step.Use_Arg (Which);
                        end if;
                        if At_Step.Folded = 5 - At_Step.Use_Arg (Which) then
                           Occurrences (Root (At_Step.Use_Nodes (Which))) :=
                             Occurrences (Root (At_Step.Use_Nodes (Which)))
                             - 1;
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;
      end;

      --  Operations without effect whose results nothing reads are not
      --  selected, nor what only they read: the emitter computes flags
      --  each operation could need, and most go unread.
      loop
         declare
            Changed : Boolean := False;
         begin
            --  Backwards, so that a chain of them goes in one pass.
            for Index in reverse 1 .. Natural (Steps.Length) loop
               declare
                  At_Step : Step renames Steps (Index);
               begin
                  if At_Step.Instruction and then not At_Step.Dead
                    and then not At_Step.Tested
                    and then At_Step.Kind = Plain
                    and then At_Step.Def_Count > 0
                    and then U.To_String (At_Step.Op) in "li" | "lui" | "la"
                      | "lla" | "mv" | "sext.w" | "neg" | "not" | "zext.b"
                      | "zext.h" | "add" | "sub" | "mul" | "mulhu" | "mulh"
                      | "and" | "or" | "xor" | "addi" | "andi" | "ori"
                      | "xori" | "sll" | "srl" | "sra" | "slli" | "srli"
                      | "srai" | "seqz" | "snez" | "sgtz" | "sltu" | "slt"
                      | "slti" | "sltiu"
                    and then (for all Which in 1 .. At_Step.Def_Count =>
                                Occurrences (Root (At_Step.Def_Nodes (Which)))
                                  = 0)
                  then
                     At_Step.Dead := True;
                     Changed := True;
                     for Which in 1 .. At_Step.Use_Count loop
                        --  A folded constant's read was counted off.
                        if At_Step.Folded = 0
                          or else At_Step.Use_Arg (Which) = At_Step.Folded
                        then
                           Occurrences (Root (At_Step.Use_Nodes (Which))) :=
                             Occurrences (Root (At_Step.Use_Nodes (Which)))
                             - 1;
                        end if;
                     end loop;
                  end if;
               end;
            end loop;
            exit when not Changed;
         end;
      end loop;

      --  A comparison's truth value only the zero test after it reads is
      --  that test: `sltu` then `bnez` is `bltu`.  Between the two there
      --  may be only operations already dropped, and the comparison's
      --  operands live to the branch.
      for Index in 1 .. Natural (Steps.Length) loop
         declare
            Compare_Step : Step renames Steps (Index);
            Op : constant String := U.To_String (Compare_Step.Op);
            Next : Natural := Index + 1;
         begin
            if Compare_Step.Instruction and then not Compare_Step.Dead
              and then Op in "sltu" | "slt" | "seqz" | "snez" | "slti"
                | "sltiu"
              and then Compare_Step.Def_Count = 1
            then
               while Next <= Natural (Steps.Length)
                 and then (Steps (Next).Dead
                           or else (not Steps (Next).Instruction
                                    and then Directive
                                      (U.To_String (Steps (Next).Text))))
               loop
                  Next := Next + 1;
               end loop;
               if Next <= Natural (Steps.Length)
                 and then Steps (Next).Instruction
                 and then U.To_String (Steps (Next).Op) in "beqz" | "bnez"
                 and then Steps (Next).Use_Count = 1
                 and then Root (Steps (Next).Use_Nodes (1))
                   = Root (Compare_Step.Def_Nodes (1))
                 and then Occurrences (Root (Compare_Step.Def_Nodes (1))) = 1
                 and then Defined (Root (Compare_Step.Def_Nodes (1))) = 1
               then
                  Compare_Step.Tested := True;
                  Steps (Next).Tests := Index;
                  Occurrences (Root (Steps (Next).Use_Nodes (1))) := 0;
                  for Which in 1 .. Compare_Step.Use_Count loop
                     Extend (Compare_Step.Use_Nodes (Which), 2 * Next);
                  end loop;
               end if;
            end if;
         end;
      end loop;

      --  Which webs live across a call: from before it to after it.
      Calls_Upto.Append (0, Steps.Length + 1);
      for Index in 1 .. Natural (Steps.Length) loop
         Calls_Upto (Index + 1) := Calls_Upto (Index)
           + (if Steps (Index).Kind = Call then 1 else 0);
      end loop;
      Register_Of.Append (0, Parent.Length);
      Crosses.Append (False, Parent.Length);
      for Node in 1 .. Natural (Parent.Length) loop
         if Root (Node) = Node and then Last_At (Node) >= 2 then
            declare
               --  A call at step C lies within when 2C > First and
               --  2C + 1 < Last.
               Low : constant Natural := First_At (Node) / 2 + 1;
               High : constant Natural := (Last_At (Node) - 2) / 2;
            begin
               if Low <= High and then High <= Natural (Steps.Length) then
                  Crosses (Node) :=
                    Calls_Upto (High + 1) - Calls_Upto (Low) > 0;
               end if;
            end;
         end if;
      end loop;

      --  Hints: where a call or the routine's entry and exit want a word.
      for Index in 1 .. Natural (Steps.Length) loop
         declare
            At_Step : Step renames Steps (Index);
            procedure Want (Node : Natural; Register : Physical);
            procedure Want (Node : Natural; Register : Physical) is
            begin
               if Node /= 0 and then Hint (Root (Node)) = 0 then
                  Hint (Root (Node)) := Register;
               end if;
            end Want;
         begin
            case At_Step.Kind is
               when Call =>
                  for Which in 1 .. At_Step.Use_Count loop
                     if At_Step.Use_Arg (Which) = 0 then
                        Want (At_Step.Use_Nodes (Which),
                              Word_Of (At_Step.Uses (Which)));
                     end if;
                  end loop;
                  for Which in 1 .. At_Step.Def_Count loop
                     Want (At_Step.Def_Nodes (Which),
                           (if Word_Of (At_Step.Defs (Which)) = 31 then 14
                            else Word_Of (At_Step.Defs (Which))));
                  end loop;
               when Enter =>
                  for Which in 1 .. At_Step.Def_Count loop
                     if Word_Of (At_Step.Defs (Which)) <= 14 then
                        Want (At_Step.Def_Nodes (Which),
                              Word_Of (At_Step.Defs (Which)) - 8);
                     end if;
                  end loop;
               when Leave =>
                  for Which in 1 .. At_Step.Use_Count loop
                     Want (At_Step.Use_Nodes (Which),
                           (if Word_Of (At_Step.Uses (Which)) = 31 then 6
                            else Word_Of (At_Step.Uses (Which)) - 8));
                  end loop;
               when others =>
                  null;
            end case;
         end;
      end loop;

      --  Linear scan over the webs in order of their first position.
      declare
         Partner_A, Partner_B : Natural_Vectors.Vector;
         --  A web that only copies another's value reads it in the
         --  other's register while that one is not written: its owner,
         --  and how many read each owner's.
         Owner, Sharers : Natural_Vectors.Vector;
         Order_Count : Natural := 0;
         Order : Natural_Access :=
           new Natural_Array (1 .. Natural'Max (1, Natural (Parent.Length)));
         Open : Physical_Flags := Placeable;
         Active : Natural_Vectors.Vector;
         Used : Physical_Flags := [others => False];

         function Before (Left, Right : Natural) return Boolean
           is (First_At (Left) < First_At (Right)
               or else (First_At (Left) = First_At (Right)
                        and then Left < Right));
         procedure Sort is new Ada.Containers.Generic_Array_Sort
           (Positive, Natural, Natural_Array, Before);

         --  Whether Left is the cheaper web to leave in its home: fewer
         --  weighted occurrences for each position it holds a register.
         function Cheaper (Left, Right : Positive) return Boolean
           is (Long_Long_Integer (Weight (Left))
                 * Long_Long_Integer (Last_At (Right) - First_At (Right) + 1)
               < Long_Long_Integer (Weight (Right))
                 * Long_Long_Integer (Last_At (Left) - First_At (Left) + 1));

         procedure Partner (Left, Right : Positive);
         procedure Partner (Left, Right : Positive) is
         begin
            if Partner_A (Left) = 0 then
               Partner_A (Left) := Right;
            elsif Partner_B (Left) = 0 then
               Partner_B (Left) := Right;
            end if;
         end Partner;
      begin
         Partner_A.Append (0, Parent.Length);
         Partner_B.Append (0, Parent.Length);
         Owner.Append (0, Parent.Length);
         Sharers.Append (0, Parent.Length);
         for Index in 1 .. Natural (Steps.Length) loop
            declare
               At_Step : Step renames Steps (Index);
            begin
               if At_Step.Instruction
                 and then U.To_String (At_Step.Op) in "mv" | "sext.w"
                 and then At_Step.Use_Count = 1 and then At_Step.Def_Count = 1
               then
                  Partner (Root (At_Step.Use_Nodes (1)),
                           Root (At_Step.Def_Nodes (1)));
                  Partner (Root (At_Step.Def_Nodes (1)),
                           Root (At_Step.Use_Nodes (1)));
               end if;
            end;
         end loop;
         for Node in 1 .. Natural (Parent.Length) loop
            if Root (Node) = Node then
               if Forced (Node) then
                  if not Has_Home (Node_Word (Node)) then
                     raise Not_Placed;
                  end if;
               elsif Occurrences (Node) > 0 then
                  Order_Count := Order_Count + 1;
                  Order (Order_Count) := Node;
               end if;
            end if;
         end loop;
         Sort (Order (1 .. Order_Count));
         for Index in 1 .. Order_Count loop
            declare
               Web : constant Positive := Order (Index);
               Class : constant Physical_Flags :=
                 (if Crosses (Web) then Preserved else Placeable);
               Choice : Natural := 0;
               procedure Try (Register : Natural);
               procedure Try (Register : Natural) is
               begin
                  if Choice = 0 and then Register in Physical
                    and then Class (Register) and then Open (Register)
                  then
                     Choice := Register;
                  end if;
               end Try;
            begin
               for Held in reverse 1 .. Natural (Active.Length) loop
                  if Last_At (Active (Held)) < First_At (Web) then
                     Open (Register_Of (Active (Held))) := True;
                     Active.Delete (Held);
                  end if;
               end loop;
               --  The copy's source, or that source's own owner.
               if Defined (Web) = 1
                 and then U.To_String (Steps (Defined_At (Web)).Op)
                   in "mv" | "sext.w"
                 and then Steps (Defined_At (Web)).Use_Count = 1
               then
                  declare
                     Source : constant Positive :=
                       Root (Steps (Defined_At (Web)).Use_Nodes (1));
                     Held : constant Positive :=
                       (if Owner (Source) /= 0 then Owner (Source)
                        else Source);
                     Written : Boolean := False;
                  begin
                     if Held /= Web and then Register_Of (Held) /= 0
                       and then Class (Register_Of (Held))
                       and then First_At (Held) <= First_At (Web)
                       and then Last_At (Web) <= Last_At (Held)
                       and then Last_At (Web) - First_At (Web) <= 4000
                     then
                        for At_Step in First_At (Web) / 2
                          .. Natural'Min (Last_At (Web) / 2,
                                          Natural (Steps.Length))
                        loop
                           for Which in 1 .. Steps (At_Step).Def_Count loop
                              if Root (Steps (At_Step).Def_Nodes (Which))
                                = Held
                              then
                                 Written := True;
                              end if;
                           end loop;
                        end loop;
                        if not Written then
                           Register_Of (Web) := Register_Of (Held);
                           Owner (Web) := Held;
                           Sharers (Held) := Sharers (Held) + 1;
                           goto Placed_Web;
                        end if;
                     end if;
                  end;
               end if;
               if Partner_A (Web) /= 0 then
                  Try (Register_Of (Partner_A (Web)));
               end if;
               if Partner_B (Web) /= 0 then
                  Try (Register_Of (Partner_B (Web)));
               end if;
               Try (Hint (Web));
               if not Crosses (Web) then
                  for Register in 10 .. 15 loop
                     Try (Register);
                  end loop;
               end if;
               for Register in 2 .. 6 loop
                  Try (Register);
               end loop;
               if Choice = 0 then
                  declare
                     Victim : Natural := 0;
                     Victim_At : Natural := 0;
                  begin
                     for Held in 1 .. Natural (Active.Length) loop
                        --  A web with no home, a scratch word's, takes the
                        --  register of the cheapest that has one.
                        if Class (Register_Of (Active (Held)))
                          and then Sharers (Active (Held)) = 0
                          and then Has_Home (Node_Word (Active (Held)))
                          and then (if Victim /= 0
                                    then Cheaper (Active (Held), Victim)
                                    elsif Has_Home (Node_Word (Web))
                                    then Cheaper (Active (Held), Web)
                                    else True)
                        then
                           Victim := Active (Held);
                           Victim_At := Held;
                        end if;
                     end loop;
                     if Victim /= 0 then
                        Choice := Register_Of (Victim);
                        Register_Of (Victim) := 0;
                        Active.Delete (Victim_At);
                        Open (Choice) := True;
                     elsif not Has_Home (Node_Word (Web)) then
                        raise Not_Placed;
                     end if;
                  end;
               end if;
               if Choice /= 0 then
                  Register_Of (Web) := Choice;
                  Open (Choice) := False;
                  Used (Choice) := True;
                  Active.Append (Web);
               end if;
               <<Placed_Web>>
            end;
         end loop;
         Free (Order);
         for Register in Physical loop
            if Used (Register) then
               Registers := Registers + 1;
            end if;
         end loop;
      end;

      --  Selection.
      declare
         Far : constant Boolean := Natural (Steps.Length) * 16 > 120_000;
         Frame : constant Long_Long_Integer :=
           Long_Long_Integer (Of_Routine.Frame_Bytes);

         type Place_Kind is (In_Register, In_Home, Nowhere, Zero_Word,
                             Stack_Word, Frame_Word);
         type Location is record
            Kind : Place_Kind := Nowhere;
            Register : Natural := 0;
            Offset : Long_Long_Integer := 0;
            Bytes : Positive := 4;
         end record;

         procedure Raw (Line : String);
         procedure Raw (Line : String) is
         begin
            U.Append (Output, HT & Line & LF);
         end Raw;
         function Fresh return String;
         function Fresh return String is
         begin
            Labels_Made := Labels_Made + 1;
            return ".Lxtensa_word_" & Image (Labels_Made);
         end Fresh;
         function Name (Register : Natural) return String
           is ("a" & Image (Register));

         function Of_Node (Node : Natural) return Location;
         function Of_Node (Node : Natural) return Location is
            Web : constant Positive := Root (Node);
         begin
            if Register_Of (Web) /= 0 then
               return (In_Register, Register_Of (Web), 0, 4);
            elsif Occurrences (Web) = 0 and then not Forced (Web) then
               return (Kind => Nowhere, others => <>);
            end if;
            return (In_Home, 0, Home_Offset (Node_Word (Web)),
                    Home_Bytes (Node_Word (Web)));
         end Of_Node;

         --  The location of an instruction's Index'th argument.
         function Argument (At_Step : Step; Index : Positive)
           return Location;
         function Argument (At_Step : Step; Index : Positive)
           return Location
         is
            Text : constant String := U.To_String (At_Step.Args (Index));
            Word : constant Natural := Word_Number
              (if Ada.Strings.Fixed.Index (Text, "(") /= 0
               then Base_Of (Text) else Text);
         begin
            if Word = 0 then
               return (Kind => Zero_Word, others => <>);
            elsif Word = 2 then
               return (Kind => Stack_Word, others => <>);
            elsif Word = 8 then
               return (Kind => Frame_Word, others => <>);
            end if;
            for Which in 1 .. At_Step.Def_Count loop
               if At_Step.Def_Arg (Which) = Index then
                  return Of_Node (At_Step.Def_Nodes (Which));
               end if;
            end loop;
            for Which in 1 .. At_Step.Use_Count loop
               if At_Step.Use_Arg (Which) = Index then
                  return Of_Node (At_Step.Use_Nodes (Which));
               end if;
            end loop;
            raise Compiler_Defect with "Xtensa word without a place";
         end Argument;

         procedure Load_Home
           (Into_Register : String; Offset : Long_Long_Integer;
            Bytes : Positive);
         procedure Load_Home
           (Into_Register : String; Offset : Long_Long_Integer;
            Bytes : Positive) is
         begin
            if In_Reach (Offset, Bytes) then
               Raw (Load_Op (Bytes) & " " & Into_Register & ", a7, "
                    & Trim (Offset'Image));
            else
               Raw ("movi " & Into_Register & ", " & Trim (Offset'Image));
               Raw ("add " & Into_Register & ", " & Into_Register & ", a7");
               Raw (Load_Op (Bytes) & " " & Into_Register & ", "
                    & Into_Register & ", 0");
            end if;
         end Load_Home;

         procedure Store_Home
           (Value : String; Offset : Long_Long_Integer; Bytes : Positive);
         procedure Store_Home
           (Value : String; Offset : Long_Long_Integer; Bytes : Positive)
         is
            Address : constant String :=
              (if Value = "a9" then "a8" else "a9");
         begin
            if In_Reach (Offset, Bytes) then
               Raw (Store_Op (Bytes) & " " & Value & ", a7, "
                    & Trim (Offset'Image));
            else
               Raw ("movi " & Address & ", " & Trim (Offset'Image));
               Raw ("add " & Address & ", " & Address & ", a7");
               Raw (Store_Op (Bytes) & " " & Value & ", " & Address & ", 0");
            end if;
         end Store_Home;

         procedure Frame_Into (Register : String);
         procedure Frame_Into (Register : String) is
         begin
            if Frame <= 127 then
               Raw ("addi " & Register & ", a7, " & Trim (Frame'Image));
            else
               Raw ("movi " & Register & ", " & Trim (Frame'Image));
               Raw ("add " & Register & ", a7, " & Register);
            end if;
         end Frame_Into;

         --  A register holding Where's value, loaded into Temporary if
         --  it has none.
         function Source (Where : Location; Temporary : String)
           return String;
         function Source (Where : Location; Temporary : String)
           return String is
         begin
            case Where.Kind is
               when In_Register =>
                  return Name (Where.Register);
               when In_Home =>
                  Load_Home (Temporary, Where.Offset, Where.Bytes);
               when Zero_Word =>
                  Raw ("movi " & Temporary & ", 0");
               when Stack_Word =>
                  return "a1";
               when Frame_Word =>
                  Frame_Into (Temporary);
               when Nowhere =>
                  raise Compiler_Defect with "Xtensa word read unplaced";
            end case;
            return Temporary;
         end Source;

         function Target (Where : Location) return String
           is (if Where.Kind = In_Register then Name (Where.Register)
               else "a8");

         procedure Settle (Where : Location; Value : String);
         procedure Settle (Where : Location; Value : String) is
         begin
            case Where.Kind is
               when In_Register =>
                  if Name (Where.Register) /= Value then
                     Raw ("mov " & Name (Where.Register) & ", " & Value);
                  end if;
               when In_Home =>
                  Store_Home (Value, Where.Offset, Where.Bytes);
               when others =>
                  null;
            end case;
         end Settle;

         procedure Jump_To (Label : String);
         procedure Jump_To (Label : String) is
         begin
            if Far then
               Raw ("movi a8, " & Label);
               Raw ("jx a8");
            else
               Raw ("j " & Label);
            end if;
         end Jump_To;

         --  Registers moved at once, Into (I) receiving From (I).
         type Move_List is array (1 .. 8) of Natural;
         procedure Parallel
           (Into_Registers, From_Registers : Move_List; Count : Natural);
         procedure Parallel
           (Into_Registers, From_Registers : Move_List; Count : Natural)
         is
            Into_Set : constant Move_List := Into_Registers;
            From_Set : Move_List := From_Registers;
            Pending : array (1 .. 8) of Boolean := [others => False];
            Left : Natural := 0;
         begin
            for Index in 1 .. Count loop
               if Into_Set (Index) /= From_Set (Index) then
                  Pending (Index) := True;
                  Left := Left + 1;
               end if;
            end loop;
            while Left > 0 loop
               declare
                  Progress : Boolean := False;
               begin
                  for Index in 1 .. Count loop
                     if Pending (Index)
                       and then (for all Other in 1 .. Count =>
                                   not Pending (Other) or else Other = Index
                                   or else From_Set (Other)
                                     /= Into_Set (Index))
                     then
                        Raw ("mov " & Name (Into_Set (Index)) & ", "
                             & Name (From_Set (Index)));
                        Pending (Index) := False;
                        Left := Left - 1;
                        Progress := True;
                     end if;
                  end loop;
                  if not Progress then
                     --  Only cycles remain: free one destination into a8.
                     for Index in 1 .. Count loop
                        if Pending (Index) then
                           Raw ("mov a8, " & Name (Into_Set (Index)));
                           for Other in 1 .. Count loop
                              if Pending (Other)
                                and then From_Set (Other) = Into_Set (Index)
                              then
                                 From_Set (Other) := 8;
                              end if;
                           end loop;
                           exit;
                        end if;
                     end loop;
                  end if;
               end;
            end loop;
         end Parallel;

         procedure Select_Step (At_Step : Step);
         procedure Select_Step (At_Step : Step) is
            Op : constant String := U.To_String (At_Step.Op);
            function Arg (Index : Positive) return String
              is (U.To_String (At_Step.Args (Index)));
            function Place (Index : Positive) return Location
              is (Argument (At_Step, Index));
            function Numeric (Text : String) return Boolean is
              (Text'Length > 0
               and then (for all Index in Text'Range =>
                           Text (Index) in '0' .. '9'
                           or else (Index = Text'First
                                    and then Text (Index) = '-')));
            function Small (Text : String) return Boolean is
              (Numeric (Text)
               and then Long_Long_Integer'Value (Text) in -128 .. 127);

            procedure Boolean_Of
              (Condition, Left, Right : String; Result : Location);
            --  Result is one when Condition holds of Left and Right.
            procedure Boolean_Of
              (Condition, Left, Right : String; Result : Location)
            is
               Into_Register : constant String := Target (Result);
               Done : constant String := Fresh;
            begin
               if Into_Register /= Left and then Into_Register /= Right then
                  Raw ("movi " & Into_Register & ", 1");
                  Raw (Condition & " " & Left & ", "
                       & (if Right = "" then "" else Right & ", ") & Done);
                  Raw ("movi " & Into_Register & ", 0");
                  U.Append (Output, Done & ":" & LF);
                  Settle (Result, Into_Register);
               else
                  declare
                     Yes : constant String := Fresh;
                  begin
                     Raw (Condition & " " & Left & ", "
                          & (if Right = "" then "" else Right & ", ") & Yes);
                     Raw ("movi a8, 0");
                     Raw ("j " & Done);
                     U.Append (Output, Yes & ":" & LF);
                     Raw ("movi a8, 1");
                     U.Append (Output, Done & ":" & LF);
                     Settle (Result, "a8");
                  end;
               end if;
            end Boolean_Of;
         begin
            if Op in "li" | "lui" | "la" | "lla" then
               declare
                  Result : constant Location := Place (1);
                  Into_Register : constant String := Target (Result);
               begin
                  if Result.Kind = Nowhere then
                     return;
                  end if;
                  Raw ("movi " & Into_Register & ", " & Arg (2));
                  if Op = "lui" then
                     Raw ("slli " & Into_Register & ", " & Into_Register
                          & ", 12");
                  end if;
                  Settle (Result, Into_Register);
               end;
            elsif Op in "mv" | "sext.w" then
               declare
                  Result : constant Location := Place (1);
                  From : constant Location := Place (2);
               begin
                  if Result.Kind = Nowhere then
                     return;
                  elsif Result.Kind = In_Register and then From.Kind = In_Home
                  then
                     Load_Home (Name (Result.Register), From.Offset,
                                From.Bytes);
                  elsif Result.Kind = In_Register
                    and then From.Kind in Zero_Word | Frame_Word
                  then
                     Settle (Result, Source (From, Name (Result.Register)));
                  else
                     Settle (Result, Source (From, "a8"));
                  end if;
               end;
            elsif Op in "neg" | "not" | "zext.b" | "zext.h" then
               declare
                  Result : constant Location := Place (1);
                  From : constant String := Source (Place (2), "a8");
                  Into_Register : constant String := Target (Result);
               begin
                  if Op = "neg" then
                     Raw ("neg " & Into_Register & ", " & From);
                  elsif Op = "not" then
                     Raw ("movi a9, -1");
                     Raw ("xor " & Into_Register & ", " & From & ", a9");
                  else
                     Raw ("extui " & Into_Register & ", " & From & ", 0, "
                          & (if Op = "zext.b" then "8" else "16"));
                  end if;
                  Settle (Result, Into_Register);
               end;
            elsif Op in "lw" | "lbu" | "lb" | "lhu" | "lh" then
               declare
                  Result : constant Location := Place (1);
                  Into_Register : constant String := Target (Result);
                  Offset : constant Long_Long_Integer :=
                    Offset_Of (Arg (2));
                  Scale : constant Positive :=
                    (if Op = "lw" then 4 elsif Op in "lhu" | "lh" then 2
                     else 1);
                  Native : constant String :=
                    (if Op = "lw" then "l32i" elsif Op in "lbu" | "lb"
                     then "l8ui" elsif Op = "lhu" then "l16ui" else "l16si");
                  Base : constant Location := Place (2);
               begin
                  if Base.Kind = Frame_Word
                    and then In_Reach (Frame + Offset, Scale)
                  then
                     Raw (Native & " " & Into_Register & ", a7, "
                          & Trim (Long_Long_Integer'Image (Frame + Offset)));
                  elsif Base.Kind = Frame_Word then
                     Raw ("movi a9, "
                          & Trim (Long_Long_Integer'Image (Frame + Offset)));
                     Raw ("add a9, a9, a7");
                     Raw (Native & " " & Into_Register & ", a9, 0");
                  else
                     declare
                        From : constant String := Source (Base, "a9");
                     begin
                        if In_Reach (Offset, Scale) then
                           Raw (Native & " " & Into_Register & ", " & From
                                & ", " & Trim (Offset'Image));
                        else
                           if From = "a9" then
                              Raw ("movi a8, " & Trim (Offset'Image));
                              Raw ("add a9, a9, a8");
                           else
                              Raw ("movi a9, " & Trim (Offset'Image));
                              Raw ("add a9, a9, " & From);
                           end if;
                           Raw (Native & " " & Into_Register & ", a9, 0");
                        end if;
                     end;
                  end if;
                  if Op = "lb" then
                     Raw ("sext " & Into_Register & ", " & Into_Register
                          & ", 7");
                  end if;
                  Settle (Result, Into_Register);
               end;
            elsif Op in "sw" | "sb" | "sh" then
               declare
                  Offset : constant Long_Long_Integer :=
                    Offset_Of (Arg (2));
                  Scale : constant Positive :=
                    (if Op = "sw" then 4 elsif Op = "sh" then 2 else 1);
                  Native : constant String :=
                    (if Op = "sw" then "s32i" elsif Op = "sh" then "s16i"
                     else "s8i");
                  Base : constant Location := Place (2);
                  Address : U.Unbounded_String;
                  Displacement : Long_Long_Integer := Offset;
               begin
                  --  The address first, so that a value loaded into a8
                  --  is loaded last.
                  if Base.Kind = Frame_Word then
                     if In_Reach (Frame + Offset, Scale) then
                        Address := U.To_Unbounded_String ("a7");
                        Displacement := Frame + Offset;
                     else
                        Raw ("movi a9, " & Trim
                          (Long_Long_Integer'Image (Frame + Offset)));
                        Raw ("add a9, a9, a7");
                        Address := U.To_Unbounded_String ("a9");
                        Displacement := 0;
                     end if;
                  else
                     declare
                        From : constant String := Source (Base, "a9");
                     begin
                        if In_Reach (Offset, Scale) then
                           Address := U.To_Unbounded_String (From);
                        else
                           if From = "a9" then
                              Raw ("movi a8, " & Trim (Offset'Image));
                              Raw ("add a9, a9, a8");
                           else
                              Raw ("movi a9, " & Trim (Offset'Image));
                              Raw ("add a9, a9, " & From);
                           end if;
                           Address := U.To_Unbounded_String ("a9");
                           Displacement := 0;
                        end if;
                     end;
                  end if;
                  declare
                     Value : constant String := Source (Place (1), "a8");
                  begin
                     Raw (Native & " " & Value & ", " & U.To_String (Address)
                          & ", " & Trim (Displacement'Image));
                  end;
               end;
            elsif At_Step.Folded /= 0 then
               declare
                  Result : constant Location := Place (1);
                  From : constant String :=
                    Source (Place (At_Step.Folded), "a8");
                  Into_Register : constant String := Target (Result);
                  Bits : constant Natural := At_Step.Shift;
               begin
                  if Op = "divu" and then Bits >= 16 then
                     Raw ("extui " & Into_Register & ", " & From & ", "
                          & Image (Bits) & ", " & Image (32 - Bits));
                  elsif Op = "divu" and then Bits > 0 then
                     Raw ("srli " & Into_Register & ", " & From & ", "
                          & Image (Bits));
                  elsif Op = "remu" and then Bits = 0 then
                     Raw ("movi " & Into_Register & ", 0");
                  elsif Op = "remu" and then Bits <= 16 then
                     Raw ("extui " & Into_Register & ", " & From & ", 0, "
                          & Image (Bits));
                  elsif Op = "remu" then
                     Raw ("movi a9, " & Trim (Long_Long_Integer'Image
                                                (2 ** Bits - 1)));
                     Raw ("and " & Into_Register & ", " & From & ", a9");
                  elsif Op = "add" and then At_Step.Addend /= 0 then
                     Raw ("addi " & Into_Register & ", " & From & ", "
                          & Trim (At_Step.Addend'Image));
                  elsif Op = "mul" and then At_Step.Shift /= 0 then
                     Raw ("slli " & Into_Register & ", " & From & ", "
                          & Image (At_Step.Shift));
                  elsif Into_Register /= From then
                     Raw ("mov " & Into_Register & ", " & From);
                  end if;
                  Settle (Result, Into_Register);
               end;
            elsif Op in "add" | "sub" | "mul" | "mulhu" | "mulh" | "and"
              | "or" | "xor" | "div" | "divu" | "rem" | "remu"
            then
               declare
                  Result : constant Location := Place (1);
                  Left : constant String := Source (Place (2), "a8");
                  Right : constant String := Source (Place (3), "a9");
                  Into_Register : constant String := Target (Result);
               begin
                  Raw ((if Op = "mul" then "mull"
                        elsif Op = "mulhu" then "muluh"
                        elsif Op = "mulh" then "mulsh"
                        elsif Op = "div" then "quos"
                        elsif Op = "divu" then "quou"
                        elsif Op = "rem" then "rems" else Op)
                       & " " & Into_Register & ", " & Left & ", " & Right);
                  Settle (Result, Into_Register);
               end;
            elsif Op = "addi" then
               declare
                  Result : constant Location := Place (1);
                  Into_Register : constant String := Target (Result);
                  Amount : constant Long_Long_Integer :=
                    (if Numeric (Arg (3))
                     then Long_Long_Integer'Value (Arg (3)) else 1);
                  From_Place : constant Location := Place (2);
               begin
                  if From_Place.Kind = Frame_Word
                    and then not Numeric (Arg (3))
                  then
                     raise Compiler_Defect with
                       "Xtensa frame offset is not a number";
                  elsif From_Place.Kind = Frame_Word then
                     if Frame + Amount in -128 .. 127 then
                        Raw ("addi " & Into_Register & ", a7, "
                             & Trim (Long_Long_Integer'Image
                                 (Frame + Amount)));
                     else
                        Raw ("movi a9, " & Trim (Long_Long_Integer'Image
                                                  (Frame + Amount)));
                        Raw ("add " & Into_Register & ", a7, a9");
                     end if;
                  else
                     declare
                        From : constant String := Source (From_Place, "a8");
                     begin
                        if Amount = 0 then
                           if Into_Register /= From then
                              Raw ("mov " & Into_Register & ", " & From);
                           end if;
                        elsif Small (Arg (3)) then
                           Raw ("addi " & Into_Register & ", " & From & ", "
                                & Arg (3));
                        else
                           Raw ("movi a9, " & Arg (3));
                           Raw ("add " & Into_Register & ", " & From
                                & ", a9");
                        end if;
                     end;
                  end if;
                  Settle (Result, Into_Register);
               end;
            elsif Op in "andi" | "ori" | "xori" then
               declare
                  Result : constant Location := Place (1);
                  From : constant String := Source (Place (2), "a8");
                  Into_Register : constant String := Target (Result);
               begin
                  Raw ("movi a9, " & Arg (3));
                  Raw (Op (Op'First .. Op'Last - 1) & " " & Into_Register
                       & ", " & From & ", a9");
                  Settle (Result, Into_Register);
               end;
            elsif Op in "sll" | "srl" | "sra" then
               declare
                  Result : constant Location := Place (1);
                  From : constant String := Source (Place (2), "a8");
                  Amount : constant String := Source (Place (3), "a9");
                  Into_Register : constant String := Target (Result);
               begin
                  Raw ((if Op = "sll" then "ssl " else "ssr ") & Amount);
                  Raw (Op & " " & Into_Register & ", " & From);
                  Settle (Result, Into_Register);
               end;
            elsif Op in "slli" | "srli" | "srai" then
               declare
                  Result : constant Location := Place (1);
                  From : constant String := Source (Place (2), "a8");
                  Into_Register : constant String := Target (Result);
                  Amount : constant Natural := Natural'Value (Arg (3));
               begin
                  if Amount = 0 then
                     if Into_Register /= From then
                        Raw ("mov " & Into_Register & ", " & From);
                     end if;
                  elsif Op = "srli" and then Amount >= 16 then
                     Raw ("extui " & Into_Register & ", " & From & ", "
                          & Image (Amount) & ", " & Image (32 - Amount));
                  else
                     Raw (Op & " " & Into_Register & ", " & From & ", "
                          & Image (Amount));
                  end if;
                  Settle (Result, Into_Register);
               end;
            elsif Op in "seqz" | "snez" | "sgtz" | "sltu" | "slt" | "slti"
              | "sltiu"
            then
               declare
                  Result : constant Location := Place (1);
                  Left : constant String := Source (Place (2), "a8");
               begin
                  if Result.Kind = Nowhere then
                     return;
                  elsif Op = "seqz" then
                     Boolean_Of ("beqz", Left, "", Result);
                  elsif Op = "snez" then
                     Boolean_Of ("bnez", Left, "", Result);
                  elsif Op = "sgtz" then
                     Raw ("movi a9, 0");
                     Boolean_Of ("blt", "a9", Left, Result);
                  elsif Op in "slti" | "sltiu" then
                     Raw ("movi a9, " & Arg (3));
                     Boolean_Of ((if Op = "slti" then "blt" else "bltu"),
                                 Left, "a9", Result);
                  else
                     Boolean_Of ((if Op = "slt" then "blt" else "bltu"),
                                 Left, Source (Place (3), "a9"), Result);
                  end if;
               end;
            elsif At_Step.Kind = Branch and then At_Step.Tests /= 0 then
               declare
                  Compared : Step renames Steps (At_Step.Tests);
                  Compare_Op : constant String := U.To_String (Compared.Op);
                  Label : constant String := Arg (At_Step.Count);
                  Left : constant String :=
                    Source (Argument (Compared, 2), "a8");
                  Right : constant String :=
                    (if Compare_Op in "sltu" | "slt"
                     then Source (Argument (Compared, 3), "a9")
                     elsif Compare_Op in "slti" | "sltiu" then "a9"
                     else "");
                  Holds : constant Boolean := Op = "bnez";
                  Condition : constant String :=
                    (if Compare_Op in "sltu" | "sltiu"
                     then (if Holds then "bltu" else "bgeu")
                     elsif Compare_Op in "slt" | "slti"
                     then (if Holds then "blt" else "bge")
                     elsif Compare_Op = "seqz"
                     then (if Holds then "beqz" else "bnez")
                     else (if Holds then "bnez" else "beqz"));
               begin
                  if Compare_Op in "slti" | "sltiu" then
                     Raw ("movi a9, " & U.To_String (Compared.Args (3)));
                  end if;
                  if Far then
                     declare
                        Skip : constant String := Fresh;
                        Inverse : constant String :=
                          (if Condition = "bltu" then "bgeu"
                           elsif Condition = "bgeu" then "bltu"
                           elsif Condition = "blt" then "bge"
                           elsif Condition = "bge" then "blt"
                           elsif Condition = "beqz" then "bnez" else "beqz");
                     begin
                        Raw (Inverse & " " & Left & ", "
                             & (if Right = "" then "" else Right & ", ")
                             & Skip);
                        Jump_To (Label);
                        U.Append (Output, Skip & ":" & LF);
                     end;
                  else
                     Raw (Condition & " " & Left & ", "
                          & (if Right = "" then "" else Right & ", ")
                          & Label);
                  end if;
               end;
            elsif At_Step.Kind = Branch then
               declare
                  Label : constant String := Arg (At_Step.Count);
                  Left : constant String := Source (Place (1), "a8");
                  Right : constant String :=
                    (if At_Step.Count = 3 then Source (Place (2), "a9")
                     else "");
                  Condition : constant String :=
                    (if Op = "blez" then "bge" elsif Op = "bgtz" then "blt"
                     else Op);
                  Inverse : constant String :=
                    (if Condition = "beq" then "bne"
                     elsif Condition = "bne" then "beq"
                     elsif Condition = "blt" then "bge"
                     elsif Condition = "bge" then "blt"
                     elsif Condition = "bltu" then "bgeu"
                     elsif Condition = "bgeu" then "bltu"
                     elsif Condition = "beqz" then "bnez"
                     elsif Condition = "bnez" then "beqz"
                     elsif Condition = "bltz" then "bgez" else "bltz");
                  Operands : constant String :=
                    (if Op in "blez" | "bgtz" then "a9, " & Left & ", "
                     elsif Right = "" then Left & ", "
                     else Left & ", " & Right & ", ");
               begin
                  if Op in "blez" | "bgtz" then
                     Raw ("movi a9, 0");
                  end if;
                  if Far then
                     declare
                        Skip : constant String := Fresh;
                     begin
                        Raw (Inverse & " " & Operands & Skip);
                        Jump_To (Label);
                        U.Append (Output, Skip & ":" & LF);
                     end;
                  else
                     --  The assembler relaxes a branch beyond its reach
                     --  to the inverse branch around a J, which reaches
                     --  every target of a routine this short.
                     Raw (Condition & " " & Operands & Label);
                  end if;
               end;
            elsif Op = "j" then
               Jump_To (Arg (1));
            elsif At_Step.Kind = Call then
               declare
                  Into_Registers, From_Registers : Move_List :=
                    [others => 0];
                  Moves : Natural := 0;
                  Indirect : U.Unbounded_String;
               begin
                  if Op = "jalr" then
                     declare
                        Where : constant Location := Place (2);
                     begin
                        if Where.Kind = In_Register
                          and then Preserved (Where.Register)
                        then
                           Indirect := U.To_Unbounded_String
                             (Name (Where.Register));
                        elsif Where.Kind = In_Register then
                           Raw ("mov a9, " & Name (Where.Register));
                           Indirect := U.To_Unbounded_String ("a9");
                        else
                           Indirect := U.To_Unbounded_String
                             (Source (Where, "a9"));
                        end if;
                     end;
                  end if;
                  for Which in 1 .. At_Step.Use_Count loop
                     if At_Step.Use_Arg (Which) = 0 then
                        declare
                           Where : constant Location :=
                             Of_Node (At_Step.Use_Nodes (Which));
                        begin
                           if Where.Kind = In_Register then
                              Moves := Moves + 1;
                              Into_Registers (Moves) :=
                                Word_Of (At_Step.Uses (Which));
                              From_Registers (Moves) := Where.Register;
                           end if;
                        end;
                     end if;
                  end loop;
                  Parallel (Into_Registers, From_Registers, Moves);
                  for Which in 1 .. At_Step.Use_Count loop
                     if At_Step.Use_Arg (Which) = 0 then
                        declare
                           Where : constant Location :=
                             Of_Node (At_Step.Use_Nodes (Which));
                        begin
                           if Where.Kind = In_Home then
                              Load_Home
                                (Name (Word_Of (At_Step.Uses (Which))),
                                 Where.Offset, Where.Bytes);
                           end if;
                        end;
                     end if;
                  end loop;
                  if Op = "jalr" then
                     Raw ("callx8 " & U.To_String (Indirect));
                  else
                     Raw ("call8 " & Arg (1));
                  end if;
                  --  Results: homes first, while a10-a14 hold them all.
                  Moves := 0;
                  for Which in 1 .. At_Step.Def_Count loop
                     declare
                        Where : constant Location :=
                          Of_Node (At_Step.Def_Nodes (Which));
                        From : constant Natural :=
                          (if Word_Of (At_Step.Defs (Which)) = 31 then 14
                           else Word_Of (At_Step.Defs (Which)));
                     begin
                        if Where.Kind = In_Home then
                           Store_Home (Name (From), Where.Offset,
                                       Where.Bytes);
                        elsif Where.Kind = In_Register then
                           Moves := Moves + 1;
                           Into_Registers (Moves) := Where.Register;
                           From_Registers (Moves) := From;
                        end if;
                     end;
                  end loop;
                  Parallel (Into_Registers, From_Registers, Moves);
               end;
            elsif At_Step.Kind = Enter then
               declare
                  Into_Registers, From_Registers : Move_List :=
                    [others => 0];
                  Moves : Natural := 0;
               begin
                  for Which in 1 .. At_Step.Def_Count loop
                     declare
                        Word : constant Natural :=
                          Word_Of (At_Step.Defs (Which));
                        Where : constant Location :=
                          Of_Node (At_Step.Def_Nodes (Which));
                     begin
                        if Word <= 14 and then Where.Kind = In_Home then
                           Store_Home (Name (Word - 8), Where.Offset,
                                       Where.Bytes);
                        elsif Word <= 14 and then Where.Kind = In_Register
                        then
                           Moves := Moves + 1;
                           Into_Registers (Moves) := Where.Register;
                           From_Registers (Moves) := Word - 8;
                        end if;
                     end;
                  end loop;
                  Parallel (Into_Registers, From_Registers, Moves);
                  --  The prologue left the incoming a7 in x15's home.
                  for Which in 1 .. At_Step.Def_Count loop
                     declare
                        Where : constant Location :=
                          Of_Node (At_Step.Def_Nodes (Which));
                     begin
                        if Word_Of (At_Step.Defs (Which)) = 15
                          and then Where.Kind = In_Register
                        then
                           Load_Home (Name (Where.Register),
                                      Long_Long_Integer
                                        (Word_Offset (15, True)), 4);
                        end if;
                     end;
                  end loop;
               end;
            elsif At_Step.Kind = Leave then
               declare
                  Into_Registers, From_Registers : Move_List :=
                    [others => 0];
                  Moves : Natural := 0;
                  function Out_Register (Which : Positive) return Natural
                    is (if Word_Of (At_Step.Uses (Which)) = 31 then 6
                        else Word_Of (At_Step.Uses (Which)) - 8);
               begin
                  for Which in 1 .. At_Step.Use_Count loop
                     declare
                        Where : constant Location :=
                          Of_Node (At_Step.Use_Nodes (Which));
                     begin
                        if Where.Kind = In_Register then
                           Moves := Moves + 1;
                           Into_Registers (Moves) := Out_Register (Which);
                           From_Registers (Moves) := Where.Register;
                        end if;
                     end;
                  end loop;
                  Parallel (Into_Registers, From_Registers, Moves);
                  for Which in 1 .. At_Step.Use_Count loop
                     declare
                        Where : constant Location :=
                          Of_Node (At_Step.Use_Nodes (Which));
                     begin
                        if Where.Kind = In_Home then
                           Load_Home (Name (Out_Register (Which)),
                                      Where.Offset, Where.Bytes);
                        end if;
                     end;
                  end loop;
                  --  SP is where the prologue left it, which RETW's
                  --  underflow handler reads the caller's base save below.
                  Raw ("retw");
               end;
            elsif Op in "fence" | "fence.tso" then
               Raw ("memw");
            elsif Op = "unimp" then
               Raw ("ill");
            elsif Op = "nop" then
               Raw ("nop");
            else
               raise Compiler_Defect with
                 "unsupported Xtensa word operation " & Op;
            end if;
         end Select_Step;
      begin
         for Index in 1 .. Natural (Steps.Length) loop
            if Steps (Index).Dead or else Steps (Index).Tested then
               null;
            elsif Steps (Index).Instruction then
               Select_Step (Steps (Index));
            else
               U.Append (Output, U.To_String (Steps (Index).Text) & LF);
            end if;
         end loop;
      end;
      Free (Live_In);
      Free (Scratch);
      Free (Current);
      Free (Global_Of);
      U.Append (Into, Output);
      Serial := Labels_Made;
      Placed := True;
   exception
      when Not_Placed =>
         Free (Live_In);
         Free (Scratch);
         Free (Current);
         Free (Global_Of);
         Registers := 0;
   end Place;

   procedure Finish_Routine
     (Of_Routine : in out Routine;
      Into : in out U.Unbounded_String;
      Serial : in out Natural;
      Registers : out Natural)
   is
      Placed : Boolean;
   begin
      Of_Routine.Active := False;
      Place (Of_Routine, Into, Serial, Registers, Placed);
      if not Placed then
         for Held of Of_Routine.Lines loop
            if Held.Kind = Logical then
               Select_Old (U.To_String (Held.Text), Into, Serial,
                           Of_Routine.Frame_Bytes, True, Of_Routine.Homes);
            else
               U.Append (Into, Held.Text);
               U.Append (Into, LF);
            end if;
         end loop;
      end if;
      Of_Routine.Lines.Clear;
   end Finish_Routine;
end Landin.Backend.Xtensa_Machine;
