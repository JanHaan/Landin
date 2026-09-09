--  Final selected instruction evidence.  Opcodes and operand tokens retain
--  widths, exact external relocation spellings and addends.  Only labels
--  explicitly defined inside a body become canonical local identities.
private with Ada.Containers.Vectors;
private with Ada.Strings.Unbounded;
with Landin.Build_Reports;

package Landin.Backend.X86_64.Machine is

   type Stream is private;
   --  Counting is unconditional; canonical evidence is optional and only
   --  useful for bodies whose identity permits machine-body sharing.
   procedure Start (Into : out Stream; Record_Body : Boolean := True);
   function Is_Recording (Of_Stream : Stream) return Boolean;
   function Retained_Tokens (Of_Stream : Stream) return Natural;
   function Retained_Labels (Of_Stream : Stream) return Natural;
   procedure Instruction (Into : in out Stream; Text : String);
   procedure Define_Label (Into : in out Stream; Name : String);
   procedure Seal (Into : in out Stream);
   function Equivalent (Left, Right : Stream) return Boolean;
   function Statistics (Of_Stream : Stream)
     return Landin.Build_Reports.Routine_Statistics;

   --  Pure selection; only encodings with exactly the same flag/register
   --  effects are shortened.  Empty means a redundant non-widening self move.
   function Selected (Text : String) return String;

private

   type Token_Kind is (Mnemonic, Operand, Punctuation, Definition, Local);
   type Token is record
      Kind : Token_Kind := Operand;
      Text : Ada.Strings.Unbounded.Unbounded_String;
      Identity : Natural := 0;
   end record;
   package Token_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Token);
   package Name_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive,
      Element_Type => Ada.Strings.Unbounded.Unbounded_String,
      "=" => Ada.Strings.Unbounded."=");
   type Stream is record
      Tokens : Token_Vectors.Vector;
      Labels : Name_Vectors.Vector;
      Counts : Landin.Build_Reports.Routine_Statistics;
      Recording : Boolean := True;
      Sealed : Boolean := False;
   end record;

end Landin.Backend.X86_64.Machine;
