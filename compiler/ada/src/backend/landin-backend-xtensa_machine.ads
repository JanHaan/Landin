--  Native Xtensa selection for the backend's 32-bit logical words.
--
--  The emitter writes a routine as RISC-V-form instructions over words:
--  the logical words x0-x31 its selection names, and for each scalar value
--  and eligible slot of an assembly-free routine a word `vN` of its own.
--  Such a routine is buffered whole (Begin_Routine to Finish_Routine): its
--  words' liveness is computed over the routine's own text, each word's
--  definitions are joined into webs, and the webs are placed in the
--  window's a2-a6, which every CALL8 preserves, and a10-a15, which it
--  does not, or in their homes in the frame (D1627).  a8 and a9 are
--  selection's own transients.  A routine with an `assembler.block`, or
--  whose text the analysis cannot follow, keeps every word in its home at
--  a7 + offset, a8-a13 as transients, and its scratch words x5-x7, x9 and
--  x18 in a2-a6 when it has no block.  No logical instruction is stored in
--  the emitted program.
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Landin.Backend.Xtensa_Machine is
   --  Compact homes exclude zero, SP, the derived immutable CFA and the
   --  scratch words x5-x7, x9 and x18, which an assembly-free routine
   --  keeps in registers; unused x26 has none.  Any other omitted logical
   --  word is refused rather than aliased.
   function Word_Offset (Word : Natural; Compact : Boolean)
      return Landin.Targets.Byte_Count;

   --  The bytes of an assembly-free routine's compact bank at a7.
   Compact_Bank_Bytes : constant := 80;

   procedure Select_Word
     (Instruction : String;
      Into : in out Ada.Strings.Unbounded.Unbounded_String;
      Serial : in out Natural;
      Frame_Bytes : Landin.Targets.Byte_Count := 0;
      Scratch_Registers : Boolean := False);

   --  Shorten only local jumps proved in range by a conservative bound
   --  over a complete framed routine, retaining arbitrary-range fallback.
   procedure Compact_Jumps
     (Into : in out Ada.Strings.Unbounded.Unbounded_String;
      First : Positive);

   --  One assembly-free routine's text while it is buffered.
   type Routine is limited private;

   --  The first value word's number, `v0`; a word above it is the
   --  emitter's own, given a home by Declare_Home before it is used.
   First_Value_Word : constant := 32;

   procedure Begin_Routine
     (Of_Routine : in out Routine;
      Frame_Bytes : Landin.Targets.Byte_Count);
   function Buffering (Of_Routine : Routine) return Boolean;

   --  Word's home at a7 + Offset, Bytes wide: 1, 2 or 4.  A narrower word
   --  holds its value zero-extended.
   procedure Declare_Home
     (Of_Routine : in out Routine;
      Word : Natural;
      Offset : Landin.Targets.Byte_Count;
      Bytes : Positive);

   --  A logical instruction, or several separated by line feeds.
   procedure Add (Of_Routine : in out Routine; Instruction : String);
   --  A label, directive or native line exactly as it is to be written.
   procedure Add_Line (Of_Routine : in out Routine; Line : String);

   --  Select the buffered routine into Into.  Registers is how many
   --  physical registers its placement used, zero when it kept every word
   --  in its home.
   procedure Finish_Routine
     (Of_Routine : in out Routine;
      Into : in out Ada.Strings.Unbounded.Unbounded_String;
      Serial : in out Natural;
      Registers : out Natural);

private
   type Line_Kind is (Logical, Line);
   type Buffered is record
      Kind : Line_Kind := Logical;
      Text : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   package Buffered_Vectors is new Ada.Containers.Vectors
     (Positive, Buffered);

   type Home is record
      Declared : Boolean := False;
      Offset : Landin.Targets.Byte_Count := 0;
      Bytes : Positive := 4;
   end record;
   package Home_Vectors is new Ada.Containers.Vectors (Natural, Home);

   type Routine is limited record
      Active : Boolean := False;
      Frame_Bytes : Landin.Targets.Byte_Count := 0;
      Lines : Buffered_Vectors.Vector;
      --  Indexed by word less First_Value_Word.
      Homes : Home_Vectors.Vector;
   end record;
end Landin.Backend.Xtensa_Machine;
