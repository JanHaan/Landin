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
with Landin.Syntax.Dump;
with Landin.Syntax;
with Landin.Testing.Fixtures;
with Landin.Tokens.Lexer;
with Landin.Tokens;

package body Landin.Tests.Parser_Suite is

   package Unbounded renames Ada.Strings.Unbounded;
   package Fixtures renames Landin.Testing.Fixtures;

   use type Landin.Platform.Read_Status;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Source.Source_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Syntax.Parameter_Convention;
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
   --  Neutral direct labelled applications
   ------------------------------------------------------------------

   procedure Labeled_Applications_Keep_Both_Projections
     (Item : in out Landin.Testing.Context);

   procedure Labeled_Applications_Keep_Both_Projections
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add
          ("labelled.ldn",
           "f: () -> none =" & ASCII.LF
           & "  _ = target(" & ASCII.LF
           & "    scalar: u8," & ASCII.LF
           & "    nominal: packet," & ASCII.LF
           & "    nested: outer(inner(u8, 4), [2][3]u16)," & ASCII.LF
           & "    array: [4]u32," & ASCII.LF
           & "    signature: (x: i32) -> (r: u32)," & ASCII.LF
           & "    count: 4," & ASCII.LF
           & "    value: source(1 + 2))" & ASCII.LF
           & "  _ = target(1, named: 2)" & ASCII.LF
           & "  _ = target(named: 1, 2, 3)" & ASCII.LF
           & "  _ = target(1)" & ASCII.LF
           & "  _ = (x: 1)" & ASCII.LF
           & "end f" & ASCII.LF);
      Applications : Natural := 0;
      Pure_Calls   : Natural := 0;
      Bare_Structs : Natural := 0;
   begin
      Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Found);

      declare
         Parsed : constant Landin.Syntax.Tree :=
           Landin.Syntax.Parser.Parse (Stream, Names, Found);
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Diagnostics.Count (Found), 1,
            "positionals after a label diagnose once across the run");
         Landin.Testing.Check_Equal
           (Item,
            Landin.Diagnostics.Code
              (Landin.Diagnostics.Get
                 (Landin.Diagnostics.Sorted (Found), 1)),
            "L0112", "argument ordering owns its syntax diagnostic");

         for Node in Landin.Syntax.Node_Id'(1)
                     .. Landin.Syntax.Last_Node (Parsed)
         loop
            case Landin.Syntax.Kind (Parsed, Node) is
               when Landin.Syntax.Labeled_Application =>
                  Applications := Applications + 1;
                  Landin.Testing.Check
                    (Item,
                     Landin.Syntax.Kind
                       (Parsed, Landin.Syntax.Callee_Of (Parsed, Node))
                         = Landin.Syntax.Name_Reference,
                     "a labelled application retains its direct callee");

                  if Landin.Syntax.Argument_Count (Parsed, Node) = 7 then
                     declare
                        Scalar    : constant Landin.Syntax.Node_Id :=
                          Landin.Syntax.Nth_Argument (Parsed, Node, 1);
                        Nested    : constant Landin.Syntax.Node_Id :=
                          Landin.Syntax.Nth_Argument (Parsed, Node, 3);
                        Array_Arg : constant Landin.Syntax.Node_Id :=
                          Landin.Syntax.Nth_Argument (Parsed, Node, 4);
                        Signature : constant Landin.Syntax.Node_Id :=
                          Landin.Syntax.Nth_Argument (Parsed, Node, 5);
                        Fixed     : constant Landin.Syntax.Node_Id :=
                          Landin.Syntax.Nth_Argument (Parsed, Node, 6);
                        Value     : constant Landin.Syntax.Node_Id :=
                          Landin.Syntax.Nth_Argument (Parsed, Node, 7);
                     begin
                        Landin.Testing.Check
                          (Item,
                           Landin.Syntax.Expression_Projection
                             (Parsed, Scalar) =
                               Landin.Syntax.Type_Projection (Parsed, Scalar),
                           "a bare reference shares its two projections");
                        Landin.Testing.Check
                          (Item,
                           Landin.Syntax.Expression_Projection
                             (Parsed, Nested) =
                               Landin.Syntax.Type_Projection (Parsed, Nested),
                           "a nested positional application is one subtree");
                        Landin.Testing.Check
                          (Item,
                           Landin.Syntax.Expression_Projection
                             (Parsed, Array_Arg) = Landin.Syntax.No_Node
                           and then Landin.Syntax.Kind
                             (Parsed,
                              Landin.Syntax.Type_Projection
                                (Parsed, Array_Arg)) =
                                  Landin.Syntax.Array_Type,
                           "a fixed array has only its type projection");
                        Landin.Testing.Check
                          (Item,
                           Landin.Syntax.Expression_Projection
                             (Parsed, Signature) = Landin.Syntax.No_Node
                           and then Landin.Syntax.Kind
                             (Parsed,
                              Landin.Syntax.Type_Projection
                                (Parsed, Signature)) =
                                  Landin.Syntax.Function_Type,
                           "a full signature has only its type projection");
                        Landin.Testing.Check
                          (Item,
                           Landin.Syntax.Expression_Projection
                             (Parsed, Fixed) /= Landin.Syntax.No_Node
                           and then Landin.Syntax.Type_Projection
                             (Parsed, Fixed) = Landin.Syntax.No_Node,
                           "a fixed integer remains expression syntax");
                        Landin.Testing.Check
                          (Item,
                           Landin.Syntax.Expression_Projection
                             (Parsed, Value) =
                               Landin.Syntax.Type_Projection (Parsed, Value),
                           "a direct call with a fixed expression remains"
                           & " neutral until its callee is known");
                     end;
                  elsif Landin.Syntax.Argument_Count (Parsed, Node) = 2 then
                     declare
                        First : constant Landin.Syntax.Node_Id :=
                          Landin.Syntax.Nth_Argument (Parsed, Node, 1);
                     begin
                        Landin.Testing.Check
                          (Item,
                           Landin.Syntax.Argument_Label (Parsed, First) =
                             Landin.Source.Names.No_Name,
                           "a leading positional argument keeps no label");
                     end;
                  end if;
               when Landin.Syntax.Call =>
                  Pure_Calls := Pure_Calls + 1;
               when Landin.Syntax.Struct_Literal =>
                  Bare_Structs := Bare_Structs + 1;
               when others =>
                  null;
            end case;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Applications, 3,
         "every direct argument list containing a label stays neutral");
      Landin.Testing.Check
        (Item, Pure_Calls >= 3,
         "pure positional calls, including nested calls, stay Call nodes");
      Landin.Testing.Check_Equal
        (Item, Bare_Structs, 1,
         "a bare labelled parenthesis stays a struct literal");
   end Labeled_Applications_Keep_Both_Projections;

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
   --  [1100]: deferred call syntax
   ------------------------------------------------------------------

   procedure Defer_Statements_Retain_Their_Calls
     (Item : in out Landin.Testing.Context);

   procedure Defer_Statements_Retain_Their_Calls
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add
          ("defer.ldn",
           "cleanup: (value: i32) -> none =" & ASCII.LF
           & "    _ = value" & ASCII.LF
           & "end cleanup" & ASCII.LF
           & "f: () -> none =" & ASCII.LF
           & "    defer cleanup(42)" & ASCII.LF
           & "end f" & ASCII.LF);
      Seen : Natural := 0;
   begin
      Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Found);

      declare
         Parsed : constant Landin.Syntax.Tree :=
           Landin.Syntax.Parser.Parse (Stream, Names, Found);
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Diagnostics.Count (Found), 0,
            "a deferred call parses cleanly");

         for Node in Landin.Syntax.Node_Id'(1)
                     .. Landin.Syntax.Last_Node (Parsed)
         loop
            if Landin.Syntax.Kind (Parsed, Node)
                 = Landin.Syntax.Defer_Statement
            then
               Seen := Seen + 1;
               declare
                  Call : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Deferred_Call (Parsed, Node);
               begin
                  Landin.Testing.Check
                    (Item,
                     Landin.Syntax.Kind (Parsed, Call) = Landin.Syntax.Call
                     and then Landin.Syntax.Argument_Count (Parsed, Call) = 1,
                     "the defer node retains its one call and argument");
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "one defer statement was built");

      declare
         Codes : Unbounded.Unbounded_String;
         Total, Nodes : Natural;
         Held : Boolean;
      begin
         Read_And_Parse
           ("cleanup: () -> none = end cleanup" & ASCII.LF
            & "f: () -> none = defer cleanup end f" & ASCII.LF,
            Codes, Total, Nodes, Held);
         Landin.Testing.Check
           (Item, Held and then Nodes > 0,
            "a malformed deferred call still yields a sound tree");
         Landin.Testing.Check_Equal
           (Item, Total, 1, "the malformed defer reports once");
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Codes), "L0103",
            "the missing call parentheses keep the token diagnostic");
      end;
   end Defer_Statements_Retain_Their_Calls;

   ------------------------------------------------------------------
   --  [1110]: failure-only cleanup syntax
   ------------------------------------------------------------------

   procedure Undo_Statements_Retain_Their_Calls
     (Item : in out Landin.Testing.Context);

   procedure Undo_Statements_Retain_Their_Calls
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add
          ("undo.ldn",
           "cleanup: (value: i32) -> none =" & ASCII.LF
           & "    _ = value" & ASCII.LF
           & "end cleanup" & ASCII.LF
           & "f: () -> none =" & ASCII.LF
           & "    undo cleanup(42)" & ASCII.LF
           & "end f" & ASCII.LF);
      Seen : Natural := 0;
   begin
      Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Found);

      declare
         Parsed : constant Landin.Syntax.Tree :=
           Landin.Syntax.Parser.Parse (Stream, Names, Found);
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Diagnostics.Count (Found), 0,
            "an undo call parses cleanly");

         for Node in Landin.Syntax.Node_Id'(1)
                     .. Landin.Syntax.Last_Node (Parsed)
         loop
            if Landin.Syntax.Kind (Parsed, Node)
                 = Landin.Syntax.Undo_Statement
            then
               Seen := Seen + 1;
               declare
                  Call : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Undo_Call (Parsed, Node);
               begin
                  Landin.Testing.Check
                    (Item,
                     Landin.Syntax.Kind (Parsed, Call) = Landin.Syntax.Call
                     and then Landin.Syntax.Argument_Count (Parsed, Call) = 1,
                     "the undo node retains its one call and argument");
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "one undo statement was built");

      declare
         Codes : Unbounded.Unbounded_String;
         Total, Nodes : Natural;
         Held : Boolean;
      begin
         Read_And_Parse
           ("cleanup: () -> none = end cleanup" & ASCII.LF
            & "f: () -> none = undo cleanup end f" & ASCII.LF,
            Codes, Total, Nodes, Held);
         Landin.Testing.Check
           (Item, Held and then Nodes > 0,
            "a malformed undo call still yields a sound tree");
         Landin.Testing.Check_Equal
           (Item, Total, 1, "the malformed undo reports once");
         Landin.Testing.Check_Equal
           (Item, Unbounded.To_String (Codes), "L0103",
            "the missing undo call parentheses keep the token diagnostic");
      end;
   end Undo_Statements_Retain_Their_Calls;

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

   --  D135's first increment is syntax-only: aliases hold both formal
   --  kinds, array bounds can name a fixed formal, and applications retain
   --  the positional mix without pretending substitution exists yet.
   procedure Parameterized_Type_Aliases_Are_Parsed
     (Item : in out Landin.Testing.Context);

   procedure Parameterized_Structs_Are_Parsed
     (Item : in out Landin.Testing.Context);

   procedure Parameterized_Alias_Errors_Keep_Grammar_Boundaries
     (Item : in out Landin.Testing.Context);

   procedure Reference_Signature_Syntax_Is_Represented
     (Item : in out Landin.Testing.Context);

   procedure Parameterized_Type_Aliases_Are_Parsed
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add
          ("aliases.ldn",
           "bytes: type (t: type, fixed n: u32) = [n * 2]t" & ASCII.LF
           & "direct: type = [64 * 1024]u8" & ASCII.LF
           & "four: type = bytes(u8, 4)" & ASCII.LF);
   begin
      Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Found);

      declare
         Parsed : constant Landin.Syntax.Tree :=
           Landin.Syntax.Parser.Parse (Stream, Names, Found);
         Bytes : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Parsed, 1);
         T : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Type_Formal (Parsed, Bytes, 1);
         N : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Type_Formal (Parsed, Bytes, 2);
         Alias_Body : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Parsed, Bytes);
         Bound : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Bound_Of (Parsed, Alias_Body);
         Direct : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type
             (Parsed, Landin.Syntax.Nth_Declaration (Parsed, 2));
         Application : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type
             (Parsed, Landin.Syntax.Nth_Declaration (Parsed, 3));
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Diagnostics.Count (Found), 0,
            "parameterized aliases parse without a syntax report");
         Landin.Testing.Check_Equal
           (Item, Landin.Syntax.Type_Formal_Count (Parsed, Bytes), 2,
            "the alias retains both formals");
         Landin.Testing.Check
           (Item, Landin.Syntax.Kind (Parsed, T) = Landin.Syntax.Type_Formal
             and then Landin.Syntax.Kind (Parsed, N)
                        = Landin.Syntax.Fixed_Formal,
            "the formal kinds retain type and fixed spelling");
         Landin.Testing.Check
           (Item, Landin.Syntax.Kind
             (Parsed, Landin.Syntax.Declared_Type (Parsed, N))
                = Landin.Syntax.Type_Name,
            "a fixed formal retains its declared type");
         Landin.Testing.Check
           (Item,
            Landin.Syntax.Kind (Parsed, Alias_Body)
              = Landin.Syntax.Array_Type
             and then Landin.Syntax.Kind (Parsed, Bound)
                        = Landin.Syntax.Multiply
             and then Landin.Syntax.Kind
               (Parsed, Landin.Syntax.Left_Of (Parsed, Bound))
                  = Landin.Syntax.Name_Reference
             and then Landin.Syntax.Kind
               (Parsed, Landin.Syntax.Right_Of (Parsed, Bound))
                  = Landin.Syntax.Integer_Literal
             and then Landin.Syntax.Kind
               (Parsed, Landin.Syntax.Element_Of (Parsed, Alias_Body))
                  = Landin.Syntax.Type_Reference,
            "the alias body retains its fixed expression and type formal");
         Landin.Testing.Check
           (Item, Landin.Syntax.Kind (Parsed, Direct)
                    = Landin.Syntax.Array_Type
             and then Landin.Syntax.Kind
               (Parsed, Landin.Syntax.Bound_Of (Parsed, Direct))
                  = Landin.Syntax.Multiply,
            "a concrete arithmetic bound is parsed as an expression");
         Landin.Testing.Check
           (Item, Landin.Syntax.Kind (Parsed, Application)
                    = Landin.Syntax.Type_Application
             and then Landin.Syntax.Type_Argument_Count (Parsed, Application)
                        = 2
             and then Landin.Syntax.Kind
               (Parsed, Landin.Syntax.Applied_Type (Parsed, Application))
                  = Landin.Syntax.Type_Reference
             and then Landin.Syntax.Kind
               (Parsed, Landin.Syntax.Nth_Type_Argument
                  (Parsed, Application, 1)) = Landin.Syntax.Type_Name
             and then Landin.Syntax.Kind
               (Parsed, Landin.Syntax.Nth_Type_Argument
                  (Parsed, Application, 2)) = Landin.Syntax.Integer_Literal,
            "the application retains its positional type and fixed arguments");
      end;

      declare
         Codes : Unbounded.Unbounded_String;
         Total : Natural;
         Nodes : Natural;
         Held  : Boolean;
      begin
         Read_And_Parse
           ("f: (value: t, fixed n: u32, t: type) -> none = end f"
            & ASCII.LF,
            Codes, Total, Nodes, Held);
         Landin.Testing.Check
           (Item, Held and then Nodes > 0
             and then Unbounded.To_String (Codes) = "",
            "generic routine formals parse with no static-call spelling");
      end;

      declare
         Sources : Landin.Source.Sets.Source_Set;
         Names   : Landin.Source.Names.Table;
         Stream  : Landin.Tokens.Token_Stream;
         Found   : Landin.Diagnostics.Diagnostic_List;
         Id      : constant Landin.Source.Source_Id :=
           Sources.Add
             ("bound-recovery.ldn", "bad: type = [1 + ]u8" & ASCII.LF);
      begin
         Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
         Landin.Diagnostics.Lexical.Report (Stream, Found);
         declare
            Parsed : constant Landin.Syntax.Tree :=
              Landin.Syntax.Parser.Parse (Stream, Names, Found);
            Declaration : constant Landin.Syntax.Node_Id :=
              Landin.Syntax.Nth_Declaration (Parsed, 1);
            Array_Node : constant Landin.Syntax.Node_Id :=
              Landin.Syntax.Declared_Type (Parsed, Declaration);
            Bound_Node : constant Landin.Syntax.Node_Id :=
              Landin.Syntax.Bound_Of (Parsed, Array_Node);
         begin
            Landin.Testing.Check
              (Item, Landin.Diagnostics.Count (Found) = 1
                and then Landin.Diagnostics.Code
                  (Landin.Diagnostics.Get (Found, 1)) = "L0102",
               "a missing bound operand has one expression report");
            Landin.Testing.Check
              (Item, Landin.Syntax.Kind (Parsed, Array_Node)
                       = Landin.Syntax.Array_Type
                and then Landin.Syntax.Kind (Parsed, Bound_Node)
                           = Landin.Syntax.Add
                and then Landin.Syntax.Kind
                  (Parsed, Landin.Syntax.Right_Of (Parsed, Bound_Node))
                           = Landin.Syntax.Error_Expression
                and then Landin.Syntax.Kind
                  (Parsed, Landin.Syntax.Element_Of (Parsed, Array_Node))
                           = Landin.Syntax.Type_Name,
               "the array closer and valid element survive bound recovery");
         end;
      end;
   end Parameterized_Type_Aliases_Are_Parsed;

   --  The parser uses the same declaration, formal, struct-body and
   --  application nodes it already uses separately.  This is deliberately
   --  a parser-only seam: checker support for the nominal instance is later.
   procedure Parameterized_Structs_Are_Parsed
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add
          ("structs.ldn",
           "pair: type (left: type, fixed count: left) = struct" & ASCII.LF
           & "    first: left" & ASCII.LF
           & "    rest: [count]left" & ASCII.LF
           & "end pair" & ASCII.LF
           & "sample: pair(u8, 2)" & ASCII.LF);
   begin
      Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Found);

      declare
         Parsed : constant Landin.Syntax.Tree :=
           Landin.Syntax.Parser.Parse (Stream, Names, Found);
         Pair : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Parsed, 1);
         Left : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Type_Formal (Parsed, Pair, 1);
         Count : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Type_Formal (Parsed, Pair, 2);
         Struct_Body : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Parsed, Pair);
         First : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Field (Parsed, Struct_Body, 1);
         Rest : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Field (Parsed, Struct_Body, 2);
         Application : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type
             (Parsed, Landin.Syntax.Nth_Declaration (Parsed, 2));
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Diagnostics.Count (Found), 0,
            "a parameterized struct parses without a syntax report");
         Landin.Testing.Check
           (Item, Landin.Syntax.Type_Formal_Count (Parsed, Pair) = 2
             and then Landin.Syntax.Kind (Parsed, Left)
                        = Landin.Syntax.Type_Formal
             and then Landin.Syntax.Kind (Parsed, Count)
                        = Landin.Syntax.Fixed_Formal,
            "the parameterized struct retains both formal kinds");
         Landin.Testing.Check
           (Item, Landin.Syntax.Kind (Parsed, Struct_Body)
                    = Landin.Syntax.Struct_Body
             and then Landin.Syntax.Field_Count (Parsed, Struct_Body) = 2
             and then Landin.Syntax.Kind
               (Parsed, Landin.Syntax.Declared_Type (Parsed, First))
                  = Landin.Syntax.Type_Reference
             and then Landin.Syntax.Kind
               (Parsed, Landin.Syntax.Declared_Type (Parsed, Rest))
                  = Landin.Syntax.Array_Type,
            "the struct body retains field types that use its formals");
         Landin.Testing.Check
           (Item, Landin.Syntax.Kind (Parsed, Application)
                    = Landin.Syntax.Type_Application
             and then Landin.Syntax.Kind
               (Parsed, Landin.Syntax.Applied_Type (Parsed, Application))
                  = Landin.Syntax.Type_Reference
             and then Landin.Syntax.Type_Argument_Count
               (Parsed, Application) = 2
             and then Landin.Syntax.Kind
               (Parsed, Landin.Syntax.Nth_Type_Argument
                  (Parsed, Application, 1)) = Landin.Syntax.Type_Name
             and then Landin.Syntax.Kind
               (Parsed, Landin.Syntax.Nth_Type_Argument
                  (Parsed, Application, 2))
                    = Landin.Syntax.Integer_Literal,
            "a parameterized struct application retains positional arguments");
      end;
   end Parameterized_Structs_Are_Parsed;

   --  R2.50's first increment is representation only.  This case keeps the
   --  pointer/slice permission bit, parameter modifiers, return-source run,
   --  generic signature positions, `addr` place and ordinary `.val` member
   --  selection distinct without asking checking what any of them means.
   procedure Reference_Signature_Syntax_Is_Represented
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add
          ("references.ldn",
           "item: type = u8" & ASCII.LF
           & "callback: type = (escaping inout owner: ptr mut item,"
           & " in source: []item, sink consumed: ptr item) ->"
           & " (view: []mut item from owner, source)" & ASCII.LF
           & "project: (t: type, fixed n: usize,"
           & " escaping inout owner: ptr mut t, source: []t) ->"
           & " (view: []mut t from owner, source) =" & ASCII.LF
           & "    view = source" & ASCII.LF
           & "end project" & ASCII.LF
           & "pointer_list: type = holder(ptr mut item, []item)" & ASCII.LF
           & "locate: (in value: item) -> (p: ptr item from value) ="
           & ASCII.LF
           & "    p = addr value.field.val" & ASCII.LF
           & "end locate" & ASCII.LF
           & "slice_forms: () -> none =" & ASCII.LF
           & "    mut data: [2]u8 = [1, 2]" & ASCII.LF
           & "    half: []mut u8 = data[0..<2]" & ASCII.LF
           & "    full: []mut u8 = data[0..1]" & ASCII.LF
           & "    empty: []u8 = []" & ASCII.LF
           & "    pointer: ptr u8 = ptr(1)" & ASCII.LF
           & "end slice_forms" & ASCII.LF);
   begin
      Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Found);

      declare
         Parsed : constant Landin.Syntax.Tree :=
           Landin.Syntax.Parser.Parse (Stream, Names, Found);
         Callback : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type
             (Parsed, Landin.Syntax.Nth_Declaration (Parsed, 2));
         Owner : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Parameter (Parsed, Callback, 1);
         Source : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Parameter (Parsed, Callback, 2);
         Consumed : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Parameter (Parsed, Callback, 3);
         Result_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Return (Parsed, Callback, 1);
         Result_Type : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Parsed, Result_Node);
         Project : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Parsed, 3);
         Application : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type
             (Parsed, Landin.Syntax.Nth_Declaration (Parsed, 4));
         Address : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Parsed, 5);
         Runs : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Body_Of (Parsed, Address);
         Assignment : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Statement (Parsed, Runs, 1);
         Address_Expression : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Value_Of (Parsed, Assignment);
         Pointee : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Operand_Of (Parsed, Address_Expression);
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Diagnostics.Count (Found), 0,
            "reference signature syntax parses without a report");
         Landin.Testing.Check
           (Item,
            Landin.Syntax.Kind (Parsed, Callback)
              = Landin.Syntax.Function_Type
            and then Landin.Syntax.Kind
              (Parsed, Landin.Syntax.Declared_Type (Parsed, Owner))
                = Landin.Syntax.Pointer_Type
            and then Landin.Syntax.Is_Referent_Mutable
              (Parsed, Landin.Syntax.Declared_Type (Parsed, Owner))
            and then Landin.Syntax.Is_Escaping (Parsed, Owner)
            and then Landin.Syntax.Convention_Of (Parsed, Owner)
              = Landin.Syntax.Inout_Convention
            and then Landin.Syntax.Convention_Of (Parsed, Source)
              = Landin.Syntax.Explicit_In
            and then Landin.Syntax.Convention_Of (Parsed, Consumed)
              = Landin.Syntax.Sink_Convention,
            "pointer permission and all written parameter modifiers remain");
         Landin.Testing.Check
           (Item,
            Landin.Syntax.Kind (Parsed, Result_Type)
              = Landin.Syntax.Slice_Type
            and then Landin.Syntax.Is_Referent_Mutable
              (Parsed, Result_Type)
            and then Landin.Syntax.Return_Source_Count
              (Parsed, Result_Node) = 2,
            "a mutable slice return retains both ordered source labels");
         Landin.Testing.Check
           (Item,
            Landin.Syntax.Generic_Formal_Count (Parsed, Project) = 2
            and then Landin.Syntax.Parameter_Count (Parsed, Project) = 2,
            "generic and runtime signature positions remain separate");
         Landin.Testing.Check
           (Item,
            Landin.Syntax.Kind (Parsed, Application)
              = Landin.Syntax.Type_Application
            and then Landin.Syntax.Kind
              (Parsed,
               Landin.Syntax.Nth_Type_Argument (Parsed, Application, 1))
                 = Landin.Syntax.Pointer_Type
            and then Landin.Syntax.Kind
              (Parsed,
               Landin.Syntax.Nth_Type_Argument (Parsed, Application, 2))
                 = Landin.Syntax.Slice_Type,
            "pointer and slice types remain positional generic arguments");
         Landin.Testing.Check
           (Item,
            Landin.Syntax.Kind (Parsed, Address_Expression)
              = Landin.Syntax.Address_Of
            and then Landin.Syntax.Kind (Parsed, Pointee)
              = Landin.Syntax.Member_Selection
            and then Landin.Source.Names.Spelling
              (Names, Landin.Syntax.Name (Parsed, Pointee)) = "val",
            "addr retains a place whose val is ordinary member selection");
         declare
            Half, Full, Empty, Converted : Natural := 0;
         begin
            for Node in Landin.Syntax.Node_Id'(1)
              .. Landin.Syntax.Last_Node (Parsed)
            loop
               case Landin.Syntax.Kind (Parsed, Node) is
                  when Landin.Syntax.Half_Open_Slice => Half := Half + 1;
                  when Landin.Syntax.Inclusive_Slice => Full := Full + 1;
                  when Landin.Syntax.Empty_Slice_Literal => Empty := Empty + 1;
                  when Landin.Syntax.Pointer_Conversion =>
                     Converted := Converted + 1;
                  when others => null;
               end case;
            end loop;
            Landin.Testing.Check
              (Item,
               Half = 1 and then Full = 1 and then Empty = 1
               and then Converted = 1,
               "slice bounds, empty slice and ptr conversion stay distinct");
         end;
      end;

      declare
         Codes : Unbounded.Unbounded_String;
         Total : Natural;
         Nodes : Natural;
         Held  : Boolean;
      begin
         Read_And_Parse
           ("broken: (escaping inout value: ptr mut) ->"
            & " (result: []mut u8 from) = end broken" & ASCII.LF
            & "next: type = ptr u8" & ASCII.LF,
            Codes, Total, Nodes, Held);
         Landin.Testing.Check
           (Item, Held and then Nodes > 0 and then Total >= 1,
            "missing referents and from names recover into a sound tree");
      end;
   end Reference_Signature_Syntax_Is_Represented;

   --  R2.60 begins at syntax only.  This holds the complete contextual
   --  source shape -- including names that remain ordinary outside it --
   --  without asking resolution or checking to validate a conformance.
   procedure Concepts_And_Conformances_Are_Represented
     (Item : in out Landin.Testing.Context);

   procedure Concepts_And_Conformances_Are_Represented
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Landin.Tokens.Token_Stream;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add
          ("concepts.ldn",
           "ordered: type = concept (t: type)" & ASCII.LF
           & "  less: (left: t, right: t) -> (yes: bool)" & ASCII.LF
           & "  equal: (left: t, right: t) -> (yes: bool)" & ASCII.LF
           & "end ordered" & ASCII.LF
           & "sortable: type = concept (t: type is ordered) is ordered"
           & ASCII.LF
           & "  sort: (data: []mut t) -> none" & ASCII.LF
           & "end sortable" & ASCII.LF
           & "(t: type is ordered, fixed n: u32) list(t) is iterable"
           & " (cur: usize, item: t, first: list_first(t), next: list_next)"
           & ASCII.LF
           & "i32 is ordered (less: less_i32, equal: equal_i32)" & ASCII.LF);
   begin
      Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Found);

      declare
         Parsed : constant Landin.Syntax.Tree :=
           Landin.Syntax.Parser.Parse (Stream, Names, Found);
         Ordered : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Parsed, 1);
         Sortable : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Parsed, 2);
         Parameterized : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Parsed, 3);
         Direct : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Parsed, 4);
         Formal : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Concept_Formal (Parsed, Sortable, 1);
         Requirement_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Concept_Entry (Parsed, Ordered, 1);
         Bound : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Conformance_Binder
             (Parsed, Parameterized, 1);
         First : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Conformance_Entry
             (Parsed, Parameterized, 1);
         Printed : constant String := Landin.Syntax.Dump.Text (Parsed, Names);
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Diagnostics.Count (Found), 0,
            "concepts and conformances are syntax-only clean input");
         Landin.Testing.Check
           (Item,
            Landin.Syntax.Kind (Parsed, Ordered)
              = Landin.Syntax.Concept_Declaration
            and then Landin.Syntax.Concept_Formal_Count (Parsed, Ordered) = 1
            and then Landin.Syntax.Concept_Parent_Count (Parsed, Ordered) = 0
            and then Landin.Syntax.Concept_Entry_Count (Parsed, Ordered) = 2,
            "a concept retains ordered formals, parents and requirements");
         Landin.Testing.Check
           (Item,
            Landin.Syntax.Kind (Parsed, Formal) = Landin.Syntax.Type_Formal
            and then Landin.Syntax.Kind
              (Parsed, Landin.Syntax.Constraint_Of (Parsed, Formal))
                = Landin.Syntax.Concept_Reference
            and then Landin.Syntax.Kind
              (Parsed, Landin.Syntax.Nth_Concept_Parent
                 (Parsed, Sortable, 1)) = Landin.Syntax.Concept_Reference,
            "direct type constraints and composition retain concept names");
         Landin.Testing.Check
           (Item,
            Landin.Syntax.Kind (Parsed, Requirement_Node)
              = Landin.Syntax.Concept_Entry
            and then Landin.Syntax.Parameter_Count
              (Parsed, Requirement_Node) = 2
            and then Landin.Syntax.Return_Count
              (Parsed, Requirement_Node) = 1,
            "a requirement has a complete signature but no function body");
         Landin.Testing.Check
           (Item,
            Landin.Syntax.Kind (Parsed, Parameterized)
              = Landin.Syntax.Conformance_Declaration
            and then Landin.Syntax.Conformance_Binder_Count
              (Parsed, Parameterized) = 2
            and then Landin.Syntax.Kind
              (Parsed,
               Landin.Syntax.Conforming_Type (Parsed, Parameterized))
                = Landin.Syntax.Type_Application
            and then Landin.Syntax.Kind
              (Parsed,
               Landin.Syntax.Conforming_Concept (Parsed, Parameterized))
                = Landin.Syntax.Concept_Reference
            and then Landin.Syntax.Kind (Parsed, Bound)
              = Landin.Syntax.Type_Formal
            and then Landin.Syntax.Conformance_Entry_Count
              (Parsed, Parameterized) = 4
            and then Landin.Syntax.Kind
              (Parsed, Landin.Syntax.Conformance_RHS (Parsed, First))
                = Landin.Syntax.Name_Reference,
            "a parameterized conformance preserves its binder and RHS run");
         Landin.Testing.Check
           (Item,
            Landin.Syntax.Kind (Parsed, Direct)
              = Landin.Syntax.Conformance_Declaration
            and then Landin.Syntax.Conformance_Binder_Count (Parsed, Direct)
              = 0
            and then Landin.Syntax.Conformance_Entry_Count (Parsed, Direct)
              = 2
            and then Contains (Printed, "CONCEPT_DECLARATION")
            and then Contains (Printed, "CONFORMANCE_ENTRY"),
            "the generic syntax dump includes the new node kinds and slots");
      end;

      declare
         Codes : Unbounded.Unbounded_String;
         Total : Natural;
         Nodes : Natural;
         Held  : Boolean;
      begin
         Read_And_Parse
           ("bad: type = concept (T: type)" & ASCII.LF
            & "  less: (left: T) -> none" & ASCII.LF
            & "next: type = u8" & ASCII.LF,
            Codes, Total, Nodes, Held);
         Landin.Testing.Check
           (Item, Held and then Nodes > 0,
            "an unclosed concept keeps a postorder sound tree");

         Read_And_Parse
           ("concept: u8 = 1" & ASCII.LF
            & "is: u8 = concept" & ASCII.LF,
            Codes, Total, Nodes, Held);
         Landin.Testing.Check
           (Item, Held and then Nodes > 0 and then Total = 0,
            "concept and is remain ordinary identifiers outside context");
      end;
   end Concepts_And_Conformances_Are_Represented;

   procedure Parameterized_Alias_Errors_Keep_Grammar_Boundaries
     (Item : in out Landin.Testing.Context)
   is
      procedure Parse
        (Text : String;
         Into : out Unbounded.Unbounded_String;
         Declarations : out Natural;
         Second : out Landin.Syntax.Node_Kind);

      procedure Parse
        (Text : String;
         Into : out Unbounded.Unbounded_String;
         Declarations : out Natural;
         Second : out Landin.Syntax.Node_Kind)
      is
         Sources : Landin.Source.Sets.Source_Set;
         Names   : Landin.Source.Names.Table;
         Stream  : Landin.Tokens.Token_Stream;
         Found   : Landin.Diagnostics.Diagnostic_List;
         Id      : constant Landin.Source.Source_Id :=
           Sources.Add ("recovery.ldn", Text);
      begin
         Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
         Landin.Diagnostics.Lexical.Report (Stream, Found);

         declare
            Parsed : constant Landin.Syntax.Tree :=
              Landin.Syntax.Parser.Parse (Stream, Names, Found);
         begin
            Declarations := Landin.Syntax.Declaration_Count (Parsed);
            Second :=
              (if Declarations >= 2
               then Landin.Syntax.Kind
                 (Parsed, Landin.Syntax.Nth_Declaration (Parsed, 2))
               else Landin.Syntax.Error_Declaration);
            Into := Unbounded.To_Unbounded_String
              (Landin.Diagnostics.Code
                 (Landin.Diagnostics.Get (Found, 1)));
         end;
      end Parse;

      Code : Unbounded.Unbounded_String;
      Declarations : Natural;
      Second : Landin.Syntax.Node_Kind;
   begin
      Parse
        ("broken: type (t: type = t" & ASCII.LF
         & "next: type = u8" & ASCII.LF,
         Code, Declarations, Second);
      Landin.Testing.Check
        (Item, Declarations = 2
          and then Second = Landin.Syntax.Type_Declaration,
         "a malformed formal list preserves the next declaration");

      Parse
        ("problem: atom" & ASCII.LF
         & "bad: type (t: type) = problem | problem" & ASCII.LF,
         Code, Declarations, Second);
      Landin.Testing.Check
        (Item, Declarations = 2
          and then Second = Landin.Syntax.Type_Declaration
          and then Unbounded.To_String (Code) = "L0010",
         "a parameterized atom union is refused, not parsed as a union");
   end Parameterized_Alias_Errors_Keep_Grammar_Boundaries;

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
        (Into, "parser", "keeps neutral labelled applications",
         Labeled_Applications_Keep_Both_Projections'Access);
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
        (Into, "parser", "defer statements retain their calls",
         Defer_Statements_Retain_Their_Calls'Access);
      Landin.Testing.Register
        (Into, "parser", "undo statements retain their calls",
         Undo_Statements_Retain_Their_Calls'Access);
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
        (Into, "parser", "parses parameterized type aliases",
         Parameterized_Type_Aliases_Are_Parsed'Access);
      Landin.Testing.Register
        (Into, "parser", "parses parameterized struct type declarations",
         Parameterized_Structs_Are_Parsed'Access);
      Landin.Testing.Register
        (Into, "parser", "represents concepts and conformances",
         Concepts_And_Conformances_Are_Represented'Access);
      Landin.Testing.Register
        (Into, "parser", "parameterized aliases keep grammar boundaries",
         Parameterized_Alias_Errors_Keep_Grammar_Boundaries'Access);
      Landin.Testing.Register
        (Into, "parser", "reference signature syntax is represented",
         Reference_Signature_Syntax_Is_Represented'Access);
      Landin.Testing.Register
        (Into, "parser", "reports carry the pinned codes",
         Reports_Carry_The_Pinned_Codes'Access);
   end Register;

end Landin.Tests.Parser_Suite;
