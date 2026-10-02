with Landin.Diagnostics.Lexical;
with Landin.Source;
with Landin.Syntax.Forest;
with Landin.Tokens.Lexer;
with Landin.Tokens.Spacing;

package body Landin.Stages.Syntax is

   overriding function Name (Item : Instance) return String is
      pragma Unreferenced (Item);
   begin
      return "syntax";
   end Name;

   overriding procedure Run
     (Item    : Instance;
      Whole   : in out Compilation'Class;
      Outcome : out Stage_Outcome)
   is
      pragma Unreferenced (Item);
   begin
      Run_Using (Whole, Outcome);
   end Run;

   procedure Run_Using
     (Whole    : in out Compilation'Class;
      Outcome  : out Stage_Outcome;
      Previous : access Compilation := null;
      Watch    : access procedure (Name : String) := null)
   is
      --  The one view every helper below takes; see Landin.Stages.Run.
      Context : Compilation renames Compilation (Whole);

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
      Spaces : constant not null access Landin.Tokens.Spacing.Table :=
        Landin.Stages.Spacing (Context);
   begin
      --  The driver's loader may append sources before semantic stages run.
      --  A forest is append-only, so each loader pass parses only the newly
      --  acquired suffix and preserves every existing Source_Id/Tree pair.
      for Index in Landin.Syntax.Forest.Count (Trees.all) + 1
        .. Source_Count (Context)
      loop
         declare
            Id : constant Landin.Source.Source_Id :=
              Nth_Source (Context, Index);
            Snapshot : Landin.Source.Snapshot renames
              Source (Context, Id);
            Reuse : constant Boolean := Previous /= null
              and then Index <= Source_Count (Previous.all)
              and then Landin.Syntax.Forest.Contains
                (Landin.Stages.Trees (Previous.all).all, Id)
              and then Landin.Source.Name (Snapshot) =
                Landin.Source.Name (Source (Previous.all, Id))
              and then Landin.Source.Text (Snapshot) =
                Landin.Source.Text (Source (Previous.all, Id));
         begin
            if Reuse then
               Landin.Syntax.Forest.Transfer_Next
                 (Landin.Stages.Trees (Previous.all).all, Trees.all);
               Landin.Tokens.Spacing.Transfer_Next
                 (Landin.Stages.Spacing (Previous.all).all, Spaces.all);
            else
               declare
                  Stream : Landin.Tokens.Token_Stream;
                  Found  : Landin.Diagnostics.Diagnostic_List;
               begin
                  if Watch /= null then
                     Watch (Landin.Source.Name (Snapshot));
                  end if;
                  Landin.Tokens.Lexer.Lex (Snapshot, Names.all, Stream);
                  Landin.Diagnostics.Lexical.Report (Stream, Found);

                  --  One tree per source, in source order.
                  Landin.Syntax.Forest.Add
                    (Trees.all, Stream, Names.all, Found);

                  --  Space remains beside the tree after the stream ends.
                  Landin.Tokens.Spacing.Add (Spaces.all, Stream);

                  --  An unsound recovery tree needs an error diagnostic.
                  declare
                     Parsed : constant not null access constant
                       Landin.Syntax.Tree := Trees.Tree_Of (Id);
                  begin
                     if not Landin.Syntax.Is_Sound
                       (Parsed.all, Landin.Syntax.Root (Parsed.all))
                       and then not Found.Has_Errors
                     then
                        raise Landin.Compiler_Defect with
                          "syntax recovery produced no error diagnostic";
                     end if;
                  end;

                  --  Sorted per source, appended in source order: a report
                  --  is read top to bottom of the file it is about.
                  declare
                     Ordered : constant Landin.Diagnostics.Diagnostic_List :=
                       Landin.Diagnostics.Sorted (Found);
                  begin
                     for Position in 1 .. Landin.Diagnostics.Count (Ordered)
                     loop
                        Report
                          (Context,
                           Landin.Diagnostics.Get (Ordered, Position));
                     end loop;
                  end;
               end;
            end if;
         end;
      end loop;

      Outcome := (if Failed (Context) then Stop else Continue);
   end Run_Using;

end Landin.Stages.Syntax;
