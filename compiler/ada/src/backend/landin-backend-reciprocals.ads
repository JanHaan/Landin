--  Division by a known divisor as a multiplication by its reciprocal.
--
--  A divide instruction takes tens of cycles where a multiply and a shift
--  take a few.  For a divisor known when the program is compiled, Granlund
--  and Montgomery ("Division by Invariant Integers using Multiplication",
--  PLDI 1994) give a multiplier and a shift whose product with every
--  dividend of a given width is exactly the truncated quotient; Warren's
--  Hacker's Delight, chapter 10, gives the signed form and the correction
--  a multiplier one bit too wide for its register needs.  This package is
--  that arithmetic on the divisor alone.  Which instructions apply it is a
--  backend's, and none of it asks the host how wide anything is.
--
--  Every form reads the dividend N as a 64-bit value, zero- or
--  sign-extended from its own width, and takes T, the high 64 bits of its
--  128-bit product with Multiplier, unsigned or signed as the division is:
--
--    unsigned  Q = T / 2 ** Shift,
--              or with Add, Q = ((N - T) / 2 + T) / 2 ** Shift;
--    signed    Q = floor ((T, or with Add T + N) / 2 ** Shift),
--              plus one when that is negative, so that Q truncates.
--
--  A signed reciprocal is the one for the divisor's magnitude, and a
--  negative divisor negates the quotient afterwards.  A dividend of 32 bits
--  or fewer never needs Add or Shift: its multiplier is scaled into the
--  whole high half instead, so one high multiply is the quotient.

package Landin.Backend.Reciprocals is

   type Word is mod 2 ** 64;

   subtype Dividend_Bits is Positive
     with Static_Predicate => Dividend_Bits in 8 | 16 | 32 | 64;

   type Reciprocal is record
      Multiplier : Word := 0;
      Shift      : Natural := 0;
      Add        : Boolean := False;
   end record;

   --  A power of two needs no reciprocal: a shift divides by it.
   function Is_Power_Of_Two (Divisor : Word) return Boolean
     is (Divisor /= 0 and then (Divisor and (Divisor - 1)) = 0);

   --  Divisor is neither zero nor a power of two, and below 2 ** Bits.
   function Unsigned_Reciprocal
     (Divisor : Word; Bits : Dividend_Bits) return Reciprocal;

   --  Magnitude is neither zero nor a power of two, and below
   --  2 ** (Bits - 1): the divisor's absolute value.
   function Signed_Reciprocal
     (Magnitude : Word; Bits : Dividend_Bits) return Reciprocal;

end Landin.Backend.Reciprocals;
