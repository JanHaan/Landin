--  One analysis of one module, as a server makes it.
--
--  A module is what `refine` would compile for the file an editor named:
--  the file's own directory as the entry module under the server's roots,
--  or the file alone when it has no directory a root reaches.  It is loaded
--  through the caller's host, which holds the editor's buffers over the
--  filesystem, and checked by the stages `refine` runs, in the order it
--  runs them.
--
--  What the report holds differs from `refine`'s in one way, D253's: a
--  source whose every error lies inside routine bodies is checked as its
--  stand-in, so the names and types around a half-written body are still
--  checked.  Its syntax errors are its own, every later diagnostic comes
--  from the stand-in, and one that touches a held body is dropped, since
--  what the stand-in says there is not what the source says.  A module with
--  any other syntax error is reported exactly as `refine` reports it.
--
--  The compilation is the caller's, created for one analysis and freed
--  with it: nothing here keeps a table between two.

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

with Landin.Diagnostics;
with Landin.Platform;
with Landin.Server.Holes;
with Landin.Source;
with Landin.Stages;

package Landin.Server.Analysis is

   type Request is record
      --  Rooted when nonempty: Entry_Directory is loaded under Roots.
      Entry_Directory : Ada.Strings.Unbounded.Unbounded_String;
      Roots           : Landin.Platform.Path_List;
      --  Otherwise these files, as one module.
      Files           : Landin.Platform.Path_List;
      --  Each `name=value` a `--option=` would give.  Valid and distinct:
      --  the caller has refused anything else.
      Options         : Landin.Platform.Path_List;
   end record;

   package Hold_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Holes.Span_List,
      "=" => Holes.Span_Vectors."=");

   type Result is record
      --  The report the server publishes, sorted.
      Found  : Landin.Diagnostics.Diagnostic_List;
      --  Each source's held regions, by Source_Id; empty for one analysed
      --  as it is.
      Held   : Hold_Vectors.Vector;
      --  Whether the stages ran past syntax, so names and types may be
      --  asked of the compilation.
      Checked : Boolean := False;
   end record;

   --  Load and check Asked into Context, a compilation nothing else has
   --  touched.  Host serves every read; nothing is written.
   procedure Analyse
     (Context : in out Landin.Stages.Compilation;
      Host    : Landin.Platform.Filesystem'Class;
      Asked   : Request;
      Answer  : out Result);

   --  Whether Where in Source lies in one of its held regions.
   function Is_Held
     (Answer : Result;
      Source : Landin.Source.Source_Id;
      Where  : Landin.Source.Span) return Boolean;

end Landin.Server.Analysis;
