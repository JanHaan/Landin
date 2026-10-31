--  Diagnostics produced while the driver closes a rooted module graph.
--  Host discovery stays outside semantic stages, but its failures use the
--  same catalogue and source spans as every other report.

with Landin.Diagnostics.Catalogue;
with Landin.Source;

package Landin.Diagnostics.Modules is

   --  A code this package reports.  Failure is the catalogue's Code_Name
   --  derived, so it has the catalogue's names and a new code needs no
   --  second list here; Code_For is the conversion back.
   type Failure is new Landin.Diagnostics.Catalogue.Code_Name;

   function Code_For (Item : Failure)
     return Landin.Diagnostics.Catalogue.Code_Name
     is (Landin.Diagnostics.Catalogue.Code_Name (Item));

   --  D262's refusal of an import no root can supply, one sentence for
   --  the loader and resolution alike.
   function Rootless_Message (Path : String) return String
     is ("module `" & Path & "` is not found: no import root was given");

   function Rootless_Note return String
     is ("[1420]: an import outside the library is found under the roots"
         & " --root names; compile the module's directory with"
         & " --root=DIR");

   procedure Report
     (Item    : Failure;
      Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Note    : String := "";
      Fixes   : Fix_List := No_Fixes;
      Into    : in out Diagnostic_List);

end Landin.Diagnostics.Modules;
