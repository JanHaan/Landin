with Ada.Characters.Handling;

package body Landin.Backend.Site_Counts is

   No_Register : constant Integer := -1;

   function Is_Space (C : Character) return Boolean
     is (C = ' ' or else C = Character'Val (9) or else C = Character'Val (13));

   function Trimmed (Text : String) return String;
   function Trimmed (Text : String) return String is
      First : Positive := Text'First;
      Last : Natural := Text'Last;
   begin
      while First <= Last and then Is_Space (Text (First)) loop
         First := First + 1;
      end loop;
      while Last >= First and then Is_Space (Text (Last)) loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trimmed;

   function Digits_Value (Text : String) return Integer;
   function Digits_Value (Text : String) return Integer is
      Result : Natural := 0;
   begin
      if Text'Length = 0 or else Text'Length > 2 then
         return No_Register;
      end if;
      for C of Text loop
         if C not in '0' .. '9' then
            return No_Register;
         end if;
         Result := Result * 10 + (Character'Pos (C) - Character'Pos ('0'));
      end loop;
      return Result;
   end Digits_Value;

   --  The general register Name spells, numbered as the architecture
   --  numbers it, or No_Register for anything else, a zero register and
   --  every floating-point or vector register among them.
   function Number (Of_Syntax : Syntax; Name : String) return Integer;
   function Number (Of_Syntax : Syntax; Name : String) return Integer is
      Tail : constant String :=
        (if Name'Length > 1 then Name (Name'First + 1 .. Name'Last) else "");
      Value : constant Integer := Digits_Value (Tail);
   begin
      if Name'Length = 0 then
         return No_Register;
      end if;
      case Of_Syntax is
         when A64 =>
            if Name = "sp" or else Name = "wsp" then
               return 31;
            elsif Name = "fp" then
               return 29;
            elsif Name = "lr" then
               return 30;
            elsif Name (Name'First) in 'x' | 'w' and then Value in 0 .. 30
            then
               return Value;
            end if;
         when RISC_V =>
            if Name = "zero" then
               return 0;
            elsif Name = "ra" then
               return 1;
            elsif Name = "sp" then
               return 2;
            elsif Name = "gp" then
               return 3;
            elsif Name = "tp" then
               return 4;
            elsif Name = "fp" then
               return 8;
            elsif Name (Name'First) = 'x' and then Value in 0 .. 31 then
               return Value;
            elsif Name (Name'First) = 'a' and then Value in 0 .. 7 then
               return 10 + Value;
            elsif Name (Name'First) = 's' and then Value in 0 .. 1 then
               return 8 + Value;
            elsif Name (Name'First) = 's' and then Value in 2 .. 11 then
               return 16 + Value;
            elsif Name (Name'First) = 't' and then Value in 0 .. 2 then
               return 5 + Value;
            elsif Name (Name'First) = 't' and then Value in 3 .. 6 then
               return 25 + Value;
            end if;
         when Thumb =>
            if Name = "sp" then
               return 13;
            elsif Name = "lr" then
               return 14;
            elsif Name = "pc" then
               return 15;
            elsif Name = "fp" then
               return 11;
            elsif Name = "ip" then
               return 12;
            elsif Name = "sl" then
               return 10;
            elsif Name = "sb" then
               return 9;
            elsif Name (Name'First) = 'r' and then Value in 0 .. 15 then
               return Value;
            end if;
      end case;
      return No_Register;
   end Number;

   --  The stack pointer and the frame pointer each backend keeps.
   function Is_Stack (Of_Syntax : Syntax; Register : Integer) return Boolean
     is (case Of_Syntax is
            when A64 => Register in 29 | 31,
            when RISC_V => Register in 2 | 8,
            when Thumb => Register in 11 | 13);

   function Holds_Address (Into : Counter; Name : String) return Boolean;
   function Holds_Address (Into : Counter; Name : String) return Boolean is
      Register : constant Integer := Number (Into.Of_Syntax, Name);
   begin
      return Register /= No_Register
        and then (Is_Stack (Into.Of_Syntax, Register)
                  or else Into.Derived (Register));
   end Holds_Address;

   procedure Set (Into : in out Counter; Name : String; Value : Boolean);
   procedure Set (Into : in out Counter; Name : String; Value : Boolean) is
      Register : constant Integer := Number (Into.Of_Syntax, Name);
   begin
      if Register /= No_Register then
         Into.Derived (Register) := Value;
      end if;
   end Set;

   --  The base register of a memory operand: the first name inside its
   --  brackets on Arm, inside its parentheses on RISC-V, or "".
   function Base_Of (Of_Syntax : Syntax; Operand : String) return String;
   function Base_Of (Of_Syntax : Syntax; Operand : String) return String is
      Open : constant Character :=
        (if Of_Syntax = RISC_V then '(' else '[');
      First : Natural := 0;
   begin
      for Index in Operand'Range loop
         if First = 0 and then Operand (Index) = Open then
            First := Index + 1;
         elsif First /= 0
           and then Operand (Index) in ',' | ']' | ')'
         then
            return Trimmed (Operand (First .. Index - 1));
         end if;
      end loop;
      return "";
   end Base_Of;

   function Is_Memory (Of_Syntax : Syntax; Operand : String) return Boolean
     is (Base_Of (Of_Syntax, Operand) /= "");

   function Starts (Text, Prefix : String) return Boolean
     is (Text'Length >= Prefix'Length
         and then Text (Text'First .. Text'First + Prefix'Length - 1)
           = Prefix);

   function One_Of (Text : String; Words : String) return Boolean;
   --  Whether Text is one of the space-separated Words.
   function One_Of (Text : String; Words : String) return Boolean is
      First : Positive := Words'First;
   begin
      for Index in Words'First .. Words'Last + 1 loop
         if Index > Words'Last or else Words (Index) = ' ' then
            if Words (First .. Index - 1) = Text then
               return True;
            end if;
            First := Index + 1;
         end if;
      end loop;
      return False;
   end One_Of;

   Thumb_Conditions : constant String :=
     "eq ne cs cc hs lo mi pl vs vc hi ls ge lt gt le al";

   --  Whether an instruction Mnemonic spells writes no register named by
   --  its first operand: a branch, a comparison, a barrier or a trap.
   function Writes_Nothing
     (Of_Syntax : Syntax; Mnemonic : String) return Boolean
     is (case Of_Syntax is
            when A64 =>
               Mnemonic = "b" or else Starts (Mnemonic, "b.")
               or else One_Of (Mnemonic,
                 "cbz cbnz tbz tbnz cmp cmn tst ccmp ccmn fcmp fcmpe fccmp"
                 & " ret br brk svc hvc nop dmb dsb isb msr prfm hint yield"
                 & " wfe wfi sev sevl clrex udf"),
            when RISC_V =>
               One_Of (Mnemonic,
                 "beq bne blt bge bltu bgeu beqz bnez bltz bgez blez bgtz"
                 & " bgt ble bgtu bleu j jr ret unimp ecall ebreak fence"
                 & " fence.i nop wfi csrw csrs csrc csrwi csrsi csrci"),
            when Thumb =>
               Mnemonic = "b"
               or else (Mnemonic'Length = 3
                        and then Mnemonic (Mnemonic'First) = 'b'
                        and then One_Of
                          (Mnemonic (Mnemonic'First + 1 .. Mnemonic'Last),
                           Thumb_Conditions))
               or else Starts (Mnemonic, "it")
               or else One_Of (Mnemonic,
                 "cbz cbnz cmp cmn tst teq bx bkpt svc nop cpsid cpsie dmb"
                 & " dsb isb msr wfi wfe sev udf"));

   procedure Add (Into : in out Counter; Line : String) is
      Text : constant String := Trimmed (Line);
      Space : Natural := 0;
   begin
      if Text'Length = 0
        or else Text (Text'First) in '.' | '#' | '@' | ';' | '/'
      then
         return;
      elsif Text (Text'Last) = ':' then
         --  Control can arrive here from anywhere.
         Into.Derived := [others => False];
         return;
      end if;
      for Index in Text'Range loop
         if Is_Space (Text (Index)) then
            Space := Index;
            exit;
         end if;
      end loop;
      declare
         Mnemonic : constant String := Ada.Characters.Handling.To_Lower
           (if Space = 0 then Text else Text (Text'First .. Space - 1));
         Rest : constant String := Ada.Characters.Handling.To_Lower
           (if Space = 0 then "" else Text (Space + 1 .. Text'Last));
         Commas : Natural := 0;
         S : constant Syntax := Into.Of_Syntax;
      begin
         Into.Instructions := Into.Instructions + 1;
         for C of Rest loop
            if C = ',' then
               Commas := Commas + 1;
            end if;
         end loop;
         declare
            --  The operands, split at the commas outside any bracket,
            --  brace or parenthesis.
            type Bounds is record
               First : Positive;
               Last : Natural;
            end record;
            Parts : array (1 .. Commas + 1) of Bounds :=
              [others => (1, 0)];
            Count : Natural := 0;
            function Operand (Index : Positive) return String
              is (if Index > Count then ""
                  else Trimmed (Rest (Parts (Index).First
                                      .. Parts (Index).Last)));
            Depth : Natural := 0;
            Start : Positive := Rest'First;

            function Is_Call return Boolean;
            function Is_Indirect_Call return Boolean;
            function Is_Load return Boolean;
            function Is_Store return Boolean;
            procedure Count_Access (Load : Boolean);

            function Is_Call return Boolean is
              (case S is
                  when A64 | Thumb => Mnemonic = "bl",
                  when RISC_V =>
                     Mnemonic = "call"
                     or else (Mnemonic = "jal"
                              and then (Count = 1
                                        or else Number (S, Operand (1)) = 1)));

            function Is_Indirect_Call return Boolean is
              (case S is
                  when A64 => Starts (Mnemonic, "blr"),
                  when Thumb => Mnemonic = "blx",
                  when RISC_V =>
                     Mnemonic = "jalr" and then Number (S, Operand (1)) /= 0);

            function Is_Load return Boolean is
              (case S is
                  when A64 => Starts (Mnemonic, "ld"),
                  when RISC_V =>
                     One_Of (Mnemonic, "lb lh lw ld lbu lhu lwu flh flw fld")
                     or else Starts (Mnemonic, "lr."),
                  when Thumb =>
                     Starts (Mnemonic, "ldr") or else Starts (Mnemonic, "ldm")
                     or else Starts (Mnemonic, "vldr")
                     or else Starts (Mnemonic, "vldm")
                     or else Mnemonic in "pop" | "vpop");

            function Is_Store return Boolean is
              (case S is
                  when A64 => Starts (Mnemonic, "st"),
                  when RISC_V =>
                     One_Of (Mnemonic, "sb sh sw sd fsh fsw fsd")
                     or else Starts (Mnemonic, "sc."),
                  when Thumb =>
                     Starts (Mnemonic, "str") or else Starts (Mnemonic, "stm")
                     or else Starts (Mnemonic, "vstr")
                     or else Starts (Mnemonic, "vstm")
                     or else Mnemonic in "push" | "vpush");

            procedure Count_Access (Load : Boolean) is
               On_Stack : Boolean := Mnemonic in "push" | "pop" | "vpush"
                 | "vpop";
            begin
               for Index in 1 .. Count loop
                  declare
                     Part : constant String := Operand (Index);
                  begin
                     if Is_Memory (S, Part) then
                        On_Stack := On_Stack
                          or else Holds_Address (Into, Base_Of (S, Part));
                     end if;
                  end;
               end loop;
               --  A multiple transfer names its base as its first operand.
               if S = Thumb
                 and then (Starts (Mnemonic, "ldm")
                           or else Starts (Mnemonic, "stm")
                           or else Starts (Mnemonic, "vldm")
                           or else Starts (Mnemonic, "vstm"))
               then
                  declare
                     Base : constant String := Operand (1);
                  begin
                     On_Stack := On_Stack or else Holds_Address
                       (Into, (if Base'Length > 0
                                 and then Base (Base'Last) = '!'
                               then Base (Base'First .. Base'Last - 1)
                               else Base));
                  end;
               end if;
               if On_Stack then
                  if Load then
                     Into.Loads := Into.Loads + 1;
                  else
                     Into.Stores := Into.Stores + 1;
                  end if;
               end if;
            end Count_Access;
         begin
            for Index in Rest'Range loop
               if Rest (Index) in '[' | '{' | '(' then
                  Depth := Depth + 1;
               elsif Rest (Index) in ']' | '}' | ')' and then Depth > 0 then
                  Depth := Depth - 1;
               elsif Rest (Index) = ',' and then Depth = 0 then
                  Count := Count + 1;
                  Parts (Count) := (Start, Index - 1);
                  Start := Index + 1;
               end if;
            end loop;
            if Rest'Length > 0 then
               Count := Count + 1;
               Parts (Count) := (Start, Rest'Last);
            end if;

            if Is_Call then
               Into.Direct := Into.Direct + 1;
               Into.Derived := [others => False];
            elsif Is_Indirect_Call then
               Into.Indirect := Into.Indirect + 1;
               Into.Derived := [others => False];
            elsif Is_Load then
               Count_Access (Load => True);
               if Mnemonic in "pop" | "vpop" or else Starts (Mnemonic, "ldm")
               then
                  Into.Derived := [others => False];
               else
                  --  Every register before the address is loaded.
                  for Index in 1 .. Count loop
                     exit when Is_Memory (S, Operand (Index));
                     Set (Into, Operand (Index), False);
                  end loop;
               end if;
            elsif Is_Store then
               Count_Access (Load => False);
            elsif Mnemonic in "mov" | "mv" | "movs" and then Count = 2 then
               Set (Into, Operand (1), Holds_Address (Into, Operand (2)));
            elsif Mnemonic in "add" | "adds" | "addi" | "sub" | "subs"
              and then Count = 3
            then
               Set (Into, Operand (1),
                    Holds_Address (Into, Operand (2))
                    or else (Mnemonic in "add" | "adds"
                             and then Holds_Address (Into, Operand (3))));
            elsif Mnemonic in "add" | "adds" | "sub" | "subs"
              and then Count = 2
            then
               --  Thumb's two-operand form adds to its destination.
               Set (Into, Operand (1),
                    Holds_Address (Into, Operand (1))
                    or else (Mnemonic in "add" | "adds"
                             and then Holds_Address (Into, Operand (2))));
            elsif not Writes_Nothing (S, Mnemonic) and then Count > 0 then
               Set (Into, Operand (1), False);
            end if;
         end;
      end;
   end Add;

   procedure Add_Lines (Into : in out Counter; Text : String) is
      First : Positive := Text'First;
   begin
      for Index in Text'Range loop
         if Text (Index) = Character'Val (10) then
            Add (Into, Text (First .. Index - 1));
            First := Index + 1;
         end if;
      end loop;
      if First <= Text'Last then
         Add (Into, Text (First .. Text'Last));
      end if;
   end Add_Lines;

   procedure Fill
     (From : Counter;
      Into : in out Landin.Build_Reports.Routine_Statistics) is
   begin
      Into.Instructions := From.Instructions;
      Into.Stack_Loads := From.Loads;
      Into.Stack_Stores := From.Stores;
      Into.Direct_Calls := From.Direct;
      Into.Indirect_Calls := From.Indirect;
   end Fill;

   procedure Clear (Into : in out Counter) is
   begin
      Into.Derived := [others => False];
      Into.Instructions := 0;
      Into.Loads := 0;
      Into.Stores := 0;
      Into.Direct := 0;
      Into.Indirect := 0;
   end Clear;

end Landin.Backend.Site_Counts;
