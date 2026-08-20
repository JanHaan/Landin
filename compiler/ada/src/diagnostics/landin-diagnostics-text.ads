--  Deterministic text rendering of a diagnostic report.
--
--  Rendering is separated from transport so that a test can assert a code
--  and a span without depending on prose, and a golden test can assert the
--  prose without reaching into the report.  The same report always renders
--  to the same bytes.

with Landin.Source.Sets;

package Landin.Diagnostics.Text is

   --  Rendered in the order given by Sorted, one block per diagnostic.
   --  Every line ends with a line feed, including the last, so appending
   --  two reports cannot run two diagnostics together.
   function Render
     (List    : Diagnostic_List;
      Sources : Landin.Source.Sets.Source_Set) return String;

   function Render
     (Item    : Diagnostic;
      Sources : Landin.Source.Sets.Source_Set) return String;

   --  "error", "warning", "note".  Kept here rather than in the transport
   --  so that Severity'Image never leaks into output.
   function Image (Level : Severity) return String;

end Landin.Diagnostics.Text;
