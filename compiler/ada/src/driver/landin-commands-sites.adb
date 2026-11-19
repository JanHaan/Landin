with Ada.Strings.Unbounded;
with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Text;
with Landin.Site_Tables;
with Landin.Source.Sets;

package body Landin.Commands.Sites is
   package US renames Ada.Strings.Unbounded;
   package Cat renames Landin.Diagnostics.Catalogue;

   LF : constant Character := Character'Val (10);

   procedure Resolve
     (Artifact, Map_Path, Dsym_Path : String;
      Operands : Landin.Platform.Path_List;
      Host     : Landin.Platform.Filesystem'Class;
      Result   : in out Landin.Driver.Outcome)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Found : constant Landin.Site_Tables.Answer :=
        Landin.Site_Tables.Resolve (Artifact, Map_Path, Dsym_Path, Operands,
                                    Host);
   begin
      case Found.Kind is
         when Landin.Site_Tables.Misuse =>
            Result.Status := Landin.Driver.Status_Misuse;
            Result.Report := US.To_Unbounded_String
              ("refine: site resolves one site number, or a file number, a"
               & " line and a column: refine site PROGRAM SITE" & LF);
         when Landin.Site_Tables.Refusal =>
            Result.Status := Landin.Driver.Status_Reported;
            Result.Found.Append
              (Landin.Diagnostics.Make
                 (Code => Cat.Code (Found.Code),
                  Level => Landin.Diagnostics.Error,
                  Source => Landin.Source.No_Source,
                  Where => Landin.Source.Empty_Span,
                  Message => US.To_String (Found.Message)));
            Result.Report := US.To_Unbounded_String
              (Landin.Diagnostics.Text.Render (Result.Found, Sources));
         when Landin.Site_Tables.Resolved =>
            Result.Output := US.To_Unbounded_String
              (Landin.Site_Tables.Text (Found) & LF);
      end case;
   end Resolve;

end Landin.Commands.Sites;
