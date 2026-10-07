--  Native RISC-V instruction selection shared by the RV64 emitter and a
--  future RV32 emitter. Width is a target fact supplied by the caller;
--  neither an instruction nor an extension changes the ABI or layout.
with Landin.Targets;

package Landin.Backend.RiscV_Instructions is

   subtype Register_Number is Natural range 0 .. 31;
   subtype Machine_Width is Landin.Targets.Bit_Width
     with Static_Predicate => Machine_Width in 32 | 64;
   type Pattern is mod 2 ** 64;

   function Register (Number : Register_Number) return String;

   --  GNU's LI pseudo-instruction materializes an exact XLEN-bit pattern.
   --  Spell the signed representative, including the minimum value, so no
   --  assembler has to accept a decimal integer outside its signed range.
   function Immediate
     (Destination : Register_Number; Value : Pattern;
      Width : Machine_Width) return String;

   function Memory
     (Store : Boolean; Size : Landin.Targets.Scalar_Size;
      Value, Base : Register_Number; Width : Machine_Width;
      Offset : Integer := 0; Signed : Boolean := False) return String
     with Pre => Landin.Targets.Bytes (Size) <= Integer (Width) / 8
       and then Offset in -2048 .. 2047;

   --  Extensions are independent capabilities, never ordered levels.
   --  Prefer the standard Zba encoding when both are assumed. All forms
   --  compute Base + Index * 2**Shift modulo XLEN. A shift greater than
   --  three has no extension form and keeps the baseline pair.
   function Indexed_Address
     (Destination, Base, Index, Scratch : Register_Number;
      Shift : Natural; Width : Machine_Width;
      Zba, Xtheadba : Boolean) return String
     with Pre => Shift < Natural (Width)
       and then Scratch /= Base and then Scratch /= Index
       and then Scratch /= 0;

end Landin.Backend.RiscV_Instructions;
