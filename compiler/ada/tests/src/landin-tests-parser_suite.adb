with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Diagnostics.Lexical;
with Landin.Diagnostics;
with Landin.Driver;
with Landin.Platform;
with Landin.Testing.Fakes;
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
   use type Landin.Syntax.Node_Kind;
   use type Fixtures.Fixture_Class;

   --  Relative to compiler/ada, which is where the harness runs.
   Corpus : constant String := "../tests/fixtures";

   function Contains (Text : String; Needle : String) return Boolean;

   function Contains (Text : String; Needle : String) return Boolean
     is (Ada.Strings.Fixed.Index (Text, Needle) /= 0);

   --  Whether Whole begins with Part, comparing the rendered code lists as
   --  bytes.  An empty Part is a prefix of anything, which is what a
   --  fixture the parse says nothing about needs.
   function Is_Prefix (Part : String; Whole : String) return Boolean
     is (Part'Length = 0
         or else (Part'Length <= Whole'Length
                  and then Whole (Whole'First
                                  .. Whole'First + Part'Length - 1)
                           = Part));

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
      --  Deliberate real-host exception: this robustness case mutates the
      --  repository fixture tree itself, just as the corpus agreement case
      --  does, rather than testing a stage through the fake filesystem.
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

                           --  The scan and the parse run before every
                           --  other stage, so whatever they report is the
                           --  front of the report a fixture pins.  A
                           --  fixture refused for a reason of names parses
                           --  cleanly and its prefix is empty, which is
                           --  the whole of what this case may assert about
                           --  it; the driver case below runs the rest.
                           if Fixtures.Codes (Fixture) /= "" then
                              Pinned := Pinned + 1;
                              Landin.Testing.Check
                                (Item,
                                 Is_Prefix
                                   (Unbounded.To_String (Codes),
                                    Fixtures.Codes (Fixture)),
                                 Fixtures.Name (Fixture)
                                 & ": what the parse reports must begin"
                                 & " the codes the fixture names, and "
                                 & Unbounded.To_String (Codes)
                                 & " does not begin "
                                 & Fixtures.Codes (Fixture));
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
   --  Contextual array repetition
   ------------------------------------------------------------------

   procedure Mixed_Repetition_Preserves_Contextual_Of
     (Item : in out Landin.Testing.Context);

   procedure Mixed_Repetition_Preserves_Contextual_Of
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add
          ("mixed.ldn",
           "f: (of: u32, other: u32) -> (value: u32) =" & ASCII.LF
           & "  mixed: [4]u32 = [1, of, of other]" & ASCII.LF
           & "  ordinary: [3]u32 = [of, other, of]" & ASCII.LF
           & "  sum: [1]u32 = [of + 1]" & ASCII.LF
           & "  value = mixed[0] + ordinary[0] + sum[0]" & ASCII.LF
           & "end f" & ASCII.LF);
      Mixed  : Natural := 0;
      Three  : Natural := 0;
      One    : Natural := 0;
   begin
      Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Found);

      declare
         Parsed : constant Landin.Syntax.Tree :=
           Landin.Syntax.Parser.Parse (Stream, Names, Found);
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Diagnostics.Count (Found), 0,
            "the mixed form and ordinary names called `of` parse cleanly");

         for Node in Landin.Syntax.Node_Id'(1)
                     .. Landin.Syntax.Last_Node (Parsed)
         loop
            case Landin.Syntax.Kind (Parsed, Node) is
               when Landin.Syntax.Mixed_Array_Repetition =>
                  Mixed := Mixed + 1;
                  Landin.Testing.Check_Equal
                    (Item, Landin.Syntax.Element_Count (Parsed, Node), 2,
                     "the source prefix has two elements");
                  Landin.Testing.Check
                    (Item,
                     Landin.Syntax.Kind
                       (Parsed, Landin.Syntax.Repeated_Element (Parsed, Node))
                       = Landin.Syntax.Name_Reference,
                     "the suffix keeps its one repeated expression");
               when Landin.Syntax.Array_Literal =>
                  if Landin.Syntax.Element_Count (Parsed, Node) = 3 then
                     Three := Three + 1;
                  elsif Landin.Syntax.Element_Count (Parsed, Node) = 1 then
                     One := One + 1;
                  end if;
               when others =>
                  null;
            end case;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Mixed, 1, "one mixed-prefix repetition was recognized");
      Landin.Testing.Check_Equal
        (Item, Three, 1, "`[of, other, of]` stays an ordinary literal");
      Landin.Testing.Check_Equal
        (Item, One, 1, "`[of + 1]` stays an ordinary literal");
   end Mixed_Repetition_Preserves_Contextual_Of;

   ------------------------------------------------------------------
   --  Ordinary-struct literal recognition and retained refusals
   ------------------------------------------------------------------

   procedure Struct_Literal_Shapes_Are_Refused_Once
     (Item : in out Landin.Testing.Context);

   procedure Struct_Literal_Shapes_Are_Refused_Once
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Program
        (Text : String; Expected : String; Because : String);

      procedure Check_Program
        (Text : String; Expected : String; Because : String)
      is
         Codes : Unbounded.Unbounded_String;
         Total : Natural;
         Nodes : Natural;
         Held  : Boolean;
      begin
         Read_And_Parse (Text, Codes, Total, Nodes, Held);
         Landin.Testing.Check (Item, Held, Because & ": the tree is sound");
         Landin.Testing.Check (Item, Nodes > 0, Because & ": a tree exists");
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Codes), Expected,
            Because & ": the intended refusal owns the report");
      end Check_Program;
   begin
      Check_Program
        ("point: type = struct" & ASCII.LF
         & "  x: i32" & ASCII.LF
         & "  y: i32" & ASCII.LF
         & "end point" & ASCII.LF
         & "origin: point = (x: 1, y: (2))" & ASCII.LF,
         "", "a nested field image");

      Check_Program
        ("point: type = struct" & ASCII.LF
         & "  x: i32" & ASCII.LF
         & "end point" & ASCII.LF
         & "origin: point = (x: 1",
         "L0103", "a truncated field image");

      Check_Program
        ("point: type = struct" & ASCII.LF
         & "  x: i32" & ASCII.LF
         & "end point" & ASCII.LF
         & "origin: point = point(x: 1)" & ASCII.LF,
         "", "call-shaped construction");

      Check_Program
        ("point: type = struct" & ASCII.LF
         & "  x: i32" & ASCII.LF
         & "end point" & ASCII.LF
         & "first: point = (x: 1)[0]" & ASCII.LF
         & "second: point = point(x: 1)[0]" & ASCII.LF,
         "L0010, L0010", "indexes after refused field images");

      Check_Program
        ("point: type = struct" & ASCII.LF
         & "  x: i32" & ASCII.LF
         & "end point" & ASCII.LF
         & "origin: point = point(x: 1) +",
         "L0102", "an error following a construction");

      Check_Program
        ("add: (x: i32, y: i32) -> (sum: i32) =" & ASCII.LF
         & "  sum = x + y" & ASCII.LF
         & "end add" & ASCII.LF
         & "f: (of: i32) -> (r: i32) =" & ASCII.LF
         & "  r = add((of), (of + 1)) + (of - 1)" & ASCII.LF
         & "end f" & ASCII.LF,
         "", "ordinary parentheses, calls and a binding named `of`");
   end Struct_Literal_Shapes_Are_Refused_Once;

   ------------------------------------------------------------------
   --  Contextual ordinary-struct variant-part refusal
   ------------------------------------------------------------------

   procedure Variant_Parts_Are_Parsed
     (Item : in out Landin.Testing.Context);

   procedure Variant_Parts_Are_Parsed
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Program
        (Text : String; Expected : String; Because : String);

      procedure Check_Program
        (Text : String; Expected : String; Because : String)
      is
         Codes : Unbounded.Unbounded_String;
         Total : Natural;
         Nodes : Natural;
         Held  : Boolean;
      begin
         Read_And_Parse (Text, Codes, Total, Nodes, Held);
         Landin.Testing.Check (Item, Held, Because & ": the tree is sound");
         Landin.Testing.Check (Item, Nodes > 0, Because & ": a tree exists");
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Codes), Expected,
            Because & ": the variant part has the expected reports");
      end Check_Program;
   begin
      Check_Program
        ("figure: type = struct" & ASCII.LF
         & "  label: u8" & ASCII.LF
         & "  kind: variant" & ASCII.LF
         & "    circle: (radius: i32) |" & ASCII.LF
         & "    rectangle: (width: i32, height: i32)" & ASCII.LF
         & "  end kind" & ASCII.LF
         & "  ready: bool" & ASCII.LF
         & "end figure" & ASCII.LF
         & "after: u8" & ASCII.LF,
         "", "payload cases and a following common field");

      Check_Program
        ("node: type = struct" & ASCII.LF
         & "  kind: variant" & ASCII.LF
         & "    leaf |" & ASCII.LF
         & "    branch: (first: u32, count: u32)" & ASCII.LF
         & "  end kind" & ASCII.LF
         & "end node" & ASCII.LF,
         "", "a bare case before a payload case");

      Check_Program
        ("empty: type = struct" & ASCII.LF
         & "  kind: variant" & ASCII.LF
         & "  end kind" & ASCII.LF
         & "end empty" & ASCII.LF,
         "L0101", "an empty variant part");

      Check_Program
        ("single: type = struct" & ASCII.LF
         & "  kind: variant" & ASCII.LF
         & "    circle: (radius: i32)" & ASCII.LF
         & "  end kind" & ASCII.LF
         & "end single" & ASCII.LF,
         "", "a single payload case before its closer");

      Check_Program
         ("broken: type = struct" & ASCII.LF
         & "  kind: variant" & ASCII.LF
         & "    leaf" & ASCII.LF
         & "  end kinds" & ASCII.LF
         & "end broken" & ASCII.LF
         & "after: u8 =",
         "L0109, L0102", "a misspelled part closer preserves later input");

      Check_Program
        ("variant: type = u8" & ASCII.LF
         & "holder: type = struct" & ASCII.LF
         & "  kind: variant" & ASCII.LF
         & "  next: u8" & ASCII.LF
         & "end holder" & ASCII.LF
         & "only: type = struct" & ASCII.LF
         & "  kind: variant" & ASCII.LF
         & "end only" & ASCII.LF,
         "", "`variant` remains an ordinary contextual type name");

      Check_Program
        ("variant: type = u8" & ASCII.LF
         & "separate: type = struct" & ASCII.LF
         & "  kind: variant" & ASCII.LF
         & "  next: (x: i32)" & ASCII.LF
         & "end separate" & ASCII.LF,
         "L0010", "a following inline struct keeps its own refusal");
   end Variant_Parts_Are_Parsed;

   procedure Match_Statements_Are_Parsed
     (Item : in out Landin.Testing.Context);

   procedure Match_Statements_Are_Parsed
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Program
        (Text : String; Expected : String; Because : String);

      procedure Check_Program
        (Text : String; Expected : String; Because : String)
      is
         Codes : Unbounded.Unbounded_String;
         Total : Natural;
         Nodes : Natural;
         Held  : Boolean;
      begin
         Read_And_Parse (Text, Codes, Total, Nodes, Held);
         Landin.Testing.Check (Item, Held, Because & ": the tree is sound");
         Landin.Testing.Check (Item, Nodes > 0, Because & ": a tree exists");
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Codes), Expected,
            Because & ": reports agree");
      end Check_Program;
   begin
      Check_Program
        ("f: (x: u8) -> none =" & ASCII.LF
         & "  match x" & ASCII.LF
         & "    leaf: _ = 1" & ASCII.LF
         & "    pair: if true then _ = 2 end if" & ASCII.LF
         & "  end match" & ASCII.LF
         & "end f" & ASCII.LF,
         "", "case arms each carry one statement");

      Check_Program
        ("f: (x: u8) -> none =" & ASCII.LF
         & "  match x" & ASCII.LF
         & "    pair(value): _ = value" & ASCII.LF
         & "  end match" & ASCII.LF
         & "end f" & ASCII.LF,
         "", "payload bindings are parsed in source order");
   end Match_Statements_Are_Parsed;

   ------------------------------------------------------------------
   --  D124: control forms in expression positions
   ------------------------------------------------------------------

   procedure Control_Expressions_Are_Parsed
     (Item : in out Landin.Testing.Context);

   procedure Control_Expressions_Are_Parsed
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add
          ("control-values.ldn",
           "f: (condition: bool, subject: u8) -> (result: i32) =" & ASCII.LF
           & "  if condition then" & ASCII.LF
           & "    begin" & ASCII.LF
           & "      local: i32 = 19" & ASCII.LF
           & "      local + 23" & ASCII.LF
           & "    end" & ASCII.LF
           & "  else" & ASCII.LF
           & "    match subject" & ASCII.LF
           & "      left: 42" & ASCII.LF
           & "      right: 21 + 21" & ASCII.LF
           & "    end match" & ASCII.LF
           & "  end if" & ASCII.LF
           & "end f" & ASCII.LF);
      Controls : Natural := 0;
      Values   : Natural := 0;
   begin
      Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Found);

      declare
         Parsed : constant Landin.Syntax.Tree :=
           Landin.Syntax.Parser.Parse (Stream, Names, Found);
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Diagnostics.Count (Found), 0,
            "if, match and bare begin values parse cleanly");

         for Node in Landin.Syntax.Node_Id'(1)
                     .. Landin.Syntax.Last_Node (Parsed)
         loop
            if Landin.Syntax.Kind (Parsed, Node)
                 in Landin.Syntax.If_Statement
                    | Landin.Syntax.Match_Statement
                    | Landin.Syntax.Bare_Block
            then
               Controls := Controls + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Syntax.Kind (Parsed, Node)
                    in Landin.Syntax.Expression_Kind,
                  "each control form is in the expression band");
            elsif Landin.Syntax.Kind (Parsed, Node) = Landin.Syntax.Block
              and then Landin.Syntax.Block_Value (Parsed, Node)
                         /= Landin.Syntax.No_Node
            then
               Values := Values + 1;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Controls, 3, "one if, match and bare block were built");
      Landin.Testing.Check_Equal
        (Item, Values, 5,
         "both if arms, both match arms and the bare block keep values");

      declare
         Codes : Unbounded.Unbounded_String;
         Total : Natural;
         Nodes : Natural;
         Held  : Boolean;
      begin
         Read_And_Parse
           ("f: () -> (result: i32) =" & ASCII.LF
            & "  begin" & ASCII.LF
            & "    42" & ASCII.LF,
            Codes, Total, Nodes, Held);
         Landin.Testing.Check
           (Item, Held and then Nodes > 0,
            "an unclosed bare block still yields a sound tree");
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Codes), "L0104, L0104",
            "the bare block and function each retain their missing closer");
      end;
   end Control_Expressions_Are_Parsed;

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

   --  Truncation exercises one shape of damage at every byte and no other.
   --  A recovering parser also has to survive bytes inserted, deleted or
   --  replaced inside otherwise real programs, and input with no program
   --  beneath it at all.  Fixed arithmetic rather than a host random source
   --  keeps the exact cases reproducible in debug, release and on every host.
   procedure Survives_Deterministic_Mutations
     (Item : in out Landin.Testing.Context);

   procedure Survives_Deterministic_Mutations
     (Item : in out Landin.Testing.Context)
   is
      type Random_Word is mod 2 ** 32;

      State : Random_Word := 16#7011_7501#;

      Mutations_Per_Program : constant Positive := 3;
      Random_Streams        : constant Positive := 512;
      Random_Length_Limit   : constant Positive := 96;

      Host      : Landin.Platform.Native.Native_Filesystem;
      Catalogue : Fixtures.Catalogue;
      Tried     : Natural := 0;
      Broken    : Natural := 0;

      function Pick (Limit : Positive) return Positive;
      function Byte return Character;
      procedure Check_Text (Text : String);

      function Pick (Limit : Positive) return Positive is
      begin
         State := State * 1_664_525 + 1_013_904_223;
         return Positive (Natural (State mod Random_Word (Limit)) + 1);
      end Pick;

      function Byte return Character
        is (Character'Val (Pick (256) - 1));

      procedure Check_Text (Text : String) is
         Codes : Unbounded.Unbounded_String;
         Total : Natural;
         Nodes : Natural;
         Held  : Boolean;
      begin
         Read_And_Parse (Text, Codes, Total, Nodes, Held);
         Tried := Tried + 1;

         if not Held or else Nodes = 0 then
            Broken := Broken + 1;
         end if;
      end Check_Text;
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

                  if Status = Landin.Platform.Read_Ok
                    and then Unbounded.Length (Content) > 0
                  then
                     for Mutation in 1 .. Mutations_Per_Program loop
                        declare
                           Mutated : Unbounded.Unbounded_String := Content;
                           Length  : constant Positive :=
                             Unbounded.Length (Mutated);
                           Site    : constant Positive := Pick (Length);
                        begin
                           case Mutation is
                              when 1 =>
                                 Mutated := Unbounded.Delete
                                   (Mutated, Site, Site);
                              when 2 =>
                                 Mutated := Unbounded.Replace_Slice
                                   (Mutated, Site, Site,
                                    String'(1 => Byte));
                              when 3 =>
                                 Mutated := Unbounded.Insert
                                   (Mutated, Pick (Length + 1),
                                    String'(1 => Byte));
                           end case;

                           Check_Text (Unbounded.To_String (Mutated));
                        end;
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;

      for Stream in 1 .. Random_Streams loop
         pragma Unreferenced (Stream);
         declare
            Text : Unbounded.Unbounded_String;
         begin
            for Position in 1 .. Pick (Random_Length_Limit) loop
               pragma Unreferenced (Position);
               Unbounded.Append (Text, Byte);
            end loop;

            Check_Text (Unbounded.To_String (Text));
         end;
      end loop;

      Landin.Testing.Check
        (Item, Tried > 1_000,
         "the corpus and raw bytes supplied deterministic mutations");
      Landin.Testing.Check_Equal
        (Item, Broken, 0,
         "every mutation yielded a tree whose invariants hold");
   end Survives_Deterministic_Mutations;

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

   ------------------------------------------------------------------
   --  The report, through the driver
   ------------------------------------------------------------------

   --  Every negative fixture names the exact ordered sequence of codes its
   --  report carries, and this is what holds the compiler to it.  It runs
   --  the whole frontend the way a user does -- Landin.Driver.Execute, with
   --  the program in a fake filesystem -- because the sequence a fixture
   --  pins is the sequence a user sees, and a case that assembled the
   --  stages itself could agree with the fixture while the driver did not.
   procedure Reports_Carry_The_Pinned_Codes
     (Item : in out Landin.Testing.Context);

   procedure Reports_Carry_The_Pinned_Codes
     (Item : in out Landin.Testing.Context)
   is
      Real      : Landin.Platform.Native.Native_Filesystem;
      Catalogue : Fixtures.Catalogue;
      Pinned    : Natural := 0;

      function Arguments_Of (First : String)
        return Landin.Platform.Path_List;

      --  The codes a rendered report carries, in the order it carries
      --  them.  Read out of the bytes rather than out of a list, because
      --  what a fixture pins is what a reader sees.
      function Codes_In (Text : String) return String;

      function Arguments_Of (First : String)
        return Landin.Platform.Path_List
      is
         Made : Landin.Platform.Path_List;
      begin
         Made.Append (First);
         return Made;
      end Arguments_Of;

      function Codes_In (Text : String) return String is
         Found : Unbounded.Unbounded_String;
         Mark  : constant String := "error[";
      begin
         for Start in Text'Range loop
            if Start + Mark'Length + 5 <= Text'Last
              and then Text (Start .. Start + Mark'Length - 1) = Mark
              and then Text (Start + Mark'Length + 5) = ']'
            then
               if Unbounded.Length (Found) > 0 then
                  Unbounded.Append (Found, ", ");
               end if;

               Unbounded.Append
                 (Found,
                  Text (Start + Mark'Length
                        .. Start + Mark'Length + 4));
            end if;
         end loop;

         return Unbounded.To_String (Found);
      end Codes_In;
   begin
      Fixtures.Discover (Catalogue, Corpus, Real);

      for Index in 1 .. Fixtures.Count (Catalogue) loop
         declare
            Fixture : constant Fixtures.Fixture :=
              Fixtures.Nth (Catalogue, Index);
            Class   : constant Fixtures.Fixture_Class :=
              Fixtures.Class (Fixture);
         begin
            if Class = Fixtures.Negative_Program
              and then Fixtures.Program (Fixture) /= ""
              and then Fixtures.Codes (Fixture) /= ""
            then
               declare
                  Path : constant String :=
                    Corpus & "/" & Fixtures.Class_Directory (Class) & "/"
                    & Fixtures.Name (Fixture) & "/"
                    & Fixtures.Program (Fixture);
                  Content : Unbounded.Unbounded_String;
                  Status  : Landin.Platform.Read_Status;
               begin
                  Real.Read_File (Path, Content, Status);

                  if Status /= Landin.Platform.Read_Ok then
                     Landin.Testing.Fail (Item, Path & " is unreadable");
                  else
                     declare
                        Host : Landin.Testing.Fakes.Fake_Filesystem;
                        Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
                     begin
                        Host.Add_File
                          ("program.ldn", Unbounded.To_String (Content));

                        declare
                           Ran : constant Landin.Driver.Outcome :=
                             Landin.Driver.Execute
                               (Arguments_Of ("program.ldn"), Host, Tools);
                        begin
                           Pinned := Pinned + 1;
                           Landin.Testing.Check_Equal
                             (Item,
                              Codes_In
                                (Unbounded.To_String (Ran.Report)),
                              Fixtures.Codes (Fixture),
                              Fixtures.Name (Fixture)
                              & ": the report carries the codes the"
                              & " fixture names");
                           Landin.Testing.Check_Equal
                             (Item, Ran.Status,
                              Landin.Driver.Status_Reported,
                              Fixtures.Name (Fixture)
                              & ": a rejected program exits reported");
                        end;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      Landin.Testing.Check
        (Item, Pinned >= 24,
         "every negative fixture that names codes was run");
   end Reports_Carry_The_Pinned_Codes;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "parser", "agrees with the corpus",
         Agrees_With_The_Corpus'Access);
      Landin.Testing.Register
        (Into, "parser", "preserves contextual of in mixed repetition",
         Mixed_Repetition_Preserves_Contextual_Of'Access);
      Landin.Testing.Register
        (Into, "parser", "parses struct literals and names refusals once",
         Struct_Literal_Shapes_Are_Refused_Once'Access);
      Landin.Testing.Register
        (Into, "parser", "parses contextual variant parts",
         Variant_Parts_Are_Parsed'Access);
      Landin.Testing.Register
        (Into, "parser", "parses tag-only match statements",
         Match_Statements_Are_Parsed'Access);
      Landin.Testing.Register
        (Into, "parser", "parses non-loop control expression values",
         Control_Expressions_Are_Parsed'Access);
      Landin.Testing.Register
        (Into, "parser", "survives every truncation",
         Survives_Every_Truncation'Access);
      Landin.Testing.Register
        (Into, "parser", "survives deterministic mutations",
         Survives_Deterministic_Mutations'Access);
      Landin.Testing.Register
        (Into, "parser", "deep nesting is reported",
         Deep_Nesting_Is_Reported'Access);
      Landin.Testing.Register
        (Into, "parser", "reports carry the pinned codes",
         Reports_Carry_The_Pinned_Codes'Access);
   end Register;

end Landin.Tests.Parser_Suite;
