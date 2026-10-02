--  What each message is answered with, as JSON.
--
--  The server's data -- a report, a formatter's edits, a compilation's
--  names and types -- turned into the protocol's shapes, with every byte
--  span converted to a range in the one place positions are converted.
--  Nothing here decides anything: a diagnostic says what the stage said,
--  a fix carries the edits the stage built, and a type is spelt as the
--  checker spells it.

with Ada.Containers.Vectors;

with Landin.Diagnostics;
with Landin.Formatting;
with Landin.Json;
with Landin.Server.Analysis;
with Landin.Server.Documents;
with Landin.Server.Positions;
with Landin.Source;
with Landin.Source.Sets;
with Landin.Stages;

package Landin.Server.Answers is

   --  Where a code is explained, as `refine explain` prints it: the
   --  reading copy of `docs/diagnostics.md`, one anchor per code.
   Explanations : constant String :=
     "https://www.701.dev/diagnostics.html#";

   --  The initialize result: what the server offers, and the position
   --  encoding it chose.
   function Capabilities (Unit : Positions.Encoding) return String;

   --  The version of the open document held at Path, or -1 for none.
   function Version_Of
     (Store : Landin.Server.Documents.Store; Path : String)
      return Long_Long_Integer;

   --  Report positions grouped by primary source in publication order.
   package Diagnostic_Indexes is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Positive);

   --  textDocument/publishDiagnostics for the selected report positions.
   --  Version -1 is left out.
   function Diagnostics
     (URI     : String;
      Version : Long_Long_Integer;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Indexes : Diagnostic_Indexes.Vector;
      Sources : not null access constant Landin.Source.Sets.Source_Set;
      Store   : Landin.Server.Documents.Store;
      Unit    : Positions.Encoding) return String;

   --  An empty publishDiagnostics for URI.
   function Cleared (URI : String) return String;

   --  The formatting result: D252's edits on Text, or null when the
   --  source does not parse.
   function Formatting
     (Laid : Landin.Formatting.Result;
      Text : String;
      Unit : Positions.Encoding) return String;

   --  A query's result over a compilation of the document's module:
   --  textDocument/codeAction, textDocument/definition or
   --  textDocument/hover.
   function Query
     (Method  : String;
      Message : Landin.Json.Document;
      Params  : Landin.Json.Value;
      URI     : String;
      Context : in out Landin.Stages.Compilation;
      Answer  : Landin.Server.Analysis.Result;
      Store   : Landin.Server.Documents.Store;
      Unit    : Positions.Encoding) return String;

end Landin.Server.Answers;
