--  [1630]/[1990]'s register tables: what an assembly operand may be placed
--  `at` on each target, and what every ordinary block overwrites.
--
--  A register is a name this table answers for.  It is never text for the
--  assembler to interpret and never a lexical name: the checker asks here,
--  with the selected target's facts, and nothing outside Landin.Targets
--  asks the host what a register is.  Names are the architecture's own
--  full-width spellings -- `r3`, `rdx`, `x9` -- and `general` is the one
--  class, spelled the same on every target.

with Ada.Strings.Unbounded;

package Landin.Targets.Assembly is

   --  What one written register name is on a target.
   type Register_Kind is
     (Not_A_Register,
      --  An ordinary integer register an operand may name.
      Operand_Register,
      --  The class the compiler chooses a register from.
      General_Class,
      --  The stack, frame and link registers and the platform's reserved
      --  ones, which no operand may name and no ordinary block may write.
      Never_Named);

   function Classify (Facts : Target_Facts; Name : String)
     return Register_Kind;

   --  Whether an ordinary block may leave this operand register changed
   --  without declaring it.  The rest are callee-saved: naming one, as an
   --  operand or a discarded output, is what makes the routine save it.
   function Overwritten (Facts : Target_Facts; Name : String) return Boolean
     with Pre => Classify (Facts, Name) = Operand_Register;

   --  Whether `general` may choose this register.
   function In_General_Class (Facts : Target_Facts; Name : String)
     return Boolean
     with Pre => Classify (Facts, Name) = Operand_Register;

   --  How many registers `general` chooses from.
   function General_Count (Facts : Target_Facts) return Natural;

   --  The registers `general` chooses from, in the order it chooses them.
   function General_Register (Facts : Target_Facts; Index : Positive)
     return String
     with Pre => Index <= General_Count (Facts);

   --  The widest integer an operand register holds, in bits.
   function Register_Width (Facts : Target_Facts) return Bit_Width;

   --  Whether any assembly is enabled on the target at all.  The synthetic
   --  model has no instruction set to write.
   function Has_Registers (Facts : Target_Facts) return Boolean;

   --  The registers a text word names on this target, whatever width it is
   --  spelled at: `eax`, `ax` and `al` all name `rax`, `w9` names `x9`.
   --  The empty string when the word names no operand register.
   function Canonical (Facts : Target_Facts; Word : String) return String;

   --  Whether a text word names a register no ordinary block may name,
   --  at any of its widths.
   function Names_Reserved (Facts : Target_Facts; Word : String)
     return Boolean;

   --  Whether a text names Register, a canonical operand register, at any
   --  width outside its `{name}` slots.  A number is one word, so `0x9`
   --  names no `x9`.
   function Text_Names
     (Facts : Target_Facts; Text : String; Register : String)
      return Boolean;

   --  A text word as the tables spell it, so `RAX` and `rax` are one.
   function Lowered (Word : String) return String;

   --  The text with every `{name}` slot replaced by Register and every
   --  doubled brace by one, which is what an instruction checker reads.
   function Filled (Text : String; Register : String) return String;

   --  An operand register as the target's assembler spells it at an
   --  integer width of Bits: `%eax` or `%rax`, `w9` or `x9`, `r3`.
   function Spelled
     (Facts : Target_Facts; Register : String; Bits : Bit_Width)
      return String
     with Pre => Classify (Facts, Register) = Operand_Register
                 and then Bits <= Register_Width (Facts);

   --  One operand of a block as emission sees it: its template name,
   --  its register once chosen, and the width its type selects.  A
   --  `general` operand's register is empty until Choose fills it.
   type Operand_Register_Choice is record
      Name     : Ada.Strings.Unbounded.Unbounded_String;
      Register : Ada.Strings.Unbounded.Unbounded_String;
      Bits     : Bit_Width := 32;
   end record;

   type Operand_Register_Array is
     array (Positive range <>) of Operand_Register_Choice;

   --  [1630]'s `general`: each empty register, in written order, becomes
   --  the first register of the class that no operand holds and the text
   --  does not name.  The checker has already refused a block the class
   --  cannot serve.
   procedure Choose
     (Facts : Target_Facts; Text : String;
      Operands : in out Operand_Register_Array);

   --  The text with every `{name}` replaced by that operand's register at
   --  its width, and every doubled brace by one.
   function Substituted
     (Facts : Target_Facts; Text : String;
      Operands : Operand_Register_Array) return String;

   --  [1990]'s uniform text rules on a hosted target, or the empty string:
   --  at most 4096 ASCII bytes in LF lines, instructions and no directive,
   --  comment, statement separator or label, and straight-line control.
   --  Which instructions exist is the platform assembler's to say.
   function Text_Error (Facts : Target_Facts; Text : String) return String
     with Pre => Architecture_Of (Facts) in X86_64 | Arm64 | RV64;

end Landin.Targets.Assembly;
