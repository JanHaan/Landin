--  Deterministic text rendering of a diagnostic report.
--
--  Rendering is separated from transport so that a test can assert a code
--  and a span without depending on prose, and a golden test can assert the
--  prose without reaching into the report.  The same report always renders
--  to the same bytes.

with Landin.Source.Sets;

package Landin.Diagnostics.Text is

   --  Text is bounded independently of the retained structured report.
   --  The minimum leaves room for an explicit truncation notice. Smaller
   --  budgets support bounded presentation tests without large inputs.
   subtype Report_Byte_Limit is Positive range 128 .. Positive'Last;
   Default_Byte_Limit : constant Report_Byte_Limit := 1_048_576;

   --  Rendered in the order given by Sorted, one block per diagnostic.
   --  Long source lines use a local excerpt with visible omission markers.
   --  A report exceeding Byte_Limit ends with a truncation notice; the
   --  diagnostic list, labels, messages and byte spans are never modified.
   --  Every line ends with a line feed, including the last, so appending
   --  two reports cannot run two diagnostics together.
   function Render
     (List    : Diagnostic_List;
      Sources : Landin.Source.Sets.Source_Set;
      Byte_Limit : Report_Byte_Limit := Default_Byte_Limit) return String;

   function Render
     (Item    : Diagnostic;
      Sources : Landin.Source.Sets.Source_Set;
      Byte_Limit : Report_Byte_Limit := Default_Byte_Limit) return String;

   --  "error", "warning", "note".  Kept here rather than in the transport
   --  so that Severity'Image never leaks into output.
   function Image (Level : Severity) return String;

end Landin.Diagnostics.Text;
