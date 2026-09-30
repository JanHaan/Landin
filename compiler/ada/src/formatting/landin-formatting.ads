--  The one layout of a Landin source.
--
--  D252 is the authority and `docs/format.md` shows every rule with a
--  written example and its formatted form.  A layout is a decision about
--  space only: no token is added, removed or changed, no comment's bytes
--  change, and no line is broken or joined.  What the formatter decides is
--  each line's indentation, the space between two tokens on one line, how
--  many blank lines survive, and that every line ends in one LF.
--
--  The answer is a list of edits and not a new file.  Each edit replaces
--  the space between two neighbours -- two tokens, a token and a comment,
--  or the edge of the file -- so the list is in byte order, never overlaps
--  and never touches a token or a comment, and it is exactly the shape an
--  editor's formatting request answers with.  An empty list is a file
--  already in the layout, which is how idempotence is stated: formatting a
--  formatted file offers nothing.  The formatted bytes come back beside the
--  edits for a caller that writes the file.
--
--  A source that does not scan or parse is refused with the syntax stage's
--  own report and no edit: a layout read from a tree recovery guessed at
--  would move code the reader has not finished writing.  Nothing later
--  than the parse is consulted, so a file whose names or types are wrong is
--  formatted all the same, and one file is formatted without the rest of
--  its module.
--
--  Nothing is kept.  The scan, the tree and every table the layout builds
--  are locals of one call; the snapshot goes into the caller's source set,
--  where the report's spans can be rendered against it.

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Landin.Diagnostics;
with Landin.Source;
with Landin.Source.Sets;

package Landin.Formatting is

   package Edit_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Landin.Diagnostics.Edit,
      "=" => Landin.Diagnostics."=");

   subtype Edit_List is Edit_Vectors.Vector;

   type Verdict is (Formatted, Refused);

   --  Id is the snapshot Format added to the caller's set.  A refused
   --  source has its report in Found, no edits, and its own bytes as Text;
   --  a formatted one has an empty Found, the edits that take it to the
   --  layout, and Text with every edit applied.
   type Result is record
      Id      : Landin.Source.Source_Id := Landin.Source.No_Source;
      Outcome : Verdict := Refused;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Edits   : Edit_List;
      Text    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Adds Text to Sources under Name and lays it out.  Raises
   --  Landin.Compiler_Defect if the formatted bytes do not scan to the same
   --  tokens and the same comments, so a fault in this package can refuse
   --  a file and can never change what it says.
   function Format
     (Sources : in out Landin.Source.Sets.Source_Set;
      Name    : String;
      Text    : String) return Result;

end Landin.Formatting;
