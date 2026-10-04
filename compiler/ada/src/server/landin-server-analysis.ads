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
--  The caller may retain the checked compilation until invalidation.
--  The temporary original is released after syntax transfer. An optional
--  caller-owned parse cache shares exact-text syntax for one publication
--  round; resolution and checking still belong to each compilation.

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

with Landin.Diagnostics;
with Landin.Platform;
with Landin.Server.Holes;
with Landin.Source;
with Landin.Stages;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Targets.Levels;

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
      --  A selected Cortex-M0 build entry, empty when none was requested.
      Firmware_Entry  : Ada.Strings.Unbounded.Unbounded_String;
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
      --  Resolution may have usable bindings even when it reported an
      --  unresolved name.  Checking may then be run for navigation alone.
      Resolved : Boolean := False;
      --  Whether the checking table was prepared for hover queries.
      Checked : Boolean := False;
      --  Directories an unresolved import could appear in under the roots.
      Missing_Directories : Landin.Platform.Path_List;
   end record;

   type Compilation_Access is access Landin.Stages.Compilation;
   procedure Release (Context : in out Compilation_Access);

   --  Ownership passes to the caller, who must release the result.
   procedure Analyse
     (For_Target : Landin.Targets.Target_Facts;
      At_Level   : Landin.Targets.Levels.Feature_Level;
      Host    : Landin.Platform.Filesystem'Class;
      Asked   : Request;
      Context : out Compilation_Access;
      Answer  : out Result;
      Watch_Syntax : access procedure (Name : String) := null;
      Cache : access Landin.Stages.Syntax.Parse_Cache := null);

   --  Visit the checked compilation before it is freed.  A broken body may
   --  require a second compilation with stand-ins; a sound source uses the
   --  tree made by the first syntax pass.
   procedure Analyse
     (For_Target : Landin.Targets.Target_Facts;
      At_Level   : Landin.Targets.Levels.Feature_Level;
      Host    : Landin.Platform.Filesystem'Class;
      Asked   : Request;
      Visit   : not null access procedure
        (Context : in out Landin.Stages.Compilation; Answer : Result);
      Watch_Syntax : access procedure (Name : String) := null;
      Cache : access Landin.Stages.Syntax.Parse_Cache := null);

   --  Whether Where in Source lies in one of its held regions.
   function Is_Held
     (Answer : Result;
      Source : Landin.Source.Source_Id;
      Where  : Landin.Source.Span) return Boolean;

end Landin.Server.Analysis;
