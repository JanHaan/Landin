--  arm64 instruction selection evidence.  These cases inspect assembly
--  text and the selection helpers' own answers; the arm64 runtime lanes,
--  under emulation or on a native host, execute what they select.  Like
--  the x86 optimization suite, each emits from lowered IR that the
--  pipeline's simplification has not seen.
with Ada.Containers.Ordered_Sets;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;
with Interfaces;

with Landin.Backend.Arm64;
with Landin.Backend.Arm64.Selection;
with Landin.Backend.Reciprocals;
with Landin.Build_Reports;
with Landin.IR.If_Conversion;
with Landin.IR.Simplification;
with Landin.Optimization;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;

package body Landin.Tests.Arm64_Selection_Suite is

   package Selection renames Landin.Backend.Arm64.Selection;
   package Opt renames Landin.Optimization;
   package US renames Ada.Strings.Unbounded;
   use type Selection.Word;
   use type Landin.Source.Source_Id;
   use type Opt.Objective;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;
   Checker : aliased Landin.Stages.Checking.Instance;
   Lowerer : aliased Landin.Stages.Lowering.Instance;
   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   function Contains (Text, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   function Count (Text, Needle : String) return Natural is
     (Ada.Strings.Fixed.Count (Text, Needle));

   --  The text from a routine's label through the end of its body.
   function Routine (Text, Name : String) return String;

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String);
   function Emitted
     (Work : in out Landin.Stages.Compilation;
      Objective : Opt.Objective) return String;

   procedure Selection_Immediates (Item : in out Landin.Testing.Context);
   procedure Reciprocals_Select_Exactly
     (Item : in out Landin.Testing.Context);
   procedure Arithmetic_Shapes (Item : in out Landin.Testing.Context);
   procedure Speed_Multiplies_Known_Divisors
     (Item : in out Landin.Testing.Context);
   procedure Comparisons_Branch_On_Flags
     (Item : in out Landin.Testing.Context);
   procedure Constants_Live_Nowhere (Item : in out Landin.Testing.Context);
   procedure Speed_Unrolls_Transfers
     (Item : in out Landin.Testing.Context);
   procedure Frames_Reach_Homes (Item : in out Landin.Testing.Context);
   procedure Slice_Elements_Check_Once
     (Item : in out Landin.Testing.Context);
   procedure Counted_Flag_Adds (Item : in out Landin.Testing.Context);
   procedure Choices_Select_Conditionally
     (Item : in out Landin.Testing.Context);

   --  Source lowered, simplified and if-converted at Objective, as the
   --  driver does, then emitted.
   function Converted
     (Item : in out Landin.Testing.Context;
      Source : String;
      Objective : Opt.Objective) return String;

   function Routine (Text, Name : String) return String is
      First : constant Natural :=
        Ada.Strings.Fixed.Index (Text, LF & Name & ":" & LF);
      Last : constant Natural :=
        (if First = 0 then 0
         else Ada.Strings.Fixed.Index
           (Text (First .. Text'Last), ".size " & Name & ","));
   begin
      if First = 0 or else Last = 0 then
         return "";
      end if;
      return Text (First .. Last);
   end Routine;

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String)
   is
      Order : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "arm64-selection.ldn", Text);
   begin
      pragma Assert (Written /= Landin.Source.No_Source);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Resolver'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      declare
         Ran : constant Natural := Landin.Stages.Run (Order, Work);
      begin
         Landin.Testing.Check_Equal
           (Item, Ran, 5, "in-memory source reaches verified IR: "
            & Landin.Stages.Rendered_Report (Work));
      end;
   end Lower;

   function Emitted
     (Work : in out Landin.Stages.Compilation;
      Objective : Opt.Objective) return String
   is
      Assembly : US.Unbounded_String;
      Report : Landin.Build_Reports.Report;
   begin
      Landin.Backend.Arm64.Emit
        (Landin.Stages.Code (Work).all, Landin.Stages.Meanings (Work).all,
         Landin.Stages.Identities (Work).all, Landin.Stages.Target (Work),
         (Objective, Opt.Off), Assembly, Report);
      return US.To_String (Assembly);
   end Emitted;

   --  The immediates selection puts inside an instruction are the ones
   --  the encodings have: every rotated run of ones repeated across 32
   --  or 64 bits and nothing else, twelve bits shifted by nothing or
   --  twelve, and fmov's 256 floats, written as exact decimals.  The
   --  move-wide lines are the fewest a seed and its movk need.
   procedure Selection_Immediates (Item : in out Landin.Testing.Context) is
      package Word_Sets is new Ada.Containers.Ordered_Sets (Selection.Word);
      Valid : array (Boolean) of Word_Sets.Set;
      Wrong : Natural := 0;
      Seed : Selection.Word := 16#2545_F491_4F6C_DD1D#;
      Floats : Natural := 0;
      type Sizes is array (Positive range <>) of Positive;
   begin
      for Size of Sizes'[2, 4, 8, 16, 32, 64] loop
         for Ones in 1 .. Size - 1 loop
            for Rotation in 0 .. Size - 1 loop
               declare
                  Mask : constant Selection.Word :=
                    (if Size = 64 then Selection.Word'Last
                     else 2 ** Size - 1);
                  Run : constant Selection.Word := 2 ** Ones - 1;
                  Element : constant Selection.Word :=
                    (if Rotation = 0 then Run
                     else (Run * 2 ** Rotation
                           or Run / 2 ** (Size - Rotation)) and Mask);
                  Whole : Selection.Word := 0;
               begin
                  for Copy in 0 .. 64 / Size - 1 loop
                     Whole := Whole or Element * 2 ** (Copy * Size);
                  end loop;
                  Valid (True).Include (Whole);
                  if Size <= 32 then
                     Valid (False).Include (Whole and 16#FFFF_FFFF#);
                  end if;
               end;
            end loop;
         end loop;
      end loop;
      for Wide in Boolean loop
         for Value of Valid (Wide) loop
            if not Selection.Is_Logical_Immediate
              (Value, (if Wide then 64 else 32))
            then
               Wrong := Wrong + 1;
            end if;
         end loop;
      end loop;
      for Probe in 1 .. 20_000 loop
         Seed := Seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
         declare
            Value : constant Selection.Word :=
              (if Probe mod 2 = 0 then Seed else Seed and 16#FFFF_FFFF#);
         begin
            if Selection.Is_Logical_Immediate (Value, 64)
              /= Valid (True).Contains (Value)
              or else Selection.Is_Logical_Immediate (Value, 32)
                /= Valid (False).Contains (Value and 16#FFFF_FFFF#)
            then
               Wrong := Wrong + 1;
            end if;
         end;
      end loop;
      Landin.Testing.Check
        (Item, Wrong = 0
         and then Natural (Valid (True).Length) = 5_334
         and then Natural (Valid (False).Length) = 1_302
         and then not Selection.Is_Logical_Immediate (0, 64)
         and then not Selection.Is_Logical_Immediate
           (Selection.Word'Last, 64)
         and then not Selection.Is_Logical_Immediate (16#FFFF_FFFF#, 32),
         "logical immediates are exactly the rotated repeated runs;"
         & Natural'Image (Wrong) & " disagree");
      Landin.Testing.Check
        (Item, Selection.Arithmetic_Immediate (4095) = "#4095"
         and then Selection.Arithmetic_Immediate (4096) = "#1, lsl #12"
         and then Selection.Arithmetic_Immediate (16#FFF000#)
           = "#4095, lsl #12"
         and then Selection.Arithmetic_Immediate (4097) = ""
         and then Selection.Arithmetic_Immediate (16#1000000#) = "",
         "arithmetic immediates are twelve bits, shifted or not");
      Landin.Testing.Check
        (Item, Selection.Immediate ("x9", 0) = "movz x9, #0"
         and then Selection.Immediate ("x9", Selection.Word'Last)
           = "movn x9, #0"
         and then Selection.Immediate ("x14", 139_968)
           = "movz x14, #8896" & LF & "movk x14, #2, lsl #16"
         and then Selection.Immediate ("x9", 16#FFFF_FFFF_FFFF_0001#)
           = "movn x9, #65534",
         "a constant takes the fewest move-wide lines");
      --  Every imm8 expands to an encodable pattern at both widths, and
      --  a pattern one bit away from it is not one.
      for Encoded in Selection.Word range 0 .. 255 loop
         declare
            A : constant Selection.Word := Encoded / 128;
            B : constant Selection.Word := Encoded / 64 and 1;
            CDEFGH : constant Selection.Word := Encoded and 63;
            Double : constant Selection.Word :=
              A * 2 ** 63 + (1 - B) * 2 ** 62 + B * 16#FF# * 2 ** 54
              + CDEFGH * 2 ** 48;
            Single : constant Selection.Word :=
              A * 2 ** 31 + (1 - B) * 2 ** 30 + B * 16#1F# * 2 ** 25
              + CDEFGH * 2 ** 19;
         begin
            if Selection.Float_Immediate (Double, False) /= ""
              and then Selection.Float_Immediate (Single, True) /= ""
              and then Selection.Float_Immediate (Double + 1, False) = ""
              and then Selection.Float_Immediate (Single + 1, True) = ""
            then
               Floats := Floats + 1;
            end if;
         end;
      end loop;
      Landin.Testing.Check
        (Item, Floats = 256
         and then Selection.Float_Immediate (16#4010_0000_0000_0000#, False)
           = "#4.0"
         and then Selection.Float_Immediate (16#BFC0_0000_0000_0000#, False)
           = "#-0.125"
         and then Selection.Float_Immediate (16#403F_0000_0000_0000#, False)
           = "#31.0"
         and then Selection.Float_Immediate (16#3FF8_0000#, True)
           = "#1.9375"
         and then Selection.Float_Immediate (0, False) = ""
         and then Selection.Float_Immediate
           (16#3FB9_9999_9999_999A#, False) = "",
         "fmov's 256 immediates at each width, written exactly");
   end Selection_Immediates;

   --  Every sequence Divide_By_Constant selects, run by a small model of
   --  the instructions it may contain, against Ada's own division and
   --  remainder: every 8-bit dividend by every 8-bit divisor, and at the
   --  wider widths each divisor up to 1100, those beside every power of
   --  two, the largest and a pseudo-random spread, over the width's
   --  extreme dividends, those beside the divisor and its largest
   --  multiples and a pseudo-random spread.  Each sign of a signed divisor
   --  and three placements of dividend and result, one shared with the
   --  scratch register, are selected in turn.  The model refuses any
   --  register outside the ones the selection is allowed to write, and a
   --  result that claims to be zero-extended and is not.
   procedure Reciprocals_Select_Exactly
     (Item : in out Landin.Testing.Context)
   is
      package R renames Landin.Backend.Reciprocals;
      use type Interfaces.Integer_64;
      subtype Word is Selection.Word;
      subtype Wide is Interfaces.Integer_64;
      function As_Wide is new Ada.Unchecked_Conversion (Word, Wide);
      function As_Word is new Ada.Unchecked_Conversion (Wide, Word);

      type Operation is
        (Move_Zero, Move_Not, Move_Keep, High, Signed_High, Add, Sub,
         Shift_Right, Shift_Signed, And_Mask, Negate, Multiply_Subtract,
         Copy, Extend_8, Extend_16, Extend_32);
      type Step is record
         Op : Operation := Copy;
         D, N, M, A : Natural := 0;
         Value : Word := 0;
         Shift : Natural := 0;
      end record;
      type Steps is array (Positive range 1 .. 16) of Step;
      type Registers is array (0 .. 30) of Word;
      type Word_Array is array (Positive range <>) of Word;

      Seed : Word := 16#9E37_79B9_7F4A_7C15#;
      Checked : Natural := 0;
      Failed : Natural := 0;
      First_Failure : US.Unbounded_String;
      Sequences : Natural := 0;

      function Upper (Left, Right : Word) return Word;
      function Signed_Upper (Left, Right : Word) return Word;
      function Next return Word;
      procedure Fail (Text : String);
      procedure Parse
        (Lines : String; Program : out Steps; Length : out Natural;
         Result : Natural);
      function Run
        (Program : Steps; Length : Natural; Input : Natural;
         Dividend : Word) return Registers;
      procedure Divisor
        (Bits : R.Dividend_Bits; Signed : Boolean; Magnitude : Word;
         Negative : Boolean);
      procedure Divisors (Bits : R.Dividend_Bits; Signed : Boolean);

      function Upper (Left, Right : Word) return Word is
         Mask : constant Word := 16#FFFF_FFFF#;
         Low_Low : constant Word := (Left and Mask) * (Right and Mask);
         Low_High : constant Word := (Left and Mask) * (Right / 2 ** 32);
         High_Low : constant Word := (Left / 2 ** 32) * (Right and Mask);
         Middle : constant Word :=
           Low_Low / 2 ** 32 + (Low_High and Mask) + (High_Low and Mask);
      begin
         return (Left / 2 ** 32) * (Right / 2 ** 32)
           + Low_High / 2 ** 32 + High_Low / 2 ** 32 + Middle / 2 ** 32;
      end Upper;

      function Signed_Upper (Left, Right : Word) return Word is
        (Upper (Left, Right)
         - (if Left >= 2 ** 63 then Right else 0)
         - (if Right >= 2 ** 63 then Left else 0));

      function Next return Word is
      begin
         Seed := Seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
         return Seed xor Seed / 2 ** 31;
      end Next;

      procedure Fail (Text : String) is
      begin
         if Failed = 0 then
            First_Failure := US.To_Unbounded_String (Text);
         end if;
         Failed := Failed + 1;
      end Fail;

      --  One instruction per line, in the forms the selection writes.
      --  Any other line, or a write to a register the selection may not
      --  touch, is a failure.
      procedure Parse
        (Lines : String; Program : out Steps; Length : out Natural;
         Result : Natural)
      is
         First : Positive := Lines'First;

         procedure Line (Text : String);

         procedure Line (Text : String) is
            Space : constant Natural := Ada.Strings.Fixed.Index (Text, " ");
            Mnemonic : constant String := Text (Text'First .. Space - 1);
            Operands : array (1 .. 5) of US.Unbounded_String;
            Count_Of : Natural := 0;
            Start : Positive := Space + 1;
            Current : Step;

            function Register (Index : Positive) return Natural is
              (Natural'Value (US.Slice (Operands (Index), 2,
                 US.Length (Operands (Index)))));
            function Number (Text : String) return Word is
              (if Text'Length > 3
                  and then Text (Text'First .. Text'First + 2) = "#0x"
               then Word'Value ("16#" & Text (Text'First + 3 .. Text'Last)
                                & "#")
               else Word'Value (Text (Text'First + 1 .. Text'Last)));
            --  A trailing `lsl #n` or `lsr #n`.
            function Shifted (Index : Positive) return Natural is
              (if Index <= Count_Of
               then Natural'Value (US.Slice (Operands (Index), 6,
                      US.Length (Operands (Index))))
               else 0);
         begin
            for Index in Space + 1 .. Text'Last + 1 loop
               if Index > Text'Last or else Text (Index) = ',' then
                  Count_Of := Count_Of + 1;
                  Operands (Count_Of) := US.To_Unbounded_String
                    (Ada.Strings.Fixed.Trim
                       (Text (Start .. Index - 1), Ada.Strings.Both));
                  Start := Index + 1;
               end if;
            end loop;
            Current.D := Register (1);
            if Mnemonic in "movz" | "movn" | "movk" then
               Current.Op := (if Mnemonic = "movz" then Move_Zero
                              elsif Mnemonic = "movn" then Move_Not
                              else Move_Keep);
               Current.Value := Number (US.To_String (Operands (2)));
               Current.Shift := Shifted (3);
            elsif Mnemonic in "umulh" | "smulh" | "sub" then
               Current.Op := (if Mnemonic = "umulh" then High
                              elsif Mnemonic = "smulh" then Signed_High
                              else Sub);
               Current.N := Register (2);
               Current.M := Register (3);
            elsif Mnemonic = "add" then
               Current.Op := Add;
               Current.N := Register (2);
               Current.M := Register (3);
               Current.Shift := Shifted (4);
            elsif Mnemonic in "lsr" | "asr" | "and" then
               Current.Op := (if Mnemonic = "lsr" then Shift_Right
                              elsif Mnemonic = "asr" then Shift_Signed
                              else And_Mask);
               Current.N := Register (2);
               Current.Value := Number (US.To_String (Operands (3)));
            elsif Mnemonic in "neg" | "mov" | "sxtb" | "sxth" | "sxtw" then
               Current.Op := (if Mnemonic = "neg" then Negate
                              elsif Mnemonic = "mov" then Copy
                              elsif Mnemonic = "sxtb" then Extend_8
                              elsif Mnemonic = "sxth" then Extend_16
                              else Extend_32);
               Current.N := Register (2);
            elsif Mnemonic = "msub" then
               Current.Op := Multiply_Subtract;
               Current.N := Register (2);
               Current.M := Register (3);
               Current.A := Register (4);
            else
               Fail ("unmodelled line " & Text);
               return;
            end if;
            if Current.D not in 9 | 11 | 12 | 14
              and then Current.D /= Result
            then
               Fail ("writes x" & Natural'Image (Current.D) & ": " & Text);
            end if;
            Length := Length + 1;
            Program (Length) := Current;
         end Line;
      begin
         Length := 0;
         for Index in Lines'Range loop
            if Lines (Index) = LF then
               Line (Lines (First .. Index - 1));
               First := Index + 1;
            end if;
         end loop;
         Line (Lines (First .. Lines'Last));
         if Length = 0 or else Program (Length).D /= Result then
            Fail ("the result is not written last: " & Lines);
         end if;
      end Parse;

      function Run
        (Program : Steps; Length : Natural; Input : Natural;
         Dividend : Word) return Registers
      is
         X : Registers := [others => 16#DEAD_BEEF_DEAD_BEEF#];

         function Sign (Value : Word; Bits : Natural) return Word is
           (if (Value / 2 ** (Bits - 1) and 1) = 1
            then (Value and (2 ** Bits - 1)) - 2 ** Bits
            else Value and (2 ** Bits - 1));
      begin
         X (Input) := Dividend;
         for Index in 1 .. Length loop
            declare
               S : Step renames Program (Index);
               N : constant Word := X (S.N);
               M : constant Word := X (S.M);
            begin
               X (S.D) :=
                 (case S.Op is
                     when Move_Zero => S.Value * 2 ** S.Shift,
                     when Move_Not => not (S.Value * 2 ** S.Shift),
                     when Move_Keep =>
                       (X (S.D) and not (16#FFFF# * 2 ** S.Shift))
                       or S.Value * 2 ** S.Shift,
                     when High => Upper (N, M),
                     when Signed_High => Signed_Upper (N, M),
                     when Add => N + M / 2 ** S.Shift,
                     when Sub => N - M,
                     when Shift_Right => N / 2 ** Natural (S.Value),
                     when Shift_Signed =>
                       (if N >= 2 ** 63
                        then not ((not N) / 2 ** Natural (S.Value))
                        else N / 2 ** Natural (S.Value)),
                     when And_Mask => N and S.Value,
                     when Negate => 0 - N,
                     when Multiply_Subtract => X (S.A) - N * M,
                     when Copy => N,
                     when Extend_8 => Sign (N, 8),
                     when Extend_16 => Sign (N, 16),
                     when Extend_32 => Sign (N, 32));
            end;
         end loop;
         return X;
      end Run;

      procedure Divisor
        (Bits : R.Dividend_Bits; Signed : Boolean; Magnitude : Word;
         Negative : Boolean)
      is
         Mask : constant Word :=
           (if Bits = 64 then Word'Last else 2 ** Bits - 1);
         Placements : constant array (0 .. 2) of Natural := [20, 9, 20];
         Results : constant array (0 .. 2) of Natural := [21, 9, 9];
         Placement : constant Natural := Natural (Magnitude mod 3);
         Input : constant Natural := Placements (Placement);
         Output : constant Natural := Results (Placement);
         Divisor_Value : constant Wide :=
           (if not Signed then 0
            elsif Negative then -Wide (Magnitude - 1) - 1
            else Wide (Magnitude));
         Least : constant Word := (if Signed then 2 ** (Bits - 1) else 0);
         Programs : array (Boolean) of Steps;
         Lengths : array (Boolean) of Natural := [0, 0];
         Claims : array (Boolean) of Boolean := [False, False];

         procedure Try (Dividend : Word);

         procedure Try (Dividend : Word) is
            Pattern : constant Word := Dividend and Mask;
            Value : constant Wide :=
              (if Signed then As_Wide
                 ((if (Pattern and Least) /= 0 then Pattern - 2 * Least
                   else Pattern))
               else 0);
         begin
            for Remainder in Boolean loop
               declare
                  Final : constant Registers :=
                    Run (Programs (Remainder), Lengths (Remainder), Input,
                         Pattern);
                  Got : constant Word := Final (Output);
                  Expected : constant Word :=
                    (if not Signed
                     then (if Remainder then Pattern mod Magnitude
                           else Pattern / Magnitude)
                     else As_Word
                       (if Remainder then Value rem Divisor_Value
                        else Value / Divisor_Value)) and Mask;
               begin
                  Checked := Checked + 1;
                  if (Got and Mask) /= Expected
                    or else (Claims (Remainder) and then Got /= Expected)
                  then
                     Fail ((if Signed then "i" else "u")
                           & R.Dividend_Bits'Image (Bits)
                           & (if Remainder then " %" else " /")
                           & (if Negative then " -" else " ")
                           & Word'Image (Magnitude) & " of"
                           & Word'Image (Pattern) & " gave"
                           & Word'Image (Got));
                  end if;
               end;
            end loop;
         end Try;
      begin
         if not Selection.Divides_By_Constant
           (Bits, Signed, Magnitude, Negative, Reciprocal => True)
         then
            return;
         end if;
         for Remainder in Boolean loop
            declare
               Lines : US.Unbounded_String;
            begin
               Selection.Divide_By_Constant
                 (Bits, Signed, Remainder, Magnitude, Negative,
                  "x" & Ada.Strings.Fixed.Trim
                    (Natural'Image (Input), Ada.Strings.Both),
                  "x" & Ada.Strings.Fixed.Trim
                    (Natural'Image (Output), Ada.Strings.Both),
                  Lines, Claims (Remainder));
               Parse (US.To_String (Lines), Programs (Remainder),
                      Lengths (Remainder), Output);
               Sequences := Sequences + 1;
            end;
         end loop;
         if Bits = 8 then
            for Dividend in Word range 0 .. 255 loop
               Try (Dividend);
            end loop;
            return;
         end if;
         for Edge of Word_Array'
           [0, 1, 2, Mask, Mask - 1, Mask / 2, Mask / 2 + 1,
            Magnitude - 1, Magnitude, Magnitude + 1,
            2 * Magnitude - 1, Mask / Magnitude * Magnitude,
            Mask / Magnitude * Magnitude - 1,
            0 - Magnitude, 1 - Magnitude, 0 - 2 * Magnitude]
         loop
            Try (Edge);
         end loop;
         for Spread in 1 .. 40 loop
            Try (Next);
         end loop;
      end Divisor;

      procedure Divisors (Bits : R.Dividend_Bits; Signed : Boolean) is
         Width : constant Natural := (if Signed then Bits - 1 else Bits);
         Largest : constant Word :=
           (if Width = 64 then Word'Last else 2 ** Width - 1);

         procedure Both (Magnitude : Word);

         procedure Both (Magnitude : Word) is
         begin
            if Magnitude in 1 .. Largest then
               Divisor (Bits, Signed, Magnitude, Negative => False);
            end if;
            if Signed and then Magnitude in 1 .. Largest + 1 then
               Divisor (Bits, Signed, Magnitude, Negative => True);
            end if;
         end Both;
      begin
         if Bits = 8 then
            for Magnitude in Word range 1 .. Largest + 1 loop
               Both (Magnitude);
            end loop;
            return;
         end if;
         for Magnitude in Word range 1 .. 1_100 loop
            Both (Magnitude);
         end loop;
         for Power in 11 .. Width loop
            Both (2 ** Power - 1);
            Both (2 ** Power);
            Both (2 ** Power + 1);
            Both (2 ** Power + 2 ** (Power - 1));
         end loop;
         Both (Largest);
         Both (Largest - 1);
         for Spread in 1 .. 32 loop
            Both (Next and Largest);
         end loop;
      end Divisors;
   begin
      for Bits in R.Dividend_Bits loop
         Divisors (Bits, Signed => False);
         Divisors (Bits, Signed => True);
      end loop;
      Landin.Testing.Check
        (Item, Failed = 0 and then Checked > 1_000_000
         and then Sequences > 10_000,
         "every selected quotient and remainder is the division's;"
         & Natural'Image (Failed) & " of" & Natural'Image (Checked)
         & " differ, first " & US.To_String (First_Failure));
   end Reciprocals_Select_Exactly;

   --  Size and speed compute where the result lives with immediates that
   --  fit: the checked u32 product of fasta's generator is one widening
   --  multiply and a test of its upper half, its sum one flag-setting add
   --  in the 32-bit view.  Speed multiplies by the modulus's reciprocal.
   --  The reference profile keeps its placed constants, the accumulator
   --  and the 64-bit fit test.
   procedure Arithmetic_Shapes (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_Arm64);
   begin
      Lower
        (Item, Work,
         "public step: (inout seed: u32) -> (value: u32) = "
         & "seed = (seed * 3877 + 29573) % 139968 value = seed end step "
         & "public bits: (a: u64, b: u8) -> (r: u64) = "
         & "r = (a & 255) | u64(b) r = r ^ 4294967295 end bits "
         & "public count: (n: i32) -> (r: i32) = mut i: i32 = 0 "
         & "while i < n do inc i end while r = i - 5 end count");
      for Objective in Opt.Objective loop
         declare
            Text : constant String := Emitted (Work, Objective);
         begin
            if Objective = Opt.None then
               Landin.Testing.Check
                 (Item, Contains (Text, HT & "udiv x11, x9, x10")
                  and then Contains (Text, HT & "mul x9, x9, x10")
                  and then Contains (Text, HT & "movz x9, #255" & LF)
                  and then not Contains (Text, "umull")
                  and then not Contains (Text, "#0xff"),
                  "none keeps the accumulator, placed constants and the"
                  & " 64-bit fit test");
            else
               Landin.Testing.Check
                 (Item, Contains (Text, "umull x")
                  and then Contains (Text, ", #0xffffffff00000000")
                  and then Contains (Text, HT & "adds w")
                  and then Contains (Text, ", #0xff" & LF)
                  and then Contains (Text, ", #0xffffffff" & LF)
                  and then Contains (Text, ", #1" & LF & HT & "b.vs ")
                  and then Contains (Text, HT & "subs w")
                  and then not Contains (Text, "movz x9, #255" & LF)
                  and then not Contains (Text, "movz x9, #1" & LF),
                  "size and speed compute in the result's view with"
                  & " immediates and the widening multiply");
               Landin.Testing.Check
                 (Item, Contains (Text, "udiv") = (Objective = Opt.Size)
                  and then Contains (Text, "umulh") = (Objective = Opt.Speed),
                  "only speed multiplies by the modulus's reciprocal");
            end if;
         end;
      end loop;
   end Arithmetic_Shapes;

   --  Speed divides by every known divisor without a divide instruction
   --  or the division's traps, at every width; size and none keep the
   --  divide for any divisor that is not a power of two, and size and
   --  speed shift or mask for one that is.
   procedure Speed_Multiplies_Known_Divisors
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_Arm64);
   begin
      Lower
        (Item, Work,
         "public a: (n: u8) -> (r: u8) = r = n / 10 end a "
         & "public b: (n: i16) -> (r: i16) = r = n % -7 end b "
         & "public c: (n: u32) -> (r: u32) = r = n % 139968 end c "
         & "public d: (n: i32) -> (r: i32) = r = n / -1000 end d "
         & "public e: (n: u64) -> (r: u64) = r = n / 7 end e "
         & "public f: (n: i64) -> (r: i64) = r = n % 641 end f "
         & "public g: (n: u32) -> (r: u32) = r = n / 16 end g "
         & "public h: (n: i64) -> (r: i64) = r = n % -8 end h");
      for Objective in Opt.Objective loop
         declare
            Text : constant String := Emitted (Work, Objective);
            Divides : constant Natural :=
              Count (Text, HT & "udiv ") + Count (Text, HT & "sdiv ");
            Traps : constant Natural := Count (Text, "_trap" & LF);
         begin
            if Objective = Opt.Speed then
               Landin.Testing.Check
                 (Item, Divides = 0 and then Traps = 0
                  and then Count (Text, HT & "umulh ") = 3
                  and then Count (Text, HT & "smulh ") = 3
                  and then Contains (Text, HT & "lsr x")
                  and then Contains (Text, ", #0xfffffffffffffff8" & LF),
                  "speed multiplies by six reciprocals, shifts and masks"
                  & " for two powers of two, and keeps no trap");
            else
               Landin.Testing.Check
                 (Item, Divides = (if Objective = Opt.None then 8 else 6)
                  and then not Contains (Text, "mulh"),
                  "size and none divide by known divisors, size by no"
                  & " power of two");
            end if;
         end;
      end loop;
   end Speed_Multiplies_Known_Divisors;

   --  An optimized comparison that the next branch tests is a cmp or fcmp
   --  and one conditional branch, inverted to fall through to the block
   --  that follows; an fcmp's conditions each split an unordered pair as
   --  D162 does, so no NaN test is added.  The reference profile makes
   --  every verdict a bool first and tests it.
   procedure Comparisons_Branch_On_Flags
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_Arm64);
   begin
      Lower
        (Item, Work,
         "public probe: (a: f64, b: f32, c: f32, n: u32) -> (r: u32) = "
         & "r = 0 "
         & "if a < 1.0 then r = 1 end if "
         & "if a >= 2.0 then r = 2 end if "
         & "if b <= c then r = 3 end if "
         & "if b > c then r = 4 end if "
         & "if a == 0.0 then r = 5 end if "
         & "if b <> c then r = 6 end if "
         & "while r < n do inc r end while end probe "
         & "public value: (a: f64, b: f64) -> (r: bool) = r = a < b "
         & "end value");
      for Objective in Opt.Objective loop
         declare
            Text : constant String := Emitted (Work, Objective);
            Probe : constant String := Routine (Text, "probe");
         begin
            if Objective = Opt.None then
               Landin.Testing.Check
                 (Item, Count (Probe, HT & "cset w9, ") = 7
                  and then Count (Probe, HT & "cbnz w9, ") = 7,
                  "the reference profile stores each verdict and tests it");
            else
               Landin.Testing.Check
                 (Item, Probe /= "" and then not Contains (Probe, "cset")
                  and then not Contains (Probe, "cbnz")
                  and then Count (Probe, HT & "fcmp d") = 3
                  and then Count (Probe, ", #0.0" & LF) = 1
                  and then Count (Probe, HT & "fcmp s") = 3
                  and then Count (Probe, HT & "b.vs") = 0
                  and then Contains (Probe, HT & "b.pl ")
                  and then Contains (Probe, HT & "b.lt ")
                  and then Contains (Probe, HT & "b.hi ")
                  and then Contains (Probe, HT & "b.le ")
                  and then Contains (Probe, HT & "b.ne ")
                  and then Contains (Probe, HT & "b.eq ")
                  and then Contains (Probe, HT & "b.hs "),
                  "size and speed branch on the comparisons' own flags,"
                  & " each inverted to fall through");
               Landin.Testing.Check
                 (Item, Contains (Routine (Text, "value"), "cset w"),
                  "a comparison that is a value still sets one");
            end if;
         end;
      end loop;
   end Comparisons_Branch_On_Flags;

   --  Size and speed place no constant that only selection reads: an
   --  f64 two or four is fmov's immediate, any other float goes through
   --  x9 straight into its register, and a zero is stored from the zero
   --  register.  None stores each to a frame home and reloads it.
   procedure Constants_Live_Nowhere (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_Arm64);
   begin
      Lower
        (Item, Work,
         "public scale: (a: f64) -> (r: f64) = "
         & "mut x: f64 = 0.0 x = a * 2.0 r = x / 4.0 + 0.1 end scale");
      for Objective in Opt.Objective loop
         declare
            Text : constant String := Emitted (Work, Objective);
         begin
            if Objective = Opt.None then
               Landin.Testing.Check
                 (Item, not Contains (Text, "#2.0")
                  and then Contains (Text, HT & "movz x9, #0" & LF
                                     & HT & "stur x9, "),
                  "none places every constant");
            else
               Landin.Testing.Check
                 (Item, Contains (Text, HT & "fmov d17, #2.0" & LF)
                  and then Contains (Text, HT & "fmov d17, #4.0" & LF)
                  and then Contains (Text, HT & "fmov d17, x9" & LF)
                  and then (Objective = Opt.Speed
                            or else Contains (Text, HT & "stur xzr, "))
                  and then not Contains (Text, "movz x9, #0" & LF),
                  "size and speed put constants straight where they are"
                  & " used");
            end if;
         end;
      end loop;
   end Constants_Live_Nowhere;

   --  Speed moves a fixed extent of up to 64 bytes as straight pairs of
   --  words and a narrower tail, with no alignment test or loop; a longer
   --  one, and every one at size and none, keeps the loop.
   procedure Speed_Unrolls_Transfers
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_Arm64);
   begin
      Lower
        (Item, Work,
         "mut pair: [2]usize mut other: [2]usize "
         & "mut odd: [61]u8 mut copy: [61]u8 "
         & "mut wide: [9]usize mut wider: [9]usize "
         & "public move: () -> none = other = pair copy = odd "
         & "wider = wide pair = zeroed end move");
      for Objective in Opt.Objective loop
         declare
            Text : constant String := Emitted (Work, Objective);
            Loops : constant Natural := Count (Text, "_words:");
         begin
            if Objective = Opt.Speed then
               Landin.Testing.Check
                 (Item, Loops = 1
                  and then Contains (Text, HT & "ldp x12, x13, [x10]" & LF)
                  and then Contains (Text, HT & "stp x12, x13, [x9, #32]")
                  and then Contains (Text, HT & "ldr w12, [x10, #56]")
                  and then Contains (Text, HT & "ldrb w12, [x10, #60]")
                  and then Contains (Text, HT & "stp xzr, xzr, [x9]" & LF),
                  "speed moves sixteen and sixty-one bytes straight,"
                  & " seventy-two in a loop");
            else
               Landin.Testing.Check
                 (Item, Loops = 4,
                  "size and none keep one loop per transfer");
            end if;
         end;
      end loop;
   end Speed_Unrolls_Transfers;

   --  Size and speed reach a frame cell with one subtraction from the
   --  frame pointer, and save and restore the callee-saved registers two
   --  adjacent homes at a time, from x15 set once when the homes lie past
   --  the unscaled range.  None builds every offset in a register first.
   procedure Frames_Reach_Homes (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_Arm64);
   begin
      Lower
        (Item, Work,
         "weigh: (value: u64) -> (r: u64) = r = value * 3 + 1 end weigh "
         & "public sum: (values: [64]u64, n: usize) -> (r: u64) = "
         & "mut total: u64 = 0 mut at: usize = 0 "
         & "while at < n do total = total + weigh(values[at]) inc at "
         & "end while r = total end sum");
      for Objective in Opt.Objective loop
         declare
            Text : constant String := Emitted (Work, Objective);
         begin
            if Objective = Opt.None then
               Landin.Testing.Check
                 (Item, Contains (Text, HT & "movz x9, #512" & LF
                                  & HT & "sub x9, x29, x9" & LF)
                  and then not Contains (Text, HT & "stp x20, x19"),
                  "none builds each frame offset in a register");
            else
               Landin.Testing.Check
                 (Item, Contains (Text, HT & "sub x9, x29, #512" & LF)
                  and then not Contains (Text, "sub x9, x29, x9"),
                  "size and speed subtract a frame offset directly");
            end if;
            if Objective = Opt.Speed then
               Landin.Testing.Check
                 (Item, Contains (Text, HT & "sub x15, x29, #")
                  and then Contains (Text, HT & "stp x20, x19, [x15")
                  and then Contains (Text, HT & "ldp x20, x19, [x15")
                  and then not Contains (Text, HT & "movz x15, "),
                  "speed saves pairs of registers from one base");
            end if;
         end;
      end loop;
   end Frames_Reach_Homes;

   --  A slice element is the inclusive range from its index to itself:
   --  size and speed check the upper edge and leave out the lower one,
   --  the index against itself, which cannot fail.  None checks both.
   procedure Slice_Elements_Check_Once
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_Arm64);
   begin
      Lower
        (Item, Work,
         "public probe: (words: []u64, i: usize) -> (r: u64) = "
         & "r = words[i] end probe");
      for Objective in Opt.Objective loop
         declare
            Text : constant String := Emitted (Work, Objective);
            Guards : constant Natural :=
              Count (Text, "_trap" & LF);
         begin
            Landin.Testing.Check_Equal
              (Item, Guards, (if Objective = Opt.None then 2 else 1),
               "a slice element's guards at "
               & Opt.Objective'Image (Objective));
         end;
      end loop;
   end Slice_Elements_Check_Once;

   function Converted
     (Item : in out Landin.Testing.Context;
      Source : String;
      Objective : Opt.Objective) return String
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_Arm64);
   begin
      Lower (Item, Work, Source);
      Landin.IR.Simplification.Run
        (Landin.Stages.Code (Work).all, Landin.Targets.Linux_Arm64,
         Objective);
      Landin.IR.If_Conversion.Run
        (Landin.Stages.Code (Work).all, Landin.Targets.Linux_Arm64,
         Objective);
      return Emitted (Work, Objective);
   end Converted;

   --  D338: counting the elements a comparison holds for adds the flag
   --  cset takes from the comparison, and keeps the addition's check.
   procedure Counted_Flag_Adds (Item : in out Landin.Testing.Context) is
      Source : constant String :=
        "public floats: (t: []f64, v: f64) -> (n: usize) = "
        & "mut k: usize = 0 first: usize = 0 "
        & "for i in first..<lenof t do if v >= t[i] then inc k end if "
        & "end for n = k end floats "
        & "public signed: (t: []i32, v: i32) -> (n: u32) = "
        & "mut k: u32 = 0 first: usize = 0 "
        & "for i in first..<lenof t do if t[i] < v then inc k end if "
        & "end for n = k end signed "
        & "public wrapped: (t: []u64, v: u64) -> (n: u64) = "
        & "mut k: u64 = 0 first: usize = 0 "
        & "for i in first..<lenof t do if t[i] > v then k = k +% 1 end if "
        & "end for n = k end wrapped";
   begin
      for Objective in Opt.Size .. Opt.Speed loop
         declare
            Text : constant String := Converted (Item, Source, Objective);
            Floats : constant String := Routine (Text, "floats");
            Signed : constant String := Routine (Text, "signed");
            Wrapped : constant String := Routine (Text, "wrapped");
            Where : constant String :=
              " at " & Opt.Objective'Image (Objective);
         begin
            Landin.Testing.Check
              (Item, Contains (Floats, HT & "fcmp d")
                     and then Contains (Floats, ", ge" & LF)
                     and then Contains (Floats, HT & "cset w")
                     and then not Contains (Floats, "cbnz")
                     and then not Contains (Floats, "b.ge ")
                     and then not Contains (Floats, "b.lt "),
               "a float count adds cset's flag" & Where);
            Landin.Testing.Check
              (Item, Contains (Signed, HT & "cset w")
                     and then Contains (Signed, ", lt" & LF)
                     and then not Contains (Signed, "cbnz"),
               "a signed count adds cset's flag" & Where);
            Landin.Testing.Check
              (Item, Contains (Wrapped, HT & "cinc x")
                     and then Contains (Wrapped, ", hi" & LF)
                     and then not Contains (Wrapped, "cset"),
               "a count that cannot overflow is cinc" & Where);
         end;
      end loop;
      Landin.Testing.Check
        (Item, Contains
           (Routine (Converted (Item, Source, Opt.None), "floats"), "cbnz"),
         "none counts with a branch");
   end Counted_Flag_Adds;

   --  D338: a choice is csel or fcsel on the flags of the comparison right
   --  before it, or on a stored bool; fcmp leaves an unordered pair's
   --  flags so that `mi` is false for it, choosing the second value.
   procedure Choices_Select_Conditionally
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "public least: (a: i64, b: i64) -> (r: i64) = "
        & "if a < b then r = a else r = b end if end least "
        & "public fleast: (a: f64, b: f64) -> (r: f64) = "
        & "if a < b then r = a else r = b end if end fleast "
        & "public pick: (c: bool, a: u32, b: u32) -> (r: u32) = "
        & "if c then r = a else r = b end if end pick";
   begin
      for Objective in Opt.Size .. Opt.Speed loop
         declare
            Text : constant String := Converted (Item, Source, Objective);
            Least : constant String := Routine (Text, "least");
            Float_Least : constant String := Routine (Text, "fleast");
            Pick : constant String := Routine (Text, "pick");
            Where : constant String :=
              " at " & Opt.Objective'Image (Objective);
         begin
            Landin.Testing.Check
              (Item, Contains (Least, HT & "csel x")
                     and then Contains (Least, ", lt" & LF)
                     and then not Contains (Least, "cset"),
               "a signed minimum selects on the comparison's flags"
               & Where);
            Landin.Testing.Check
              (Item, Contains (Float_Least, HT & "fcmp d")
                     and then Contains (Float_Least, HT & "fcsel d")
                     and then Contains (Float_Least, ", mi" & LF),
               "a float minimum selects on mi" & Where);
            Landin.Testing.Check
              (Item, Contains (Pick, ", #0" & LF)
                     and then Contains (Pick, HT & "csel x")
                     and then Contains (Pick, ", ne" & LF),
               "a stored bool is compared before the selection" & Where);
         end;
      end loop;
      Landin.Testing.Check
        (Item, not Contains (Converted (Item, Source, Opt.None), "csel"),
         "none chooses with a branch");
   end Choices_Select_Conditionally;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "arm64 selection", "immediates are the encodings'",
         Selection_Immediates'Access);
      Landin.Testing.Register
        (Into, "arm64 selection", "reciprocals select exactly",
         Reciprocals_Select_Exactly'Access);
      Landin.Testing.Register
        (Into, "arm64 selection", "arithmetic shapes",
         Arithmetic_Shapes'Access);
      Landin.Testing.Register
        (Into, "arm64 selection", "speed multiplies by known divisors",
         Speed_Multiplies_Known_Divisors'Access);
      Landin.Testing.Register
        (Into, "arm64 selection", "comparisons branch on their flags",
         Comparisons_Branch_On_Flags'Access);
      Landin.Testing.Register
        (Into, "arm64 selection", "a counted comparison is a flag add",
         Counted_Flag_Adds'Access);
      Landin.Testing.Register
        (Into, "arm64 selection", "a choice is a conditional move",
         Choices_Select_Conditionally'Access);
      Landin.Testing.Register
        (Into, "arm64 selection", "constants live nowhere",
         Constants_Live_Nowhere'Access);
      Landin.Testing.Register
        (Into, "arm64 selection", "speed unrolls small transfers",
         Speed_Unrolls_Transfers'Access);
      Landin.Testing.Register
        (Into, "arm64 selection", "frames reach homes directly",
         Frames_Reach_Homes'Access);
      Landin.Testing.Register
        (Into, "arm64 selection", "slice elements check once",
         Slice_Elements_Check_Once'Access);
   end Register;

end Landin.Tests.Arm64_Selection_Suite;
