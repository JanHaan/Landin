--  arm64 instruction choices that depend on nothing but their operands.
--
--  Which constants an instruction can carry inside itself, the move-wide
--  lines that give a register any 64-bit pattern, and the multiply and
--  shift sequence that divides by a divisor known when the program is
--  compiled.  Each answers with assembly text alone and the backend writes
--  it with its own line discipline; none of it asks the host anything.
--
--  It also declares, in one place, the registers instruction selection
--  writes on its own account, which register allocation must leave alone.

with Ada.Strings.Unbounded;

with Landin.Backend.Reciprocals;

package Landin.Backend.Arm64.Selection is

   subtype Word is Landin.Backend.Reciprocals.Word;
   use type Word;

   --  Inside any one IR operation, selection may write x9-x17 and d16-d17
   --  as scratch, whatever the operation is: a location allocation placed
   --  in one would not survive the next operation.  x8 carries a call's
   --  failure code, x18 is the platform's, and x29 and x30 are the frame
   --  record.  x0-x7 and d0-d7 are written only to pass a call's
   --  arguments and take its result, to return a routine's own result,
   --  at the routine's entry and on a panic edge, which does not return;
   --  a call clobbers every one of them anyway.  [1630]'s text may name
   --  any register, and allocation already gives way to it.
   subtype General_Scratch is Natural range 9 .. 17;
   subtype Float_Scratch is Natural range 16 .. 17;

   --  Whether selection may write general register x<Number> inside an
   --  operation, as above: the scratch registers and the four it never
   --  lends.
   function Is_Reserved (Number : Natural) return Boolean
     is (Number in General_Scratch | 8 | 18 | 29 | 30);

   --  The lines, LF-separated and without indentation, that give Register
   --  the pattern Value: a movz or movn seed and a movk for every 16-bit
   --  chunk the seed does not already supply.
   function Immediate (Register : String; Value : Word) return String;

   --  The operand text of an add, sub, cmp or cmn immediate that is Value,
   --  twelve bits alone or shifted left by twelve, or "" when none is.
   function Arithmetic_Immediate (Value : Word) return String;

   --  Whether and, orr, eor and tst at Bits, 32 or 64, can carry Value: a
   --  rotated run of ones repeated across the register.  Value is below
   --  2 ** Bits, and neither zero nor every bit qualifies.
   function Is_Logical_Immediate (Value : Word; Bits : Positive)
     return Boolean;

   --  The operand text of a logical immediate, in hexadecimal.
   function Hexadecimal (Value : Word) return String;

   --  fmov's eight-bit immediate whose expansion is the f32 (Single) or
   --  f64 bit pattern Value, as `#` and a decimal every assembler reads
   --  exactly, or "" when none is: zero is not one.
   function Float_Immediate (Value : Word; Single : Boolean) return String;

   --  Whether Divide_By_Constant has a sequence for this division: any
   --  nonzero power of two below 2 ** Bits except a signed minus one,
   --  whose quotient can overflow, and with Reciprocal any other.
   function Divides_By_Constant
     (Bits : Landin.Backend.Reciprocals.Dividend_Bits;
      Signed : Boolean;
      Magnitude : Word;
      Negative : Boolean;
      Reciprocal : Boolean) return Boolean
     is (Magnitude /= 0
         and then (Bits = 64 or else Magnitude < 2 ** Bits)
         and then not (Signed and then Negative and then Magnitude = 1)
         and then (Reciprocal
                   or else Landin.Backend.Reciprocals.Is_Power_Of_Two
                     (Magnitude)));

   --  The lines that leave in Result the quotient, or with Remainder the
   --  remainder, of the Bits-wide integer Dividend holds zero-extended,
   --  by the divisor Magnitude, negated when Negative.  A power of two is
   --  a shift or a mask; any other divisor is Landin.Backend.Reciprocals'
   --  high multiply and shifts, after which a remainder subtracts the
   --  quotient times the magnitude: the dividend's sign whatever the
   --  divisor's.  The divisor is known nonzero, and a signed one is not
   --  minus one, so no division here can trap.  Only Result and the
   --  scratch registers x9, x11, x12 and x14 are written, Result last,
   --  and Dividend may be x9.  Extended says whether Result is left
   --  zero-extended from Bits, which a signed result narrower than 64
   --  bits is not.
   procedure Divide_By_Constant
     (Bits : Landin.Backend.Reciprocals.Dividend_Bits;
      Signed : Boolean;
      Remainder : Boolean;
      Magnitude : Word;
      Negative : Boolean;
      Dividend, Result : String;
      Lines : out Ada.Strings.Unbounded.Unbounded_String;
      Extended : out Boolean)
     with Pre => Divides_By_Constant
                   (Bits, Signed, Magnitude, Negative, Reciprocal => True);

end Landin.Backend.Arm64.Selection;
