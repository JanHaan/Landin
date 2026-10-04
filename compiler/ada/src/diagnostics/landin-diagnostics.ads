--  Diagnostic transport.
--
--  A diagnostic is data: a code, a severity, one primary label and any
--  number of secondary labels, notes and fixes.  Nothing here renders
--  anything and nothing here decides policy; rendering lives in a child
--  package and the catalogue of codes belongs to the frontend that raises
--  them.
--
--  A fix is a repair a tool can make without reading the sentence: an
--  ordered set of edits, each a span of one source and the bytes that
--  replace it.  It belongs to the diagnostic and not to a note, because a
--  note is text for a reader and a fix is data for an editor, which
--  receives it unchanged: the spans are the bytes of the snapshot the
--  compilation read, and a client converts only their coordinates.
--
--  Codes are `L` followed by four digits.  They are asserted separately from
--  prose in tests, because a message may be reworded and a code may not be
--  changed silently.

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

with Landin.Source;

package Landin.Diagnostics is

   type Severity is (Note, Warning, Error);

   subtype Code_String is String (1 .. 5);

   function Is_Valid_Code (Item : String) return Boolean
     is (Item'Length = 5
         and then Item (Item'First) = 'L'
         and then (for all Index in Item'First + 1 .. Item'Last =>
                     Item (Index) in '0' .. '9'));

   type Label_Role is (Primary, Secondary);

   type Label is private;

   function Make_Label
     (Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Role    : Label_Role := Secondary) return Label;

   function Source_Of (Item : Label) return Landin.Source.Source_Id;
   function Span_Of   (Item : Label) return Landin.Source.Span;
   function Message   (Item : Label) return String;
   function Role      (Item : Label) return Label_Role;

   type Diagnostic is private;

   --  A diagnostic always has a primary label, even when the span is empty:
   --  a report with no place in the source is a report nobody can act on.
   function Make
     (Code     : Code_String;
      Level    : Severity;
      Source   : Landin.Source.Source_Id;
      Where    : Landin.Source.Span;
      Message  : String) return Diagnostic
     with Pre => Is_Valid_Code (Code);

   function Code    (Item : Diagnostic) return Code_String;
   function Level   (Item : Diagnostic) return Severity;
   function Primary (Item : Diagnostic) return Label;

   procedure Add_Label (Item : in out Diagnostic; Extra : Label)
     with Pre => Role (Extra) = Secondary;

   function Label_Count (Item : Diagnostic) return Natural;
   function Nth_Label (Item : Diagnostic; Index : Positive) return Label
     with Pre => Index <= Label_Count (Item);

   procedure Add_Note (Item : in out Diagnostic; Text : String);

   function Note_Count (Item : Diagnostic) return Natural;
   function Nth_Note (Item : Diagnostic; Index : Positive) return String
     with Pre => Index <= Note_Count (Item);

   --  One replacement: the bytes of Where in Source become Replacement.  An
   --  insertion is an empty span and a deletion an empty replacement.
   type Edit is private;

   function Make_Edit
     (Source      : Landin.Source.Source_Id;
      Where       : Landin.Source.Span;
      Replacement : String) return Edit;

   function Source_Of   (Item : Edit) return Landin.Source.Source_Id;
   function Span_Of     (Item : Edit) return Landin.Source.Span;
   function Replacement (Item : Edit) return String;

   --  Exact: the rule decides the replacement and applying it keeps what
   --  the program means, so a tool may apply it unasked.  Likely: a guess
   --  at what was meant, such as the declared name nearest a misspelling,
   --  which an editor offers and a batch tool does not apply.
   type Applicability is (Exact, Likely);

   --  What kind of repair a fix is.  Each is built by one constructor in
   --  Landin.Diagnostics.Fixes, which writes its message, so a kind is
   --  also a thing a fixture can be required to have applied.
   type Repair is
     (Respell,         --  the written name becomes one that is declared
      Name_End,        --  `end` names what it closes
      Mark_Mutable,    --  a binding that is written is declared `mut`
      Unmark_Mutable,  --  a binding nothing writes loses its `mut`
      Remove_Unused_Local, --  an unused literal binding loses its line
      Compare);        --  `=` in an expression becomes `==`

   type Fix is private;

   --  Edits are kept in source order and then byte order.  Two edits of
   --  one source may touch but never overlap, which is what an editor's
   --  workspace edit requires; an overlap is a defect in the stage that
   --  built the fix.
   function Make_Fix
     (Kind    : Repair;
      Level   : Applicability;
      Message : String) return Fix;

   procedure Add_Edit (Item : in out Fix; Extra : Edit);

   function Kind       (Item : Fix) return Repair;
   function Level      (Item : Fix) return Applicability;
   function Message    (Item : Fix) return String;
   function Edit_Count (Item : Fix) return Natural;
   function Nth_Edit (Item : Fix; Index : Positive) return Edit
     with Pre => Index <= Edit_Count (Item);

   --  What a stage hands to the package that builds its diagnostic.
   type Fix_List is array (Positive range <>) of Fix;

   No_Fixes : constant Fix_List;

   --  A fix with no edit is a sentence, and a sentence is a note.
   procedure Add_Fix (Item : in out Diagnostic; Extra : Fix)
     with Pre => Edit_Count (Extra) > 0;

   --  In the order they were added; the first is the one a tool prefers.
   function Fix_Count (Item : Diagnostic) return Natural;
   function Nth_Fix (Item : Diagnostic; Index : Positive) return Fix
     with Pre => Index <= Fix_Count (Item);

   --  A collected report.  Order of appending is not the order of reporting:
   --  Sorted puts diagnostics where a reader expects them regardless of the
   --  order the stages happened to produce them in.
   type Diagnostic_List is tagged private;

   procedure Append (List : in out Diagnostic_List; Item : Diagnostic)
     with Post => Count (List) = Count (List)'Old + 1;

   function Count (List : Diagnostic_List) return Natural;

   function Get (List : Diagnostic_List; Index : Positive) return Diagnostic
     with Pre => Index <= Count (List);

   function Has_Errors (List : Diagnostic_List) return Boolean;

   function Count_Of
     (List : Diagnostic_List; Of_Level : Severity) return Natural;

   --  Deterministic order: source, then start offset, then end offset, then
   --  severity, then code, then message.  Two runs over the same input
   --  therefore report the same sequence, which is what makes a negative
   --  fixture assertable.
   function Sorted (List : Diagnostic_List) return Diagnostic_List;

   --  Item with every label and edit that names a source naming Source
   --  instead: a report made over one copy of a file, moved onto the
   --  identity another compilation gave the same bytes.
   function Retargeted
     (Item : Diagnostic; Source : Landin.Source.Source_Id) return Diagnostic;

   --  Reuse a diagnostic for another application of the same failed
   --  instance. Its explanation, related template labels and fixes stay put.
   function With_Primary
     (Item   : Diagnostic;
      Source : Landin.Source.Source_Id;
      Where  : Landin.Source.Span) return Diagnostic;

   --  What a construct refused by name is, which [1830]'s second note
   --  says: a recorded boundary of a construct that is otherwise enabled,
   --  a form the language withdrew, or one a successor roadmap owns.  The
   --  note names the state and never the work that set it, because a work
   --  item is finished long before the note citing it stops being printed.
   type Refusal_Standing is (Recorded_Boundary, Withdrawn, Transferred);

private

   package ASU renames Ada.Strings.Unbounded;

   type Label is record
      Source  : Landin.Source.Source_Id := Landin.Source.No_Source;
      Where   : Landin.Source.Span      := Landin.Source.Empty_Span;
      Text    : ASU.Unbounded_String;
      Role    : Label_Role              := Secondary;
   end record;

   package Label_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Label);

   package Note_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   type Edit is record
      Source : Landin.Source.Source_Id := Landin.Source.No_Source;
      Where  : Landin.Source.Span      := Landin.Source.Empty_Span;
      Text   : ASU.Unbounded_String;
   end record;

   package Edit_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Edit);

   type Fix is record
      Kind  : Repair        := Respell;
      Level : Applicability := Likely;
      Text  : ASU.Unbounded_String;
      Edits : Edit_Vectors.Vector;
   end record;

   package Fix_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Fix);

   No_Fixes : constant Fix_List (1 .. 0) := [others => <>];

   type Diagnostic is record
      --  Not a code, and deliberately not shaped like one: an unset code
      --  is not a number the catalogue holds, and check.py refuses a code
      --  literal written outside it.
      Code    : Code_String := "?????";
      Level   : Severity    := Error;
      Primary : Label;
      Labels  : Label_Vectors.Vector;
      Notes   : Note_Vectors.Vector;
      Fixes   : Fix_Vectors.Vector;
   end record;

   package Diagnostic_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Diagnostic);

   type Diagnostic_List is tagged record
      Items : Diagnostic_Vectors.Vector;
   end record;

end Landin.Diagnostics;
