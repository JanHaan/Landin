with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Diagnostics.Lexical;
with Landin.Diagnostics;
with Landin.Platform.Native;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Source;
with Landin.Syntax.Parser;
with Landin.Syntax;
with Landin.Testing.Fixtures;
with Landin.Tokens.Lexer;
with Landin.Tokens;

package body Landin.Tests.Parser_Suite is

   package Unbounded renames Ada.Strings.Unbounded;
   package Fixtures renames Landin.Testing.Fixtures;

   use type Landin.Platform.Read_Status;
   use type Landin.Source.Source_Id;
   use type Landin.Syntax.Node_Id;
   use type Fixtures.Fixture_Class;

   --  Relative to compiler/ada, which is where the harness runs.
   Corpus : constant String := "../tests/fixtures";

   function Contains (Text : String; Needle : String) return Boolean;

   function Contains (Text : String; Needle : String) return Boolean
     is (Ada.Strings.Fixed.Index (Text, Needle) /= 0);

   ------------------------------------------------------------------

   --  Scans and parses one program and reports three things about it: the
   --  codes its report carries, in the order a reader sees them; how many
   --  nodes the parse built; and whether every node kept the two
   --  invariants the table is built on.  A Tree is limited and cannot be
   --  handed back, so the walk happens here.
   procedure Read_And_Parse
     (Text  : String;
      Codes : out Unbounded.Unbounded_String;
      Total : out Natural;
      Nodes : out Natural;
      Held  : out Boolean);

   procedure Read_And_Parse
     (Text  : String;
      Codes : out Unbounded.Unbounded_String;
      Total : out Natural;
      Nodes : out Natural;
      Held  : out Boolean)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add ("probe.ldn", Text);
   begin
      Codes := Unbounded.Null_Unbounded_String;
      Held  := True;

      Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Found);

      declare
         Parsed : constant Landin.Syntax.Tree :=
           Landin.Syntax.Parser.Parse (Stream, Names, Found);
      begin
         Nodes := Landin.Syntax.Node_Count (Parsed);

         --  1 .. Last_Node is a post-order, so a child's index is lower
         --  than its parent's; and a parent's extent contains every
         --  child's.  Both are postconditions, and walking every slot of
         --  every node is what makes a debug build check them.
         for Node in Landin.Syntax.Node_Id'(1)
                     .. Landin.Syntax.Last_Node (Parsed)
         loop
            for Position in 1 .. Landin.Syntax.Slot_Count (Parsed, Node)
            loop
               declare
                  Child : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Slot (Parsed, Node, Position);
               begin
                  if Child /= Landin.Syntax.No_Node then
                     if Child >= Node
                       or else not Landin.Source.Contains
                                     (Landin.Syntax.Where (Parsed, Node),
                                      Landin.Syntax.Where (Parsed, Child))
                     then
                        Held := False;
                     end if;
                  end if;
               end;
            end loop;

            if not Landin.Source.Contains
                     (Landin.Syntax.Where (Parsed, Node),
                      Landin.Syntax.Anchor (Parsed, Node))
            then
               Held := False;
            end if;
         end loop;

         if Landin.Syntax.Source_Of (Parsed) /= Id then
            Held := False;
         end if;
      end;

      declare
         Ordered : constant Landin.Diagnostics.Diagnostic_List :=
           Landin.Diagnostics.Sorted (Found);
      begin
         Total := Landin.Diagnostics.Count (Ordered);

         for Position in 1 .. Total loop
            if Position > 1 then
               Unbounded.Append (Codes, ", ");
            end if;

            Unbounded.Append
              (Codes,
               Landin.Diagnostics.Code
                 (Landin.Diagnostics.Get (Ordered, Position)));
         end loop;
      end;
   end Read_And_Parse;

   ------------------------------------------------------------------
   --  The corpus, from both sides
   ------------------------------------------------------------------

   procedure Agrees_With_The_Corpus (Item : in out Landin.Testing.Context);

   procedure Agrees_With_The_Corpus (Item : in out Landin.Testing.Context)
   is
      Host      : Landin.Platform.Native.Native_Filesystem;
      Catalogue : Fixtures.Catalogue;
      Accepted  : Natural := 0;
      Rejected  : Natural := 0;
      Pinned    : Natural := 0;
   begin
      Fixtures.Discover (Catalogue, Corpus, Host);

      for Index in 1 .. Fixtures.Count (Catalogue) loop
         declare
            Fixture : constant Fixtures.Fixture :=
              Fixtures.Nth (Catalogue, Index);
            Class   : constant Fixtures.Fixture_Class :=
              Fixtures.Class (Fixture);
         begin
            if Class in Fixtures.Positive_Program | Fixtures.Negative_Program
              and then Fixtures.Program (Fixture) /= ""
            then
               declare
                  Path : constant String :=
                    Corpus & "/" & Fixtures.Class_Directory (Class) & "/"
                    & Fixtures.Name (Fixture) & "/"
                    & Fixtures.Program (Fixture);
                  Content : Unbounded.Unbounded_String;
                  Status  : Landin.Platform.Read_Status;
               begin
                  Host.Read_File (Path, Content, Status);

                  if Status /= Landin.Platform.Read_Ok then
                     Landin.Testing.Fail
                       (Item, Path & " is unreadable");
                  else
                     declare
                        Codes : Unbounded.Unbounded_String;
                        Total : Natural;
                        Nodes : Natural;
                        Held  : Boolean;
                     begin
                        Read_And_Parse
                          (Unbounded.To_String (Content),
                           Codes, Total, Nodes, Held);

                        Landin.Testing.Check
                          (Item, Held,
                           Fixtures.Name (Fixture)
                           & ": every node lies inside its parent and"
                           & " below it");

                        --  Every file has a program node, so a parse that
                        --  built nothing did not run.
                        Landin.Testing.Check
                          (Item, Nodes > 0,
                           Fixtures.Name (Fixture) & ": a tree was built");

                        if Class = Fixtures.Positive_Program then
                           Accepted := Accepted + 1;
                           Landin.Testing.Check_Equal
                             (Item, Total, 0,
                              Fixtures.Name (Fixture)
                              & ": the grammar derives it, so the parser"
                              & " must say nothing");
                        else
                           Rejected := Rejected + 1;
                           Landin.Testing.Check
                             (Item, Total > 0,
                              Fixtures.Name (Fixture)
                              & ": the grammar refuses it, so the parser"
                              & " must report something");

                           if Fixtures.Codes (Fixture) /= "" then
                              Pinned := Pinned + 1;
                              Landin.Testing.Check_Equal
                                (Item, Unbounded.To_String (Codes),
                                 Fixtures.Codes (Fixture),
                                 Fixtures.Name (Fixture)
                                 & ": the report carries the codes the"
                                 & " fixture names");
                           end if;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      --  A corpus that shrank to nothing would pass every case above.
      Landin.Testing.Check
        (Item, Accepted >= 42,
         "every positive program in the corpus was parsed");
      Landin.Testing.Check
        (Item, Rejected >= 20,
         "every negative program in the corpus was parsed");
      Landin.Testing.Check
        (Item, Pinned = Rejected,
         "every negative program names the codes its report carries");
   end Agrees_With_The_Corpus;

   ------------------------------------------------------------------
   --  Recovery, on input nothing derives
   ------------------------------------------------------------------

   --  Every prefix of every corpus program, cut at every token boundary.
   --  A truncated file is the commonest broken file there is -- it is what
   --  an editor holds halfway through a line -- and the claim R1.40 owes
   --  is that none of them crashes and each still yields a tree.
   procedure Survives_Every_Truncation
     (Item : in out Landin.Testing.Context);

   procedure Survives_Every_Truncation
     (Item : in out Landin.Testing.Context)
   is
      Host      : Landin.Platform.Native.Native_Filesystem;
      Catalogue : Fixtures.Catalogue;
      Cuts      : Natural := 0;
      Broken    : Natural := 0;
   begin
      Fixtures.Discover (Catalogue, Corpus, Host);

      for Index in 1 .. Fixtures.Count (Catalogue) loop
         declare
            Fixture : constant Fixtures.Fixture :=
              Fixtures.Nth (Catalogue, Index);
            Class   : constant Fixtures.Fixture_Class :=
              Fixtures.Class (Fixture);
         begin
            if Class in Fixtures.Positive_Program | Fixtures.Negative_Program
              and then Fixtures.Program (Fixture) /= ""
            then
               declare
                  Path : constant String :=
                    Corpus & "/" & Fixtures.Class_Directory (Class) & "/"
                    & Fixtures.Name (Fixture) & "/"
                    & Fixtures.Program (Fixture);
                  Content : Unbounded.Unbounded_String;
                  Status  : Landin.Platform.Read_Status;
               begin
                  Host.Read_File (Path, Content, Status);

                  if Status = Landin.Platform.Read_Ok then
                     declare
                        Whole : constant String :=
                          Unbounded.To_String (Content);
                     begin
                        for Cut in Whole'First - 1 .. Whole'Last loop
                           declare
                              Codes : Unbounded.Unbounded_String;
                              Total : Natural;
                              Nodes : Natural;
                              Held  : Boolean;
                           begin
                              Read_And_Parse
                                (Whole (Whole'First .. Cut),
                                 Codes, Total, Nodes, Held);
                              Cuts := Cuts + 1;

                              if not Held or else Nodes = 0 then
                                 Broken := Broken + 1;
                              end if;
                           end;
                        end loop;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      Landin.Testing.Check
        (Item, Cuts > 1_000,
         "the corpus was truncated at every byte");
      Landin.Testing.Check_Equal
        (Item, Broken, 0,
         "every truncation yielded a tree whose invariants hold");
   end Survives_Every_Truncation;

   --  Recursive descent has to stop before the host's stack does, and
   --  Storage_Error is not a diagnostic.  Well past the limit, so the
   --  case does not have to know the limit's exact value.
   procedure Deep_Nesting_Is_Reported
     (Item : in out Landin.Testing.Context);

   procedure Deep_Nesting_Is_Reported
     (Item : in out Landin.Testing.Context)
   is
      Depth : constant Positive := Landin.Syntax.Parser.Nesting_Limit * 4;
      Text  : Unbounded.Unbounded_String;
      Codes : Unbounded.Unbounded_String;
      Total : Natural;
      Nodes : Natural;
      Held  : Boolean;
   begin
      Unbounded.Append (Text, "n: u32 = ");

      for Step in 1 .. Depth loop
         pragma Unreferenced (Step);
         Unbounded.Append (Text, "(");
      end loop;

      Unbounded.Append (Text, "1");

      for Step in 1 .. Depth loop
         pragma Unreferenced (Step);
         Unbounded.Append (Text, ")");
      end loop;

      Read_And_Parse
        (Unbounded.To_String (Text), Codes, Total, Nodes, Held);

      Landin.Testing.Check
        (Item, Held, "the table's invariants hold at the nesting limit");
      Landin.Testing.Check
        (Item, Total > 0, "nesting past the limit is reported");
      Landin.Testing.Check
        (Item,
         Contains (Unbounded.To_String (Codes), "L0111"),
         "the report uses the nesting code");
   end Deep_Nesting_Is_Reported;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "parser", "agrees with the corpus",
         Agrees_With_The_Corpus'Access);
      Landin.Testing.Register
        (Into, "parser", "survives every truncation",
         Survives_Every_Truncation'Access);
      Landin.Testing.Register
        (Into, "parser", "deep nesting is reported",
         Deep_Nesting_Is_Reported'Access);
   end Register;

end Landin.Tests.Parser_Suite;
