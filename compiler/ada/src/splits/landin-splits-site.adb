with Ada.Strings.Unbounded;
with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Text;
with Landin.Site_Tables;
with Landin.Source.Sets;

package body Landin.Splits.Site is
   package US renames Ada.Strings.Unbounded;
   package Cat renames Landin.Diagnostics.Catalogue;

   LF : constant Character := Character'Val (10);

   procedure Resolve
     (Artifact, Map_Path, Dsym_Path : String;
      Operands : Landin.Platform.Path_List;
      Host     : Landin.Platform.Filesystem'Class;
      Result   : in out Landin.Outcomes.Outcome)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Found : constant Landin.Site_Tables.Answer :=
        Landin.Site_Tables.Resolve (Artifact, Map_Path, Dsym_Path, Operands,
                                    Host);
   begin
      case Found.Kind is
         when Landin.Site_Tables.Misuse =>
            Result.Status := Landin.Outcomes.Status_Misuse;
            Result.Report := US.To_Unbounded_String
              ("refine: site resolves one site number, or a file number, a"
               & " line and a column: refine site PROGRAM SITE" & LF);
         when Landin.Site_Tables.Refusal =>
            Result.Status := Landin.Outcomes.Status_Reported;
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

   Map  : constant := 1;
   Dsym : constant := 2;

   Options : constant Option_Array :=
     [Map => Valued
        ("--map", "VALUE",
         "The build's source table; default PROGRAM.sources.json"),
      Dsym => Valued
        ("--dsym", "VALUE",
         "A Mach-O program's dSYM DWARF file, held to its UUID")];

   About : constant Command :=
     (Name => US.To_Unbounded_String ("site"),
      Summary => US.To_Unbounded_String
        ("Resolve a panic site or a caller's coordinates to a source line"),
      Usage => US.To_Unbounded_String
        ("[options] PROGRAM SITE | PROGRAM FILE LINE COLUMN"),
      Notes => US.To_Unbounded_String
        ("Example: refine site firmware.elf 4194" & LF
         & "PROGRAM is what the compilation wrote: an executable, a"
         & LF & "firmware image, or the assembly of --emit=asm. SITE is"
         & LF & "the number a panic_handler receives, in decimal or"
         & LF & "after 0x; compile with --panic-map to record sites."
         & LF & "FILE LINE COLUMN are a caller's three coordinates."
         & LF & "The answer is the source path, line and column, and"
         & LF & "for a site the check that failed. The table beside the"
         & LF & "program, PROGRAM.sources.json, answers only for the"
         & LF & "build it was written with: the program's build"
         & LF & "identity, or the assembly's SHA-256, must be the"
         & LF & "table's. A stripped program keeps its identity."
         & LF));

   function Perform
     (Asked     : Request;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class;
      Built_For : String) return Landin.Outcomes.Outcome;

   function Perform
     (Asked     : Request;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class;
      Built_For : String) return Landin.Outcomes.Outcome
   is
      pragma Unreferenced (Tools, Built_For);
      Result : Landin.Outcomes.Outcome;
      After : Landin.Platform.Path_List := Asked.Operands;
   begin
      if Natural (Asked.Operands.Length) not in 2 | 4 then
         return Refused
           (Cat.Unknown_Option,
            "site resolves a site number, or a file number, a line and a"
            & " column, against a build: refine site PROGRAM SITE",
            Landin.Outcomes.Status_Misuse);
      end if;
      After.Delete_First;
      Resolve
        (Artifact => Asked.Operands.First_Element,
         Map_Path => Value (Asked, Map), Dsym_Path => Value (Asked, Dsym),
         Operands => After, Host => Host, Result => Result);
      return Result;
   end Perform;

   function Execute
     (Arguments      : Landin.Platform.Path_List;
      Host           : Landin.Platform.Filesystem'Class;
      Tools          : Landin.Platform.Tool_Runner'Class;
      Built_For      : String := "";
      Terminal_Color : Boolean := False) return Landin.Outcomes.Outcome is
     (Landin.Splits.Execute
        (About, Options, Perform'Access, Arguments, Host, Tools, Built_For,
         Terminal_Color));

end Landin.Splits.Site;
