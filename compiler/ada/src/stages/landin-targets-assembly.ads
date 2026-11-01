--  [1630]/[1990]'s register tables: what an assembly operand may be placed
--  `at` on each target, and what every ordinary block overwrites.
--
--  A register is a name this table answers for.  It is never text for the
--  assembler to interpret and never a lexical name: the checker asks here,
--  with the selected target's facts, and nothing outside Landin.Targets
--  asks the host what a register is.  Names are the architecture's own
--  full-width spellings -- `r3`, `rdx`, `x9`, `xmm3`, `v8`, `f8` -- and
--  `general` and `float` are the two classes, each spelled the same on
--  every target (D630).

with Ada.Strings.Unbounded;
with Landin.Targets.Firmware;

package Landin.Targets.Assembly is

   --  D630: a Cortex-M profile's float registers are its description's
   --  float unit's (D615), which the target facts do not hold, so every
   --  question a float register's answer depends on also takes the unit.
   --  A hosted target has its float registers whatever the unit says.
   subtype Float_Unit is Landin.Targets.Firmware.Float_Unit;
   No_Float_Unit : constant Float_Unit :=
     Landin.Targets.Firmware.No_Float_Unit;

   --  What one written register name is on a target.
   type Register_Kind is
     (Not_A_Register,
      --  An ordinary integer register an operand may name.
      Operand_Register,
      --  The class the compiler chooses an integer register from.
      General_Class,
      --  A float register an operand may name, D630's.
      Float_Register,
      --  The class the compiler chooses a float register from.
      Float_Class,
      --  The stack, frame and link registers and the platform's reserved
      --  ones, which no operand may name and no ordinary block may write.
      Never_Named);

   function Classify
     (Facts : Target_Facts; Name : String;
      Unit : Float_Unit := No_Float_Unit) return Register_Kind;

   --  Whether an ordinary block may leave this operand register changed
   --  without declaring it.  The rest are callee-saved: naming one, as an
   --  operand or a discarded output, is what makes the routine save it.
   function Overwritten
     (Facts : Target_Facts; Name : String;
      Unit : Float_Unit := No_Float_Unit) return Boolean
     with Pre => Classify (Facts, Name, Unit)
                   in Operand_Register | Float_Register;

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

   --  D630: whether the target has float registers an operand may name.
   --  Cortex-M has them when its description selects a float unit,
   --  FPv5-D16's d0-d15, and the synthetic model has no registers at all.
   function Has_Float_Registers
     (Facts : Target_Facts; Unit : Float_Unit := No_Float_Unit)
      return Boolean;

   --  Whether `float` may choose this register: the ones every ordinary
   --  block overwrites.
   function In_Float_Class
     (Facts : Target_Facts; Name : String;
      Unit : Float_Unit := No_Float_Unit) return Boolean
     with Pre => Classify (Facts, Name, Unit) = Float_Register;

   --  How many registers `float` chooses from.
   function Float_Count
     (Facts : Target_Facts; Unit : Float_Unit := No_Float_Unit)
      return Natural;

   --  The registers `float` chooses from, in the order it chooses them.
   function Float_Class_Register
     (Facts : Target_Facts; Index : Positive;
      Unit : Float_Unit := No_Float_Unit) return String
     with Pre => Index <= Float_Count (Facts, Unit);

   --  The widest float a float register holds, in bits.
   function Float_Width
     (Facts : Target_Facts; Unit : Float_Unit := No_Float_Unit)
      return Bit_Width
     with Pre => Has_Float_Registers (Facts, Unit);

   --  The registers a text word names on this target, whatever width it is
   --  spelled at: `eax`, `ax` and `al` all name `rax`, `w9` names `x9`,
   --  `ymm3` names `xmm3`, `d8` and `s8` name `v8`, and `fs0` names `f8`;
   --  on a Cortex-M with a float unit `s16` and `s17` both name `d8`.
   --  The empty string when the word names no operand register.
   function Canonical
     (Facts : Target_Facts; Word : String;
      Unit : Float_Unit := No_Float_Unit) return String;

   --  Whether a text word names a register no ordinary block may name,
   --  at any of its widths.
   function Names_Reserved (Facts : Target_Facts; Word : String)
     return Boolean;

   --  Whether a text names Register, a canonical operand register, at any
   --  width outside its `{name}` slots.  A number is one word, so `0x9`
   --  names no `x9`.
   function Text_Names
     (Facts : Target_Facts; Text : String; Register : String;
      Unit : Float_Unit := No_Float_Unit) return Boolean;

   --  A text word as the tables spell it, so `RAX` and `rax` are one.
   function Lowered (Word : String) return String;

   --  The text with every `{name}` slot replaced by Register and every
   --  doubled brace by one, which is what an instruction checker reads.
   function Filled (Text : String; Register : String) return String;

   --  An operand register as the target's assembler spells it at a width
   --  of Bits: `%eax` or `%rax`, `w9` or `x9`, `r3`; a float register at
   --  its float's width, `%xmm3` for both, `s8` or `d8`, `f8` for both,
   --  and on a Cortex-M float unit `s16` or `d8`.
   function Spelled
     (Facts : Target_Facts; Register : String; Bits : Bit_Width;
      Unit : Float_Unit := No_Float_Unit) return String
     with Pre => (Classify (Facts, Register, Unit) = Operand_Register
                  and then Bits <= Register_Width (Facts))
                 or else (Classify (Facts, Register, Unit) = Float_Register
                          and then Bits <= Float_Width (Facts, Unit));

   --  One operand of a block as emission sees it: its template name,
   --  its register once chosen, the width its type selects, and whether
   --  that type is a float.  A `general` or `float` operand's register is
   --  empty until Choose fills it from the class its type selects.
   type Operand_Register_Choice is record
      Name     : Ada.Strings.Unbounded.Unbounded_String;
      Register : Ada.Strings.Unbounded.Unbounded_String;
      Bits     : Bit_Width := 32;
      Float    : Boolean := False;
   end record;

   type Operand_Register_Array is
     array (Positive range <>) of Operand_Register_Choice;

   --  [1630]'s `general` and `float`: each empty register, in written
   --  order, becomes the first register of its operand's class that no
   --  operand holds and the text does not name.  The checker has already
   --  refused a block a class cannot serve.
   procedure Choose
     (Facts : Target_Facts; Text : String;
      Operands : in out Operand_Register_Array;
      Unit : Float_Unit := No_Float_Unit);

   --  The text with every `{name}` replaced by that operand's register at
   --  its width, and every doubled brace by one.
   function Substituted
     (Facts : Target_Facts; Text : String;
      Operands : Operand_Register_Array;
      Unit : Float_Unit := No_Float_Unit) return String;

   --  D597: the line comment the architecture's own assembler reads, from
   --  this marker to the end of the line: `@` in Thumb, `//` on arm64 and
   --  `#` on x86-64 and RV64.  The synthetic model has none.
   function Comment_Marker (On : Architecture) return String;

   --  The text with each line's comment and the blanks before it removed.
   --  Every LF stays, so a line keeps its place.  This is the text the
   --  admission reads and the IR holds: a comment never meets an
   --  instruction, register or label check, a `{name}` in one is no slot,
   --  and emission writes none.
   function Uncommented (On : Architecture; Text : String) return String;

   --  The first number Line writes with a digit separator, `0x1800_0000`,
   --  or the empty string.  Block text is the assembler's syntax, whose
   --  numbers take none.
   function Separated_Number (Line : String) return String;

   --  The refusal of Line's first comment form that is not On's own, or of
   --  a statement separator, naming what to write instead; the empty
   --  string when Line, already uncommented, holds neither.
   function Foreign_Comment (On : Architecture; Line : String)
     return String;

   --  The refusal of a separated number, naming the number to write.
   function Separator_Refusal (Number : String) return String;

   --  [1990]'s uniform text rules on a hosted target, or the empty string:
   --  at most 4096 ASCII bytes in LF lines, instructions and no directive,
   --  statement separator or label, and straight-line control.  Each
   --  line's comment is removed first (D597).  A naked body's text may
   --  transfer control, since it owns its entry and its exit.  Which
   --  instructions exist is the platform assembler's to say.
   function Text_Error
     (Facts : Target_Facts; Text : String; Naked : Boolean := False)
      return String
     with Pre => Architecture_Of (Facts) in X86_64 | Arm64 | RV64;

end Landin.Targets.Assembly;
