with Ada.Characters.Handling;
with Ada.Strings.Fixed;

package body Landin.Targets.Assembly is

   type View_Name is access constant String;

   Float_Views : constant array (1 .. 6) of View_Name :=
     [new String'("v"), new String'("q"), new String'("d"),
      new String'("s"), new String'("h"), new String'("b")];

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

   function Classify (Facts : Target_Facts; Name : String)
     return Register_Kind is
   begin
      if Name = "general" and then Has_Registers (Facts) then
         return General_Class;
      end if;
      case Architecture_Of (Facts) is
         when Cortex_M0 =>
            if Number_In (Name, "r", 0, 7) then
               return Operand_Register;
            elsif Names_Reserved (Facts, Name) then
               return Never_Named;
            end if;
         when X86_64 =>
            if Name in "rax" | "rbx" | "rcx" | "rdx" | "rsi" | "rdi"
              or else Number_In (Name, "r", 8, 15)
            then
               return Operand_Register;
            elsif Name in "rsp" | "rbp" | "rip" then
               return Never_Named;
            end if;
         when Arm64 =>
            if Number_In (Name, "x", 0, 17)
              or else Number_In (Name, "x", 19, 28)
            then
               return Operand_Register;
            elsif Name in "sp" | "fp" | "lr" | "x18" | "x29" | "x30" then
               return Never_Named;
            end if;
         when Synthetic_32_Architecture =>
            null;
      end case;
      return Not_A_Register;
   end Classify;

   function Overwritten (Facts : Target_Facts; Name : String) return Boolean
     is (case Architecture_Of (Facts) is
            when Cortex_M0 => True,
            when X86_64 => Name not in "rbx" | "r12" | "r13" | "r14" | "r15",
            when Arm64 => Number_In (Name, "x", 0, 17),
            when Synthetic_32_Architecture => False);

   function In_General_Class (Facts : Target_Facts; Name : String)
     return Boolean
     is (Overwritten (Facts, Name));

   function General_Count (Facts : Target_Facts) return Natural
     is (case Architecture_Of (Facts) is
            when Cortex_M0 => 8,
            when X86_64 => 9,
            when Arm64 => 18,
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
         when Synthetic_32_Architecture =>
            raise Program_Error with "the synthetic model has no registers";
      end case;
   end General_Register;

   function Register_Width (Facts : Target_Facts) return Bit_Width
     is (case Architecture_Of (Facts) is
            when Cortex_M0 | Synthetic_32_Architecture => 32,
            when X86_64 | Arm64 => 64);

   function Has_Registers (Facts : Target_Facts) return Boolean
     is (Architecture_Of (Facts) /= Synthetic_32_Architecture);

   function Canonical (Facts : Target_Facts; Word : String) return String is
   begin
      case Architecture_Of (Facts) is
         when Cortex_M0 =>
            if Number_In (Word, "r", 0, 7) then
               return Word;
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
            --  v8-v15 are callee-saved in their low halves, and no
            --  operand can declare a float register yet, so no ordinary
            --  block names one at any width.
            when Arm64 =>
               Word in "sp" | "wsp" | "fp" | "lr" | "x18" | "w18" | "x29"
                 | "w29" | "x30" | "w30"
               or else (for some Prefix of Float_Views =>
                          Number_In (Word, Prefix.all, 8, 15)),
            when Synthetic_32_Architecture => False);

   function Lowered (Word : String) return String
     is (Ada.Characters.Handling.To_Lower (Word));

   function Text_Names
     (Facts : Target_Facts; Text : String; Register : String)
      return Boolean
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
                   (Facts, Lowered (Text (First .. Position - 1)))
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
     (Facts : Target_Facts; Register : String; Bits : Bit_Width)
      return String is
   begin
      case Architecture_Of (Facts) is
         when Cortex_M0 =>
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
      Operands : in out Operand_Register_Array)
   is
      use type Ada.Strings.Unbounded.Unbounded_String;

      function Held (Register : String) return Boolean
        is (for some Operand of Operands => Operand.Register = Register);
   begin
      for Operand of Operands loop
         if Ada.Strings.Unbounded.Length (Operand.Register) = 0 then
            for Index in 1 .. General_Count (Facts) loop
               declare
                  Register : constant String :=
                    General_Register (Facts, Index);
               begin
                  if not Held (Register)
                    and then not Text_Names (Facts, Text, Register)
                  then
                     Operand.Register :=
                       Ada.Strings.Unbounded.To_Unbounded_String (Register);
                     exit;
                  end if;
               end;
            end loop;
            if Ada.Strings.Unbounded.Length (Operand.Register) = 0 then
               raise Program_Error with
                 "an assembly block asked general for too many registers";
            end if;
         end if;
      end loop;
   end Choose;

   function Substituted
     (Facts : Target_Facts; Text : String;
      Operands : Operand_Register_Array) return String
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
                           Operand.Bits));
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

   function Text_Error (Facts : Target_Facts; Text : String) return String is
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
         if Clean (Clean'First) = '.'
           or else Ada.Strings.Fixed.Index (Clean, ";") /= 0
           or else Ada.Strings.Fixed.Index (Clean, "/*") /= 0
           or else Ada.Strings.Fixed.Index (Clean, "//") /= 0
           or else (Architecture_Of (Facts) = X86_64
                    and then Ada.Strings.Fixed.Index (Clean, "#") /= 0)
           --  Apple's arm64 assembler separates statements with `%%`.
           or else (Architecture_Of (Facts) = Arm64
                    and then Ada.Strings.Fixed.Index (Clean, "%%") /= 0)
         then
            return "assembly directives, comments and statement separators"
              & " refuse";
         end if;
         while Stop <= Clean'Last
           and then Clean (Stop) not in ' ' | ASCII.HT | ':'
         loop
            Stop := Stop + 1;
         end loop;
         if Stop <= Clean'Last and then Clean (Stop) = ':' then
            return "ordinary assembly is straight-line and defines no label";
         end if;
         declare
            Mnemonic : constant String := Clean (Clean'First .. Stop - 1);

            function Starts (Prefix : String) return Boolean
              is (Mnemonic'Length >= Prefix'Length
                  and then Mnemonic
                    (Mnemonic'First .. Mnemonic'First + Prefix'Length - 1)
                      = Prefix);
         begin
            if (case Architecture_Of (Facts) is
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
         if Text (Index) = ASCII.LF then
            declare
               Fault : constant String :=
                 Check_Line (Text (Start .. Index - 1));
            begin
               if Fault /= "" then
                  return Fault;
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      declare
         Fault : constant String := Check_Line (Text (Start .. Text'Last));
      begin
         if Fault /= "" then
            return Fault;
         end if;
      end;
      return (if Seen then "" else "assembly block must contain instructions");
   end Text_Error;

end Landin.Targets.Assembly;
