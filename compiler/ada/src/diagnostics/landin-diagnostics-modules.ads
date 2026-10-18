--  Diagnostics produced while the driver closes a rooted module graph.
--  Host discovery stays outside semantic stages, but its failures use the
--  same catalogue and source spans as every other report.

with Landin.Diagnostics.Catalogue;
with Landin.Source;

package Landin.Diagnostics.Modules is

   type Failure is
     (Module_Not_Found, Module_Directory_Invalid,
      Module_Unavailable_For_Target, Root_Holds_Library_Module);

   function Code_For (Item : Failure)
     return Landin.Diagnostics.Catalogue.Code_Name
     is (case Item is
            when Module_Not_Found => Catalogue.Module_Not_Found,
            when Module_Directory_Invalid =>
               Catalogue.Module_Directory_Invalid,
            when Module_Unavailable_For_Target =>
               Catalogue.Module_Unavailable_For_Target,
            when Root_Holds_Library_Module =>
               Catalogue.Root_Holds_Library_Module);

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
