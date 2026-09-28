--  [1630]/[1990]'s register tables: what an assembly operand may be placed
--  `at` on each target, and what every ordinary block overwrites.
--
--  A register is a name this table answers for.  It is never text for the
--  assembler to interpret and never a lexical name: the checker asks here,
--  with the selected target's facts, and nothing outside Landin.Targets
--  asks the host what a register is.  Names are the architecture's own
--  full-width spellings -- `r3`, `rdx`, `x9` -- and `general` is the one
--  class, spelled the same on every target.

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

   --  A text word as the tables spell it, so `RAX` and `rax` are one.
   function Lowered (Word : String) return String;

   --  The text with every `{name}` slot replaced by Register and every
   --  doubled brace by one, which is what an instruction checker reads.
   function Filled (Text : String; Register : String) return String;

   --  [1990]'s uniform text rules on a hosted target, or the empty string:
   --  at most 4096 ASCII bytes in LF lines, instructions and no directive,
   --  comment, statement separator or label, and straight-line control.
   --  Which instructions exist is the platform assembler's to say.
   function Text_Error (Facts : Target_Facts; Text : String) return String
     with Pre => Architecture_Of (Facts) in X86_64 | Arm64;

end Landin.Targets.Assembly;
