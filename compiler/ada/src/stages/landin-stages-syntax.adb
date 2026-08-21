with Landin.Diagnostics.Lexical;
with Landin.Source;
with Landin.Source.Names;
with Landin.Syntax.Parser;
with Landin.Tokens.Lexer;

package body Landin.Stages.Syntax is

   overriding function Name (Item : Instance) return String is
      pragma Unreferenced (Item);
   begin
      return "syntax";
   end Name;

   overriding procedure Run
     (Item    : Instance;
      Context : in out Compilation;
      Outcome : out Stage_Outcome)
   is
      pragma Unreferenced (Item);

      --  One table for the whole compilation: a name is the same name in
      --  two files, which is what makes R1.50's comparison two integers.
      Names : Landin.Source.Names.Table;
   begin
      for Index in 1 .. Source_Count (Context) loop
         declare
            Id : constant Landin.Source.Source_Id :=
              Nth_Source (Context, Index);
            Snapshot : constant Landin.Source.Snapshot :=
              Source (Context, Id);
            Stream : Landin.Tokens.Token_Stream;
            Found  : Landin.Diagnostics.Diagnostic_List;
         begin
            Landin.Tokens.Lexer.Lex (Snapshot, Names, Stream);
            Landin.Diagnostics.Lexical.Report (Stream, Found);

            declare
               Parsed : constant Landin.Syntax.Tree :=
                 Landin.Syntax.Parser.Parse (Stream, Names, Found);
               pragma Unreferenced (Parsed);
            begin
               null;
            end;

            --  Sorted per source, appended in source order: a report is
            --  read top to bottom of the file it is about.
            declare
               Ordered : constant Landin.Diagnostics.Diagnostic_List :=
                 Landin.Diagnostics.Sorted (Found);
            begin
               for Position in 1 .. Landin.Diagnostics.Count (Ordered) loop
                  Report
                    (Context,
                     Landin.Diagnostics.Get (Ordered, Position));
               end loop;
            end;
         end;
      end loop;

      Outcome := (if Failed (Context) then Stop else Continue);
   end Run;

end Landin.Stages.Syntax;
