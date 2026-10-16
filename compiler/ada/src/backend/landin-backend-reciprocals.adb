package body Landin.Backend.Reciprocals is

   --  floor (log2 Value) + 1: for a divisor that is not a power of two,
   --  the exponent of the next power of two above it.
   function Bit_Length (Value : Word) return Natural;

   --  2 ** Power / Divisor and its remainder, one bit of long division at
   --  a time so that no integer wider than a Word is needed.  The caller
   --  asks only for quotients below 2 ** 64.
   procedure Divide_Power
     (Power     : Natural;
      Divisor   : Word;
      Quotient  : out Word;
      Remainder : out Word);

   procedure Require
     (Divisor : Word; Bits : Dividend_Bits; Limit : Natural);

   function Bit_Length (Value : Word) return Natural is
      Rest  : Word := Value;
      Count : Natural := 0;
   begin
      while Rest /= 0 loop
         Rest := Rest / 2;
         Count := Count + 1;
      end loop;
      return Count;
   end Bit_Length;

   procedure Divide_Power
     (Power     : Natural;
      Divisor   : Word;
      Quotient  : out Word;
      Remainder : out Word)
   is
      Carried : Boolean;
   begin
      --  Divisor is at least three, so 2 ** 0 is its own remainder.  A
      --  doubled remainder may pass 2 ** 64 when the divisor is above
      --  2 ** 63; it is then certainly at least the divisor, and the
      --  modular subtraction still leaves the true remainder.
      Quotient := 0;
      Remainder := 1;
      for Step in 1 .. Power loop
         Carried := Remainder >= 2 ** 63;
         Remainder := Remainder * 2;
         Quotient := Quotient * 2;
         if Carried or else Remainder >= Divisor then
            Remainder := Remainder - Divisor;
            Quotient := Quotient + 1;
         end if;
      end loop;
   end Divide_Power;

   procedure Require
     (Divisor : Word; Bits : Dividend_Bits; Limit : Natural) is
   begin
      if Divisor < 3 or else Is_Power_Of_Two (Divisor)
        or else Bit_Length (Divisor) > Limit
      then
         raise Landin.Compiler_Defect with
           "no reciprocal for a" & Dividend_Bits'Image (Bits)
           & "-bit divisor of" & Word'Image (Divisor);
      end if;
   end Require;

   --  The multiplier is m = ceil (2 ** K / d), whose error m * d - 2 ** K
   --  is below d.  Granlund and Montgomery's theorem 4.2 makes the
   --  quotient exact for every N-bit dividend when that error is at most
   --  2 ** (K - N).
   function Unsigned_Reciprocal
     (Divisor : Word; Bits : Dividend_Bits) return Reciprocal
   is
      Length : Natural;
      Quotient, Remainder : Word;
   begin
      Require (Divisor, Bits, Bits);
      Length := Bit_Length (Divisor);
      if Bits <= 32 then
         --  K = N + Length, so the error, below d and so below
         --  2 ** Length, is small enough.  m is below 2 ** (N + 1), and
         --  K is at most 64: scaled up by the 64 - K bits K leaves, it
         --  still fits a Word, and the high half is the quotient.
         Divide_Power (Bits + Length, Divisor, Quotient, Remainder);
         return
           (Multiplier =>
              (Quotient + 1) * 2 ** (64 - Bits - Length),
            Shift => 0,
            Add => False);
      end if;

      --  A 64-bit dividend: try K = 63 + Length, whose m fits a Word;
      --  otherwise K = 64 + Length, whose m is 65 bits wide, and Add takes
      --  its top bit as one more addition of the dividend.
      Divide_Power (63 + Length, Divisor, Quotient, Remainder);
      if Divisor - Remainder < 2 ** (Length - 1) then
         return
           (Multiplier => Quotient + 1,
            Shift => Length - 1,
            Add => False);
      end if;
      declare
         Twice : constant Word := Remainder * 2;
         Up : constant Word :=
           (if Twice >= Divisor or else Twice < Remainder then 1 else 0);
      begin
         return
           (Multiplier => Quotient * 2 + Up + 1,
            Shift => Length - 1,
            Add => True);
      end;
   end Unsigned_Reciprocal;

   --  The same theorem for signed dividends of magnitude at most
   --  2 ** (N - 1).  Floor rounds a negative quotient down, which is why
   --  the backend adds one to it.
   function Signed_Reciprocal
     (Magnitude : Word; Bits : Dividend_Bits) return Reciprocal
   is
      Length : Natural;
      Quotient, Remainder : Word;
   begin
      Require (Magnitude, Bits, Bits - 1);
      Length := Bit_Length (Magnitude);
      if Bits <= 32 then
         --  K = N - 1 + Length, at most 62.  m is below 2 ** N, so the
         --  scaled multiplier stays below 2 ** 63: a positive signed
         --  operand.
         Divide_Power (Bits - 1 + Length, Magnitude, Quotient, Remainder);
         return
           (Multiplier =>
              (Quotient + 1) * 2 ** (65 - Bits - Length),
            Shift => 0,
            Add => False);
      end if;

      --  A 64-bit dividend: K = 62 + Length when its m is below 2 ** 63;
      --  otherwise K = 63 + Length, whose m reads as negative in a signed
      --  multiply, and Add puts back the dividend that subtracted.
      Divide_Power (62 + Length, Magnitude, Quotient, Remainder);
      if Magnitude - Remainder < 2 ** (Length - 1) then
         return
           (Multiplier => Quotient + 1,
            Shift => Length - 2,
            Add => False);
      end if;
      declare
         Twice : constant Word := Remainder * 2;
         Up : constant Word :=
           (if Twice >= Magnitude or else Twice < Remainder then 1 else 0);
      begin
         return
           (Multiplier => Quotient * 2 + Up + 1,
            Shift => Length - 1,
            Add => True);
      end;
   end Signed_Reciprocal;

end Landin.Backend.Reciprocals;
