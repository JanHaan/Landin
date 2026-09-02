--  Diagnostics produced while the driver closes a rooted module graph.
--  Host discovery stays outside semantic stages, but its failures use the
--  same catalogue and source spans as every other report.

with Landin.Diagnostics.Catalogue;
with Landin.Source;

package Landin.Diagnostics.Modules is

   type Failure is (Module_Not_Found, Module_Directory_Invalid);

   function Code_For (Item : Failure)
     return Landin.Diagnostics.Catalogue.Code_Name
     is (case Item is
            when Module_Not_Found => Catalogue.Module_Not_Found,
            when Module_Directory_Invalid =>
               Catalogue.Module_Directory_Invalid);

   procedure Report
     (Item    : Failure;
      Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Note    : String := "";
      Into    : in out Diagnostic_List);

end Landin.Diagnostics.Modules;
