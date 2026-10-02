--  ELF assembly spellings, for every backend whose objects are ELF.
--
--  One place for the directives the GNU assembler reads on every ELF
--  target, so that a second ELF backend does not invent them a second time.
--  Each function returns the directive alone, without the tab a backend's
--  own line discipline puts in front of it, because the x86-64 and arm64
--  backends each own how a line is written and whether an optimizer reads
--  it.  Cortex-M's ARM spelling of section types (`%progbits` for
--  `@progbits`) is not here: the ARM assembler reads `@` as a comment.

package Landin.Backend.ELF is

   --  The prefix the assembler keeps out of the symbol table.  A backend
   --  extends it until no explicit link spelling collides with it.
   Local_Prefix : constant String := ".L";

   function Function_Type (Symbol : String) return String
     is (".type " & Symbol & ", @function");

   function Object_Type (Symbol : String) return String
     is (".type " & Symbol & ", @object");

   --  A symbol's size, measured from its label to here.
   function Size_To_Here (Symbol : String) return String
     is (".size " & Symbol & ", .-" & Symbol);

   --  A symbol's size, stated as a count of bytes already spelled.
   function Size (Symbol, Bytes : String) return String
     is (".size " & Symbol & ", " & Bytes);

   --  Visible to the link but not exported from the image.
   function Hidden (Symbol : String) return String
     is (".hidden " & Symbol);

   Read_Only_Section : constant String := ".section .rodata";

   --  Read-only once the loader has applied its relocations, which is what
   --  an evidence table of code addresses is in a position-independent
   --  image.
   Relocated_Read_Only_Section : constant String :=
     ".section .data.rel.ro.local,""aw""";

   Data_Section : constant String := ".data";

   Zero_Section : constant String := ".bss";

   --  An executable stack is inherited when nothing says otherwise, and
   --  nothing a Landin backend emits needs one.
   No_Executable_Stack : constant String :=
     ".section .note.GNU-stack,"""",@progbits";

   --  The panic handler's re-entry flag, in its own zero section so that
   --  pushing it changes nothing a routine or datum around it assumes.
   Push_Panic_Flag_Section : constant String :=
     ".pushsection .bss.landin_panic,""aw"",@nobits";

   Pop_Section : constant String := ".popsection";

end Landin.Backend.ELF;
