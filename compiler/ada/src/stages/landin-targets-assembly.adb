with Ada.Characters.Handling;
with Ada.Strings.Fixed;

package body Landin.Targets.Assembly is

   use type Landin.Targets.Firmware.Float_Unit;

   type View_Name is access constant String;

   Float_Views : constant array (1 .. 6) of View_Name :=
     [new String'("v"), new String'("q"), new String'("d"),
      new String'("s"), new String'("h"), new String'("b")];

   --  RISC-V's float ABI names: ft0-ft7 are f0-f7, fs0 and fs1 f8 and f9,
   --  fa0-fa7 f10-f17, fs2-fs11 f18-f27 and ft8-ft11 f28-f31.
   function RV64_Float_Alias (Word : String) return Natural;

   RV64_Aliases : constant array (0 .. 31) of View_Name :=
     [new String'("zero"), new String'("ra"), new String'("sp"),
      new String'("gp"), new String'("tp"), new String'("t0"),
      new String'("t1"), new String'("t2"), new String'("s0"),
      new String'("s1"), new String'("a0"), new String'("a1"),
      new String'("a2"), new String'("a3"), new String'("a4"),
      new String'("a5"), new String'("a6"), new String'("a7"),
      new String'("s2"), new String'("s3"), new String'("s4"),
      new String'("s5"), new String'("s6"), new String'("s7"),
      new String'("s8"), new String'("s9"), new String'("s10"),
      new String'("s11"), new String'("t3"), new String'("t4"),
      new String'("t5"), new String'("t6")];

   function Number_In
     (Name : String; Prefix : String; First, Last : Natural) return Boolean;

   --  `r3` with Prefix "r" and 0 .. 7, without accepting `r03` or `r`.
   function Number_In
     (Name : String; Prefix : String; First, Last : Natural) return Boolean
   is
      Digits_First : constant Integer := Name'First + Prefix'Length;
      Value : Natural := 0;
   begin
      if Name'Length <= Prefix'Length
        or else Name (Name'First .. Digits_First - 1) /= Prefix
        or else Name'Last - Digits_First >= 2
        or else (Name (Digits_First) = '0' and then Name'Last > Digits_First)
      then
         return False;
      end if;
      for Index in Digits_First .. Name'Last loop
         if Name (Index) not in '0' .. '9' then
            return False;
         end if;
         Value := Value * 10
           + (Character'Pos (Name (Index)) - Character'Pos ('0'));
      end loop;
      return Value in First .. Last;
   end Number_In;

   function RV64_Float_Alias (Word : String) return Natural is
   begin
      for Number in 0 .. 11 loop
         declare
            Image : constant String := Natural'Image (Number);
            Digits_Of : constant String :=
              Image (Image'First + 1 .. Image'Last);
         begin
            if Word = "ft" & Digits_Of then
               return (if Number <= 7 then Number else Number + 20);
            elsif Word = "fs" & Digits_Of then
               return (if Number <= 1 then Number + 8 else Number + 16);
            elsif Number <= 7 and then Word = "fa" & Digits_Of then
               return Number + 10;
            end if;
         end;
      end loop;
      return Natural'Last;
   end RV64_Float_Alias;

   function Classify
     (Facts : Target_Facts; Name : String;
      Unit : Float_Unit := No_Float_Unit) return Register_Kind is
   begin
      if Name = "general" and then Has_Registers (Facts) then
         return General_Class;
      elsif Name = "float" and then Has_Registers (Facts) then
         --  The class is spelled on every target with registers, as
         --  `general` is; the checker refuses a float operand where the
         --  target has no float register for it.
         return Float_Class;
      end if;
      case Architecture_Of (Facts) is
         when Cortex_M0 =>
            if Number_In (Name, "r", 0, 7) then
               return Operand_Register;
            elsif Has_Float_Registers (Facts, Unit)
              and then Number_In (Name, "d", 0, 15)
            then
               return Float_Register;
            elsif Names_Reserved (Facts, Name) then
               return Never_Named;
            end if;
         when X86_64 =>
            if Name in "rax" | "rbx" | "rcx" | "rdx" | "rsi" | "rdi"
              or else Number_In (Name, "r", 8, 15)
            then
               return Operand_Register;
            elsif Number_In (Name, "xmm", 0, 15) then
               return Float_Register;
            elsif Name in "rsp" | "rbp" | "rip" then
               return Never_Named;
            end if;
         when Arm64 =>
            if Number_In (Name, "x", 0, 17)
              or else Number_In (Name, "x", 19, 28)
            then
               return Operand_Register;
            elsif Number_In (Name, "v", 0, 31) then
               return Float_Register;
            elsif Name in "sp" | "fp" | "lr" | "x18" | "x29" | "x30" then
               return Never_Named;
            end if;
         --  D660: RV32 names RV64's integer registers at XLEN 32, and
         --  its soft-float levels have no float register.
         when RV64 | RV32 =>
            if Number_In (Name, "x", 5, 7)
              or else Number_In (Name, "x", 9, 31)
            then
               return Operand_Register;
            elsif Has_Float_Registers (Facts, Unit)
              and then Number_In (Name, "f", 0, 31)
            then
               return Float_Register;
            elsif Names_Reserved (Facts, Name) then
               return Never_Named;
            end if;
         when Synthetic_32_Architecture =>
            null;
      end case;
      return Not_A_Register;
   end Classify;

   --  D630: x86-64's SysV ABI preserves no XMM register, AAPCS64 the low
   --  halves of v8-v15, LP64D f8, f9 and f18-f27, and AAPCS32's VFP
   --  variant d8-d15 (D616).
   function Overwritten
     (Facts : Target_Facts; Name : String;
      Unit : Float_Unit := No_Float_Unit) return Boolean
     is (case Architecture_Of (Facts) is
            when Cortex_M0 => Unit = No_Float_Unit
              or else not Number_In (Name, "d", 8, 15),
            when X86_64 => Name not in "rbx" | "r12" | "r13" | "r14" | "r15",
            when Arm64 => Number_In (Name, "x", 0, 17)
              or else Number_In (Name, "v", 0, 7)
              or else Number_In (Name, "v", 16, 31),
            when RV64 | RV32 => Number_In (Name, "x", 5, 7)
              or else Number_In (Name, "x", 10, 17)
              or else Number_In (Name, "x", 28, 31)
              or else Number_In (Name, "f", 0, 7)
              or else Number_In (Name, "f", 10, 17)
              or else Number_In (Name, "f", 28, 31),
            when Synthetic_32_Architecture => False);

   function In_General_Class (Facts : Target_Facts; Name : String)
     return Boolean
     is (Overwritten (Facts, Name));

   function General_Count (Facts : Target_Facts) return Natural
     is (case Architecture_Of (Facts) is
            when Cortex_M0 => 8,
            when X86_64 => 9,
            when Arm64 => 18,
            when RV64 | RV32 => 15,
            when Synthetic_32_Architecture => 0);

   function General_Register (Facts : Target_Facts; Index : Positive)
     return String
   is
      Image : constant String := Natural'Image (Index - 1);
      Number : constant String := Image (Image'First + 1 .. Image'Last);
   begin
      case Architecture_Of (Facts) is
         when Cortex_M0 =>
            return "r" & Number;
         when X86_64 =>
            case Index is
               when 1 => return "rax";
               when 2 => return "rcx";
               when 3 => return "rdx";
               when 4 => return "rsi";
               when 5 => return "rdi";
               when others =>
                  declare
                     Wide : constant String := Natural'Image (Index + 2);
                  begin
                     return "r" & Wide (Wide'First + 1 .. Wide'Last);
                  end;
            end case;
         when Arm64 =>
            return "x" & Number;
         when RV64 | RV32 =>
            declare
               Value : constant Natural :=
                 (if Index <= 3 then Index + 4
                  elsif Index <= 11 then Index + 6 else Index + 16);
               Wide : constant String := Natural'Image (Value);
            begin
               return "x" & Wide (Wide'First + 1 .. Wide'Last);
            end;
         when Synthetic_32_Architecture =>
            raise Program_Error with "the synthetic model has no registers";
      end case;
   end General_Register;

   function Register_Width (Facts : Target_Facts) return Bit_Width
     is (case Architecture_Of (Facts) is
            when Cortex_M0 | RV32 | Synthetic_32_Architecture => 32,
            when X86_64 | Arm64 | RV64 => 64);

   function Has_Registers (Facts : Target_Facts) return Boolean
     is (Architecture_Of (Facts) /= Synthetic_32_Architecture);

   function Has_Float_Registers
     (Facts : Target_Facts; Unit : Float_Unit := No_Float_Unit)
      return Boolean
     is (Architecture_Of (Facts) in X86_64 | Arm64 | RV64
         or else (Architecture_Of (Facts) = Cortex_M0
                  and then Unit /= No_Float_Unit));

   function In_Float_Class
     (Facts : Target_Facts; Name : String;
      Unit : Float_Unit := No_Float_Unit) return Boolean
     is (Overwritten (Facts, Name, Unit));

   function Float_Count
     (Facts : Target_Facts; Unit : Float_Unit := No_Float_Unit)
      return Natural
     is (case Architecture_Of (Facts) is
            when X86_64 => 16,
            when Arm64 => 24,
            when RV64 => 20,
            when Cortex_M0 => (if Unit = No_Float_Unit then 0 else 8),
            when RV32 => 0,
            when Synthetic_32_Architecture => 0);

   function Float_Class_Register
     (Facts : Target_Facts; Index : Positive;
      Unit : Float_Unit := No_Float_Unit) return String
   is
      pragma Unreferenced (Unit);
      --  The class in ascending order of its registers' numbers.
      Number : constant Natural :=
        (case Architecture_Of (Facts) is
            when X86_64 => Index - 1,
            when Arm64 => (if Index <= 8 then Index - 1 else Index + 7),
            when RV64 => (if Index <= 8 then Index - 1
                          elsif Index <= 16 then Index + 1
                          else Index + 11),
            when Cortex_M0 => Index - 1,
            when RV32 | Synthetic_32_Architecture =>
              raise Program_Error with "the target has no float registers");
      Image : constant String := Natural'Image (Number);
      Digits_Of : constant String := Image (Image'First + 1 .. Image'Last);
   begin
      return (case Architecture_Of (Facts) is
                 when X86_64 => "xmm",
                 when Arm64 => "v",
                 when Cortex_M0 => "d",
                 when others => "f") & Digits_Of;
   end Float_Class_Register;

   --  Every float register of the hosted targets holds an f64, and so
   --  does a double-precision unit's.
   function Float_Width
     (Facts : Target_Facts; Unit : Float_Unit := No_Float_Unit)
      return Bit_Width
     is (case Architecture_Of (Facts) is
            when X86_64 | Arm64 | RV64 => 64,
            when Cortex_M0 =>
              (if Landin.Targets.Firmware.Double_Precision (Unit) then 64
               else 32),
            when RV32 | Synthetic_32_Architecture =>
              raise Program_Error with "the target has no float registers");

   function Canonical
     (Facts : Target_Facts; Word : String;
      Unit : Float_Unit := No_Float_Unit) return String is
   begin
      case Architecture_Of (Facts) is
         when Cortex_M0 =>
            if Number_In (Word, "r", 0, 7) then
               return Word;
            elsif Unit /= No_Float_Unit
              and then Number_In (Word, "d", 0, 15)
            then
               return Word;
            elsif Unit /= No_Float_Unit
              and then Number_In (Word, "s", 0, 31)
            then
               --  s(2n) and s(2n+1) are d(n)'s halves.
               declare
                  Image : constant String := Natural'Image
                    (Natural'Value (Word (Word'First + 1 .. Word'Last)) / 2);
               begin
                  return "d" & Image (Image'First + 1 .. Image'Last);
               end;
            end if;
         when X86_64 =>
            --  Every width of the sixteen: `rax` `eax` `ax` `al` `ah`,
            --  `rsi` `esi` `si` `sil`, `r8` `r8d` `r8w` `r8b`.
            if Word in "rax" | "eax" | "ax" | "al" | "ah" then
               return "rax";
            elsif Word in "rbx" | "ebx" | "bx" | "bl" | "bh" then
               return "rbx";
            elsif Word in "rcx" | "ecx" | "cx" | "cl" | "ch" then
               return "rcx";
            elsif Word in "rdx" | "edx" | "dx" | "dl" | "dh" then
               return "rdx";
            elsif Word in "rsi" | "esi" | "si" | "sil" then
               return "rsi";
            elsif Word in "rdi" | "edi" | "di" | "dil" then
               return "rdi";
            end if;
            for Number in 8 .. 15 loop
               declare
                  Image : constant String := Natural'Image (Number);
                  Name : constant String :=
                    "r" & Image (Image'First + 1 .. Image'Last);
               begin
                  if Word = Name or else Word = Name & "d"
                    or else Word = Name & "w" or else Word = Name & "b"
                  then
                     return Name;
                  end if;
               end;
            end loop;
            --  An XMM register's wider views are the same register.
            if Number_In (Word, "xmm", 0, 15)
              or else Number_In (Word, "ymm", 0, 15)
              or else Number_In (Word, "zmm", 0, 15)
            then
               return "x" & Word (Word'First + 1 .. Word'Last);
            end if;
         when Arm64 =>
            if Number_In (Word, "x", 0, 17)
              or else Number_In (Word, "x", 19, 28)
            then
               return Word;
            elsif Number_In (Word, "w", 0, 17)
              or else Number_In (Word, "w", 19, 28)
            then
               return "x" & Word (Word'First + 1 .. Word'Last);
            end if;
            --  `v8` at every width: `q8`, `d8`, `s8`, `h8` and `b8`.
            for Prefix of Float_Views loop
               if Number_In (Word, Prefix.all, 0, 31) then
                  return "v" & Word (Word'First + 1 .. Word'Last);
               end if;
            end loop;
         when RV64 | RV32 =>
            if Number_In (Word, "x", 5, 7)
              or else Number_In (Word, "x", 9, 31)
            then
               return Word;
            end if;
            --  Operand names remain xN. Raw text may use ABI aliases, which
            --  must identify the same register for declaration and general
            --  exclusion checks, especially for saved s1-s11.
            for Index in 5 .. 31 loop
               if Index /= 8 and then Word = RV64_Aliases (Index).all then
                  declare
                     Image : constant String := Natural'Image (Index);
                  begin
                     return "x" & Image (Image'First + 1 .. Image'Last);
                  end;
               end if;
            end loop;
            if Architecture_Of (Facts) = RV32 then
               null;
            elsif Number_In (Word, "f", 0, 31) then
               return Word;
            elsif RV64_Float_Alias (Word) /= Natural'Last then
               declare
                  Image : constant String :=
                    Natural'Image (RV64_Float_Alias (Word));
               begin
                  return "f" & Image (Image'First + 1 .. Image'Last);
               end;
            end if;
         when Synthetic_32_Architecture =>
            null;
      end case;
      return "";
   end Canonical;

   function Names_Reserved (Facts : Target_Facts; Word : String)
     return Boolean
     is (case Architecture_Of (Facts) is
            when Cortex_M0 =>
               Number_In (Word, "r", 8, 15)
               or else Number_In (Word, "v", 1, 8)
               or else Word in "sp" | "lr" | "pc" | "fp" | "ip" | "sl"
                         | "sb" | "msp" | "psp" | "control",
            when X86_64 =>
               Word in "rsp" | "esp" | "sp" | "spl" | "rbp" | "ebp" | "bp"
                 | "bpl" | "rip" | "eip" | "ip",
            --  v8-v15 are callee-saved in their low halves, and D630 lets
            --  a block declare one, as it declares x19.
            when Arm64 =>
               Word in "sp" | "wsp" | "fp" | "lr" | "x18" | "w18" | "x29"
                 | "w29" | "x30" | "w30",
            --  LP64D's preserved float registers, f8, f9 and f18-f27, are
            --  declared as its preserved integers are (D630).
            when RV64 | RV32 =>
               Number_In (Word, "x", 0, 4) or else Word in "x8"
                 | "zero" | "ra" | "sp" | "gp" | "tp" | "fp" | "s0",
            when Synthetic_32_Architecture => False);

   function Lowered (Word : String) return String
     is (Ada.Characters.Handling.To_Lower (Word));

   function Text_Names
     (Facts : Target_Facts; Text : String; Register : String;
      Unit : Float_Unit := No_Float_Unit) return Boolean
   is
      Position : Natural := Text'First;
   begin
      while Position <= Text'Last loop
         if Text (Position) in '{' | '}'
           and then Position < Text'Last
           and then Text (Position + 1) = Text (Position)
         then
            Position := Position + 2;
         elsif Text (Position) = '{' then
            while Position <= Text'Last and then Text (Position) /= '}' loop
               Position := Position + 1;
            end loop;
            Position := Position + 1;
         elsif Text (Position) in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
           | '_'
         then
            declare
               First : constant Natural := Position;
            begin
               while Position <= Text'Last
                 and then Text (Position) in 'a' .. 'z' | 'A' .. 'Z'
                   | '0' .. '9' | '_'
               loop
                  Position := Position + 1;
               end loop;
               if Text (First) not in '0' .. '9'
                 and then Canonical
                   (Facts, Lowered (Text (First .. Position - 1)), Unit)
                     = Register
               then
                  return True;
               end if;
            end;
         else
            Position := Position + 1;
         end if;
      end loop;
      return False;
   end Text_Names;

   function Filled (Text : String; Register : String) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String;
      Position : Natural := Text'First;
   begin
      while Position <= Text'Last loop
         if Text (Position) in '{' | '}'
           and then Position < Text'Last
           and then Text (Position + 1) = Text (Position)
         then
            Ada.Strings.Unbounded.Append (Result, Text (Position));
            Position := Position + 2;
         elsif Text (Position) = '{' then
            declare
               Close : Natural := Position + 1;
            begin
               while Close <= Text'Last and then Text (Close) /= '}' loop
                  Close := Close + 1;
               end loop;
               Ada.Strings.Unbounded.Append (Result, Register);
               Position := Close + 1;
            end;
         else
            Ada.Strings.Unbounded.Append (Result, Text (Position));
            Position := Position + 1;
         end if;
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end Filled;

   function Spelled
     (Facts : Target_Facts; Register : String; Bits : Bit_Width;
      Unit : Float_Unit := No_Float_Unit) return String is
   begin
      if Classify (Facts, Register, Unit) = Float_Register then
         --  D630: x86-64 and RV64 name a float register the same at both
         --  widths; arm64 names v's low half by the float it holds, and a
         --  Cortex-M unit d(n)'s by s(2n) for an f32.
         declare
            Number : constant String :=
              Register (Register'First + 1 .. Register'Last);

            function Single return String
              is (Ada.Strings.Fixed.Trim
                    (Natural'Image (2 * Natural'Value (Number)),
                     Ada.Strings.Left));
         begin
            return (case Architecture_Of (Facts) is
                       when X86_64 => "%" & Register,
                       when Arm64 =>
                         (if Bits > 32 then "d" else "s") & Number,
                       when Cortex_M0 =>
                         (if Bits > 32 then Register
                          else "s" & Single),
                       when others => Register);
         end;
      end if;
      case Architecture_Of (Facts) is
         when Cortex_M0 | RV64 | RV32 =>
            return Register;
         when Arm64 =>
            return (if Bits > 32 then Register
                    else "w" & Register (Register'First + 1 .. Register'Last));
         when X86_64 =>
            if Register in "rax" | "rbx" | "rcx" | "rdx" then
               declare
                  Letter : constant Character :=
                    Register (Register'First + 1);
               begin
                  return "%" & (case Bits is
                     when 1 .. 8 => Letter & "l",
                     when 9 .. 16 => Letter & "x",
                     when 17 .. 32 => "e" & Letter & "x",
                     when others => Register);
               end;
            elsif Register in "rsi" | "rdi" then
               declare
                  Pair : constant String :=
                    Register (Register'First + 1 .. Register'Last);
               begin
                  return "%" & (case Bits is
                     when 1 .. 8 => Pair & "l",
                     when 9 .. 16 => Pair,
                     when 17 .. 32 => "e" & Pair,
                     when others => Register);
               end;
            else
               return "%" & Register & (case Bits is
                  when 1 .. 8 => "b",
                  when 9 .. 16 => "w",
                  when 17 .. 32 => "d",
                  when others => "");
            end if;
         when Synthetic_32_Architecture =>
            raise Program_Error with "the synthetic model has no registers";
      end case;
   end Spelled;

   procedure Choose
     (Facts : Target_Facts; Text : String;
      Operands : in out Operand_Register_Array;
      Unit : Float_Unit := No_Float_Unit)
   is
      use type Ada.Strings.Unbounded.Unbounded_String;

      function Held (Register : String) return Boolean
        is (for some Operand of Operands => Operand.Register = Register);
   begin
      for Operand of Operands loop
         if Ada.Strings.Unbounded.Length (Operand.Register) = 0 then
            for Index in 1 .. (if Operand.Float
                               then Float_Count (Facts, Unit)
                               else General_Count (Facts))
            loop
               declare
                  Register : constant String :=
                    (if Operand.Float
                     then Float_Class_Register (Facts, Index, Unit)
                     else General_Register (Facts, Index));
               begin
                  if not Held (Register)
                    and then not Text_Names (Facts, Text, Register, Unit)
                  then
                     Operand.Register :=
                       Ada.Strings.Unbounded.To_Unbounded_String (Register);
                     exit;
                  end if;
               end;
            end loop;
            if Ada.Strings.Unbounded.Length (Operand.Register) = 0 then
               raise Program_Error with
                 "an assembly block asked a class for too many registers";
            end if;
         end if;
      end loop;
   end Choose;

   function Substituted
     (Facts : Target_Facts; Text : String;
      Operands : Operand_Register_Array;
      Unit : Float_Unit := No_Float_Unit) return String
   is
      Result : Ada.Strings.Unbounded.Unbounded_String;
      Position : Natural := Text'First;
   begin
      while Position <= Text'Last loop
         if Text (Position) in '{' | '}'
           and then Position < Text'Last
           and then Text (Position + 1) = Text (Position)
         then
            Ada.Strings.Unbounded.Append (Result, Text (Position));
            Position := Position + 2;
         elsif Text (Position) = '{' then
            declare
               Close : Natural := Position + 1;
               Found : Boolean := False;
            begin
               while Close <= Text'Last and then Text (Close) /= '}' loop
                  Close := Close + 1;
               end loop;
               for Operand of Operands loop
                  if Ada.Strings.Unbounded.To_String (Operand.Name)
                    = Text (Position + 1 .. Close - 1)
                  then
                     Ada.Strings.Unbounded.Append
                       (Result, Spelled
                          (Facts,
                           Ada.Strings.Unbounded.To_String (Operand.Register),
                           Operand.Bits, Unit));
                     Found := True;
                     exit;
                  end if;
               end loop;
               if not Found then
                  raise Program_Error with
                    "an assembly slot names no operand";
               end if;
               Position := Close + 1;
            end;
         else
            Ada.Strings.Unbounded.Append (Result, Text (Position));
            Position := Position + 1;
         end if;
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end Substituted;

   function Comment_Marker (On : Architecture) return String
     is (case On is
            when Cortex_M0 => "@",
            when Arm64 => "//",
            when X86_64 | RV64 | RV32 => "#",
            when Synthetic_32_Architecture => "");

   function Uncommented (On : Architecture; Text : String) return String is
      Marker : constant String := Comment_Marker (On);
      Result : Ada.Strings.Unbounded.Unbounded_String;
      Start : Integer := Text'First;

      procedure Add (Line : String);

      procedure Add (Line : String) is
         Cut : constant Natural :=
           (if Marker = "" then 0
            else Ada.Strings.Fixed.Index (Line, Marker));
      begin
         if Cut = 0 then
            Ada.Strings.Unbounded.Append (Result, Line);
         else
            Ada.Strings.Unbounded.Append
              (Result, Ada.Strings.Fixed.Trim
                 (Line (Line'First .. Cut - 1), Ada.Strings.Right));
         end if;
      end Add;
   begin
      for Index in Text'Range loop
         if Text (Index) = ASCII.LF then
            Add (Text (Start .. Index - 1));
            Ada.Strings.Unbounded.Append (Result, ASCII.LF);
            Start := Index + 1;
         end if;
      end loop;
      Add (Text (Start .. Text'Last));
      return Ada.Strings.Unbounded.To_String (Result);
   end Uncommented;

   function Separated_Number (Line : String) return String is
      Position : Natural := Line'First;
   begin
      while Position <= Line'Last loop
         if Line (Position) in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_'
         then
            declare
               First : constant Natural := Position;
            begin
               while Position <= Line'Last
                 and then Line (Position) in 'a' .. 'z' | 'A' .. 'Z'
                   | '0' .. '9' | '_'
               loop
                  Position := Position + 1;
               end loop;
               if Line (First) in '0' .. '9'
                 and then Ada.Strings.Fixed.Index
                   (Line (First .. Position - 1), "_") /= 0
               then
                  return Line (First .. Position - 1);
               end if;
            end;
         else
            Position := Position + 1;
         end if;
      end loop;
      return "";
   end Separated_Number;

   function Foreign_Comment (On : Architecture; Line : String)
     return String
   is
      Marker : constant String := Comment_Marker (On);
      Assembly : constant String :=
        (case On is
            when Cortex_M0 => "Cortex-M",
            when Arm64 => "arm64",
            when X86_64 => "x86-64",
            when RV64 => "RV64",
            when RV32 => "RV32",
            when Synthetic_32_Architecture => "synthetic");
      Clean : constant String := Ada.Strings.Fixed.Trim
        (Line, Ada.Strings.Both);

      function Not_A_Comment (Form : String) return String
        is ("`" & Form & "` begins no comment in " & Assembly
            & " assembly text: a comment is `" & Marker
            & "` to the end of the line");

      function Separator (Form : String) return String
        is ("`" & Form & "` separates statements, and assembly text holds"
            & " one instruction a line: a comment is `" & Marker
            & "` to the end of the line");
   begin
      if Ada.Strings.Fixed.Index (Clean, "/*") /= 0 then
         return Not_A_Comment ("/*");
      elsif On /= Arm64 and then Ada.Strings.Fixed.Index (Clean, "//") /= 0
      then
         return Not_A_Comment ("//");
      elsif On in Cortex_M0 | Arm64
        and then Clean'Length > 0
        and then Clean (Clean'First) = '#'
      then
         --  GNU as reads `#` that begins a line as a comment on both, a
         --  form [1990] does not give the text: elsewhere `#` is an
         --  immediate.
         return Not_A_Comment ("#");
      elsif Ada.Strings.Fixed.Index (Clean, ";") /= 0 then
         return Separator (";");
      --  Apple's arm64 assembler separates statements with `%%`.
      elsif On = Arm64 and then Ada.Strings.Fixed.Index (Clean, "%%") /= 0
      then
         return Separator ("%%");
      end if;
      return "";
   end Foreign_Comment;

   function Separator_Refusal (Number : String) return String is
      Written : String (1 .. Number'Length);
      Last : Natural := 0;
   begin
      for C of Number loop
         if C /= '_' then
            Last := Last + 1;
            Written (Last) := C;
         end if;
      end loop;
      return "a number in assembly text is the assembler's and takes no"
        & " digit separator: write `" & Written (1 .. Last) & "` for `"
        & Number & "`";
   end Separator_Refusal;

   function Text_Error
     (Facts : Target_Facts; Text : String; Naked : Boolean := False)
      return String
   is
      Start : Integer := Text'First;
      Seen : Boolean := False;

      function Check_Line (Line : String) return String;

      function Check_Line (Line : String) return String is
         Clean : constant String := Ada.Strings.Fixed.Trim
           (Ada.Characters.Handling.To_Lower (Line), Ada.Strings.Both);
         Stop : Natural := Clean'First;
      begin
         if Clean'Length = 0 then
            return "";
         end if;
         Seen := True;
         if Clean (Clean'First) = '.' then
            return "assembly text holds no directive";
         elsif Foreign_Comment (Architecture_Of (Facts), Clean) /= "" then
            return Foreign_Comment (Architecture_Of (Facts), Clean);
         elsif Separated_Number (Clean) /= "" then
            return Separator_Refusal (Separated_Number (Clean));
         end if;
         while Stop <= Clean'Last
           and then Clean (Stop) not in ' ' | ASCII.HT | ':'
         loop
            Stop := Stop + 1;
         end loop;
         if Stop <= Clean'Last and then Clean (Stop) = ':' then
            --  A naked body owns its control flow, so it may label a
            --  target as it may branch to one (D598); the rest of the
            --  line is an instruction like any other.
            if not Naked then
               return "ordinary assembly is straight-line and defines no"
                 & " label; a naked routine's body may";
            elsif Stop = Clean'First
              or else (for some C of Clean (Clean'First .. Stop - 1) =>
                         C not in 'a' .. 'z' | '0' .. '9' | '_')
            then
               return "a naked label requires an ASCII identifier";
            end if;
            return Check_Line (Clean (Stop + 1 .. Clean'Last));
         end if;
         declare
            Mnemonic : constant String := Clean (Clean'First .. Stop - 1);

            function Starts (Prefix : String) return Boolean
              is (Mnemonic'Length >= Prefix'Length
                  and then Mnemonic
                    (Mnemonic'First .. Mnemonic'First + Prefix'Length - 1)
                      = Prefix);
         begin
            --  A naked body owns its control flow: it is how a process
            --  entry reaches the routine it runs.
            if not Naked and then (case Architecture_Of (Facts) is
                  when X86_64 =>
                     Starts ("j") or else Starts ("call")
                     or else Starts ("ret") or else Starts ("iret")
                     or else Starts ("loop") or else Starts ("sysret")
                     or else Starts ("sysexit"),
                  when Arm64 =>
                     Mnemonic in "b" | "bl" | "blr" | "br" | "ret" | "cbz"
                       | "cbnz" | "tbz" | "tbnz" | "eret" | "braa" | "brab"
                       | "braaz" | "brabz" | "blraa" | "blrab" | "blraaz"
                       | "blrabz" | "retaa" | "retab" | "eretaa" | "eretab"
                     or else Starts ("b."),
                  when RV64 | RV32 =>
                     Starts ("b") or else Starts ("j")
                     or else Starts ("c.b") or else Starts ("c.j")
                     --  `ecall` is the system call, which x86-64's
                     --  `syscall` and arm64's `svc` already are: the
                     --  kernel returns to the next instruction.
                     or else Mnemonic in "call" | "tail" | "ret"
                       | "ebreak" | "sret" | "mret" | "uret" | "dret"
                       | "c.ebreak"
                     --  D670: firmware waits for an interrupt in an
                     --  ordinary block, as Cortex-M's does: WFI resumes
                     --  at the next instruction once the handler returns.
                     --  Its `ecall` is an exception, which takes no slot
                     --  and enters the unhandled loop, never to return.
                     or else (Architecture_Of (Facts) = RV64
                              and then Mnemonic = "wfi")
                     or else (Architecture_Of (Facts) = RV32
                              and then Mnemonic = "ecall"),
                  when others => False)
            then
               return "ordinary assembly is straight-line and transfers no"
                 & " control";
            end if;
         end;
         return "";
      end Check_Line;
   begin
      if Text'Length > 4096 then
         return "one assembly block exceeds 4096 bytes";
      end if;
      for Index in Text'Range loop
         if Text (Index) not in ASCII.HT | ASCII.LF | ' ' .. '~' then
            return "assembly text requires ASCII instructions and LF lines";
         end if;
      end loop;
      declare
         Lines : constant String :=
           Uncommented (Architecture_Of (Facts), Text);
      begin
         Start := Lines'First;
         for Index in Lines'Range loop
            if Lines (Index) = ASCII.LF then
               declare
                  Fault : constant String :=
                    Check_Line (Lines (Start .. Index - 1));
               begin
                  if Fault /= "" then
                     return Fault;
                  end if;
               end;
               Start := Index + 1;
            end if;
         end loop;
         declare
            Fault : constant String :=
              Check_Line (Lines (Start .. Lines'Last));
         begin
            if Fault /= "" then
               return Fault;
            end if;
         end;
      end;
      return (if Seen then "" else "assembly block must contain instructions");
   end Text_Error;

end Landin.Targets.Assembly;
