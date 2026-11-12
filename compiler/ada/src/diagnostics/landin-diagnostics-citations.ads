--  What `refine explain` prints for a construct or a decision (D530), read
--  from the citations file (D1240).
--
--  A diagnostic's note cites the paragraph or the decision that states its
--  rule, `[1760]` or `D275`, and a reader at a terminal follows that
--  citation here: the title, the document and, for a decision, the section
--  of `spec.md`'s register it is in, its page on the site and, when asked,
--  its text.  None of it is compiled in.  `python3 check.py --catalogue`
--  writes it from `tour.md` and `spec.md` into `citations.txt`, which
--  ships in the compiler's library, so a decision added to `spec.md`
--  changes one line of data and rebuilds nothing; `check.py` fails when
--  the file and the documents disagree.
--
--  This package reads the file's text and never the file: the driver
--  finds and reads it through `Landin.Platform` and hands the bytes over.
--
--  The file's first line is Format_Line, and its second the source line,
--  Source_Head and the digest of the compiler sources it was generated
--  from (D1357).  Each line after them is one entry of six fields a tab
--  apart: `C` or `D`, the number in decimal, the
--  title, a construct's document or a decision's register section, the
--  page, and the text `--full` adds.  In a field `\\`, `\t` and `\n` stand
--  for a backslash, a tab and a line end.  The text is rendered for a
--  terminal by the generator: a code span keeps its backticks, a link is
--  its text and bold its words, a paragraph is one line and a fenced
--  block is indented four spaces.
--
--  A number the table does not hold answers "" everywhere, so Holds is
--  what a caller asks first.

with Ada.Strings.Unbounded;

package Landin.Diagnostics.Citations is

   --  The file's name in the library's directory.
   File_Name : constant String := "citations.txt";

   --  The first line of a file this compiler reads.  The number changes
   --  when the fields do, so a file in another format is refused whole
   --  rather than read as something it does not say.
   Format_Line : constant String := "landin-citations 1";

   --  How the line after Format_Line opens.  The rest of it is the
   --  SHA-256 digest, in lower-case hexadecimal, that
   --  scripts/build_identity.py gives the compiler sources of the checkout
   --  the file was generated in: the one `refine version --json` reports
   --  as `source_digest`.  It is no entry, so a reader that predates it
   --  passes over it, and the format line is the same.
   Source_Head : constant String := "source ";

   --  The length of the digest the source line names.
   Digest_Length : constant := 64;

   type Citation_Kind is (Construct, Decision);

   type Table is private;

   --  The table Content holds.  Content that does not open with
   --  Format_Line is not Readable, and holds nothing.
   function Read
     (Content : Ada.Strings.Unbounded.Unbounded_String) return Table;

   function Readable (From : Table) return Boolean;

   --  The first line of what was read, at most sixty bytes of it and only
   --  its printable ASCII, for the refusal that says what was found.
   function First_Line (From : Table) return String;

   --  The digest the source line names, or "" when the line after
   --  Format_Line is no source line of Digest_Length lower-case hexadecimal
   --  digits, as in a file written before the line was.  A Readable table
   --  is read whether or not it has one.
   function Source (From : Table) return String;

   function Holds
     (From : Table; Kind : Citation_Kind; Number : Natural) return Boolean;

   --  A construct's title as its heading writes it, without the number;
   --  a decision's, without its `Dnnn —`.
   function Title
     (From : Table; Kind : Citation_Kind; Number : Natural) return String;

   --  The document that defines a construct, `tour.md` or `spec.md`; the
   --  register section a decision is recorded under, as the site heads
   --  it: `Decisions: The toolchain, C and the machine`.
   function Place
     (From : Table; Kind : Citation_Kind; Number : Natural) return String;

   --  The address of the entry on https://www.701.dev, with the anchor
   --  the site's renderer gives its heading.
   function Page
     (From : Table; Kind : Citation_Kind; Number : Natural) return String;

   --  What `--full` adds: a construct's own text up to its next heading,
   --  and a decision's `Chosen` paragraphs.
   function Text
     (From : Table; Kind : Citation_Kind; Number : Natural) return String;

private

   type Table is record
      Content : Ada.Strings.Unbounded.Unbounded_String;
      Ok      : Boolean := False;
   end record;

   function Readable (From : Table) return Boolean is (From.Ok);

end Landin.Diagnostics.Citations;
