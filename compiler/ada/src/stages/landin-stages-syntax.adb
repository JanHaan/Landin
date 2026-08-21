with Landin.Diagnostics.Lexical;
with Landin.Source;
with Landin.Syntax.Forest;
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

      --  Both of these belong to the compilation and not to this Run.  The
      --  identities because a Name_Id in a tree names a spelling in one
      --  table and would name nothing once a per-Run table went out of
      --  scope; the trees because the stage that resolves names runs after
      --  this one returns.  The stage object itself is an `in` parameter of
      --  a limited interface and holds nothing, which is what makes one
      --  library-level instance right.
      Names : constant not null access Landin.Source.Names.Table :=
        Identities (Context);
      Trees : constant not null access Landin.Syntax.Forest.Table :=
        Landin.Stages.Trees (Context);
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
            Landin.Tokens.Lexer.Lex (Snapshot, Names.all, Stream);
            Landin.Diagnostics.Lexical.Report (Stream, Found);

            --  One tree per source, in the order the sources were added,
            --  which is the order the forest numbers them by.
            Landin.Syntax.Forest.Add
              (Trees.all, Stream, Names.all, Found);

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
