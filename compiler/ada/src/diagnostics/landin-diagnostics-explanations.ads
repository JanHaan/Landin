--  What `refine explain` prints.
--
--  The catalogue holds no prose, for the reason its header gives: a message
--  is one wording of a rule, and a table of them would split a code for a
--  wording reason.  An explanation is not a message.  It says what rule a
--  code enforces, cites the paragraph that states it and says what to
--  change, once per code, and it is written as prose in
--  `docs/diagnostics.md`.  The body of this package is generated from that
--  page by `python3 check.py --catalogue`, so the executable carries its own
--  copy and reads no file; `check.py` fails when the two disagree.
--
--  Each function is an exhaustive case over Code_Name, so a code added to
--  the catalogue without a section does not compile.

with Landin.Diagnostics.Catalogue;

package Landin.Diagnostics.Explanations is

   --  The section's prose, one paragraph per line with a blank line
   --  between paragraphs.  A retired code's begins `Retired.`
   function Explanation (Of_Code : Catalogue.Code_Name) return String;

   --  A program the code refuses, or "" for a code no short program can
   --  provoke.  The test program compiles each and requires its report to
   --  begin with the code.
   function Example (Of_Code : Catalogue.Code_Name) return String;

end Landin.Diagnostics.Explanations;
